local Surrogate = require("Modules.Optimizer.Surrogate")
local Features = require("Modules.Optimizer.SurrogateFeatures")
local json = require("dkjson")

describe("Optimizer learned ranker safety contract", function()
	local engine = {
		pobVersion = "3.29.0",
		pobBranch = "dev",
		dataVersion = "3.29",
		treeVersion = "3_29",
		manifestFingerprint = string.rep("a", 64),
	}

	local function makeModel(overrides)
		local model = {
			format = "pob-optimizer-surrogate",
		schemaVersion = 7,
		featurePolicy = "exact-pair-build-context-lineage-engine-manifest-v6",
			groupingPolicy = "reviewed-source-snapshot-union-v2",
			engine = {
				pobVersion = engine.pobVersion,
				pobBranch = engine.pobBranch,
				dataVersion = engine.dataVersion,
				treeVersion = engine.treeVersion,
				manifestFingerprint = engine.manifestFingerprint,
			},
			deterministic = true,
			trainingSourceLineages = 8,
			holdoutSourceLineages = 5,
			trainingRows = 128,
			holdoutRows = 50,
			validation = {
				status = "passed",
				heldOutSpearman = 0.84,
				topParetoRecall = 0.92,
				baselineInputOrderSpearman = 0.5,
				baselineInputOrderTopParetoRecall = 0.75,
				baselineNonRegression = true,
				baselineScoredSourceLineages = 5,
				baselineParetoScoredGroups = 5,
				baselineParetoUnscoredGroups = 0,
				heldOutCoverage = 0.88,
				heldOutRows = 50,
				scoredSourceLineages = 5,
			},
			InDomain = function() return true end,
			Rank = function(self, candidates)
				local ranked = { }
				for index = #candidates, 1, -1 do ranked[#ranked + 1] = candidates[index] end
				return ranked
			end,
		}
		for key, value in pairs(overrides or { }) do model[key] = value end
		return model
	end

	before_each(function() Surrogate.Disable() end)
	after_each(function() Surrogate.Disable() end)

	it("keeps the model disabled by default and preserves deterministic order", function()
		local candidates = { { id = 1 }, { id = 2 } }
		local ranked, status = Surrogate.Rank(candidates, engine)
		assert.is_true(ranked == candidates)
		assert.are.equal("disabled", status)
		assert.is_nil(Surrogate.model)
		assert.is_false(Surrogate.enabled)
	end)

	it("requires the complete matching PoB and tree version plus held-out quality", function()
		local model = makeModel()
		assert.is_true(Surrogate.Install(model))
		assert.is_true(Surrogate.IsCompatible(model, engine))
		for _, key in ipairs({ "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }) do
			local incompatible = {
				pobVersion = engine.pobVersion,
				pobBranch = engine.pobBranch,
				dataVersion = engine.dataVersion,
				treeVersion = engine.treeVersion,
				manifestFingerprint = engine.manifestFingerprint,
			}
			incompatible[key] = key == "manifestFingerprint" and string.rep("b", 64) or (tostring(incompatible[key]) .. "-different")
			local ok, reason = Surrogate.IsCompatible(model, incompatible)
			assert.is_false(ok)
			assert.is_truthy(reason:find("engine_version_mismatch", 1, true))
		end
		local ok, reason = Surrogate.Install(makeModel({ validation = { status = "passed", heldOutSpearman = 0.79, topParetoRecall = 0.99 } }))
		assert.is_false(ok)
		assert.are.equal("held_out_quality_gate_failed", reason)
		assert.is_false(Surrogate.enabled)
		local belowBaseline = makeModel({ validation = {
			status = "passed", heldOutSpearman = 0.84, topParetoRecall = 0.92,
			baselineInputOrderSpearman = 0.85, baselineInputOrderTopParetoRecall = 0.95,
			baselineNonRegression = true, baselineScoredSourceLineages = 5,
			baselineParetoScoredGroups = 5, baselineParetoUnscoredGroups = 0,
			heldOutCoverage = 0.88, heldOutRows = 50, scoredSourceLineages = 5,
		} })
		ok, reason = Surrogate.Install(belowBaseline)
		assert.is_false(ok, "absolute quality thresholds cannot override degradation against PoB's preserved candidate order")
		assert.are.equal("held_out_quality_gate_failed", reason)
		local missingBaseline = makeModel()
		missingBaseline.validation.baselineNonRegression = nil
		ok, reason = Surrogate.Install(missingBaseline)
		assert.is_false(ok)
		assert.are.equal("held_out_quality_gate_failed", reason)
	end)

	it("rejects incomplete versions, incompatible feature policy, and missing independent holdout groups", function()
		local ok, reason = Surrogate.Install(makeModel({ engine = { dataVersion = engine.dataVersion } }))
		assert.is_false(ok)
		assert.are.equal("model_engine_identity_incomplete", reason)
		ok, reason = Surrogate.Install(makeModel({ featurePolicy = "public-popularity-v1" }))
		assert.is_false(ok)
		assert.are.equal("unsupported_feature_policy", reason)
		ok, reason = Surrogate.Install(makeModel({ schemaVersion = 1 }))
		assert.is_false(ok)
		assert.are.equal("unsupported_model_schema", reason)
		ok, reason = Surrogate.Install(makeModel({ groupingPolicy = "unreviewed-build-state-v1" }))
		assert.is_false(ok)
		assert.are.equal("unsupported_grouping_policy", reason)
		ok, reason = Surrogate.Install(makeModel({ holdoutSourceLineages = 0 }))
		assert.is_false(ok)
		assert.are.equal("source_lineage_holdout_missing", reason)
		ok, reason = Surrogate.Install(makeModel({ trainingSourceLineages = 7 }))
		assert.is_false(ok)
		assert.are.equal("source_lineage_holdout_missing", reason)
	end)

	it("allows a compatible quality-gated model to reorder without dropping candidates", function()
		assert.is_true(Surrogate.Install(makeModel()))
		local candidates = { { id = 1 }, { id = 2 }, { id = 3 } }
		local ranked, status = Surrogate.Rank(candidates, engine)
		assert.are.equal("ranked", status)
		assert.are.equal(3, #ranked)
		assert.is_true(ranked[1] == candidates[3])
		assert.is_true(ranked[2] == candidates[2])
		assert.is_true(ranked[3] == candidates[1])
	end)

	it("isolates in-place proposal-array sorting from the original order", function()
		local model = makeModel({
			Rank = function(self, candidates)
				table.sort(candidates, function(left, right) return left.id > right.id end)
				return candidates
			end,
		})
		assert.is_true(Surrogate.Install(model))
		local candidates = { { id = 1 }, { id = 2 }, { id = 3 } }
		local ranked, status = Surrogate.Rank(candidates, engine)
		assert.are.equal("ranked", status)
		assert.is_true(candidates[1].id == 1 and candidates[2].id == 2 and candidates[3].id == 3)
		assert.is_true(ranked[1] == candidates[3] and ranked[3] == candidates[1])
	end)

	it("falls back to the original candidates if ranking drops, duplicates, or invents candidates", function()
		local candidates = { { id = 1 }, { id = 2 } }
		for _, rankedOutput in ipairs({
			{ candidates[1] },
			{ candidates[1], candidates[1] },
			{ candidates[1], { id = 3 } },
		}) do
			local model = makeModel({ Rank = function() return rankedOutput end })
			assert.is_true(Surrogate.Install(model))
			local ranked, status = Surrogate.Rank(candidates, engine)
			assert.is_true(ranked == candidates)
			assert.are.equal("invalid_model_ranking", status)
		end
	end)

	it("falls back when the build is outside domain or model execution fails", function()
		local candidates = { { id = 1 }, { id = 2 } }
		local model = makeModel({ InDomain = function() return false end })
		assert.is_true(Surrogate.Install(model))
		local ranked, status = Surrogate.Rank(candidates, engine)
		assert.is_true(ranked == candidates)
		assert.are.equal("outside_model_domain", status)
		model = makeModel({ Rank = function() error("model failure") end })
		assert.is_true(Surrogate.Install(model))
		ranked, status = Surrogate.Rank(candidates, engine)
		assert.is_true(ranked == candidates)
		assert.are.equal("invalid_model_ranking", status)
	end)

	it("does not use a model when the candidate array or current engine identity is invalid", function()
		assert.is_true(Surrogate.Install(makeModel()))
		local candidates = { { id = 1 }, { id = 2 } }
		local ranked, status = Surrogate.Rank(candidates, "3.29")
		assert.is_true(ranked == candidates)
		assert.are.equal("current_engine_identity_incomplete", status)
		local malformed = { [1] = candidates[1], [3] = candidates[2] }
		ranked, status = Surrogate.Rank(malformed, engine)
		assert.is_true(ranked == malformed)
		assert.are.equal("invalid_candidate_array", status)
	end)

	it("projects only exact one-passive study pairs and matches runtime feature hashing", function()
		local row = {
			kind = "passive_node_pair",
			classId = 2,
			ascendancyId = 5,
			mainSkill = "Fireball",
			characterLevel = 90,
			allocatedNodeIds = { 101, 102 },
			masterySelections = { { nodeId = 102, effectId = 7 } },
			skillGroups = {
				{ supportProfileVersion = 2, socketValidation = { valid = true, status = "linked" },
					slot = "Body Armour", enabled = true, slotEnabled = true, includeInFullDPS = true,
					selectedMainGroup = true, gems = {
						{ gemId = "SkillGemFireballTransfig", gameId = "Metadata/Items/Gems/SkillGemFireball",
							skillId = "FireballTransfig", variantId = "FireballTransfig", level = 20, quality = 20, enabled = true, isSupport = false, socketMatched = true },
						{ gemId = "SupportAddedFireDamage", gameId = "Metadata/Items/Gems/SupportAddedFireDamage",
							level = 20, quality = 20, enabled = true, isSupport = true, socketMatched = true },
					}, skills = { { supportProfileVersion = 2, selectedMainSkill = true, supports = {
						{ gemId = "Metadata/Items/Gems/SupportGreaterMultipleProjectiles", gameId = "Metadata/Items/Gems/SupportGemGreaterVolley",
							variantId = "GreaterMultipleProjectiles", skillId = "SupportGreaterMultipleProjectiles",
							effectId = "SupportGreaterMultipleProjectiles", origin = "item_granted", sourceSlot = "Body Armour",
							sourceItemFingerprint = string.rep("d", 64), targetGroupIndex = 1, targetSkillIndex = 1,
							targetEffectId = "Fireball", level = 15, quality = 0, active = true, configured = true,
							calculatorApplied = true, socketMatched = false, socketState = "not_applicable",
							linkState = "verified_item_local", groupState = "active", playableActive = true,
							supportProfileVersion = 2 },
					} } } },
			},
			itemSlots = { { slot = "Body Armour", base = "Vaal Regalia", rarity = "RARE", itemFingerprint = string.rep("d", 64) } },
			experiment = { unit = "one_passive_node", addedNodeIds = { 103 }, removedNodeIds = { } },
			baselineMetrics = { CombinedDPS = 100, TotalEHP = 5000 },
		}
		local projected = Features.FromStudyRow(row, "CombinedDPS")
		assert.is_table(projected)
		local tokenSet = { }
		for _, token in ipairs(projected.tokens) do tokenSet[token] = true end
		for _, token in ipairs({
			"added-node:103", "allocated-node:101", "allocated-node:102", "ascendancy:5", "class:2",
			"mastery:102:7", "skill:Fireball", "configured-skill-effect:FireballTransfig",
			"support:game:Metadata/Items/Gems/SupportAddedFireDamage",
			"support-profile:v2", "skill-group-socket-validation:linked", "skill-support-profile:v2",
			"main-skill-support-profile:v2", "support-origin:item_granted", "support-effect:SupportGreaterMultipleProjectiles",
			"support-target-effect:Fireball", "support-target-group:1", "support-target-skill-index:1",
			"support-source-slot:Body Armour", "support-source-item:" .. string.rep("d", 64),
			"support-level:15", "equipped-item-fingerprint:Body Armour:" .. string.rep("d", 64),
			"equipped-item-base:Body Armour:Vaal Regalia", "selected-main-skill-group",
		}) do assert.is_true(tokenSet[token], "missing build-context feature: " .. token) end
		assert.are.same({ 90, 2, 100, 5000, 1 }, projected.numeric)
		row.kind = "item_slot_pair"
		assert.is_nil(Features.FromStudyRow(row, "CombinedDPS"))
		assert.are.equal((function()
			local expected = 0
			for index = 1, #"added-node:103" do expected = (expected * 131 + string.byte("added-node:103", index)) % Features.HASH_MODULUS end
			return expected % 256 + 1
		end)(), Features.HashToken("added-node:103", 256))
	end)

	it("keeps legacy v1 supports out of v6 features when socket legality is unknown", function()
		local legacy = Features.FromStudyRow({
			kind = "passive_node_pair", classId = 2, ascendancyId = 5, mainSkill = "Fireball",
			characterLevel = 90, allocatedNodeIds = { 101, 102 },
			experiment = { unit = "one_passive_node", addedNodeIds = { 103 }, removedNodeIds = { } },
			baselineMetrics = { CombinedDPS = 100, TotalEHP = 5000 },
			skillGroups = { { supportProfileVersion = 1, slot = "Body Armour", enabled = true,
				slotEnabled = true, includeInFullDPS = true, selectedMainGroup = true,
				gems = { { gemId = "SupportAddedFireDamage", gameId = "SupportGemAddedFireDamage",
					level = 20, enabled = true, isSupport = true } },
				skills = { { supportProfileVersion = 1, selectedMainSkill = true, supports = {
					{ effectId = "SupportAddedFireDamage", origin = "socketed_gem", active = true,
						playableActive = true, supportProfileVersion = 1 },
				} } },
			} },
		}, "CombinedDPS")
		assert.is_table(legacy)
		assert.are.equal("exact-pair-build-context-lineage-engine-manifest-v6", legacy.featurePolicy)
		local tokenSet = { }
		for _, token in ipairs(legacy.tokens) do tokenSet[token] = true end
		assert.is_true(tokenSet["support-profile:legacy-unknown"])
		assert.is_nil(tokenSet["support:game:SupportGemAddedFireDamage"])
		assert.is_nil(tokenSet["support-effect:SupportAddedFireDamage"])
	end)

	it("projects only an isolated one-passive proposal from the exact current build context", function()
		local itemGrantedEffect = { support = true, id = "SupportGreaterMultipleProjectiles", name = "Greater Multiple Projectiles", fromItem = true }
		local itemGrantedSupport = { grantedEffect = itemGrantedEffect, level = 15, quality = 0,
			origin = "item_granted", sourceSlot = "Body Armour" }
		local build = {
			characterLevel = 90,
			mainSocketGroup = 1,
			spec = {
				curClassId = 2, curAscendClassId = 5,
				nodes = { [103] = { type = "Notable" } },
				allocNodes = { [101] = true, [102] = true },
				masterySelections = { [102] = 7 },
			},
			skillsTab = {
				socketGroupList = { [1] = { slot = "Body Armour", enabled = true, slotEnabled = true,
					includeInFullDPS = true, mainActiveSkill = 1, gemList = {
						{ gemId = "SkillGemFireballTransfig", skillId = "FireballTransfig", level = 20, quality = 20, matchesSocket = true,
							gemData = { id = "SkillGemFireballTransfig", gameId = "Metadata/Items/Gems/SkillGemFireball" },
							grantedEffect = { support = false } },
						{ gemId = "SupportAddedFireDamage", level = 20, quality = 20, matchesSocket = true,
							gemData = { id = "SupportAddedFireDamage", gameId = "Metadata/Items/Gems/SupportAddedFireDamage" },
							grantedEffect = { support = true, color = 3 } },
				}, displaySkillList = { [1] = {
				activeEffect = { grantedEffect = { id = "Fireball", name = "Fireball" } },
					effectList = { itemGrantedSupport },
					supportList = { itemGrantedSupport },
				} } } },
			},
			itemsTab = {
				activeItemSet = { ["Body Armour"] = { selItemId = 1 } },
				slots = { ["Body Armour"] = { } },
				items = { [1] = { name = "Vaal Regalia", type = "Vaal Regalia", baseName = "Vaal Regalia",
					base = { name = "Vaal Regalia" }, rarity = "RARE", explicitModLines = { { line = "+20 to maximum Life" } },
					sockets = { { color = "W", group = 1 }, { color = "W", group = 1 } } } },
			},
		}
		local featureInput = Features.FromCandidate(build, { nodeIds = { 103 } }, { CombinedDPS = 125, TotalEHP = 6000 }, "CombinedDPS")
		assert.is_table(featureInput)
		assert.are.equal("Fireball", featureInput.mainSkill)
		local tokenSet = { }
		for _, token in ipairs(featureInput.tokens) do tokenSet[token] = true end
		assert.is_true(tokenSet["allocated-node:101"] and tokenSet["allocated-node:102"])
		assert.is_true(tokenSet["mastery:102:7"] and tokenSet["added-node:103"])
		assert.is_true(tokenSet["configured-skill-effect:FireballTransfig"])
		assert.is_true(tokenSet["support:game:Metadata/Items/Gems/SupportAddedFireDamage"])
		assert.is_true(tokenSet["equipped-item-base:Body Armour:Vaal Regalia"])
		local sourceItemFingerprint = Features.ItemFingerprint(build.itemsTab.items[1])
		assert.is_true(tokenSet["support-origin:item_granted"])
		assert.is_true(tokenSet["support-effect:SupportGreaterMultipleProjectiles"])
		assert.is_true(tokenSet["support-target-effect:Fireball"])
		assert.is_true(tokenSet["support-target-group:1"] and tokenSet["support-target-skill-index:1"])
		assert.is_true(tokenSet["support-source-item:" .. sourceItemFingerprint])
		assert.is_true(tokenSet["equipped-item-fingerprint:Body Armour:" .. sourceItemFingerprint])
		assert.are_not.equal(sourceItemFingerprint, Features.ItemFingerprint({ baseName = "Vaal Regalia",
			rarity = "RARE", explicitModLines = { { line = "+40 to maximum Life" } } }),
			"item fingerprints must distinguish different mod rolls on the same base")
		assert.are.same({ 90, 2, 125, 6000, 1 }, featureInput.numeric)
		assert.is_nil(Features.FromCandidate(build, { nodeIds = { 103 }, gearVariant = {} }, { CombinedDPS = 125, TotalEHP = 6000 }, "CombinedDPS"))
	end)

	it("loads a bounded numeric artifact and ranks only supported passive mutations", function()
		local dimension, hidden = 16, 1
		local inputSize, inputHidden = dimension + #Features.numericNames, { }
		for index = 1, inputSize do inputHidden[index] = { 0 } end
		inputHidden[Features.HashToken("added-node:101", dimension)][1] = 1
		local artifact = {
			format = "pob-optimizer-surrogate", schemaVersion = 7,
			featurePolicy = "exact-pair-build-context-lineage-engine-manifest-v6", groupingPolicy = "reviewed-source-snapshot-union-v2",
			modelType = "passive-one-node-build-context-mlp-v2",
			deterministic = true, engine = engine,
			trainingSourceLineages = 8, holdoutSourceLineages = 5, objectiveMetric = "CombinedDPS",
			trainingRows = 128, holdoutRows = 50,
			featureDimension = dimension, hiddenSize = hidden,
			numericMean = { 0, 0, 0, 0, 0 }, numericScale = { 1, 1, 1, 1, 1 },
			weights = { inputHidden = inputHidden, biasHidden = { 0 }, hiddenOutput = { 1 }, biasOutput = 0 },
			domain = { supportedMutations = {
				{ classId = 2, ascendancyId = 5, mainSkill = "Fireball", changedNodeId = 101 },
				{ classId = 2, ascendancyId = 5, mainSkill = "Fireball", changedNodeId = 102 },
				{ classId = 4, ascendancyId = 8, mainSkill = "Arc", changedNodeId = 102 },
			} },
			validation = { status = "passed", heldOutSpearman = 0.82, topParetoRecall = 0.91,
				baselineInputOrderSpearman = 0.4, baselineInputOrderTopParetoRecall = 0.6,
				baselineNonRegression = true, baselineScoredSourceLineages = 5,
				baselineParetoScoredGroups = 5, baselineParetoUnscoredGroups = 0,
				heldOutCoverage = 0.85, heldOutRows = 50, scoredSourceLineages = 5 },
		}
		assert.is_true(Surrogate.LoadArtifactJson(json.encode(artifact)))
		local candidates = {
			{ id = "weaker", surrogateFeatures = { featurePolicy = "exact-pair-build-context-lineage-engine-manifest-v6", objectiveMetric = "CombinedDPS", classId = 2, ascendancyId = 5, mainSkill = "Fireball", changedNodeIds = { 102 }, tokens = { "added-node:102" }, numeric = { 90, 10, 1000, 5000, 1 } } },
			{ id = "cross-combination", surrogateFeatures = { featurePolicy = "exact-pair-build-context-lineage-engine-manifest-v6", objectiveMetric = "CombinedDPS", classId = 2, ascendancyId = 5, mainSkill = "Arc", changedNodeIds = { 102 }, tokens = { "added-node:102" }, numeric = { 90, 10, 1000, 5000, 1 } } },
			{ id = "unsupported-node", surrogateFeatures = { featurePolicy = "exact-pair-build-context-lineage-engine-manifest-v6", objectiveMetric = "CombinedDPS", classId = 2, ascendancyId = 5, mainSkill = "Fireball", changedNodeIds = { 999 }, tokens = { "added-node:999" }, numeric = { 90, 10, 1000, 5000, 1 } } },
			{ id = "stronger", surrogateFeatures = { featurePolicy = "exact-pair-build-context-lineage-engine-manifest-v6", objectiveMetric = "CombinedDPS", classId = 2, ascendancyId = 5, mainSkill = "Fireball", changedNodeIds = { 101 }, tokens = { "added-node:101" }, numeric = { 90, 10, 1000, 5000, 1 } } },
		}
		local ranked, status = Surrogate.Rank(candidates, engine)
		assert.are.equal("ranked", status)
		assert.is_true(ranked[1] == candidates[4])
		assert.is_true(ranked[2] == candidates[2], "an unobserved skill/context/node tuple must retain its original position")
		assert.is_true(ranked[3] == candidates[3], "an unobserved node must retain its original position")
		assert.is_true(ranked[4] == candidates[1])
		local invalid = { }
		for key, value in pairs(artifact) do invalid[key] = value end
		invalid.weights = { inputHidden = { { 0 } }, biasHidden = { 0 }, hiddenOutput = { 0 }, biasOutput = 0 }
		assert.is_false(Surrogate.InstallArtifact(invalid))
		assert.is_false(Surrogate.enabled)
	end)

	it("refuses to load a local model while study-withdrawal cleanup is pending", function()
		assert.is_true(Surrogate.Install(makeModel()))
		local userPath = os.tmpname()
		local separator = package.config and package.config:sub(1, 1) or "\\"
		local markerPath = userPath .. separator .. "OptimizerStudies" .. separator .. "training-artifacts-invalidated.json"
		local modelPath = userPath .. separator .. "OptimizerModels" .. separator .. "active.json"
		local originalOpen = io.open
		local modelWasRead = false
		io.open = function(path, mode)
			if path == markerPath then return { close = function() return true end } end
			if path == modelPath then modelWasRead = true; error("model read must be blocked by the pending withdrawal") end
			return originalOpen(path, mode)
		end
		local callOk, loaded, reason = pcall(Surrogate.LoadFromUserPath, userPath)
		io.open = originalOpen
		assert.is_true(callOk, tostring(loaded))
		assert.is_false(loaded)
		assert.are.equal("training_artifact_invalidated_by_study_withdrawal", reason)
		assert.is_false(modelWasRead)
		assert.is_false(Surrogate.enabled)
	end)
end)
