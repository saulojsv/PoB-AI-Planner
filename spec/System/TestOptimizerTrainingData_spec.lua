local TrainingData = require("Modules.Optimizer.TrainingData")
local StudyRecords = require("Modules.Optimizer.StudyRecords")
local json = require("dkjson")
local ffi = require("ffi")
ffi.cdef[[
	int _mkdir(const char *dirname);
	int _rmdir(const char *dirname);
	int _access(const char *path, int mode);
]]
local crt = ffi.load("msvcr100")

local function createTestDirectory(path)
	path = path:gsub("[/\\\\]+$", "")
	if crt._mkdir(path) == 0 then return true end
	return nil, "could not create test directory"
end

local function certifiedRecord(recordId, buildIndex)
	local index = buildIndex or 1
	return {
		recordId = recordId,
		schemaVersion = 2,
		kind = "passive_node_pair",
		trainingEligible = true,
		quarantine = { status = "approved" },
		certification = {
			reviewStatus = "approved", reviewSchemaVersion = 3,
			reviewId = "review-fixture-" .. tostring(index), reviewedAt = "2026-10-19T00:00:00Z",
			attestations = { exactPair = true, scenario = true, activity = true, lookupTables = true,
				localTrainingConsent = true, sourceRightsVerified = true },
			sourceRights = { basis = "open_license", licenseId = "CC-BY-4.0", scope = "offline_local_model_training" },
		},
		engine = { pobVersion = "3.29.0", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
			manifestFingerprint = string.rep("a", 64), lookupTableStatus = "certified" },
		lineage = { schemaVersion = 1, fingerprint = string.rep("0", 63) .. tostring(index),
			snapshotFingerprint = string.rep("f", 63) .. tostring(index), basis = "public_source_url" },
		buildState = {
			characterLevel = 90 + index,
			class = { classId = 2, class = "Witch", ascendancyId = 5, ascendancy = "Elementalist" },
			allocatedNodeIds = { 101, 102, 200 + index, 401 + index },
			masterySelections = { [401 + index] = 7 },
			mainSkill = "Fireball",
			configuration = { activeConfigSetId = 1, title = "Pinnacle", values = { enemyIsBoss = true }, customModifiers = { } },
			skillGroups = {
				{ groupIndex = 1, slot = "Weapon 1", enabled = true, slotEnabled = true, includeInFullDPS = true, selectedMainGroup = true,
					gems = { { gemId = "Fireball", gameId = "Metadata/Items/Gems/SkillGemFireball", skillId = "Fireball", level = 20, quality = 20, enabled = true, count = 1, isSupport = false } } },
			},
		},
		source = {
			type = "public_build_study", provider = "poe.ninja", label = "Popular build", importRank = index,
			sourceUrl = "https://example.invalid/build/" .. tostring(index) .. "?token=private-" .. tostring(index),
		},
		experiment = { unit = "one_passive_node", addedNodeIds = { 300 + index }, removedNodeIds = { } },
		baseline = { metrics = { CombinedDPS = 100, TotalEHP = 1000 }, requirements = { feasible = true }, activitySustain = { status = "pass" } },
		candidate = { metrics = { CombinedDPS = 110, TotalEHP = 1010 }, requirements = { feasible = true }, activitySustain = { status = "pass" } },
		metricDelta = { CombinedDPS = 10, TotalEHP = 10 },
		admission = {
			exactCalculated = true,
			useRequirementsFeasible = true,
			scenarioConditionsCertified = true,
			activitySustainCertified = true,
			activityRatesFeasible = true,
			activityStatus = "pass",
			lookupTablesCertified = true,
		},
	}
end

local expectedEngine = { pobVersion = "3.29.0", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
	manifestFingerprint = string.rep("a", 64) }

