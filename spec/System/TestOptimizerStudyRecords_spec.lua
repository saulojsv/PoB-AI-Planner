local StudyRecords = require("Modules.Optimizer.StudyRecords")
local Version = require("Modules.Optimizer.Version")
local json = require("dkjson")

local function exactPairRecord()
	return {
		kind = "gem_variant_pair",
		engine = { pobVersion = "fixture", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
			manifestFingerprint = string.rep("a", 64), lookupTableStatus = "not_audited" },
		buildState = {
			characterLevel = 90,
			class = { class = "Witch", ascendancy = "Elementalist" },
			allocatedNodeIds = { 101, 102, 103 },
			mainSkill = "Fireball",
			configuration = { values = { enemyIsBoss = true } },
			exactMetrics = { CombinedDPS = 100 },
		},
		experiment = {
			unit = "one_gem_parameter",
			changedParameter = "quality",
			groupIndex = 1,
			gemIndex = 1,
			before = { gemId = "Fireball", level = 1, quality = 0 },
			after = { gemId = "Fireball", level = 1, quality = 1 },
		},
		baseline = { metrics = { CombinedDPS = 100 }, requirements = { feasible = true } },
		candidate = { metrics = { CombinedDPS = 110 }, requirements = { feasible = true } },
		admission = { exactCalculated = true },
		metricDelta = { CombinedDPS = 10 },
	}
end

local function reviewableRecord()
	local record = exactPairRecord()
	record.kind = "passive_node_pair"
	record.engine = { pobVersion = "fixture", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
		manifestFingerprint = string.rep("a", 64), lookupTableStatus = "not_audited" }
	record.buildState.class = { class = "Witch", ascendancy = "Elementalist" }
	record.buildState.configuration = { activeConfigSetId = 1, title = "Pinnacle", values = { enemyIsBoss = true }, customModifiers = { } }
	record.experiment = { unit = "one_passive_node", addedNodeIds = { 205 }, removedNodeIds = { } }
	record.baseline.activitySustain = { status = "pass" }
	record.candidate.activitySustain = { status = "pass" }
	record.admission = {
		exactCalculated = true,
		useRequirementsFeasible = true,
		activityStatus = "pass",
		activityRatesFeasible = true,
		activitySustainCertified = false,
		scenarioConditionsCertified = false,
		lookupTablesCertified = false,
	}
	return record
end

local function validRightsEvidence()
	return { basis = "open_license", licenseId = "CC-BY-4.0",
		licenseUrl = "https://creativecommons.org/licenses/by/4.0/" }
end

local expectedEngine = { pobVersion = "fixture", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
	manifestFingerprint = string.rep("a", 64) }

