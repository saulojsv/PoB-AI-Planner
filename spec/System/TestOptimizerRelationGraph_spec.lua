local RelationGraph = require("Modules.Optimizer.RelationGraph")
local StudyContext = require("Modules.Optimizer.StudyContext")

describe("Optimizer report-only relation graph", function()
	local expected = {
		pobVersion = "3.29.0", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
		manifestFingerprint = string.rep("a", 64),
	}

	local function engineIdentity()
		return { pobVersion = "3.29.0", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
			manifestFingerprint = string.rep("a", 64) }
	end
	local configuration = { activeConfigSetId = 1, title = "Default", values = { enemyIsBoss = true } }
	local sourceBuildSignature = string.rep("a", 64)
	local scenarioSignature = assert(StudyContext.ScenarioSignature(configuration))

	local function cell(dps, life, gemId, effectId, itemId)
		return {
			metrics = { CombinedDPS = dps, Life = life },
			selectedSkill = {
				gemId = gemId, effectId = effectId, groupIndex = 1, gemIndex = 1, isMainSkill = true,
				supportGemIds = { "SupportGemAddedFireDamage" },
				supportEffectIds = { "SupportAddedFireDamage" },
				socketedSupportGemIds = { "SupportGemAddedFireDamage" },
			},
			selectedItem = { slot = "Helmet", itemId = itemId },
			requirements = { feasible = true },
			mainSkillPayability = { feasible = true },
			activitySustain = { status = "pass" },
			socketStatus = "native_linked_group",
			exactCalculated = true,
			evaluationMethod = "calcs_getMiscCalculator",
				evidenceContext = {
				schemaVersion = 1, buildSignatureAlgorithm = "sha256", buildSignatureVersion = 1,
				buildSignature = sourceBuildSignature, scenarioSignature = scenarioSignature,
					engine = engineIdentity(),
			},
		}
	end

	local function skillItemRecord()
		local cells = {
			baseline = cell(100, 1000, "SkillGemFireball", "Fireball", 10),
			factorA = cell(130, 1000, "SkillGemArc", "Arc", 10),
			factorB = cell(110, 1200, "SkillGemFireball", "Fireball", 22),
			combined = cell(155, 1200, "SkillGemArc", "Arc", 22),
		}
		local interaction = {
			CombinedDPS = { baseline = 100, factorA = 130, factorB = 110, combined = 155, interaction = 15 },
			Life = { baseline = 1000, factorA = 1000, factorB = 1200, combined = 1200, interaction = 0 },
		}
		return {
			recordId = "study-20261022T120000Z-1-1", recordedAt = "2026-10-22T12:00:00Z",
			kind = "skill_item_slot_factorial_interaction",
			source = {
				type = "active_build", buildSignatureAlgorithm = "sha256", buildSignatureVersion = 1,
				buildSignature = sourceBuildSignature, scenarioSignature = scenarioSignature,
			},
			engine = engineIdentity(),
			buildState = { class = { classId = 2, class = "Witch", ascendancyId = 2, ascendancy = "Necromancer" },
				characterLevel = 90, mainSkill = "Fireball", dataVersion = "3.29", treeVersion = "3_29", configuration = configuration },
			experiment = {
				unit = "four_cell_skill_item_slot_factorial", factorialSchemaVersion = 1,
				formula = "combined - factorA - factorB + baseline", socketStatus = "native_linked_group",
				factorA = {
					operation = "replace_selected_main_skill_gem", groupIndex = 1, gemIndex = 1,
					before = { gemId = "SkillGemFireball", level = 20, quality = 0 },
					after = { gemId = "SkillGemArc", level = 20, quality = 0 },
					sourceEffectId = "Fireball", effectId = "Arc", socketedSupportGemIds = { "SupportGemAddedFireDamage" },
				},
				factorB = {
					operation = "replace_item_in_slot", slot = "Helmet",
					before = { itemId = 10, poBItemText = "Rare Helmet A" },
					after = { itemId = 22, poBItemText = "Rare Helmet B" },
				},
			},
			factorial = { formula = "combined - factorA - factorB + baseline", cells = cells, interaction = interaction, metricCount = 2 },
			admission = { exactCalculated = true, trainingEligible = false },
			trainingEligible = false,
			quarantined = true,
			quarantine = { status = "training_schema_unsupported", reasons = { "factorial_training_schema_unsupported" } },
		}
	end

	local function passiveItemRecord()
		local record = skillItemRecord()
		record.recordId = "study-20261023T120000Z-1-1"
		record.kind = "passive_item_slot_factorial_interaction"
		record.experiment.unit = "four_cell_passive_item_slot_factorial"
		record.buildState.allocatedNodeIds = { }
		record.experiment.factorA = { operation = "add_passive_node", nodeId = 501 }
		record.experiment.factorB = {
			operation = "replace_item_in_slot", slot = "Helmet",
			before = { itemId = 10, poBItemText = "Rare Helmet A" },
			after = { itemId = 22, poBItemText = "Rare Helmet B" },
		}
		for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
			local cell = record.factorial.cells[name]
			cell.selectedSkill.gemId = "SkillGemFireball"
			cell.selectedSkill.effectId = "Fireball"
			cell.selectedItem.itemId = (name == "factorB" or name == "combined") and 22 or 10
			cell.nodeId = 501
			cell.nodeAllocated = name == "factorA" or name == "combined"
			cell.addedNodeIds = cell.nodeAllocated and { 501 } or { }
		end
		return record
	end

	local function skillSupportRecord()
		local record = skillItemRecord()
		record.recordId = "study-20261022T120001Z-2-2"
		record.kind = "skill_support_factorial_interaction"
		record.experiment.unit = "four_cell_skill_support_factorial"
		record.experiment.socketStatus = "native_linked_group"
		record.experiment.factorB = {
			operation = "replace_support_gem", groupIndex = 1, gemIndex = 2,
			before = { gemId = "SupportGemAddedFireDamage", level = 20, quality = 0 },
			after = { gemId = "SupportGemControlledDestruction", level = 20, quality = 0 },
		}
		record.experiment.factorA = {
			operation = "replace_selected_main_skill_gem", groupIndex = 1, gemIndex = 1,
			before = { gemId = "SkillGemFireball", level = 20, quality = 0 },
			after = { gemId = "SkillGemArc", level = 20, quality = 0 },
			sourceEffectId = "Fireball", effectId = "Arc",
		}
		record.experiment.factorB.slot = nil
		record.experiment.factorB.before.itemId = nil
		record.experiment.factorB.after.itemId = nil
		for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
			local selected = record.factorial.cells[name].selectedSkill
			local supportId = (name == "factorB" or name == "combined")
				and "SupportGemControlledDestruction" or "SupportGemAddedFireDamage"
			local supportEffectId = (name == "factorB" or name == "combined")
				and "SupportControlledDestruction" or "SupportAddedFireDamage"
			selected.supportGemId = supportId
			selected.supportApplied = true
			selected.level = 20
			selected.quality = 0
			selected.supportLevel = 20
			selected.supportQuality = 0
			selected.supportGemIds = { supportId }
			selected.supportEffectIds = { supportEffectId }
			selected.socketedSupportGemIds = { supportId }
		end
		return record
	end

	local function skillSkillRecord()
		local record = skillItemRecord()
		record.recordId = "study-20261024T030001Z-4-4"
		record.kind = "skill_skill_factorial_interaction"
		record.experiment = {
			unit = "four_cell_skill_skill_factorial", factorialSchemaVersion = 1,
			formula = "combined - factorA - factorB + baseline", socketStatus = "native_linked_groups",
			factorA = { operation = "replace_full_dps_skill_gem", groupIndex = 1, gemIndex = 1,
				before = { gemId = "SkillGemFireball", effectId = "Fireball", level = 20, quality = 0 },
				after = { gemId = "SkillGemArc", effectId = "Arc", level = 20, quality = 0 }, socketedSupportGemIds = { } },
			factorB = { operation = "replace_full_dps_skill_gem", groupIndex = 2, gemIndex = 1,
				before = { gemId = "SkillGemCyclone", effectId = "Cyclone", level = 20, quality = 0 },
				after = { gemId = "SkillGemFrostBlades", effectId = "FrostBlades", level = 20, quality = 0 }, socketedSupportGemIds = { } },
		}
		local values = { baseline = 100, factorA = 120, factorB = 110, combined = 145 }
		local selected = {
			baseline = { "SkillGemFireball", "Fireball", "SkillGemCyclone", "Cyclone" },
			factorA = { "SkillGemArc", "Arc", "SkillGemCyclone", "Cyclone" },
			factorB = { "SkillGemFireball", "Fireball", "SkillGemFrostBlades", "FrostBlades" },
			combined = { "SkillGemArc", "Arc", "SkillGemFrostBlades", "FrostBlades" },
		}
		local cells = { }
		for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
			local cell = record.factorial.cells[name]
			cell.metrics = { FullDPS = values[name] }
			local ids = selected[name]
			cell.socketStatus = "native_linked_groups"
			cell.selectedSkills = {
				factorA = { gemId = ids[1], effectId = ids[2], groupIndex = 1, gemIndex = 1,
					level = 20, quality = 0, fullDPSIncluded = true,
					fullDPSActivityIdentity = ids[2] .. "\31Weapon 1\31", socketedSupportGemIds = { } },
				factorB = { gemId = ids[3], effectId = ids[4], groupIndex = 2, gemIndex = 1,
					level = 20, quality = 0, fullDPSIncluded = true,
					fullDPSActivityIdentity = ids[4] .. "\31Body Armour\31", socketedSupportGemIds = { } },
			}
			cell.exactCalculated = true
			cell.evaluationMethod = "calcs_getMiscCalculator"
			cell.socketStatus = "native_linked_groups"
			cell.evidenceContext = {
				schemaVersion = 1, buildSignatureAlgorithm = "sha256", buildSignatureVersion = 1,
				buildSignature = sourceBuildSignature, scenarioSignature = scenarioSignature, engine = engineIdentity(),
			}
			cells[name] = cell
		end
		record.factorial = {
			formula = "combined - factorA - factorB + baseline", cells = cells,
			interaction = { FullDPS = { baseline = 100, factorA = 120, factorB = 110, combined = 145, interaction = 15 } },
			metricCount = 1,
		}
		record.admission.exactCalculated = true
		record.admission.trainingEligible = false
		record.quarantined = true
		record.trainingEligible = false
		record.quarantine = { status = "training_schema_unsupported", reasons = { "factorial_training_schema_unsupported" } }
		return record
	end

	local function passiveSupportRecord()
		local record = skillSupportRecord()
		record.recordId = "study-20261024T030000Z-4-4"
		record.kind = "passive_support_factorial_interaction"
		record.experiment.unit = "four_cell_passive_support_factorial"
		record.experiment.factorA = { operation = "add_passive_node", nodeId = 501 }
		record.experiment.factorB.skillGemIndex = 1
		record.buildState.allocatedNodeIds = { }
		record.admission.trainingEligible = false
		for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
			local cell = record.factorial.cells[name]
			cell.selectedSkill.gemId = "SkillGemFireball"
			cell.selectedSkill.effectId = "Fireball"
			cell.nodeId = 501
			cell.nodeAllocated = name == "factorA" or name == "combined"
			cell.addedNodeIds = cell.nodeAllocated and { 501 } or { }
			cell.passivePointsUsed = cell.nodeAllocated and 101 or 100
		end
		return record
	end

	it("emits typed skill×item edges only after recomputing exact four-cell interactions", function()
		local graph = assert(RelationGraph.Build({ skillItemRecord() }, expected, 25))
		assert.are.equal("report_only_evidence_graph", graph.status)
		assert.are.equal(1, graph.edgeCount)
		assert.are.equal(0, graph.discardedCount)
		local edge = graph.edges[1]
		assert.are.equal("main_skill_gem_x_item_slot", edge.edgeType)
		assert.are.equal("main_skill_gem", edge.nodeA.type)
		assert.are.equal("item_slot", edge.nodeB.type)
		assert.are.equal("Helmet", edge.nodeB.slot)
		assert.are.equal(15, edge.metrics.CombinedDPS.interaction)
		assert.are.equal(sourceBuildSignature, edge.source.buildSignature)
		assert.are.equal(scenarioSignature, edge.source.scenarioSignature)
		assert.are.equal(1, graph.aggregationDiagnostics.eligibleEdgeCount)
		assert.are.equal(1, #graph.interactionSummaries)
		assert.are.equal("single_source_build", graph.interactionSummaries[1].status)
		assert.are.equal(1, graph.interactionSummaries[1].metrics[1].sampleCount)
		assert.is_false(edge.trainingEligible)
		assert.is_false(edge.rankingEligible)
		assert.is_false(graph.optimizerInput)
		assert.is_false(graph.trainingEligible)
		assert.is_false(graph.rankingEligible)
		assert.is_false(graph.exactPobRecalculated, "the graph reads stored exact PoB cells; it does not claim a new engine calculation")
		local emptySlot = skillItemRecord()
		emptySlot.experiment.factorB.after.itemId = 0
		emptySlot.experiment.factorB.after.poBItemText = nil
		emptySlot.factorial.cells.factorB.selectedItem.itemId = 0
		emptySlot.factorial.cells.combined.selectedItem.itemId = 0
		local emptyGraph = assert(RelationGraph.Build({ emptySlot }, expected, 25))
		assert.are.equal(1, emptyGraph.edgeCount)
		assert.are.equal(0, emptyGraph.edges[1].nodeB.toItemId)
	end)

	it("emits exact passive×item edges only when the single-node and item cells match", function()
		local graph = assert(RelationGraph.Build({ passiveItemRecord() }, expected, 25))
		assert.are.equal(1, graph.edgeCount)
		assert.are.equal(0, graph.discardedCount)
		local edge = graph.edges[1]
		assert.are.equal("passive_node_x_item_slot", edge.edgeType)
		assert.are.equal("passive_node", edge.nodeA.type)
		assert.are.equal(501, edge.nodeA.nodeId)
		assert.are.equal("item_slot", edge.nodeB.type)
		assert.are.equal("Helmet", edge.nodeB.slot)
		assert.are.equal(15, edge.metrics.CombinedDPS.interaction)
		assert.is_false(edge.trainingEligible)
		assert.is_false(edge.rankingEligible)
		assert.is_false(graph.optimizerInput)
		assert.are.equal(1, graph.interactionSummaries[1].recordCount)

		local repairedPath = passiveItemRecord()
		repairedPath.factorial.cells.combined.addedNodeIds = { 501, 502 }
		local wrongNodeState = passiveItemRecord()
		wrongNodeState.factorial.cells.factorB.nodeAllocated = true
		local wrongItem = passiveItemRecord()
		wrongItem.factorial.cells.combined.selectedItem.itemId = 10
		local invalid = assert(RelationGraph.Build({ repairedPath, wrongNodeState, wrongItem }, expected, 25))
		assert.are.equal(0, invalid.edgeCount)
		assert.are.equal(3, invalid.discardedCount)
		assert.are.equal("passive_item_cell_path_repair_mismatch_combined", invalid.discarded[1].reason)
		assert.are.equal("passive_item_cell_node_identity_mismatch_factorB", invalid.discarded[2].reason)
		assert.are.equal("passive_item_cell_item_identity_mismatch_combined", invalid.discarded[3].reason)
	end)

	it("discards changed identities, altered interaction values, and stale engine versions", function()
		local wrongCell = skillItemRecord()
		wrongCell.factorial.cells.factorB.selectedItem.itemId = 10
		local wrongInteraction = skillItemRecord()
		wrongInteraction.factorial.interaction.CombinedDPS.interaction = 999
		local stale = skillItemRecord()
		stale.engine.treeVersion = "old_tree"
		local staleManifest = skillItemRecord()
		staleManifest.engine.manifestFingerprint = string.rep("b", 64)
		local graph = assert(RelationGraph.Build({ wrongCell, wrongInteraction, stale, staleManifest }, expected, 25))
		assert.are.equal(0, graph.edgeCount)
		assert.are.equal(4, graph.discardedCount)
		assert.is_truthy(graph.discarded[1].reason:find("cell_identity_mismatch", 1, true))
		assert.is_truthy(graph.discarded[2].reason:find("integrity_mismatch", 1, true))
		assert.are.equal("engine_treeVersion_mismatch", graph.discarded[3].reason)
		assert.are.equal("engine_manifestFingerprint_mismatch", graph.discarded[4].reason)
	end)

	it("supports the existing passive and skill×support factorial schemas", function()
		local passive = {
			recordId = "study-20261022T120002Z-3-3", kind = "passive_factorial_interaction",
			engine = { pobVersion = "3.29.0", pobBranch = "dev", dataVersion = "3.29", treeVersion = "3_29",
				manifestFingerprint = string.rep("a", 64) },
			buildState = { class = { class = "Witch" }, mainSkill = "Fireball", configuration = { values = { } } },
			experiment = { unit = "four_cell_passive_factorial", factorialSchemaVersion = 1,
				formula = "combined - factorA - factorB + baseline",
				factorA = { operation = "add_passive_node", nodeId = 501 },
				factorB = { operation = "add_passive_node", nodeId = 502 } },
			baseline = { metrics = { CombinedDPS = 100 } },
			candidate = { metrics = { CombinedDPS = 150 } },
			factorial = {
				formula = "combined - factorA - factorB + baseline", metricCount = 1,
				cells = { factorA = { metrics = { CombinedDPS = 120 } }, factorB = { metrics = { CombinedDPS = 110 } } },
				interaction = { CombinedDPS = { baseline = 100, factorA = 120, factorB = 110, combined = 150, interaction = 20 } },
			},
			admission = { exactCalculated = true },
		}
		local graph = assert(RelationGraph.Build({ passive, skillSupportRecord() }, expected, 25))
		assert.are.equal(2, graph.edgeCount)
		assert.are.equal("passive_node_x_passive_node", graph.edges[1].edgeType)
		assert.are.equal(20, graph.edges[1].metrics.CombinedDPS.interaction)
		assert.are.equal("main_skill_gem_x_support_gem", graph.edges[2].edgeType)
		assert.are.equal("support_gem", graph.edges[2].nodeB.type)
		assert.are.equal(15, graph.edges[2].metrics.CombinedDPS.interaction)
		assert.are.equal(1, graph.aggregationDiagnostics.eligibleEdgeCount)
		assert.are.equal(1, #graph.interactionSummaries)
		assert.are.equal("main_skill_gem_x_support_gem", graph.interactionSummaries[1].edgeType)
	end)

	it("accepts exact two-skill Full DPS interactions and rejects altered identities or cell proof", function()
		local valid = skillSkillRecord()
		local graph = assert(RelationGraph.Build({ valid }, expected, 25))
		assert.are.equal(1, graph.edgeCount, graph.discarded[1] and graph.discarded[1].reason or "skill×skill factorial edge missing")
		assert.are.equal("active_skill_gem_x_active_skill_gem", graph.edges[1].edgeType)
		assert.is_false(graph.edges[1].trainingEligible)
		assert.is_false(graph.edges[1].rankingEligible)

		local sameGroup = skillSkillRecord()
		sameGroup.experiment.factorB.groupIndex = 1
		local wrongCell = skillSkillRecord()
		wrongCell.factorial.cells.combined.selectedSkills.factorA.effectId = "Fireball"
		local missingFullDPS = skillSkillRecord()
		missingFullDPS.factorial.cells.factorB.selectedSkills.factorB.fullDPSIncluded = false
		local supportChanged = skillSkillRecord()
		supportChanged.factorial.cells.combined.selectedSkills.factorB.socketedSupportGemIds = { "SupportGemAddedFireDamage" }
		local invalidGraph = assert(RelationGraph.Build({ sameGroup, wrongCell, missingFullDPS, supportChanged }, expected, 25))
		assert.are.equal(0, invalidGraph.edgeCount)
		assert.are.equal(4, invalidGraph.discardedCount)
		assert.are.equal("skill_skill_factor_ids_invalid", invalidGraph.discarded[1].reason)
		assert.are.equal("skill_skill_cell_identity_mismatch_combined_a", invalidGraph.discarded[2].reason)
		assert.are.equal("skill_skill_cell_identity_mismatch_factorB_b", invalidGraph.discarded[3].reason)
		assert.are.equal("skill_skill_cell_identity_mismatch_combined_b", invalidGraph.discarded[4].reason)
	end)

	it("rejects skill×support cells without exact certificates or matching scenario and engine context", function()
		local invalidCases = {
			{
				name = "missing exact marker",
				mutate = function(record) record.factorial.cells.factorB.exactCalculated = nil end,
				reason = "skill_support_cell_calculation_provenance_invalid_factorB",
			},
			{
				name = "missing calculation method",
				mutate = function(record) record.factorial.cells.factorB.evaluationMethod = nil end,
				reason = "skill_support_cell_calculation_provenance_invalid_factorB",
			},
			{
				name = "missing cell certificate",
				mutate = function(record) record.factorial.cells.factorB.evidenceContext = nil end,
				reason = "skill_support_cell_evidence_context_missing_factorB",
			},
			{
				name = "scenario divergence",
				mutate = function(record) record.factorial.cells.factorB.evidenceContext.scenarioSignature = string.rep("b", 64) end,
				reason = "skill_support_cell_scenario_signature_mismatch_factorB",
			},
			{
				name = "engine divergence",
				mutate = function(record) record.factorial.cells.factorB.evidenceContext.engine.dataVersion = "3.28" end,
				reason = "skill_support_cell_record_engine_mismatch_factorB",
			},
		}
		for _, invalidCase in ipairs(invalidCases) do
			local record = skillSupportRecord()
			invalidCase.mutate(record)
			local graph = assert(RelationGraph.Build({ record }, expected, 25))
			assert.are.equal(0, graph.edgeCount, invalidCase.name)
			assert.are.equal(1, graph.discardedCount, invalidCase.name)
			assert.are.equal(invalidCase.reason, graph.discarded[1].reason, invalidCase.name)
		end
	end)

	it("requires cell provenance for skill/item and passive/support factorial evidence", function()
		local validPassiveSupport = assert(RelationGraph.Build({ passiveSupportRecord() }, expected, 25))
		assert.are.equal(1, validPassiveSupport.edgeCount,
			validPassiveSupport.discarded[1] and validPassiveSupport.discarded[1].reason
				or "the exact passive/support fixture must satisfy the cell contract")
		local invalidCases = {
			{
				name = "skill/item cell context is missing",
				record = skillItemRecord(),
				mutate = function(record) record.factorial.cells.factorB.evidenceContext = nil end,
				reason = "skill_item_cell_context_mismatch_factorB",
			},
			{
				name = "passive/item calculation marker is missing",
				record = passiveItemRecord(),
				mutate = function(record) record.factorial.cells.factorB.exactCalculated = false end,
				reason = "passive_item_cell_calculation_provenance_invalid_factorB",
			},
			{
				name = "passive/support scenario diverges",
				record = passiveSupportRecord(),
				mutate = function(record) record.factorial.cells.factorB.evidenceContext.scenarioSignature = string.rep("b", 64) end,
				reason = "passive_support_cell_scenario_signature_mismatch_factorB",
			},
		}
		for _, invalidCase in ipairs(invalidCases) do
			invalidCase.mutate(invalidCase.record)
			local graph = assert(RelationGraph.Build({ invalidCase.record }, expected, 25))
			assert.are.equal(0, graph.edgeCount, invalidCase.name)
			assert.are.equal(1, graph.discardedCount, invalidCase.name)
			assert.are.equal(invalidCase.reason, graph.discarded[1].reason, invalidCase.name)
		end
	end)

	it("deduplicates repeated source builds and aggregates only distinct matching contexts", function()
		local first = skillItemRecord()
		local repeated = skillItemRecord()
		repeated.recordId = "study-20261022T120010Z-10-10"
		local second = skillItemRecord()
		second.recordId = "study-20261022T120011Z-11-11"
		local secondSignature = string.rep("b", 64)
		second.source.buildSignature = secondSignature
		for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
			second.factorial.cells[name].evidenceContext.buildSignature = secondSignature
		end
		-- PoB item IDs are local to a build. Identical exact item snapshots should
		-- group even when the source build assigned different internal IDs.
		second.experiment.factorB.before.itemId = 510
		second.experiment.factorB.after.itemId = 522
		second.factorial.cells.baseline.selectedItem.itemId = 510
		second.factorial.cells.factorA.selectedItem.itemId = 510
		second.factorial.cells.factorB.selectedItem.itemId = 522
		second.factorial.cells.combined.selectedItem.itemId = 522
		local graph = assert(RelationGraph.Build({ first, repeated, second }, expected, 25))
		assert.are.equal(3, graph.edgeCount)
		assert.are.equal(1, #graph.interactionSummaries)
		local summary = graph.interactionSummaries[1]
		assert.are.equal(2, summary.distinctSourceBuildCount)
		assert.are.equal(1, summary.repeatedSameSourceRecordCount)
		assert.are.equal(2, summary.metrics[1].sampleCount)
		assert.are.equal("same_sign_across_distinct_build_signatures", summary.metrics[1].status)
		assert.are.equal("all_zero_across_distinct_build_signatures", summary.metrics[2].status)
		assert.is_false(summary.independentSamplesConfirmed)
		assert.is_false(summary.trainingEligible)
		assert.is_false(summary.rankingEligible)
		assert.is_false(summary.optimizerInput)
	end)

	it("reports heterogeneous effects and isolates scenario contexts", function()
		local positive = skillItemRecord()
		local negative = skillItemRecord()
		negative.recordId = "study-20261022T120012Z-12-12"
		local negativeSignature = string.rep("c", 64)
		negative.source.buildSignature = negativeSignature
		for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
			negative.factorial.cells[name].evidenceContext.buildSignature = negativeSignature
		end
		negative.factorial.cells.combined.metrics.CombinedDPS = 135
		negative.factorial.interaction.CombinedDPS.combined = 135
		negative.factorial.interaction.CombinedDPS.interaction = -5
		local differentScenario = skillItemRecord()
		differentScenario.recordId = "study-20261022T120013Z-13-13"
		differentScenario.source.buildSignature = string.rep("d", 64)
		differentScenario.source.scenarioSignature = assert(StudyContext.ScenarioSignature({ activeConfigSetId = 1,
			title = "Default", values = { enemyIsBoss = false } }))
		differentScenario.buildState.configuration = { activeConfigSetId = 1, title = "Default", values = { enemyIsBoss = false } }
		for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
			local context = differentScenario.factorial.cells[name].evidenceContext
			context.buildSignature = differentScenario.source.buildSignature
			context.scenarioSignature = differentScenario.source.scenarioSignature
		end
		local graph = assert(RelationGraph.Build({ positive, negative, differentScenario }, expected, 25))
		assert.are.equal(2, #graph.interactionSummaries)
		local mixed, separateScenario
		for _, summary in ipairs(graph.interactionSummaries) do
			if summary.context.scenarioSignature == scenarioSignature then mixed = summary
			else separateScenario = summary end
		end
		assert.is_truthy(mixed)
		assert.are.equal(2, mixed.distinctSourceBuildCount)
		assert.are.equal("heterogeneous_across_distinct_build_signatures", mixed.metrics[1].status)
		assert.are.equal(1, separateScenario.distinctSourceBuildCount)
		assert.are.equal("single_source_build", separateScenario.metrics[1].status)
	end)

	it("quarantines same-build conflicting interaction repeats from descriptive stats", function()
		local first = skillItemRecord()
		local conflict = skillItemRecord()
		conflict.recordId = "study-20261022T120014Z-14-14"
		conflict.factorial.cells.combined.metrics.CombinedDPS = 160
		conflict.factorial.interaction.CombinedDPS.combined = 160
		conflict.factorial.interaction.CombinedDPS.interaction = 20
		local graph = assert(RelationGraph.Build({ first, conflict }, expected, 25))
		local metric = graph.interactionSummaries[1].metrics[1]
		assert.are.equal(1, metric.withinSourceConflictCount)
		assert.are.equal(0, metric.sampleCount)
		assert.are.equal("within_source_conflict", metric.status)
	end)

	it("rejects incomplete or unsupported records and bounds the query", function()
		local invalid = skillItemRecord()
		invalid.factorial.cells.combined = nil
		local unsupported = skillItemRecord()
		unsupported.kind = "item_slot_pair"
		local graph = assert(RelationGraph.Build({ invalid, unsupported }, expected, 2))
		assert.are.equal(0, graph.edgeCount)
		assert.are.equal(2, graph.discardedCount)
		local rejected, err = RelationGraph.Build({ }, expected, 26)
		assert.is_nil(rejected)
		assert.is_truthy(err:find("1 to 25", 1, true))
	end)

	it("rejects missing source signatures, mismatched scenario/cell context, non-finite cells, and unquarantined rows", function()
		local missingSignature = skillItemRecord()
		missingSignature.source.buildSignature = nil
		local scenarioMismatch = skillItemRecord()
		scenarioMismatch.source.scenarioSignature = string.rep("b", 64)
		local cellMismatch = skillItemRecord()
		cellMismatch.factorial.cells.factorB.evidenceContext.engine.dataVersion = "3.28"
		local cellBuildMismatch = skillItemRecord()
		cellBuildMismatch.factorial.cells.baseline.evidenceContext.buildSignature = string.rep("b", 64)
		local supportMismatch = skillItemRecord()
		supportMismatch.factorial.cells.factorA.selectedSkill.supportGemIds = { "SupportGemControlledDestruction" }
		local nonFinite = skillItemRecord()
		nonFinite.factorial.cells.factorA.metrics.CombinedDPS = math.huge
		nonFinite.factorial.cells.factorA.metrics.Life = 0/0
		local unquarantined = skillItemRecord()
		unquarantined.quarantined = false
		local graph = assert(RelationGraph.Build({ missingSignature, scenarioMismatch, cellMismatch, cellBuildMismatch,
			supportMismatch, nonFinite, unquarantined }, expected, 25))
		assert.are.equal(0, graph.edgeCount)
		assert.are.equal(7, graph.discardedCount)
		assert.are.equal("skill_item_source_build_signature_missing", graph.discarded[1].reason)
		assert.are.equal("skill_item_scenario_signature_mismatch", graph.discarded[2].reason)
		assert.are.equal("skill_item_cell_context_mismatch_factorB", graph.discarded[3].reason)
		assert.are.equal("skill_item_cell_context_mismatch_baseline", graph.discarded[4].reason)
		assert.are.equal("skill_item_cell_skill_identity_mismatch_factorA", graph.discarded[5].reason)
		assert.is_truthy(graph.discarded[6].reason:find("no common finite", 1, true))
		assert.are.equal("skill_item_record_not_quarantined", graph.discarded[7].reason)
	end)
end)