describe("Optimizer supervised study preparation", function()
	it("keeps ordinary exact studies quarantined and reports the missing gates", function()
		local record = certifiedRecord("not-admitted", 1)
		record.trainingEligible = false
		record.quarantine.status = "pending_review"
		record.certification = nil
		record.admission.scenarioConditionsCertified = false
		record.admission.activitySustainCertified = false
		record.admission.lookupTablesCertified = false
		record.engine.lookupTableStatus = "not_audited"
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal("blocked_no_certified_records", dataset.status)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.not_admitted)
		assert.are.equal(1, dataset.excludedReasons.scenario_not_certified)
		assert.are.equal(1, dataset.excludedReasons.activity_not_certified)
		assert.are.equal(1, dataset.excludedReasons.lookup_tables_not_certified)
		assert.is_false(dataset.modelTrainingEnabled)
	end)

	it("keeps exact passive factorial interactions outside the one-factor training schema", function()
		local record = certifiedRecord("factorial-not-yet-admitted", 1)
		record.kind = "passive_factorial_interaction"
		record.experiment = {
			unit = "four_cell_passive_factorial",
			factorA = { operation = "add_passive_node", nodeId = 501 },
			factorB = { operation = "add_passive_node", nodeId = 502 },
		}
		record.factorial = {
			formula = "combined - factorA - factorB + baseline",
			cells = { factorA = { metrics = { CombinedDPS = 110 } }, factorB = { metrics = { CombinedDPS = 112 } } },
			interaction = { CombinedDPS = { interaction = 3 } },
			metricCount = 1,
		}
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal("blocked_no_certified_records", dataset.status)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.factorial_training_schema_unsupported)
		assert.are.equal(1, dataset.excludedReasons.experiment_context_incomplete)
		assert.is_false(dataset.modelTrainingEnabled)
		local review = TrainingData.AssessReview(record, expectedEngine)
		assert.is_false(review.canApprove, "the one-factor review flow must not approve a factorial target")
		assert.is_truthy(table.concat(review.blockers, ","):find("factorial_training_schema_unsupported", 1, true))
	end)

	it("keeps skill/support interaction targets quarantined from one-factor training", function()
		local record = certifiedRecord("skill-support-factorial-not-yet-admitted", 1)
		record.kind = "skill_support_factorial_interaction"
		record.experiment = {
			unit = "four_cell_skill_support_factorial",
			factorA = { operation = "replace_selected_main_skill_gem" },
			factorB = { operation = "replace_support_gem" },
		}
		record.factorial = {
			formula = "combined - factorA - factorB + baseline",
			cells = { baseline = { metrics = { CombinedDPS = 100 } }, factorA = { metrics = { CombinedDPS = 120 } },
				factorB = { metrics = { CombinedDPS = 110 } }, combined = { metrics = { CombinedDPS = 150 } } },
			interaction = { CombinedDPS = { interaction = 20 } }, metricCount = 1,
		}
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal("blocked_no_certified_records", dataset.status)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.factorial_training_schema_unsupported)
		assert.is_false(dataset.modelTrainingEnabled)
		local review = TrainingData.AssessReview(record, expectedEngine)
		assert.is_false(review.canApprove)
		assert.is_truthy(table.concat(review.blockers, ","):find("factorial_training_schema_unsupported", 1, true))
	end)

	it("keeps two-skill Full DPS interactions quarantined from one-factor training", function()
		local record = certifiedRecord("skill-skill-factorial-not-yet-admitted", 1)
		record.kind = "skill_skill_factorial_interaction"
		record.experiment = {
			unit = "four_cell_skill_skill_factorial",
			factorA = { operation = "replace_full_dps_skill_gem" },
			factorB = { operation = "replace_full_dps_skill_gem" },
		}
		record.factorial = {
			formula = "combined - factorA - factorB + baseline",
			cells = { baseline = { metrics = { FullDPS = 100 } }, factorA = { metrics = { FullDPS = 120 } },
				factorB = { metrics = { FullDPS = 110 } }, combined = { metrics = { FullDPS = 145 } } },
			interaction = { FullDPS = { interaction = 15 } }, metricCount = 1,
		}
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal("blocked_no_certified_records", dataset.status)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.factorial_training_schema_unsupported)
		assert.is_false(dataset.modelTrainingEnabled)
		local review = TrainingData.AssessReview(record, expectedEngine)
		assert.is_false(review.canApprove)
		assert.is_truthy(table.concat(review.blockers, ","):find("factorial_training_schema_unsupported", 1, true))
	end)

	it("keeps passive/support interaction targets outside one-factor training and review", function()
		local record = certifiedRecord("passive-support-factorial-not-yet-admitted", 1)
		record.kind = "passive_support_factorial_interaction"
		record.experiment = {
			unit = "four_cell_passive_support_factorial",
			factorA = { operation = "add_passive_node", nodeId = 501 },
			factorB = { operation = "replace_support_gem", before = { gemId = "AddedFire" }, after = { gemId = "ControlledDestruction" } },
		}
		record.factorial = {
			formula = "combined - factorA - factorB + baseline",
			cells = { baseline = { metrics = { CombinedDPS = 100 } }, factorA = { metrics = { CombinedDPS = 120 } },
				factorB = { metrics = { CombinedDPS = 110 } }, combined = { metrics = { CombinedDPS = 150 } } },
			interaction = { CombinedDPS = { interaction = 20 } }, metricCount = 1,
		}
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal("blocked_no_certified_records", dataset.status)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.factorial_training_schema_unsupported)
		assert.is_false(dataset.modelTrainingEnabled)
		local review = TrainingData.AssessReview(record, expectedEngine)
		assert.is_false(review.canApprove)
		assert.is_truthy(table.concat(review.blockers, ","):find("factorial_training_schema_unsupported", 1, true))
	end)

	it("keeps skill/item-slot interaction targets quarantined from one-factor training", function()
		local record = certifiedRecord("skill-item-factorial-not-yet-admitted", 1)
		record.kind = "skill_item_slot_factorial_interaction"
		record.experiment = {
			unit = "four_cell_skill_item_slot_factorial",
			factorA = { operation = "replace_selected_main_skill_gem" },
			factorB = { operation = "replace_item_in_slot", slot = "Helmet" },
		}
		record.factorial = {
			formula = "combined - factorA - factorB + baseline",
			cells = { baseline = { metrics = { CombinedDPS = 100 } }, factorA = { metrics = { CombinedDPS = 120 } },
				factorB = { metrics = { CombinedDPS = 110 } }, combined = { metrics = { CombinedDPS = 150 } } },
			interaction = { CombinedDPS = { interaction = 20 } }, metricCount = 1,
		}
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal("blocked_no_certified_records", dataset.status)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.factorial_training_schema_unsupported)
		assert.is_false(dataset.modelTrainingEnabled)
		local review = TrainingData.AssessReview(record, expectedEngine)
		assert.is_false(review.canApprove)
		assert.is_truthy(table.concat(review.blockers, ","):find("factorial_training_schema_unsupported", 1, true))
	end)

	it("keeps passive/item interaction targets out of the one-factor training schema", function()
		local record = certifiedRecord("passive-item-factorial-not-yet-admitted", 1)
		record.kind = "passive_item_slot_factorial_interaction"
		record.experiment = {
			unit = "four_cell_passive_item_slot_factorial",
			factorA = { operation = "add_passive_node", nodeId = 501 },
			factorB = { operation = "replace_item_in_slot", slot = "Helmet" },
		}
		record.factorial = {
			formula = "combined - factorA - factorB + baseline",
			cells = { baseline = { metrics = { CombinedDPS = 100 } }, factorA = { metrics = { CombinedDPS = 120 } },
				factorB = { metrics = { CombinedDPS = 110 } }, combined = { metrics = { CombinedDPS = 150 } } },
			interaction = { CombinedDPS = { interaction = 20 } }, metricCount = 1,
		}
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal("blocked_no_certified_records", dataset.status)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.factorial_training_schema_unsupported)
		assert.is_false(dataset.modelTrainingEnabled)
		local review = TrainingData.AssessReview(record, expectedEngine)
		assert.is_false(review.canApprove)
		assert.is_truthy(table.concat(review.blockers, ","):find("factorial_training_schema_unsupported", 1, true))
	end)

	it("prepares a mastery-effect feature only when its source node and selected effect match", function()
		local record = certifiedRecord("mastery-pair", 1)
		record.kind = "mastery_effect_pair"
		record.experiment = {
			unit = "one_mastery_effect",
			changedParameter = "masteryEffect",
			masteryNodeId = 402,
			before = { effectId = 7 },
			after = { effectId = 8 },
		}
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal(1, dataset.eligibleRows)
		assert.are.equal(402, dataset.rows[1].features.experiment.masteryNodeId)
		assert.are.equal("masteryEffect", dataset.rows[1].features.experiment.changedParameter)
		assert.are.equal(7, dataset.rows[1].features.experiment.before.effectId)
		assert.are.equal(8, dataset.rows[1].features.experiment.after.effectId)
		assert.is_false(dataset.modelTrainingEnabled)

		local malformed = certifiedRecord("malformed-mastery-pair", 1)
		malformed.kind = "mastery_effect_pair"
		malformed.experiment = {
			unit = "one_mastery_effect",
			masteryNodeId = 402,
			before = { effectId = 99 },
			after = { effectId = 8 },
		}
		local rejected = TrainingData.Prepare({ malformed }, expectedEngine)
		assert.are.equal(0, rejected.eligibleRows)
		assert.are.equal(1, rejected.excludedReasons.invalid_mastery_effect_pair)
	end)

	it("prepares exact labels without popularity features and holds out whole builds", function()
		local records = {
			certifiedRecord("pair-1", 1),
			certifiedRecord("pair-2", 1),
			certifiedRecord("pair-3", 2),
		}
		-- The first two experiments share the exact same source build snapshot.
		records[1].experiment.before = { poBItemText = "untrusted raw item text" }
		records[1].experiment.after = { poBItemText = "another raw item text" }
		records[2].experiment.addedNodeIds = { 501 }
		records[2].candidate.metrics.CombinedDPS = 112
		records[2].metricDelta.CombinedDPS = 12
		local dataset = TrainingData.Prepare(records, expectedEngine)
		local replay = TrainingData.Prepare(records, expectedEngine)
		assert.are.equal("dataset_ready_for_offline_evaluation", dataset.status)
		assert.are.equal(3, dataset.eligibleRows)
		assert.are.equal(2, dataset.sourceLineages)
		assert.are.equal(3, dataset.trainingRows + dataset.holdoutRows)
		assert.are.equal(dataset.trainingRows, replay.trainingRows)
		assert.are.equal(dataset.holdoutRows, replay.holdoutRows)
		assert.is_true(dataset.popularityFeaturesExcluded)
		assert.is_false(dataset.modelTrainingEnabled)
		assert.are.equal(10, dataset.rows[1].labels.CombinedDPS)
		assert.are.equal(101, dataset.rows[1].features.allocatedNodeIds[1])
		assert.are.equal(102, dataset.rows[1].features.allocatedNodeIds[2])
		assert.are.equal(201, dataset.rows[1].features.allocatedNodeIds[3])
		assert.are.equal(7, dataset.rows[1].features.masterySelections[1].effectId)
		assert.are.equal("Weapon 1", dataset.rows[1].features.skillGroups[1].slot)
		assert.are.equal("Metadata/Items/Gems/SkillGemFireball", dataset.rows[1].features.skillGroups[1].gems[1].gameId)
		assert.is_table(dataset.rows[1].features.itemSlots)
		assert.is_nil(dataset.rows[1].features.source)
		assert.is_nil(dataset.rows[1].features.provider)
		assert.is_nil(dataset.rows[1].features.importRank)
		assert.is_nil(dataset.rows[1].features.experiment.before.poBItemText)
		local trainLineages, holdoutLineages = { }, { }
		for _, row in ipairs(dataset.training) do trainLineages[row.sourceGroupId] = true end
		for _, row in ipairs(dataset.holdout) do holdoutLineages[row.sourceGroupId] = true end
		for lineageId in pairs(trainLineages) do assert.is_nil(holdoutLineages[lineageId]) end
	end)

	it("encodes only sanitized, versioned exact pairs and keeps node deltas allowlisted", function()
		local records = { certifiedRecord("export-1", 1), certifiedRecord("export-2", 1), certifiedRecord("export-3", 2) }
		records[1].experiment.before = { poBItemText = "private raw item text" }
		records[1].certification.sourceRights.licenseUrl = "https://license.example/private?token=private-rights-url"
		records[1].certification.sourceRights.permissionReference = "private-permission-reference"
		records[1].experiment.addedNodeIds = { 701 }
		records[1].buildState.skillGroups[1].gems[1].gemId = "Fireball\nprivate gem marker"
		local dataset = TrainingData.Prepare(records, expectedEngine)
		local encoded, metadata = TrainingData.EncodeJsonl(dataset)
		assert.is_truthy(encoded, metadata)
		assert.are.equal("certified", dataset.rows[1].engine.lookupTableStatus)
		assert.are.equal(3, metadata.rows)
		assert.is_nil(encoded:find("private raw item text", 1, true))
		assert.is_nil(encoded:find("poe.ninja", 1, true))
		assert.is_nil(encoded:find("Popular build", 1, true))
		assert.is_nil(encoded:find("export-1", 1, true))
		assert.is_nil(encoded:find("private gem marker", 1, true))
		assert.is_nil(encoded:find("private-rights-url", 1, true))
		assert.is_nil(encoded:find("private-permission-reference", 1, true))
		local header = assert(json.decode(encoded:match("([^\n]+)")))
		assert.are.equal("dataset_header", header.recordType)
		assert.are.equal(6, header.datasetSchemaVersion)
		assert.are.equal("exact-pair-build-context-lineage-engine-manifest-v6", header.featurePolicy)
		assert.are.equal("3.29", header.engine.dataVersion)
		assert.are.equal(701, dataset.rows[1].features.experiment.addedNodeIds[1])
		local foundNodeDelta = false
		for line in encoded:gmatch("[^\n]+") do
			local row = assert(json.decode(line))
			if row.recordType == "exact_pair" and row.features.experiment.addedNodeIds[1] == 701 then foundNodeDelta = true end
		end
		assert.is_true(foundNodeDelta)
	end)

	it("projects equipped item bases while excluding item names and raw mods from model inputs", function()
		local records = { certifiedRecord("item-context-1", 1), certifiedRecord("item-context-2", 1), certifiedRecord("item-context-3", 2) }
		for _, record in ipairs(records) do
			record.buildState.supportFeatureSchemaVersion = 2
			local group = record.buildState.skillGroups[1]
			group.supportProfileVersion = 2
			group.socketValidation = { valid = true, status = "linked" }
			group.gems[1].variantId = "Fireball"
			group.gems[1].socketMatched = true
			group.skills = { { skillIndex = 1, selectedMainSkill = true, supportProfileVersion = 2, supports = {
				{ gemId = "Metadata/Items/Gems/SupportHypothermia", gameId = "Metadata/Items/Gems/SupportGemHypothermia",
					variantId = "Hypothermia", skillId = "SupportHypothermia", effectId = "SupportHypothermia",
					level = 15, quality = 0, origin = "item_granted", sourceSlot = "Body Armour",
					sourceItemFingerprint = string.rep("d", 64), targetGroupIndex = 1, targetSkillIndex = 1,
					targetEffectId = "Fireball", active = true, configured = true, calculatorApplied = true,
					socketMatched = false, socketState = "not_applicable", linkState = "verified_item_local",
					groupState = "active", playableActive = true, supportProfileVersion = 2 },
			} } }
			record.buildState.items = { [77] = { id = 77, name = "private item name", base = "Vaal Regalia",
				rarity = "RARE", itemFingerprint = string.rep("d", 64), mods = { "+999 to maximum Life" } } }
			record.buildState.equippedSlots = { { slot = "Body Armour", itemId = 77, active = true } }
		end
		local dataset = TrainingData.Prepare(records, expectedEngine)
		local encoded = assert(TrainingData.EncodeJsonl(dataset))
		local feature = dataset.rows[1].features.itemSlots[1]
		assert.are.equal("Body Armour", feature.slot)
		assert.are.equal("Vaal Regalia", feature.base)
		assert.are.equal("RARE", feature.rarity)
		assert.are.equal(string.rep("d", 64), feature.itemFingerprint)
		local support = dataset.rows[1].features.skillGroups[1].skills[1].supports[1]
		assert.are.equal("item_granted", support.origin)
		assert.are.equal("SupportHypothermia", support.effectId)
		assert.are.equal("Body Armour", support.sourceSlot)
		assert.are.equal(string.rep("d", 64), support.sourceItemFingerprint)
		assert.are.equal("Fireball", support.targetEffectId)
		assert.is_true(support.playableActive)
		assert.are.equal(2, support.supportProfileVersion)
		assert.are.equal("Fireball", dataset.rows[1].features.skillGroups[1].gems[1].variantId)
		assert.is_nil(encoded:find("private item name", 1, true))
		assert.is_nil(encoded:find("999 to maximum Life", 1, true))
	end)

	it("exports locally only after certified independent-build readiness", function()
		local root = os.tmpname()
		os.remove(root)
		root = root .. "-optimizer-export"
		assert.is_truthy(createTestDirectory(root))
		local storePath, storeDirectory = StudyRecords.GetStorePath(root)
		assert.is_truthy(createTestDirectory(storeDirectory))
		local records = { certifiedRecord("disk-1", 1), certifiedRecord("disk-2", 1), certifiedRecord("disk-3", 2) }
		local store = assert(io.open(storePath, "wb"))
		for _, record in ipairs(records) do assert(store:write(assert(json.encode(record)), "\n")) end
		assert(store:close())
		local exported, exportError = StudyRecords.ExportTrainingDataset(root, expectedEngine, createTestDirectory)
		assert.is_truthy(exported, exportError)
		assert.is_true(exported.exported)
		assert.are.equal("exported", exported.status)
		assert.are.equal(2, exported.sourceLineages)
		assert.is_false(exported.readiness.modelTrainingEnabled)
		local exportedPath = storeDirectory .. package.config:sub(1, 1) .. "TrainingDatasets" .. package.config:sub(1, 1) .. exported.path:match("([^/]+)$")
		local file = assert(io.open(exportedPath, "rb"))
		local contents = file:read("*a")
		file:close()
		assert.is_truthy(contents:find("dataset_header", 1, true))
		assert.is_nil(contents:find("Popular build", 1, true))
		assert.is_nil(contents:find("disk-1", 1, true))
		assert(os.remove(exportedPath))
		assert.are.equal(0, crt._rmdir(storeDirectory .. package.config:sub(1, 1) .. "TrainingDatasets"))
		assert(os.remove(storePath))
		assert.are.equal(0, crt._rmdir(storeDirectory))
		assert.are.equal(0, crt._rmdir(root))
	end)

	it("exports only exact study pairs with separate consented reviews and source-lineage holdout", function()
		local root = os.tmpname()
		os.remove(root)
		root = root .. "-optimizer-reviewed-export"
		assert.is_truthy(createTestDirectory(root))
		local storePath, storeDirectory = StudyRecords.GetStorePath(root)
		local reviewPath = assert(StudyRecords.GetReviewPath(root))
		assert.is_truthy(createTestDirectory(storeDirectory))
		local first = assert(StudyRecords.AppendToPath(certifiedRecord("review-export-1", 1), storePath))
		local second = assert(StudyRecords.AppendToPath(certifiedRecord("review-export-2", 2), storePath))
		local attestations = { exactPair = true, scenario = true, activity = true, lookupTables = true,
			localTrainingConsent = true, sourceRightsVerified = true,
			sourceRightsEvidence = { basis = "open_license", licenseId = "CC-BY-4.0",
				licenseUrl = "https://creativecommons.org/licenses/by/4.0/" } }
		local incomplete, consentError = StudyRecords.ReviewToPath(storePath, first.recordId, "approved", {
			exactPair = true, scenario = true, activity = true, lookupTables = true,
		}, expectedEngine)
		assert.is_nil(incomplete)
		assert.is_truthy(consentError:find("local-training consent", 1, true))
		assert(StudyRecords.ReviewToPath(storePath, first.recordId, "approved", attestations, expectedEngine))
		assert(StudyRecords.ReviewToPath(storePath, second.recordId, "approved", attestations, expectedEngine))

		local listed = assert(StudyRecords.List(storePath, 5, "3.29", "3_29", "3.29.0", "dev", string.rep("a", 64)))
		assert.are.equal(2, listed.trainingEligible)
		assert.are.equal("dataset_ready_for_offline_evaluation", listed.trainingReadiness.status)
		assert.are.equal(1, listed.trainingReadiness.trainingRows)
		assert.are.equal(1, listed.trainingReadiness.holdoutRows)
		assert.is_false(listed.trainingReadiness.modelTrainingEnabled)

		local exported = assert(StudyRecords.ExportTrainingDataset(root, expectedEngine, createTestDirectory))
		assert.is_true(exported.exported)
		assert.are.equal(2, exported.sourceLineages)
		assert.is_false(exported.readiness.modelTrainingEnabled)
		local separator = package.config:sub(1, 1)
		local outputPath = storeDirectory .. separator .. "TrainingDatasets" .. separator .. exported.path:match("([^/]+)$")
		local file = assert(io.open(outputPath, "rb"))
		local content = file:read("*a")
		file:close()
		local trainRows, holdoutRows = 0, 0
		for line in content:gmatch("[^\n]+") do
			local row = assert(json.decode(line))
			if row.recordType == "exact_pair" and row.split == "train" then trainRows = trainRows + 1 end
			if row.recordType == "exact_pair" and row.split == "holdout" then holdoutRows = holdoutRows + 1 end
		end
		assert.are.equal(1, trainRows)
		assert.are.equal(1, holdoutRows)
		assert.is_nil(content:find(first.recordId, 1, true))
		assert.is_nil(content:find("review-export", 1, true))
		assert(os.remove(outputPath))
		assert.are.equal(0, crt._rmdir(storeDirectory .. separator .. "TrainingDatasets"))
		assert(os.remove(reviewPath))
		assert(os.remove(storePath))
		assert.are.equal(0, crt._rmdir(storeDirectory))
		assert.are.equal(0, crt._rmdir(root))
	end)

	it("refuses an uncertified export without creating an output directory", function()
		local root = os.tmpname()
		os.remove(root)
		root = root .. "-optimizer-blocked"
		assert.is_truthy(createTestDirectory(root))
		local storePath, storeDirectory = StudyRecords.GetStorePath(root)
		assert.is_truthy(createTestDirectory(storeDirectory))
		assert(StudyRecords.AppendToPath({ engine = { dataVersion = "3.29", treeVersion = "3_29" } }, storePath))
		local result = assert(StudyRecords.ExportTrainingDataset(root, expectedEngine, createTestDirectory))
		assert.is_false(result.exported)
		assert.are.equal("blocked_no_certified_records", result.status)
		assert.are.equal(-1, crt._access(storeDirectory .. package.config:sub(1, 1) .. "TrainingDatasets", 0))
		assert(os.remove(storePath))
		assert.are.equal(0, crt._rmdir(storeDirectory))
		assert.are.equal(0, crt._rmdir(root))
	end)

	it("does not split a source lineage for mastery map representation variants", function()
		local numericKey = certifiedRecord("numeric-mastery-key", 1)
		local textualKey = certifiedRecord("text-mastery-key", 1)
		textualKey.buildState.masterySelections = { ["402"] = 7 }
		local dataset = TrainingData.Prepare({ numericKey, textualKey }, expectedEngine)
		assert.are.equal(1, dataset.sourceLineages)
	end)

	it("keeps mirrored copies of the same exact build snapshot in one holdout group", function()
		local first = certifiedRecord("mirror-a", 1)
		local mirrored = certifiedRecord("mirror-b", 2)
		mirrored.buildState = assert(json.decode(assert(json.encode(first.buildState))))
		mirrored.lineage.snapshotFingerprint = first.lineage.snapshotFingerprint
		mirrored.lineage.fingerprint = string.rep("a", 63) .. "2"
		mirrored.source.sourceUrl = "https://another.example/build/mirror-b"
		local dataset = TrainingData.Prepare({ first, mirrored }, expectedEngine)
		assert.are.equal("blocked_source_lineage_holdout", dataset.status)
		assert.are.equal(1, dataset.sourceLineages)
		assert.are.equal(0, dataset.trainingRows)
		assert.are.equal(0, dataset.holdoutRows)
	end)

	it("keeps changed snapshots from one public source together", function()
		local first = certifiedRecord("source-variant-a", 1)
		local changed = certifiedRecord("source-variant-b", 2)
		changed.lineage.fingerprint = first.lineage.fingerprint
		changed.source.sourceUrl = first.source.sourceUrl
		local dataset = TrainingData.Prepare({ first, changed }, expectedEngine)
		assert.are.equal("blocked_source_lineage_holdout", dataset.status)
		assert.are.equal(1, dataset.sourceLineages)
		assert.are.equal(0, dataset.trainingRows)
		assert.are.equal(0, dataset.holdoutRows)
	end)

	it("rejects stale engine versions and inconsistent numeric labels", function()
		local stale = certifiedRecord("stale", 1)
		stale.engine.dataVersion = "3.28"
		stale.engine.treeVersion = "3_28"
		local wrongDelta = certifiedRecord("wrong-delta", 2)
		wrongDelta.candidate.metrics.CombinedDPS = 111
		local dataset = TrainingData.Prepare({ stale, wrongDelta }, expectedEngine)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.metric_delta_mismatch)
		local otherVersion = TrainingData.Prepare({ stale }, {
			pobVersion = "3.28.0", pobBranch = "dev", dataVersion = "3.28", treeVersion = "3_28",
		})
		assert.are.equal(0, otherVersion.eligibleRows)
		assert.are.equal(1, otherVersion.excludedReasons.engine_version_mismatch)
	end)

	it("rejects a changed or missing manifest fingerprint before supervised export", function()
		local changed = certifiedRecord("changed-manifest", 1)
		changed.engine.manifestFingerprint = string.rep("b", 64)
		local missing = certifiedRecord("missing-manifest", 2)
		missing.engine.manifestFingerprint = nil
		local dataset = TrainingData.Prepare({ changed, missing }, expectedEngine)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.engine_version_mismatch)
		assert.are.equal(1, dataset.excludedReasons.missing_engine_manifestFingerprint)
		local noCurrentIdentity = TrainingData.Prepare({ certifiedRecord("no-current-identity", 3) }, nil)
		assert.are.equal(0, noCurrentIdentity.eligibleRows)
		assert.are.equal(1, noCurrentIdentity.excludedReasons.current_engine_identity_missing)
	end)

	it("rejects free-form metric names before they can enter exported labels", function()
		local record = certifiedRecord("private-metric-key", 1)
		record.baseline.metrics["private metric note"] = 5
		record.candidate.metrics["private metric note"] = 7
		record.metricDelta["private metric note"] = 2
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.invalid_metric_key)
	end)

	it("reports the need for a distinct source lineage instead of leaking variants into holdout", function()
		local first, second = certifiedRecord("pair-a", 1), certifiedRecord("pair-b", 1)
		second.buildState.allocatedNodeIds = { 101, 102, 999, 1001 }
		second.buildState.mainSkill = "Arc"
		local dataset = TrainingData.Prepare({ first, second }, expectedEngine)
		assert.are.equal("blocked_source_lineage_holdout", dataset.status)
		assert.are.equal(1, dataset.sourceLineages)
		assert.are.equal(0, dataset.trainingRows)
		assert.are.equal(0, dataset.holdoutRows)
	end)

	it("blocks a record when local consent or source-use rights are missing", function()
		local noConsent = certifiedRecord("no-consent", 1)
		noConsent.certification.attestations.localTrainingConsent = false
		local noRights = certifiedRecord("no-rights", 2)
		noRights.certification.attestations.sourceRightsVerified = false
		local dataset = TrainingData.Prepare({ noConsent, noRights }, expectedEngine)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.local_training_consent_missing)
		assert.are.equal(1, dataset.excludedReasons.source_rights_unverified)
	end)

	it("does not admit schema-2 approvals or rights summaries without a verified basis and scope", function()
		local legacy = certifiedRecord("legacy-rights-review", 1)
		legacy.certification.reviewSchemaVersion = 2
		local wrongScope = certifiedRecord("wrong-rights-scope", 2)
		wrongScope.certification.sourceRights.scope = "remote_training"
		local noBasis = certifiedRecord("missing-rights-basis", 3)
		noBasis.certification.sourceRights.basis = "public_url"
		local dataset = TrainingData.Prepare({ legacy, wrongScope, noBasis }, expectedEngine)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(0, dataset.excludedReasons.local_training_consent_missing or 0)
		assert.are.equal(3, dataset.excludedReasons.source_rights_evidence_missing)
	end)

	it("rejects legacy record schemas without rewriting their stored contents", function()
		local record = certifiedRecord("legacy-record", 1)
		record.schemaVersion = 1
		local dataset = TrainingData.Prepare({ record }, expectedEngine)
		assert.are.equal(0, dataset.eligibleRows)
		assert.are.equal(1, dataset.excludedReasons.unsupported_record_schema)

		local path = os.tmpname()
		local file = assert(io.open(path, "wb"))
		record.recordId = "study-20261022T000000Z-1-1"
		assert(file:write(assert(json.encode(record)), "\n"))
		assert(file:close())
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29", "3.29.0", "dev", string.rep("a", 64)))
		assert.are.equal(1, listed.totalRecords)
		assert.are.equal(0, listed.trainingEligible)
		local read = assert(StudyRecords.ReadById(path, record.recordId, "3.29", "3_29", "3.29.0", "dev", string.rep("a", 64)))
		assert.are.equal(1, read.schemaVersion)
		assert(os.remove(path))
	end)

	it("groups public-source variants by a local lineage fingerprint and redacts URLs from AI views", function()
		local root = os.tmpname()
		os.remove(root)
		root = root .. "-optimizer-lineage"
		assert.is_truthy(createTestDirectory(root))
		local storePath, storeDirectory = StudyRecords.GetStorePath(root)
		assert.is_truthy(createTestDirectory(storeDirectory))
		local original = certifiedRecord("lineage-original", 1)
		local variant = certifiedRecord("lineage-variant", 1)
		variant.buildState.mainSkill = "Arc"
		local storedOriginal = assert(StudyRecords.AppendToPath(original, storePath))
		local storedVariant = assert(StudyRecords.AppendToPath(variant, storePath))
		local readOriginal = assert(StudyRecords.ReadById(storePath, storedOriginal.recordId, "3.29", "3_29", "3.29.0", "dev", string.rep("a", 64)))
		local readVariant = assert(StudyRecords.ReadById(storePath, storedVariant.recordId, "3.29", "3_29", "3.29.0", "dev", string.rep("a", 64)))
		assert.are.equal(2, readOriginal.schemaVersion)
		assert.are.equal(readOriginal.lineage.fingerprint, readVariant.lineage.fingerprint)
		local aiView = StudyRecords.RedactForAI(readOriginal)
		local encoded = assert(json.encode(aiView))
		assert.is_nil(encoded:find("token=private", 1, true))
		assert.is_nil(encoded:find("https://example.invalid", 1, true))
		assert.is_true(aiView.source.sourceUrlRedacted)
		assert.is_true(aiView.lineage.verified)
		assert(os.remove(storePath))
		assert.are.equal(0, crt._rmdir(storeDirectory))
		assert.are.equal(0, crt._rmdir(root))
	end)

	it("exposes a bounded readiness summary from the local study listing", function()
		local path = os.tmpname()
		os.remove(path)
		local stored = assert(StudyRecords.AppendToPath({
			engine = { dataVersion = "3.29", treeVersion = "3_29" },
			admission = { exactCalculated = true, trainingEligible = false },
		}, path))
		assert.is_truthy(stored.recordId)
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29", "3.29.0", "dev", string.rep("a", 64)))
		assert.are.equal(0, listed.trainingEligible)
		assert.are.equal("blocked_no_certified_records", listed.trainingReadiness.status)
		assert.is_true(listed.trainingReadiness.popularityFeaturesExcluded)
		os.remove(path)
	end)
end)