describe("Optimizer exact study records", function()
	it("requires bounded, typed evidence for the fixed local-training scope", function()
		local missing = StudyRecords.NormalizeRightsEvidence({ basis = "open_license", licenseId = "CC-BY-4.0" })
		assert.is_nil(missing)
		local unsafeUrl = StudyRecords.NormalizeRightsEvidence({ basis = "open_license", licenseId = "CC-BY-4.0",
			licenseUrl = "https://license.example/text?token=secret" })
		assert.is_nil(unsafeUrl)
		local personalReference = StudyRecords.NormalizeRightsEvidence({ basis = "creator_permission", permissionReference = "owner@example.com" })
		assert.is_nil(personalReference)
		local accepted = assert(StudyRecords.NormalizeRightsEvidence({ basis = "creator_permission", permissionReference = "permission:ticket-2026-001" }))
		assert.are.equal("offline_local_model_training", accepted.scope)
	end)

	it("uses an explicit local engine branch when the checkout manifest has no branch", function()
		local oldBranch, oldDevMode = launch.versionBranch, launch.devMode
		local ok, failure = pcall(function()
			launch.versionBranch = nil
			launch.devMode = true
			assert.are.equal("local", Version.Branch())
			assert.are.equal("local", Version.Snapshot({ spec = { treeVersion = "3_29" } }).pobBranch)
			launch.versionBranch, launch.devMode = "dev", true
			assert.are.equal("dev", Version.Branch())
		end)
		launch.versionBranch, launch.devMode = oldBranch, oldDevMode
		if not ok then error(failure) end
	end)

	it("uses PoB's loaded game-tree data version when data.version is not defined", function()
		local build = { data = { }, spec = { treeVersion = "3_29" } }
		assert.are.equal("3.29", Version.Data(build, { ["3_29"] = { display = "3.29" } }))
		assert.are.equal("tree_compatibility_key", Version.DataSource(build))
		build.data.version = "custom-data-3.29"
		assert.are.equal("custom-data-3.29", Version.Data(build, { ["3_29"] = { display = "3.29" } }))
		assert.are.equal("pob_loaded_data_table_version", Version.DataSource(build))
	end)

	it("persists and retrieves versioned exact pairs without training admission", function()
		local path = os.tmpname()
		os.remove(path)
		local record = {
			kind = "gem_variant_pair",
			source = { type = "native_comparison_build", comparisonId = "pob-comparison-fixture", label = "Local build", index = 2 },
			engine = { pobVersion = "fixture", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
				manifestFingerprint = string.rep("a", 64), lookupTableStatus = "not_audited" },
			admission = { exactCalculated = true, trainingEligible = false },
			experiment = {
				unit = "one_gem_parameter",
				changedParameter = "quality",
				before = { gemId = "Fireball", level = 1, quality = 0 },
				after = { gemId = "Fireball", level = 1, quality = 1 },
			},
			baseline = { metrics = { CombinedDPS = 100 } },
			candidate = { metrics = { CombinedDPS = 110 } },
			metricDelta = { CombinedDPS = 10 },
		}
		local stored, storeError = StudyRecords.AppendToPath(record, path)
		assert.is_truthy(stored, storeError)
		assert.is_truthy(stored.recordId)
		local found, readError = StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "fixture", "dev", string.rep("a", 64))
		assert.is_truthy(found, readError)
		assert.are.equal("current", found.versionStatus)
		assert.is_true(found.quarantined)
		assert.is_false(found.trainingEligible)
		assert.are.equal(10, found.metricDelta.CombinedDPS)
		local listed, listError = StudyRecords.List(path, 5, "3.29", "3_29", "fixture", "dev", string.rep("a", 64))
		assert.is_truthy(listed, listError)
		assert.are.equal(1, listed.totalRecords)
		assert.are.equal(1, #listed.records)
		assert.are.equal("gem_variant_pair", listed.records[1].kind)
		assert.are.equal("native_comparison_build", listed.records[1].sourceType)
		assert.is_nil(listed.records[1].sourceId)
		assert.is_nil(listed.records[1].sourceLabel)
		assert.is_nil(listed.records[1].sourceIndex)
		assert.are.equal("quality", listed.records[1].experiment.changedParameter)
		assert.are.equal(0, listed.records[1].experiment.before.quality)
		assert.are.equal(1, listed.records[1].experiment.after.quality)
		assert.is_true(listed.records[1].quarantined)
		os.remove(path)
	end)

	it("reports privacy-safe learning coverage by exact family and engine without claiming combination coverage", function()
		local path = os.tmpname()
		os.remove(path)
		local gem = exactPairRecord()
		gem.source = { type = "public_build_study", label = "PRIVATE imported title", sourceUrl = "https://private.invalid/secret" }
		gem.buildState.skillGroups = { { activeSkill = "Fireball", supportGems = { "AddedChaosDamageSupport" } } }
		local first = assert(StudyRecords.AppendToPath(gem, path))
		local duplicate = assert(StudyRecords.AppendToPath(gem, path))
		assert.is_true(duplicate.duplicate)

		local passive = exactPairRecord()
		passive.kind = "passive_node_pair"
		passive.experiment = { unit = "one_passive_node", addedNodeIds = { 201 }, removedNodeIds = { } }
		assert(StudyRecords.AppendToPath(passive, path))

		local item = exactPairRecord()
		item.kind = "item_slot_pair"
		item.engine.dataVersion, item.engine.treeVersion = "3.28", "3_28"
		item.experiment = { slot = "Helmet", before = { itemId = "private-item-a" }, after = { itemId = "private-item-b" } }
		assert(StudyRecords.AppendToPath(item, path))

		local incomplete = exactPairRecord()
		incomplete.kind = "legacy_or_unverified_pair"
		incomplete.admission.exactCalculated = false
		incomplete.baseline.metrics, incomplete.candidate.metrics = { }, { }
		assert(StudyRecords.AppendToPath(incomplete, path))

		local listed = assert(StudyRecords.List(path, 25, expectedEngine.dataVersion, expectedEngine.treeVersion,
			expectedEngine.pobVersion, expectedEngine.pobBranch, expectedEngine.manifestFingerprint))
		local coverage = listed.learningCoverage
		assert.are.equal(4, coverage.uniqueRecords)
		assert.are.equal(0, coverage.duplicateRecordsSuppressed)
		assert.are.equal(3, coverage.exactPairRows)
		assert.are.equal(1, coverage.unverifiedPairRows)
		assert.are.equal(3, coverage.versionRows.current)
		assert.are.equal(1, coverage.versionRows.mismatch)
		assert.are.equal(1, coverage.experimentFamilies.gemVariantPairs)
		assert.are.equal(1, coverage.experimentFamilies.passiveNodePairs)
		assert.are.equal(1, coverage.experimentFamilies.itemSlotPairs)
		assert.are.equal(4, coverage.reviewRows.pending)
		assert.are.equal(1, coverage.contextDiversity.classStartsObserved)
		assert.are.equal(3, coverage.contextDiversity.sourceBuildStatesObserved)
		assert.are.equal("not_measured", coverage.combinationCoverage)
		assert.are.equal("report_only", coverage.graphRole)
		assert.is_false(coverage.modelTrainingEnabled)
		local encoded = assert(json.encode(coverage))
		assert.is_nil(encoded:find("PRIVATE imported title", 1, true))
		assert.is_nil(encoded:find("private.invalid", 1, true))
		assert.is_nil(encoded:find("private-item-a", 1, true))
		os.remove(path)
	end)

	it("returns empty learning coverage without creating study storage", function()
		local path = os.tmpname()
		os.remove(path)
		local listed = assert(StudyRecords.List(path, 25, expectedEngine.dataVersion, expectedEngine.treeVersion,
			expectedEngine.pobVersion, expectedEngine.pobBranch, expectedEngine.manifestFingerprint))
		assert.are.equal("no_exact_pairs", listed.learningCoverage.status)
		assert.are.equal(0, listed.learningCoverage.contextDiversity.sourceBuildStatesObserved)
		assert.are.equal(0, listed.learningCoverage.experimentFamilies.gemVariantPairs)
		local file = io.open(path, "rb")
		assert.is_nil(file)
	end)

	it("quarantines records when either PoB data or passive-tree version changes", function()
		local path = os.tmpname()
		os.remove(path)
		local stored = assert(StudyRecords.AppendToPath({
			engine = { pobVersion = "fixture", pobBranch = "dev", dataVersion = "3.28", treeVersion = "3_28",
				manifestFingerprint = string.rep("a", 64) },
			admission = { exactCalculated = true, trainingEligible = false },
		}, path))
		local found = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "fixture", "dev", string.rep("a", 64)))
		assert.are.equal("version_mismatch", found.versionStatus)
		assert.is_true(found.quarantined)
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29", "fixture", "dev", string.rep("a", 64)))
		assert.are.equal("version_mismatch", listed.records[1].versionStatus)
		os.remove(path)
	end)

	it("rejects malformed record IDs and oversized records before writing", function()
		assert.is_nil(StudyRecords.ReadById("unused", "../../pob-build.xml", "3.29", "3_29"))
		local path = os.tmpname()
		os.remove(path)
		local large = { payload = string.rep("x", StudyRecords.MAX_RECORD_BYTES) }
		local stored = StudyRecords.AppendToPath(large, path)
		assert.is_nil(stored)
		local file = io.open(path, "rb")
		assert.is_nil(file)
		os.remove(path)
	end)

	it("compacts redundant study snapshot details only when needed and deduplicates the compact record", function()
		local path = os.tmpname()
		os.remove(path)
		local function nodeHeavyRecord()
			local record = exactPairRecord()
			record.buildState.allocatedNodeIds = { 101, 102, 103 }
			record.buildState.allocatedNodes = { }
			for index = 1, 900 do
				record.buildState.allocatedNodes[index] = { id = index, name = string.rep("Passive node ", 12), type = "Normal" }
			end
			return record
		end
		local first = assert(StudyRecords.AppendToPath(nodeHeavyRecord(), path))
		local stored = assert(StudyRecords.ReadById(path, first.recordId, "3.29", "3_29"))
		assert.is_nil(stored.buildState.allocatedNodes)
		assert.are.same({ 101, 102, 103 }, stored.buildState.allocatedNodeIds)
		assert.are.equal("allocatedNodes", stored.buildState.recordCompaction.omittedFields[1])
		assert.are.equal(100, stored.buildState.exactMetrics.CombinedDPS)
		assert.is_false(stored.trainingEligible)
		local repeated = assert(StudyRecords.AppendToPath(nodeHeavyRecord(), path))
		assert.is_true(repeated.duplicate)
		assert.are.equal(first.recordId, repeated.recordId)

		local verboseReadiness = exactPairRecord()
		verboseReadiness.buildState.characterLevel = 91
		verboseReadiness.buildState.buildReadiness = { report = string.rep("diagnostic ", 6000) }
		local readinessStored = assert(StudyRecords.AppendToPath(verboseReadiness, path))
		local readinessRecord = assert(StudyRecords.ReadById(path, readinessStored.recordId, "3.29", "3_29"))
		assert.is_nil(readinessRecord.buildState.buildReadiness)
		assert.are.equal("buildReadiness", readinessRecord.buildState.recordCompaction.omittedFields[1])
		assert.are.equal(91, readinessRecord.buildState.characterLevel)
		assert.are.equal(100, readinessRecord.buildState.exactMetrics.CombinedDPS)
		os.remove(path)
	end)

	it("compacts the expanded skill-cost audit for oversized factorial records while retaining exact cells", function()
		local path = os.tmpname()
		os.remove(path)
		local record = exactPairRecord()
		record.kind = "skill_support_factorial_interaction"
		record.buildState.skillGroups = { { activeSkill = "Boneshatter", supports = { "Melee Physical Damage" } } }
		record.buildState.fullDPSPayability = { status = "pass", feasible = true }
		record.buildState.skillCostAudit = { verbose = string.rep("exact per-skill cost evidence ", 2800) }
		record.experiment = {
			unit = "four_cell_skill_support_factorial", factorialSchemaVersion = 1,
			formula = "combined - factorA - factorB + baseline",
			factorA = { operation = "replace_selected_main_skill_gem", before = { gemId = "Boneshatter" }, after = { gemId = "Heavy Strike" } },
			factorB = { operation = "replace_support_gem", before = { gemId = "Melee Physical Damage" }, after = { gemId = "Fortify" } },
			socketStatus = "native_linked_group",
		}
		record.baseline = { metrics = { CombinedDPS = 100 }, requirements = { feasible = true },
			mainSkillPayability = { feasible = true }, activitySustain = { status = "pass" } }
		record.candidate = { metrics = { CombinedDPS = 140 }, requirements = { feasible = true },
			mainSkillPayability = { feasible = true }, activitySustain = { status = "pass" } }
		record.factorial = {
			formula = record.experiment.formula,
			cells = {
				baseline = { metrics = { CombinedDPS = 100 }, mainSkillPayability = { feasible = true }, activitySustain = { status = "pass" } },
				factorA = { metrics = { CombinedDPS = 120 }, mainSkillPayability = { feasible = true }, activitySustain = { status = "pass" } },
				factorB = { metrics = { CombinedDPS = 110 }, mainSkillPayability = { feasible = true }, activitySustain = { status = "pass" } },
				combined = { metrics = { CombinedDPS = 140 }, mainSkillPayability = { feasible = true }, activitySustain = { status = "pass" } },
			},
			interaction = { CombinedDPS = { interaction = 10 } }, metricCount = 1,
		}
		local stored, storeError = StudyRecords.AppendToPath(record, path)
		assert.is_truthy(stored, storeError)
		local saved = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29"))
		assert.is_nil(saved.buildState.skillCostAudit)
		assert.are.equal("pass", saved.buildState.fullDPSPayability.status)
		assert.are.same({ "skillCostAudit" }, saved.buildState.recordCompaction.omittedFields)
		assert.are.equal(100, saved.factorial.cells.baseline.metrics.CombinedDPS)
		assert.are.equal(140, saved.factorial.cells.combined.metrics.CombinedDPS)
		assert.are.equal(10, saved.factorial.interaction.CombinedDPS.interaction)
		assert.is_false(saved.trainingEligible)
		os.remove(path)
	end)

	it("does not append an identical exact build experiment twice", function()
		local path = os.tmpname()
		os.remove(path)
		local original = exactPairRecord()
		original.label = "Initial hypothesis"
		original.experiment.label = "Initial hypothesis"
		local first = assert(StudyRecords.AppendToPath(original, path))
		assert.is_false(first.duplicate)
		local repeated = exactPairRecord()
		repeated.label = "Reworded hypothesis"
		repeated.experiment.label = "Reworded hypothesis"
		local second = assert(StudyRecords.AppendToPath(repeated, path))
		assert.is_true(second.duplicate)
		assert.are.equal(first.recordId, second.recordId)
		assert.are.equal(0, second.storedBytes)
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29"))
		assert.are.equal(1, listed.totalRecords)
		assert.are.equal(0, listed.duplicateRecordsSuppressed)
		os.remove(path)
	end)

	it("normalizes safe numeric keys in sparse PoB item and node maps for duplicate identity", function()
		local path = os.tmpname()
		os.remove(path)
		local function nodeMapRecord()
			local record = exactPairRecord()
			record.buildState.masterySelections = { [4492] = 5356 }
			record.buildState.jewelBySocket = { [3] = "Lethal Pride", [17] = "Militant Faith" }
			record.buildState.items = { [16] = { name = "Rare Dagger", slot = "Weapon 1" }, [30] = { name = "The Squire", slot = "Weapon 2" } }
			return record
		end
		local first = assert(StudyRecords.AppendToPath(nodeMapRecord(), path))
		local repeated = assert(StudyRecords.AppendToPath(nodeMapRecord(), path))
		assert.is_true(repeated.duplicate)
		assert.are.equal(first.recordId, repeated.recordId)
		local stored = assert(StudyRecords.ReadById(path, first.recordId, "3.29", "3_29"))
		assert.are.equal(5356, stored.buildState.masterySelections["4492"] or stored.buildState.masterySelections[4492])
		assert.are.equal("Lethal Pride", stored.buildState.jewelBySocket["3"] or stored.buildState.jewelBySocket[3])
		local rareDagger = stored.buildState.items["16"] or stored.buildState.items[16]
		local theSquire = stored.buildState.items["30"] or stored.buildState.items[30]
		assert.are.equal("Rare Dagger", rareDagger.name)
		assert.are.equal("The Squire", theSquire.name)
		os.remove(path)
	end)

	it("rejects numeric and numeric-looking string keys that collide in study identity", function()
		local path = os.tmpname()
		os.remove(path)
		local record = exactPairRecord()
		record.buildState.items = { [16] = { name = "Numeric key" }, ["16"] = { name = "String key" } }
		local stored, storeError = StudyRecords.AppendToPath(record, path)
		assert.is_nil(stored)
		assert.is_truthy(storeError:find("colliding object keys", 1, true))
		assert.is_nil(io.open(path, "rb"))
		os.remove(path)
	end)

	it("keeps distinct builds and gem variants separate", function()
		local path = os.tmpname()
		os.remove(path)
		assert(StudyRecords.AppendToPath(exactPairRecord(), path))
		local otherBuild = exactPairRecord()
		otherBuild.buildState.characterLevel = 91
		local buildStored = assert(StudyRecords.AppendToPath(otherBuild, path))
		assert.is_false(buildStored.duplicate)
		local otherVariant = exactPairRecord()
		otherVariant.experiment.after.quality = 2
		local variantStored = assert(StudyRecords.AppendToPath(otherVariant, path))
		assert.is_false(variantStored.duplicate)
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29"))
		assert.are.equal(3, listed.totalRecords)
		os.remove(path)
	end)

	it("includes all factorial cells in idempotent study identity and list summaries", function()
		local path = os.tmpname()
		os.remove(path)
		local function factorialRecord()
			local record = exactPairRecord()
			record.kind = "passive_factorial_interaction"
			record.experiment = {
				unit = "four_cell_passive_factorial",
				factorialSchemaVersion = 1,
				formula = "combined - factorA - factorB + baseline",
				factorA = { operation = "add_passive_node", nodeId = 201 },
				factorB = { operation = "add_passive_node", nodeId = 202 },
			}
			record.factorial = {
				formula = record.experiment.formula,
				cells = {
					factorA = { metrics = { CombinedDPS = 120 }, passivePointsUsed = 4 },
					factorB = { metrics = { CombinedDPS = 130 }, passivePointsUsed = 4 },
				},
				interaction = { CombinedDPS = { interaction = 10 } },
				metricCount = 1,
			}
			return record
		end
		local first = assert(StudyRecords.AppendToPath(factorialRecord(), path))
		local repeated = assert(StudyRecords.AppendToPath(factorialRecord(), path))
		assert.is_true(repeated.duplicate)
		assert.are.equal(first.recordId, repeated.recordId)
		local changedFactorCell = factorialRecord()
		changedFactorCell.factorial.cells.factorA.metrics.CombinedDPS = 121
		local second = assert(StudyRecords.AppendToPath(changedFactorCell, path))
		assert.is_false(second.duplicate)
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29"))
		assert.are.equal(2, listed.totalRecords)
		local summary = listed.records[1]
		assert.are.equal("combined - factorA - factorB + baseline", summary.factorial.formula)
		assert.are.equal(201, summary.factorial.factorANodeId)
		assert.are.equal(202, summary.factorial.factorBNodeId)
		assert.are.equal(1, summary.factorial.metricCount)
		local storedRecord = assert(StudyRecords.ReadById(path, first.recordId, "3.29", "3_29", "fixture", "dev", string.rep("a", 64)))
		assert.is_false(storedRecord.trainingEligible)
		assert.are.equal("training_schema_unsupported", storedRecord.quarantineStatus)
		assert.is_false(storedRecord.reviewAssessment.canApprove)
		assert.is_truthy(table.concat(storedRecord.reviewAssessment.blockers, ",")
			:find("factorial_training_schema_unsupported", 1, true))
		local approved, approvalError = StudyRecords.ReviewToPath(path, first.recordId, "approved",
			{ exactPair = true, scenario = true, activity = true, lookupTables = true,
				localTrainingConsent = true, sourceRightsVerified = true, sourceRightsEvidence = validRightsEvidence() },
			{ pobVersion = "fixture", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
				manifestFingerprint = string.rep("a", 64) })
		assert.is_nil(approved)
		assert.is_truthy(approvalError:find("factorial_training_schema_unsupported", 1, true))
		os.remove(path)
	end)

	it("summarizes skill/support factorial identities without admitting them to one-factor review", function()
		local path = os.tmpname()
		os.remove(path)
		local record = exactPairRecord()
		record.kind = "skill_support_factorial_interaction"
		record.experiment = {
			unit = "four_cell_skill_support_factorial",
			factorialSchemaVersion = 1,
			formula = "combined - factorA - factorB + baseline",
			factorA = { operation = "replace_selected_main_skill_gem", groupIndex = 1, gemIndex = 1,
				before = { gemId = "SkillGemFireball" }, after = { gemId = "SkillGemArc" } },
			factorB = { operation = "replace_support_gem", groupIndex = 1, gemIndex = 2,
				before = { gemId = "SupportGemAddedColdDamage" }, after = { gemId = "SupportGemControlledDestruction" } },
			socketStatus = "unlinked_planning_group",
		}
		record.factorial = {
			formula = record.experiment.formula,
			cells = { baseline = { metrics = { CombinedDPS = 100 } }, factorA = { metrics = { CombinedDPS = 120 } },
				factorB = { metrics = { CombinedDPS = 110 } }, combined = { metrics = { CombinedDPS = 150 } } },
			interaction = { CombinedDPS = { interaction = 20 } }, metricCount = 1,
		}
		local stored = assert(StudyRecords.AppendToPath(record, path))
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29"))
		assert.are.equal(1, listed.totalRecords)
		assert.are.equal("replace_selected_main_skill_gem", listed.records[1].factorial.factorA.operation)
		assert.are.equal("replace_support_gem", listed.records[1].factorial.factorB.operation)
		assert.are.equal("unlinked_planning_group", listed.records[1].factorial.socketStatus)
		local storedRecord = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "3.29.0", "dev"))
		assert.is_false(storedRecord.trainingEligible)
		assert.is_false(storedRecord.reviewAssessment.canApprove)
		assert.is_truthy(table.concat(storedRecord.reviewAssessment.blockers, ",")
			:find("factorial_training_schema_unsupported", 1, true))
		os.remove(path)
	end)

	it("counts two-skill Full DPS factorial evidence while keeping it quarantined", function()
		local path = os.tmpname()
		os.remove(path)
		local record = exactPairRecord()
		record.kind = "skill_skill_factorial_interaction"
		record.experiment = {
			unit = "four_cell_skill_skill_factorial", factorialSchemaVersion = 1,
			formula = "combined - factorA - factorB + baseline",
			factorA = { operation = "replace_full_dps_skill_gem", groupIndex = 1, gemIndex = 1,
				before = { gemId = "SkillGemFireball", effectId = "Fireball", level = 20, quality = 0 },
				after = { gemId = "SkillGemArc", effectId = "Arc", level = 20, quality = 0 }, socketedSupportGemIds = { } },
			factorB = { operation = "replace_full_dps_skill_gem", groupIndex = 2, gemIndex = 1,
				before = { gemId = "SkillGemCyclone", effectId = "Cyclone", level = 20, quality = 0 },
				after = { gemId = "SkillGemFrostBlades", effectId = "FrostBlades", level = 20, quality = 0 }, socketedSupportGemIds = { } },
			socketStatus = "native_linked_groups",
		}
		record.factorial = {
			formula = record.experiment.formula,
			cells = { baseline = { metrics = { FullDPS = 100 } }, factorA = { metrics = { FullDPS = 120 } },
				factorB = { metrics = { FullDPS = 110 } }, combined = { metrics = { FullDPS = 145 } } },
			interaction = { FullDPS = { interaction = 15 } }, metricCount = 1,
		}
		local stored = assert(StudyRecords.AppendToPath(record, path))
		local current = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "fixture", "dev",
			expectedEngine.manifestFingerprint))
		assert.is_false(current.trainingEligible)
		assert.are.equal("training_schema_unsupported", current.quarantineStatus)
		assert.is_false(current.reviewAssessment.canApprove)
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29"))
		assert.are.equal(1, listed.learningCoverage.experimentFamilies.skillSkillFactorialInteractions)
		assert.is_false(listed.learningCoverage.modelTrainingEnabled)
		os.remove(path)
	end)

	it("counts passive/support factorial evidence separately and keeps it quarantined", function()
		local path = os.tmpname()
		os.remove(path)
		local record = exactPairRecord()
		record.kind = "passive_support_factorial_interaction"
		record.experiment = {
			unit = "four_cell_passive_support_factorial", factorialSchemaVersion = 1,
			formula = "combined - factorA - factorB + baseline",
			factorA = { operation = "add_passive_node", nodeId = 501 },
			factorB = { operation = "replace_support_gem", groupIndex = 1, skillGemIndex = 1, gemIndex = 2,
				before = { gemId = "SupportGemAddedFire", level = 20, quality = 20 },
				after = { gemId = "SupportGemControlledDestruction", level = 20, quality = 20 } },
			socketStatus = "native_linked_group",
		}
		record.factorial = {
			formula = record.experiment.formula,
			cells = { baseline = { metrics = { CombinedDPS = 100 } }, factorA = { metrics = { CombinedDPS = 120 } },
				factorB = { metrics = { CombinedDPS = 110 } }, combined = { metrics = { CombinedDPS = 150 } } },
			interaction = { CombinedDPS = { interaction = 20 } }, metricCount = 1,
		}
		local stored, storeError = StudyRecords.AppendToPath(record, path)
		assert.is_truthy(stored, storeError)
		local current = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "fixture", "dev", string.rep("a", 64)))
		assert.is_false(current.trainingEligible)
		assert.are.equal("training_schema_unsupported", current.quarantineStatus)
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29"))
		assert.are.equal(1, listed.learningCoverage.experimentFamilies.passiveSupportFactorialInteractions)
		assert.is_false(listed.learningCoverage.modelTrainingEnabled)
		os.remove(path)
	end)

	it("keeps skill/item-slot factorial records quarantined even when reviewed", function()
		local path = os.tmpname()
		os.remove(path)
		local record = exactPairRecord()
		record.kind = "skill_item_slot_factorial_interaction"
		record.experiment = {
			unit = "four_cell_skill_item_slot_factorial", factorialSchemaVersion = 1,
			formula = "combined - factorA - factorB + baseline",
			factorA = { operation = "replace_selected_main_skill_gem", before = { gemId = "Fireball" }, after = { gemId = "Arc" } },
			factorB = { operation = "replace_item_in_slot", slot = "Helmet", before = { itemId = 1 }, after = { itemId = 2 } },
		}
		record.factorial = {
			formula = record.experiment.formula,
			cells = { baseline = { metrics = { CombinedDPS = 100 } }, factorA = { metrics = { CombinedDPS = 120 } },
				factorB = { metrics = { CombinedDPS = 110 } }, combined = { metrics = { CombinedDPS = 150 } } },
			interaction = { CombinedDPS = { interaction = 20 } }, metricCount = 1,
		}
		local stored = assert(StudyRecords.AppendToPath(record, path))
		local current = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "3.29.0", "dev"))
		assert.is_false(current.trainingEligible)
		assert.is_false(current.reviewAssessment.canApprove)
		assert.is_truthy(table.concat(current.reviewAssessment.blockers, ","):find("factorial_training_schema_unsupported", 1, true))
		local approved, approveError = StudyRecords.ReviewToPath(path, stored.recordId, "approved",
			{ exactPair = true, scenario = true, activity = true, lookupTables = true,
				localTrainingConsent = true, sourceRightsVerified = true, sourceRightsEvidence = validRightsEvidence() },
			{ pobVersion = "3.29.0", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29" })
		assert.is_nil(approved)
		assert.is_truthy(approveError:find("factorial_training_schema_unsupported", 1, true))
		os.remove(path)
	end)

	it("lists passive/item factorial observations and blocks one-factor training review", function()
		local path = os.tmpname()
		os.remove(path)
		local record = exactPairRecord()
		record.kind = "passive_item_slot_factorial_interaction"
		record.experiment = {
			unit = "four_cell_passive_item_slot_factorial", factorialSchemaVersion = 1,
			formula = "combined - factorA - factorB + baseline", socketStatus = "native_linked_group",
			factorA = { operation = "add_passive_node", nodeId = 501 },
			factorB = { operation = "replace_item_in_slot", slot = "Helmet",
				before = { itemId = 1, poBItemText = "Rare Helmet A" },
				after = { itemId = 2, poBItemText = "Rare Helmet B" } },
		}
		record.factorial = {
			formula = record.experiment.formula,
			cells = { baseline = { metrics = { CombinedDPS = 100 } }, factorA = { metrics = { CombinedDPS = 120 } },
				factorB = { metrics = { CombinedDPS = 110 } }, combined = { metrics = { CombinedDPS = 150 } } },
			interaction = { CombinedDPS = { baseline = 100, factorA = 120, factorB = 110, combined = 150, interaction = 20 } },
			metricCount = 1,
		}
		local stored = assert(StudyRecords.AppendToPath(record, path))
		local current = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "3.29.0", "dev"))
		assert.is_false(current.trainingEligible)
		assert.is_false(current.reviewAssessment.canApprove)
		assert.is_truthy(table.concat(current.reviewAssessment.blockers, ","):find("factorial_training_schema_unsupported", 1, true))
		local approved, approveError = StudyRecords.ReviewToPath(path, stored.recordId, "approved",
			{ exactPair = true, scenario = true, activity = true, lookupTables = true,
				localTrainingConsent = true, sourceRightsVerified = true, sourceRightsEvidence = validRightsEvidence() },
			{ pobVersion = "3.29.0", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29" })
		assert.is_nil(approved)
		assert.is_truthy(approveError:find("factorial_training_schema_unsupported", 1, true))
		local listed = assert(StudyRecords.List(path, 25, "3.29", "3_29", "3.29.0", "dev"))
		assert.are.equal(1, listed.learningCoverage.experimentFamilies.passiveItemFactorialInteractions)
		assert.is_false(listed.trainingReadiness.modelTrainingEnabled)
		os.remove(path)
	end)

	it("uses the exact PoB item text to distinguish item-slot research pairs", function()
		local path = os.tmpname()
		os.remove(path)
		local original = exactPairRecord()
		original.kind = "item_slot_pair"
		original.experiment = { unit = "one_item_slot", slot = "Amulet", before = { itemId = 1, poBItemText = "Rare amulet A" }, after = { itemId = 2, poBItemText = "Rare amulet B" } }
		local first = assert(StudyRecords.AppendToPath(original, path))
		local storedRecord = assert(StudyRecords.ReadById(path, first.recordId, "3.29", "3_29"))
		assert.are.equal("Rare amulet B", storedRecord.experiment.after.poBItemText)
		local duplicate = exactPairRecord()
		duplicate.kind = "item_slot_pair"
		duplicate.label = "Different wording"
		duplicate.experiment = { unit = "one_item_slot", slot = "Amulet", label = "Different wording", before = { itemId = 1, poBItemText = "Rare amulet A" }, after = { itemId = 2, poBItemText = "Rare amulet B" } }
		local repeated = assert(StudyRecords.AppendToPath(duplicate, path))
		assert.is_true(repeated.duplicate)
		assert.are.equal(first.recordId, repeated.recordId)
		local changed = exactPairRecord()
		changed.kind = "item_slot_pair"
		changed.experiment = { unit = "one_item_slot", slot = "Amulet", before = { itemId = 1, poBItemText = "Rare amulet A" }, after = { itemId = 2, poBItemText = "Rare amulet C" } }
		local distinct = assert(StudyRecords.AppendToPath(changed, path))
		assert.is_false(distinct.duplicate)
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29"))
		assert.are.equal(2, listed.totalRecords)
		assert.is_nil(listed.records[1].experiment.after.poBItemText)
		os.remove(path)
	end)

	it("suppresses duplicate rows already present in a legacy JSONL store", function()
		local path = os.tmpname()
		os.remove(path)
		local stored = assert(StudyRecords.AppendToPath(exactPairRecord(), path))
		local input = assert(io.open(path, "rb"))
		local decoded = assert(json.decode(input:read("*l")))
		input:close()
		decoded.recordId = decoded.recordId:gsub("%-%d+$", "-999999")
		decoded.recordedAt = "2026-10-19T00:00:00Z"
		local output = assert(io.open(path, "ab"))
		assert(output:write(assert(json.encode(decoded)), "\n"))
		output:close()
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29"))
		assert.are.equal(1, listed.totalRecords)
		assert.are.equal(1, listed.duplicateRecordsSuppressed)
		assert.are.equal(decoded.recordId, listed.records[1].recordId)
		local nextAttempt = assert(StudyRecords.AppendToPath(exactPairRecord(), path))
		assert.is_true(nextAttempt.duplicate)
		assert.are.equal(stored.recordId, nextAttempt.recordId)
		os.remove(path)
	end)

	it("requires explicit local attestations, stores approval separately, and admits only the unchanged pair", function()
		local path = os.tmpname()
		os.remove(path)
		local reviewPath = path .. ".reviews.jsonl"
		os.remove(reviewPath)
		local stored = assert(StudyRecords.AppendToPath(reviewableRecord(), path))
		local rawFile = assert(io.open(path, "rb"))
		local originalLine = rawFile:read("*l")
		rawFile:close()
		local original = assert(json.decode(originalLine))
		local assessment = StudyRecords.AssessForReview(original, expectedEngine)
		assert.is_true(assessment.canApprove)
		local missingAttestations, attestationError = StudyRecords.ReviewToPath(path, stored.recordId, "approved",
			{ exactPair = true }, expectedEngine)
		assert.is_nil(missingAttestations)
		assert.is_truthy(attestationError and attestationError:find("local-training consent", 1, true))
		local missingRights, rightsError = StudyRecords.ReviewToPath(path, stored.recordId, "approved", {
			exactPair = true, scenario = true, activity = true, lookupTables = true,
			localTrainingConsent = true, sourceRightsVerified = true,
		}, expectedEngine)
		assert.is_nil(missingRights)
		assert.is_truthy(rightsError and rightsError:find("Source-use evidence is required", 1, true))
		local blockedFile = io.open(reviewPath, "rb")
		assert.is_nil(blockedFile, "a blocked review must not create a journal")

		local approval = assert(StudyRecords.ReviewToPath(path, stored.recordId, "approved", {
			exactPair = true, scenario = true, activity = true, lookupTables = true,
			localTrainingConsent = true, sourceRightsVerified = true,
				sourceRightsEvidence = validRightsEvidence(),
		}, expectedEngine))
		assert.is_false(approval.duplicate)
		local reviewed = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "fixture", "dev", string.rep("a", 64)))
		assert.is_true(reviewed.trainingEligible)
		assert.is_false(reviewed.quarantined)
		assert.are.equal("approved", reviewed.reviewStatus)
		assert.are.equal(3, reviewed.certification.reviewSchemaVersion)
		assert.are.same({ basis = "open_license", licenseId = "CC-BY-4.0", scope = "offline_local_model_training" },
			reviewed.certification.sourceRights)
		assert.are.equal("certified", reviewed.engine.lookupTableStatus)
		assert.is_true(reviewed.certification.attestations.lookupTables)
		local listed = assert(StudyRecords.List(path, 5, "3.29", "3_29", "fixture", "dev", string.rep("a", 64)))
		assert.are.equal(1, listed.trainingEligible)
		assert.are.equal("blocked_source_lineage_holdout", listed.trainingReadiness.status)

		local afterReview = assert(io.open(path, "rb"))
		assert.are.equal(originalLine, afterReview:read("*l"), "the exact paired record must remain immutable")
		afterReview:close()
		local reviewFile = assert(io.open(reviewPath, "rb"))
		local reviewEntry = assert(json.decode(reviewFile:read("*l")))
		reviewFile:close()
		assert.are.equal("https://creativecommons.org/licenses/by/4.0/", reviewEntry.sourceRightsEvidence.licenseUrl)
		assert.is_nil(reviewed.certification.sourceRights.licenseUrl, "raw rights references must not enter public record summaries")
		reviewEntry.schemaVersion = 2
		reviewEntry.sourceRightsEvidence = nil
		local legacyFile = assert(io.open(reviewPath, "wb"))
		assert(legacyFile:write(assert(json.encode(reviewEntry)), "\n"))
		legacyFile:close()
		local legacyReviewed = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "fixture", "dev", string.rep("a", 64)))
		assert.is_false(legacyReviewed.trainingEligible, "legacy approvals remain readable but cannot enter the current trainer")
		assert.is_nil(legacyReviewed.certification.sourceRights)
		os.remove(path)
		os.remove(reviewPath)
	end)

	it("invalidates approval when the reviewed exact record fingerprint changes", function()
		local path = os.tmpname()
		os.remove(path)
		local reviewPath = path .. ".reviews.jsonl"
		os.remove(reviewPath)
		local stored = assert(StudyRecords.AppendToPath(reviewableRecord(), path))
		assert(StudyRecords.ReviewToPath(path, stored.recordId, "approved", {
			exactPair = true, scenario = true, activity = true, lookupTables = true,
			localTrainingConsent = true, sourceRightsVerified = true,
				sourceRightsEvidence = validRightsEvidence(),
		}, expectedEngine))
		local file = assert(io.open(path, "rb"))
		local changed = assert(json.decode(file:read("*l")))
		file:close()
		changed.candidate.metrics.CombinedDPS = 120
		local output = assert(io.open(path, "wb"))
		assert(output:write(assert(json.encode(changed)), "\n"))
		output:close()
		local reviewed = assert(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29", "fixture", "dev", string.rep("a", 64)))
		assert.is_false(reviewed.trainingEligible)
		assert.is_true(reviewed.quarantined)
		assert.are.equal("stale_record_changed", reviewed.reviewStatus)
		os.remove(path)
		os.remove(reviewPath)
	end)

	it("withdraws one record, erases its review, and invalidates managed derived training artifacts", function()
		local path = os.tmpname()
		os.remove(path)
		local reviewPath = path .. ".reviews.jsonl"
		local withdrawalPath = path .. ".withdrawn-records.jsonl"
		os.remove(reviewPath)
		os.remove(withdrawalPath)
		local private = exactPairRecord()
		private.source = { type = "public_build_study", provider = "fixture", sourceUrl = "https://private.invalid/deleted-build" }
		local withdrawn = assert(StudyRecords.AppendToPath(private, path))
		local retained = assert(StudyRecords.AppendToPath(exactPairRecord(), path))
		assert(StudyRecords.ReviewToPath(path, withdrawn.recordId, "rejected", { }, expectedEngine))
		assert(StudyRecords.ReviewToPath(path, retained.recordId, "rejected", { }, expectedEngine))

		local cleared = { }
		local function clearDirectory(relativePath)
			cleared[#cleared + 1] = relativePath
			return true
		end
		local result = assert(StudyRecords.DeleteById(path, withdrawn.recordId, clearDirectory))
		assert.are.equal("deleted", result.status)
		assert.is_true(result.deleted)
		assert.are.equal(1, result.removedRecords)
		assert.are.equal(1, result.removedReviewEntries)
		assert.is_true(result.derivedArtifactsPurged)
		assert.is_false(result.trainingBlocked)
		assert.are.same({ "OptimizerStudies/TrainingDatasets", "OptimizerModels" }, cleared)

		local missing, missingError = StudyRecords.ReadById(path, withdrawn.recordId, "3.29", "3_29")
		assert.is_nil(missing)
		assert.is_truthy(missingError:find("withdrawn or deleted", 1, true))
		assert.is_truthy(StudyRecords.ReadById(path, retained.recordId, "3.29", "3_29"))
		local listed = assert(StudyRecords.List(path, 25, "3.29", "3_29"))
		assert.are.equal(1, listed.totalRecords)
		assert.are.equal(retained.recordId, listed.records[1].recordId)

		local store = assert(io.open(path, "rb"))
		local storedText = store:read("*a")
		store:close()
		assert.is_nil(storedText:find(withdrawn.recordId, 1, true))
		assert.is_nil(storedText:find("private.invalid", 1, true))
		local reviews = assert(io.open(reviewPath, "rb"))
		local reviewText = reviews:read("*a")
		reviews:close()
		assert.is_nil(reviewText:find(withdrawn.recordId, 1, true))
		assert.is_truthy(reviewText:find(retained.recordId, 1, true))
		local ledger = assert(io.open(withdrawalPath, "rb"))
		local ledgerText = ledger:read("*a")
		ledger:close()
		assert.is_nil(ledgerText:find(withdrawn.recordId, 1, true), "the persistent tombstone must not retain the raw ID")
		assert.is_truthy(ledgerText:find("recordIdHash", 1, true))

		os.remove(path)
		os.remove(reviewPath)
		os.remove(withdrawalPath)
		os.remove(path .. ".training-artifacts-invalidated.json")
	end)

	it("reapplies a completed withdrawal tombstone if backup data reappears during cleanup retry", function()
		local path = os.tmpname()
		os.remove(path)
		local stored = assert(StudyRecords.AppendToPath(exactPairRecord(), path))
		local original = assert(io.open(path, "rb"))
		local originalText = original:read("*a")
		original:close()
		local deleted = assert(StudyRecords.DeleteById(path, stored.recordId, function() return true end))
		assert.are.equal("deleted", deleted.status)
		local restore = assert(io.open(path, "wb"))
		assert(restore:write(originalText))
		restore:close()
		local marker = assert(io.open(path .. ".training-artifacts-invalidated.json", "wb"))
		assert(marker:write('{"schemaVersion":1,"status":"study_withdrawal_cleanup_pending"}'))
		marker:close()

		local retried = assert(StudyRecords.DeleteById(path, stored.recordId, function() return true end))
		assert.are.equal("deleted", retried.status)
		assert.are.equal(1, retried.removedRecords)
		assert.is_false(retried.trainingBlocked)
		local raw = assert(io.open(path, "rb"))
		assert.are.equal("", raw:read("*a"))
		raw:close()
		assert.is_nil(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29"))
		assert.is_nil(io.open(path .. ".training-artifacts-invalidated.json", "rb"))
		os.remove(path)
		os.remove(path .. ".withdrawn-records.jsonl")
	end)

	it("hides pending withdrawals and blocks retraining when derived-artifact cleanup fails, then resumes safely", function()
		local path = os.tmpname()
		os.remove(path)
		local reviewPath = path .. ".reviews.jsonl"
		local withdrawalPath = path .. ".withdrawn-records.jsonl"
		os.remove(reviewPath)
		os.remove(withdrawalPath)
		local stored = assert(StudyRecords.AppendToPath(reviewableRecord(), path))
		assert(StudyRecords.ReviewToPath(path, stored.recordId, "rejected", { }, expectedEngine))
		local original = assert(io.open(path, "rb"))
		local originalText = original:read("*a")
		original:close()
		local failed = assert(StudyRecords.DeleteById(path, stored.recordId, function()
			return nil, "simulated access denied"
		end))
		assert.are.equal("cleanup_pending", failed.status)
		assert.is_false(failed.deleted)
		assert.is_true(failed.sourceRecordsHidden)
		assert.is_true(failed.trainingBlocked)
		local unavailable, unavailableError = StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29")
		assert.is_nil(unavailable)
		assert.is_truthy(unavailableError:find("withdrawn or deleted", 1, true))
		local listed = assert(StudyRecords.List(path, 25, "3.29", "3_29"))
		assert.are.equal(0, listed.totalRecords)
		assert.is_true(listed.withdrawalCleanupPending)
		local stillStored = assert(io.open(path, "rb"))
		assert.are.equal(originalText, stillStored:read("*a"), "a failed artifact purge must leave the raw store untouched")
		stillStored:close()
		local approval, approvalError = StudyRecords.ReviewToPath(path, stored.recordId, "approved", {
			exactPair = true, scenario = true, activity = true, lookupTables = true,
			localTrainingConsent = true, sourceRightsVerified = true,
				sourceRightsEvidence = validRightsEvidence(),
		}, expectedEngine)
		assert.is_nil(approval)
		assert.is_truthy(approvalError:find("withdrawn or deleted", 1, true))

		local resumed = assert(StudyRecords.DeleteById(path, stored.recordId, function() return true end))
		assert.are.equal("deleted", resumed.status)
		assert.are.equal(1, resumed.removedRecords)
		assert.is_false(resumed.trainingBlocked)
		local clearedStore = io.open(path, "rb")
		if clearedStore then assert.are.equal("", clearedStore:read("*a")); clearedStore:close() end
		os.remove(path)
		os.remove(reviewPath)
		os.remove(withdrawalPath)
		os.remove(path .. ".training-artifacts-invalidated.json")
	end)

	it("preserves the withdrawal tombstone and model block if atomic source-store replacement fails", function()
		local path = os.tmpname()
		os.remove(path)
		local withdrawalPath = path .. ".withdrawn-records.jsonl"
		os.remove(withdrawalPath)
		local stored = assert(StudyRecords.AppendToPath(exactPairRecord(), path))
		local failStoreReplace = function(source, target)
			if target == path then return nil, "simulated store replacement failure" end
			return os.rename(source, target)
		end
		local result = assert(StudyRecords.DeleteById(path, stored.recordId, function() return true end, failStoreReplace))
		assert.are.equal("cleanup_pending", result.status)
		assert.is_false(result.deleted)
		assert.is_true(result.trainingBlocked)
		local marker = assert(io.open(path .. ".training-artifacts-invalidated.json", "rb"))
		marker:close()
		local raw = assert(io.open(path, "rb"))
		assert.is_truthy(raw:read("*a"):find(stored.recordId, 1, true))
		raw:close()
		assert.is_nil(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29"))
		local completed = assert(StudyRecords.DeleteById(path, stored.recordId, function() return true end))
		assert.are.equal("deleted", completed.status, completed.message)
		local clearedStore = io.open(path, "rb")
		if clearedStore then assert.are.equal("", clearedStore:read("*a")); clearedStore:close() end
		assert.is_nil(io.open(path .. ".training-artifacts-invalidated.json", "rb"))
		os.remove(path)
		os.remove(withdrawalPath)
	end)

	it("prunes only records older than the UTC cutoff and preserves invalid timestamps", function()
		local path = os.tmpname()
		os.remove(path)
		local reviewPath = path .. ".reviews.jsonl"
		local withdrawalPath = path .. ".withdrawn-records.jsonl"
		os.remove(reviewPath)
		os.remove(withdrawalPath)
		local old = assert(StudyRecords.AppendToPath(exactPairRecord(), path))
		local recentRecord = exactPairRecord()
		recentRecord.candidate.metrics.CombinedDPS = 120
		local recent = assert(StudyRecords.AppendToPath(recentRecord, path))
		local undatedRecord = exactPairRecord()
		undatedRecord.candidate.metrics.CombinedDPS = 130
		local undated = assert(StudyRecords.AppendToPath(undatedRecord, path))
		local invalidDateRecord = exactPairRecord()
		invalidDateRecord.candidate.metrics.CombinedDPS = 140
		local invalidDate = assert(StudyRecords.AppendToPath(invalidDateRecord, path))
		for _, entry in ipairs({ { id = old.recordId, at = "2020-01-01T00:00:00Z" },
			{ id = recent.recordId, at = os.date("!%Y-%m-%dT%H:%M:%SZ") },
			{ id = undated.recordId, at = "unknown" },
			{ id = invalidDate.recordId, at = "2020-13-99T88:88:88Z" } }) do
			local input = assert(io.open(path, "rb"))
			local rows = { }
			for line in input:lines() do
				local value = assert(json.decode(line))
				if value.recordId == entry.id then value.recordedAt = entry.at end
				rows[#rows + 1] = assert(json.encode(value))
			end
			input:close()
			local output = assert(io.open(path, "wb"))
			assert(output:write(table.concat(rows, "\n"), "\n"))
			output:close()
		end
		assert(StudyRecords.ReviewToPath(path, old.recordId, "rejected", { }, expectedEngine))
		assert(StudyRecords.ReviewToPath(path, recent.recordId, "rejected", { }, expectedEngine))
		local cleared = { }
		local pruned = assert(StudyRecords.PruneOlderThan(path, 30, function(relativePath)
			cleared[#cleared + 1] = relativePath
			return true
		end))
		assert.are.equal("deleted", pruned.status)
		assert.are.equal(1, pruned.prunedRecords)
		assert.is_true(pruned.preservedUndatedRecords)
		assert.are.same({ "OptimizerStudies/TrainingDatasets", "OptimizerModels" }, cleared)
		assert.is_nil(StudyRecords.ReadById(path, old.recordId, "3.29", "3_29"))
		assert.is_truthy(StudyRecords.ReadById(path, recent.recordId, "3.29", "3_29"))
		assert.is_truthy(StudyRecords.ReadById(path, undated.recordId, "3.29", "3_29"))
		assert.is_truthy(StudyRecords.ReadById(path, invalidDate.recordId, "3.29", "3_29"), "an impossible calendar timestamp is preserved")
		local listed = assert(StudyRecords.List(path, 25, "3.29", "3_29"))
		assert.are.equal(3, listed.totalRecords)
		local reviewFile = assert(io.open(reviewPath, "rb"))
		local reviewText = reviewFile:read("*a")
		reviewFile:close()
		assert.is_nil(reviewText:find(old.recordId, 1, true))
		assert.is_truthy(reviewText:find(recent.recordId, 1, true))
		os.remove(path)
		os.remove(reviewPath)
		os.remove(withdrawalPath)
		os.remove(path .. ".training-artifacts-invalidated.json")
	end)

	it("refuses invalid retention thresholds and malformed source data before purging", function()
		local path = os.tmpname()
		os.remove(path)
		local calls = 0
		local function clearDirectory()
			calls = calls + 1
			return true
		end
		local invalid, invalidError = StudyRecords.PruneOlderThan(path, 0, clearDirectory)
		assert.is_nil(invalid)
		assert.is_truthy(invalidError)
		assert.are.equal(0, calls)
		local output = assert(io.open(path, "wb"))
		assert(output:write("{not-json}\n"))
		output:close()
		local result, readError = StudyRecords.PruneOlderThan(path, 30, clearDirectory)
		assert.is_nil(result)
		assert.is_truthy(readError:find("cleanup was refused", 1, true))
		assert.are.equal(0, calls)
		os.remove(path)
	end)

	it("fails closed when the training-invalidation marker cannot be read", function()
		local path = os.tmpname()
		os.remove(path)
		local stored = assert(StudyRecords.AppendToPath(exactPairRecord(), path))
		local markerPath = path .. ".training-artifacts-invalidated.json"
		local originalOpen = io.open
		local cleanupCalls = 0
		io.open = function(target, mode)
			if target == markerPath then return nil, "Permission denied" end
			return originalOpen(target, mode)
		end
		local callOk, listed, listError, deleted, deleteError = pcall(function()
			local result, resultError = StudyRecords.List(path, 25, "3.29", "3_29")
			local deleteResult, deleteResultError = StudyRecords.DeleteById(path, stored.recordId, function()
				cleanupCalls = cleanupCalls + 1
				return true
			end)
			return result, resultError, deleteResult, deleteResultError
		end)
		io.open = originalOpen
		assert.is_true(callOk, tostring(listed))
		assert.is_nil(listed)
		assert.is_truthy(listError:find("Could not inspect the local training-invalidation marker", 1, true))
		assert.is_nil(deleted)
		assert.is_truthy(deleteError:find("Could not inspect the local training-invalidation marker", 1, true))
		assert.are.equal(0, cleanupCalls)
		assert.is_truthy(StudyRecords.ReadById(path, stored.recordId, "3.29", "3_29"))
		os.remove(path)
	end)
end)
