-- Path of Building
--
-- Module: Report-only typed graph of exact PoB factorial studies.
-- This graph is evidence for inspection only. It is never consumed by search,
-- feasibility, ranking, or the current supervised training schema.

local FactorialStudy = require("Modules.Optimizer.FactorialStudy")
local StudyContext = require("Modules.Optimizer.StudyContext")

local graph = { }
local FORMULA = "combined - factorA - factorB + baseline"
local FACTOR_CELLS = { "baseline", "factorA", "factorB", "combined" }

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function sameVersion(record, expected)
	local engine = record.engine or { }
	for _, key in ipairs({ "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }) do
		if expected[key] == nil or engine[key] == nil or tostring(expected[key]) ~= tostring(engine[key]) then
			return false, "engine_" .. key .. "_mismatch"
		end
	end
	if type(engine.manifestFingerprint) ~= "string" or #engine.manifestFingerprint ~= 64
		or not engine.manifestFingerprint:match("^[%da-f]+$") then return false, "engine_manifestFingerprint_invalid" end
	return true
end

local function near(left, right)
	return finite(left) and finite(right) and math.abs(left - right) <= math.max(1e-9, math.abs(right) * 1e-12)
end

local function transitionId(kind, beforeId, afterId, suffix)
	return kind .. ":" .. tostring(beforeId or "") .. "->" .. tostring(afterId or "") .. (suffix and (":" .. suffix) or "")
end

local function sameEngine(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	for _, key in ipairs({ "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }) do
		if tostring(left[key] or "") == "" or tostring(left[key]) ~= tostring(right[key]) then return false end
	end
	if type(left.manifestFingerprint) ~= "string" or #left.manifestFingerprint ~= 64
		or not left.manifestFingerprint:match("^[%da-f]+$") then return false end
	return true
end

local function sameStringArray(left, right)
	if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
	for index, value in ipairs(left) do
		if type(value) ~= "string" or value == "" or value ~= right[index] then return false end
	end
	return true
end

local function validStringArray(value)
	if type(value) ~= "table" then return false end
	local count, maximum = 0, 0
	for key, item in pairs(value) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key)
			or type(item) ~= "string" or item == "" then return false end
		count = count + 1
		if key > maximum then maximum = key end
	end
	return count == maximum
end

local function stringArraySubset(values, allowed)
	local allowSet = { }
	for _, value in ipairs(allowed or { }) do allowSet[value] = true end
	for _, value in ipairs(values or { }) do if not allowSet[value] then return false end end
	return true
end

local function validItemSnapshot(item)
	if type(item) ~= "table" then return false end
	local itemId = tonumber(item.itemId)
	if not finite(itemId) or itemId < 0 or itemId ~= math.floor(itemId) then return false end
	if itemId == 0 then return item.poBItemText == nil or item.poBItemText == "" end
	return type(item.poBItemText) == "string" and item.poBItemText ~= "" and #item.poBItemText <= 8192
end

local function validateSkillItemCellContext(record, expected)
	local source = record.source
	if type(source) ~= "table" or (source.type ~= "active_build" and source.type ~= "native_comparison_build"
		and source.type ~= "public_build_study") then
		return nil, "skill_item_source_identity_missing"
	end
	if source.type == "native_comparison_build" and (type(source.comparisonId) ~= "string" or source.comparisonId == "") then
		return nil, "skill_item_comparison_identity_missing"
	end
	if source.type == "public_build_study" and (type(source.studyId) ~= "string" or source.studyId == "") then
		return nil, "skill_item_public_study_identity_missing"
	end
	if source.buildSignatureAlgorithm ~= "sha256" or tonumber(source.buildSignatureVersion) ~= 1
		or not StudyContext.IsFingerprint(source.buildSignature) then
		return nil, "skill_item_source_build_signature_missing"
	end
	if not StudyContext.IsFingerprint(source.scenarioSignature) then return nil, "skill_item_scenario_signature_missing" end
	if record.trainingEligible ~= false or record.quarantined ~= true or type(record.quarantine) ~= "table"
		or (record.quarantine.status ~= "pending_review" and record.quarantine.status ~= "training_schema_unsupported") then
		return nil, "skill_item_record_not_quarantined"
	end
	if not record.admission or record.admission.trainingEligible ~= false then return nil, "skill_item_training_gate_missing" end
	local buildState = record.buildState
	if tostring(buildState.dataVersion or "") ~= tostring(record.engine.dataVersion)
		or tostring(buildState.treeVersion or "") ~= tostring(record.engine.treeVersion) then
		return nil, "skill_item_build_version_mismatch"
	end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(buildState.configuration)
	if not scenarioSignature then return nil, "skill_item_scenario_invalid: " .. tostring(scenarioError) end
	if scenarioSignature ~= source.scenarioSignature then return nil, "skill_item_scenario_signature_mismatch" end
	local experiment = record.experiment
	local factorA, factorB = experiment.factorA, experiment.factorB
	if type(factorA) ~= "table" or not finite(tonumber(factorA.groupIndex)) or tonumber(factorA.groupIndex) < 1
		or tonumber(factorA.groupIndex) ~= math.floor(tonumber(factorA.groupIndex))
		or not finite(tonumber(factorA.gemIndex)) or tonumber(factorA.gemIndex) < 1
		or tonumber(factorA.gemIndex) ~= math.floor(tonumber(factorA.gemIndex)) then
		return nil, "skill_item_skill_slot_identity_invalid"
	end
	local beforeSkill, afterSkill = factorA.before, factorA.after
	if type(beforeSkill) ~= "table" or type(afterSkill) ~= "table"
		or type(beforeSkill.gemId) ~= "string" or beforeSkill.gemId == ""
		or type(afterSkill.gemId) ~= "string" or afterSkill.gemId == ""
		or beforeSkill.gemId == afterSkill.gemId
		or type(factorA.sourceEffectId) ~= "string" or factorA.sourceEffectId == ""
		or type(factorA.effectId) ~= "string" or factorA.effectId == ""
		or not finite(tonumber(beforeSkill.level)) or tonumber(beforeSkill.level) < 1
		or tonumber(beforeSkill.level) ~= tonumber(afterSkill.level)
		or not finite(tonumber(beforeSkill.quality)) or tonumber(beforeSkill.quality) ~= tonumber(afterSkill.quality) then
		return nil, "skill_item_skill_factor_identity_invalid"
	end
	if not validStringArray(factorA.socketedSupportGemIds) then return nil, "skill_item_support_context_missing" end
	if type(factorB) ~= "table" or type(factorB.slot) ~= "string" or factorB.slot == ""
		or not validItemSnapshot(factorB.before) or not validItemSnapshot(factorB.after)
		or tonumber(factorB.before.itemId) == tonumber(factorB.after.itemId)
		or factorB.before.poBItemText == factorB.after.poBItemText then
		return nil, "skill_item_item_slot_factor_identity_invalid"
	end
	if experiment.socketStatus ~= "native_linked_group" then return nil, "skill_item_socket_link_context_invalid" end
	local expectedCells = {
		baseline = { gem = beforeSkill.gemId, effect = factorA.sourceEffectId, itemId = factorB.before.itemId },
		factorA = { gem = afterSkill.gemId, effect = factorA.effectId, itemId = factorB.before.itemId },
		factorB = { gem = beforeSkill.gemId, effect = factorA.sourceEffectId, itemId = factorB.after.itemId },
		combined = { gem = afterSkill.gemId, effect = factorA.effectId, itemId = factorB.after.itemId },
	}
	for _, name in ipairs(FACTOR_CELLS) do
		local cell = record.factorial.cells[name]
		if cell.exactCalculated ~= true or cell.evaluationMethod ~= "calcs_getMiscCalculator"
			or cell.socketStatus ~= "native_linked_group" then
			return nil, "skill_item_cell_calculation_provenance_invalid_" .. name
		end
		local context = cell.evidenceContext
		if type(context) ~= "table" or tonumber(context.schemaVersion) ~= 1
			or context.buildSignatureAlgorithm ~= "sha256" or tonumber(context.buildSignatureVersion) ~= 1
			or context.buildSignature ~= source.buildSignature or context.scenarioSignature ~= source.scenarioSignature
			or not sameEngine(context.engine, record.engine) or not sameEngine(context.engine, expected) then
			return nil, "skill_item_cell_context_mismatch_" .. name
		end
		local selected, selectedItem = cell.selectedSkill, cell.selectedItem
		local identity = expectedCells[name]
		if type(selected) ~= "table" or selected.isMainSkill ~= true
			or tonumber(selected.groupIndex) ~= tonumber(factorA.groupIndex)
			or tonumber(selected.gemIndex) ~= tonumber(factorA.gemIndex)
			or tostring(selected.gemId) ~= tostring(identity.gem)
			or tostring(selected.effectId) ~= tostring(identity.effect)
			or not validStringArray(selected.supportGemIds) or not validStringArray(selected.supportEffectIds)
			or not stringArraySubset(selected.supportGemIds, factorA.socketedSupportGemIds)
			or not sameStringArray(selected.socketedSupportGemIds, factorA.socketedSupportGemIds) then
			return nil, "skill_item_cell_skill_identity_mismatch_" .. name
		end
		if type(selectedItem) ~= "table" or selectedItem.slot ~= factorB.slot
			or tonumber(selectedItem.itemId) ~= tonumber(identity.itemId) then
			return nil, "skill_item_cell_identity_mismatch_" .. name
		end
	end
	return true
end

local function validatePassiveItemCellContext(record, expected)
	local source = record.source
	if type(source) ~= "table" or (source.type ~= "active_build" and source.type ~= "native_comparison_build"
		and source.type ~= "public_build_study") then
		return nil, "passive_item_source_identity_missing"
	end
	if source.buildSignatureAlgorithm ~= "sha256" or tonumber(source.buildSignatureVersion) ~= 1
		or not StudyContext.IsFingerprint(source.buildSignature) then
		return nil, "passive_item_source_build_signature_missing"
	end
	if not StudyContext.IsFingerprint(source.scenarioSignature) then return nil, "passive_item_scenario_signature_missing" end
	if record.trainingEligible ~= false or record.quarantined ~= true or type(record.quarantine) ~= "table"
		or (record.quarantine.status ~= "pending_review" and record.quarantine.status ~= "training_schema_unsupported") then
		return nil, "passive_item_record_not_quarantined"
	end
	if not record.admission or record.admission.trainingEligible ~= false then return nil, "passive_item_training_gate_missing" end
	local buildState = record.buildState
	if tostring(buildState.dataVersion or "") ~= tostring(record.engine.dataVersion)
		or tostring(buildState.treeVersion or "") ~= tostring(record.engine.treeVersion) then
		return nil, "passive_item_build_version_mismatch"
	end
	if type(buildState.allocatedNodeIds) ~= "table" or #buildState.allocatedNodeIds > 4096 then
		return nil, "passive_item_source_tree_context_missing"
	end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(buildState.configuration)
	if not scenarioSignature then return nil, "passive_item_scenario_invalid: " .. tostring(scenarioError) end
	if scenarioSignature ~= source.scenarioSignature then return nil, "passive_item_scenario_signature_mismatch" end
	local experiment = record.experiment
	local factorA, factorB = experiment.factorA, experiment.factorB
	local nodeId = type(factorA) == "table" and tonumber(factorA.nodeId)
	if type(factorA) ~= "table" or factorA.operation ~= "add_passive_node"
		or not finite(nodeId) or nodeId < 1 or nodeId ~= math.floor(nodeId) then
		return nil, "passive_item_node_factor_identity_invalid"
	end
	for _, allocatedNodeId in ipairs(buildState.allocatedNodeIds) do
		if tonumber(allocatedNodeId) == nodeId then return nil, "passive_item_node_was_preallocated" end
	end
	if type(factorB) ~= "table" or factorB.operation ~= "replace_item_in_slot"
		or type(factorB.slot) ~= "string" or factorB.slot == ""
		or not validItemSnapshot(factorB.before) or not validItemSnapshot(factorB.after)
		or tonumber(factorB.before.itemId) == tonumber(factorB.after.itemId)
		or factorB.before.poBItemText == factorB.after.poBItemText then
		return nil, "passive_item_item_slot_factor_identity_invalid"
	end
	if experiment.socketStatus ~= "native_linked_group" then return nil, "passive_item_socket_link_context_invalid" end
	local expectedItems = {
		baseline = tonumber(factorB.before.itemId), factorA = tonumber(factorB.before.itemId),
		factorB = tonumber(factorB.after.itemId), combined = tonumber(factorB.after.itemId),
	}
	local expectedAllocated = { baseline = false, factorA = true, factorB = false, combined = true }
	local skillIdentity
	for _, name in ipairs(FACTOR_CELLS) do
		local cell = record.factorial.cells[name]
		if cell.exactCalculated ~= true or cell.evaluationMethod ~= "calcs_getMiscCalculator"
			or cell.socketStatus ~= "native_linked_group" then
			return nil, "passive_item_cell_calculation_provenance_invalid_" .. name
		end
		local context = cell.evidenceContext
		if type(context) ~= "table" or tonumber(context.schemaVersion) ~= 1
			or context.buildSignatureAlgorithm ~= "sha256" or tonumber(context.buildSignatureVersion) ~= 1
			or context.buildSignature ~= source.buildSignature or context.scenarioSignature ~= source.scenarioSignature
			or not sameEngine(context.engine, record.engine) or not sameEngine(context.engine, expected) then
			return nil, "passive_item_cell_context_mismatch_" .. name
		end
		local selected, selectedItem = cell.selectedSkill, cell.selectedItem
		if type(selected) ~= "table" or selected.isMainSkill ~= true
			or not finite(tonumber(selected.groupIndex)) or tonumber(selected.groupIndex) < 1
			or tonumber(selected.groupIndex) ~= math.floor(tonumber(selected.groupIndex))
			or not finite(tonumber(selected.gemIndex)) or tonumber(selected.gemIndex) < 1
			or tonumber(selected.gemIndex) ~= math.floor(tonumber(selected.gemIndex))
			or type(selected.gemId) ~= "string" or selected.gemId == ""
			or type(selected.effectId) ~= "string" or selected.effectId == ""
			or not validStringArray(selected.supportGemIds) or not validStringArray(selected.supportEffectIds)
			or not validStringArray(selected.socketedSupportGemIds) then
			return nil, "passive_item_cell_skill_identity_missing_" .. name
		end
		if skillIdentity and (tonumber(selected.groupIndex) ~= tonumber(skillIdentity.groupIndex)
			or tonumber(selected.gemIndex) ~= tonumber(skillIdentity.gemIndex)
			or selected.gemId ~= skillIdentity.gemId or selected.effectId ~= skillIdentity.effectId
			or not sameStringArray(selected.supportGemIds, skillIdentity.supportGemIds)
			or not sameStringArray(selected.supportEffectIds, skillIdentity.supportEffectIds)
			or not sameStringArray(selected.socketedSupportGemIds, skillIdentity.socketedSupportGemIds)) then
			return nil, "passive_item_cell_skill_context_mismatch_" .. name
		end
		if not skillIdentity then skillIdentity = selected end
		if type(selectedItem) ~= "table" or selectedItem.slot ~= factorB.slot
			or tonumber(selectedItem.itemId) ~= expectedItems[name] then
			return nil, "passive_item_cell_item_identity_mismatch_" .. name
		end
		if tonumber(cell.nodeId) ~= nodeId or cell.nodeAllocated ~= expectedAllocated[name]
			or type(cell.addedNodeIds) ~= "table" then
			return nil, "passive_item_cell_node_identity_mismatch_" .. name
		end
		if expectedAllocated[name] then
			if #cell.addedNodeIds ~= 1 or tonumber(cell.addedNodeIds[1]) ~= nodeId then
				return nil, "passive_item_cell_path_repair_mismatch_" .. name
			end
		elseif #cell.addedNodeIds ~= 0 then
			return nil, "passive_item_cell_path_repair_mismatch_" .. name
		end
	end
	return true
end

local function validatePassiveSupportCellContext(record, expected)
	local source = record.source
	if type(source) ~= "table" or (source.type ~= "active_build" and source.type ~= "native_comparison_build"
		and source.type ~= "public_build_study") then
		return nil, "passive_support_source_identity_missing"
	end
	if source.type == "native_comparison_build" and (type(source.comparisonId) ~= "string" or source.comparisonId == "") then
		return nil, "passive_support_comparison_identity_missing"
	end
	if source.type == "public_build_study" and (type(source.studyId) ~= "string" or source.studyId == "") then
		return nil, "passive_support_study_identity_missing"
	end
	if source.buildSignatureAlgorithm ~= "sha256" or tonumber(source.buildSignatureVersion) ~= 1
		or not StudyContext.IsFingerprint(source.buildSignature) then
		return nil, "passive_support_source_build_signature_missing"
	end
	local sourceBuild = source.buildSignature
	if not StudyContext.IsFingerprint(source.scenarioSignature) then return nil, "passive_support_scenario_signature_missing" end
	if record.trainingEligible ~= false or record.quarantined ~= true or type(record.quarantine) ~= "table"
		or (record.quarantine.status ~= "pending_review" and record.quarantine.status ~= "training_schema_unsupported") then
		return nil, "passive_support_record_not_quarantined"
	end
	if not record.admission or record.admission.trainingEligible ~= false then return nil, "passive_support_training_gate_missing" end
	local buildState = record.buildState
	if tostring(buildState.dataVersion or "") ~= tostring(record.engine.dataVersion)
		or tostring(buildState.treeVersion or "") ~= tostring(record.engine.treeVersion) then
		return nil, "passive_support_build_version_mismatch"
	end
	if type(buildState.allocatedNodeIds) ~= "table" or #buildState.allocatedNodeIds > 4096 then
		return nil, "passive_support_source_tree_context_missing"
	end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(buildState.configuration)
	if not scenarioSignature then return nil, "passive_support_scenario_invalid: " .. tostring(scenarioError) end
	if scenarioSignature ~= source.scenarioSignature then return nil, "passive_support_scenario_signature_mismatch" end
	local experiment = record.experiment
	local factorA, factorB = experiment.factorA, experiment.factorB
	local nodeId = type(factorA) == "table" and tonumber(factorA.nodeId)
	if type(factorA) ~= "table" or factorA.operation ~= "add_passive_node"
		or not finite(nodeId) or nodeId < 1 or nodeId ~= math.floor(nodeId) then
		return nil, "passive_support_node_factor_identity_invalid"
	end
	for _, allocatedNodeId in ipairs(buildState.allocatedNodeIds) do
		if tonumber(allocatedNodeId) == nodeId then return nil, "passive_support_node_was_preallocated" end
	end
	local beforeSupport = type(factorB) == "table" and factorB.before
	local afterSupport = type(factorB) == "table" and factorB.after
	if type(factorB) ~= "table" or factorB.operation ~= "replace_support_gem"
		or not finite(tonumber(factorB.groupIndex)) or tonumber(factorB.groupIndex) < 1
		or tonumber(factorB.groupIndex) ~= math.floor(tonumber(factorB.groupIndex))
		or not finite(tonumber(factorB.gemIndex)) or tonumber(factorB.gemIndex) < 1
		or tonumber(factorB.gemIndex) ~= math.floor(tonumber(factorB.gemIndex))
		or type(beforeSupport) ~= "table" or type(afterSupport) ~= "table"
		or type(beforeSupport.gemId) ~= "string" or beforeSupport.gemId == ""
		or type(afterSupport.gemId) ~= "string" or afterSupport.gemId == ""
		or beforeSupport.gemId == afterSupport.gemId
		or not finite(tonumber(beforeSupport.level)) or tonumber(beforeSupport.level) < 1
		or tonumber(beforeSupport.level) ~= tonumber(afterSupport.level)
		or not finite(tonumber(beforeSupport.quality)) or tonumber(beforeSupport.quality) ~= tonumber(afterSupport.quality) then
		return nil, "passive_support_gem_factor_identity_invalid"
	end
	if experiment.socketStatus ~= "native_linked_group" and experiment.socketStatus ~= "unlinked_planning_group" then
		return nil, "passive_support_socket_link_context_invalid"
	end
	local expectedSupport = {
		baseline = beforeSupport.gemId, factorA = beforeSupport.gemId,
		factorB = afterSupport.gemId, combined = afterSupport.gemId,
	}
	local expectedNode = { baseline = false, factorA = true, factorB = false, combined = true }
	local referenceSupportIds, referenceSocketedIds, referenceSkill
	for _, name in ipairs(FACTOR_CELLS) do
		local cell = record.factorial.cells[name]
		if cell.exactCalculated ~= true or cell.evaluationMethod ~= "calcs_getMiscCalculator"
			or cell.socketStatus ~= experiment.socketStatus then
			return nil, "passive_support_cell_calculation_provenance_invalid_" .. name
		end
		local context = cell.evidenceContext
		if type(context) ~= "table" then
			return nil, "passive_support_cell_context_mismatch_" .. name
		end
		if tonumber(context.schemaVersion) ~= 1 or context.buildSignatureAlgorithm ~= "sha256"
			or tonumber(context.buildSignatureVersion) ~= 1 then
			return nil, "passive_support_cell_context_schema_invalid_" .. name
		end
		if context.buildSignature ~= sourceBuild then return nil, "passive_support_cell_build_signature_mismatch_" .. name end
		if context.scenarioSignature ~= source.scenarioSignature then return nil, "passive_support_cell_scenario_signature_mismatch_" .. name end
		if not sameEngine(context.engine, record.engine) then return nil, "passive_support_cell_record_engine_mismatch_" .. name end
		if not sameEngine(context.engine, expected) then return nil, "passive_support_cell_current_engine_mismatch_" .. name end
		local selected = cell.selectedSkill
		if type(selected) ~= "table" or selected.isMainSkill ~= true
			or tonumber(selected.groupIndex) ~= tonumber(factorB.groupIndex)
			or not finite(tonumber(selected.gemIndex)) or tonumber(selected.gemIndex) < 1
			or tonumber(selected.gemIndex) ~= math.floor(tonumber(selected.gemIndex))
			or type(selected.gemId) ~= "string" or selected.gemId == ""
			or type(selected.effectId) ~= "string" or selected.effectId == ""
			or not finite(tonumber(selected.level)) or tonumber(selected.level) < 1
			or not finite(tonumber(selected.quality)) or tonumber(selected.quality) < 0
			or tonumber(selected.supportLevel) ~= tonumber(beforeSupport.level)
			or tonumber(selected.supportQuality) ~= tonumber(beforeSupport.quality)
			or not validStringArray(selected.supportGemIds) or not validStringArray(selected.supportEffectIds)
			or not validStringArray(selected.socketedSupportGemIds)
			or tostring(selected.supportGemId) ~= tostring(expectedSupport[name]) or selected.supportApplied ~= true then
			return nil, "passive_support_cell_skill_identity_mismatch_" .. name
		end
		if name == "baseline" then
			referenceSkill = selected
		elseif tostring(selected.gemId) ~= tostring(referenceSkill.gemId)
			or tostring(selected.effectId) ~= tostring(referenceSkill.effectId)
			or tonumber(selected.groupIndex) ~= tonumber(referenceSkill.groupIndex)
			or tonumber(selected.gemIndex) ~= tonumber(referenceSkill.gemIndex)
			or tonumber(selected.level) ~= tonumber(referenceSkill.level)
			or tonumber(selected.quality) ~= tonumber(referenceSkill.quality) then
			return nil, "passive_support_cell_main_skill_changed_" .. name
		end
		if tonumber(selected.gemIndex) ~= tonumber(factorB.skillGemIndex) then return nil, "passive_support_source_skill_slot_mismatch" end
		local changedSupport = expectedSupport[name]
		local residual = { }
		local removedSupport = false
		for _, gemId in ipairs(selected.supportGemIds) do
			if gemId == changedSupport and not removedSupport then removedSupport = true
			else residual[#residual + 1] = gemId end
		end
		if not removedSupport then return nil, "passive_support_cell_selected_support_not_applied_" .. name end
		table.sort(residual)
		local residualKey = table.concat(residual, "\0")
		if referenceSupportIds and residualKey ~= referenceSupportIds then
			return nil, "passive_support_cell_other_supports_changed_" .. name
		end
		referenceSupportIds = referenceSupportIds or residualKey
		local socketedResidual = { }
		local removedSocketed = false
		for _, gemId in ipairs(selected.socketedSupportGemIds) do
			if gemId == changedSupport and not removedSocketed then removedSocketed = true
			else socketedResidual[#socketedResidual + 1] = gemId end
		end
		if not removedSocketed then return nil, "passive_support_cell_socketed_support_missing_" .. name end
		table.sort(socketedResidual)
		local socketedKey = table.concat(socketedResidual, "\0")
		if referenceSocketedIds and referenceSocketedIds ~= socketedKey then
			return nil, "passive_support_cell_socket_topology_changed_" .. name
		end
		referenceSocketedIds = referenceSocketedIds or socketedKey
		if tonumber(cell.nodeId) ~= nodeId or cell.nodeAllocated ~= expectedNode[name]
			or type(cell.addedNodeIds) ~= "table" then
			return nil, "passive_support_cell_node_identity_mismatch_" .. name
		end
		if expectedNode[name] then
			if #cell.addedNodeIds ~= 1 or tonumber(cell.addedNodeIds[1]) ~= nodeId then
				return nil, "passive_support_cell_path_repair_mismatch_" .. name
			end
		else
			if #cell.addedNodeIds ~= 0 then return nil, "passive_support_cell_path_repair_mismatch_" .. name end
		end
		local pointsUsed = tonumber(cell.passivePointsUsed)
		if not finite(pointsUsed) or pointsUsed < 0 then
			return nil, "passive_support_cell_point_count_missing_" .. name
		end
		if name == "baseline" or name == "factorB" then
			if name == "factorB" and pointsUsed ~= tonumber(record.factorial.cells.baseline.passivePointsUsed) then
				return nil, "passive_support_non_node_point_count_changed"
			end
		else
			local noNodeCell = name == "factorA" and record.factorial.cells.baseline or record.factorial.cells.factorB
			if pointsUsed ~= tonumber(noNodeCell.passivePointsUsed) + 1 then
				return nil, "passive_support_node_point_delta_invalid_" .. name
			end
		end
	end
	if not referenceSkill or tonumber(referenceSkill.gemIndex) ~= tonumber(factorB.skillGemIndex) then
		return nil, "passive_support_source_skill_slot_mismatch"
	end
	return true
end

local function validateSkillSupportCellContext(record, expected)
	local source = record.source
	if type(source) ~= "table" or (source.type ~= "active_build" and source.type ~= "native_comparison_build"
		and source.type ~= "public_build_study") then
		return nil, "skill_support_source_identity_missing"
	end
	if source.type == "native_comparison_build" and (type(source.comparisonId) ~= "string" or source.comparisonId == "") then
		return nil, "skill_support_comparison_identity_missing"
	end
	if source.type == "public_build_study" and (type(source.studyId) ~= "string" or source.studyId == "") then
		return nil, "skill_support_public_study_identity_missing"
	end
	if source.buildSignatureAlgorithm ~= "sha256" or tonumber(source.buildSignatureVersion) ~= 1
		or not StudyContext.IsFingerprint(source.buildSignature) then
		return nil, "skill_support_source_build_signature_missing"
	end
	if not StudyContext.IsFingerprint(source.scenarioSignature) then return nil, "skill_support_scenario_signature_missing" end
	if record.trainingEligible ~= false or record.quarantined ~= true or type(record.quarantine) ~= "table"
		or (record.quarantine.status ~= "pending_review" and record.quarantine.status ~= "training_schema_unsupported") then
		return nil, "skill_support_record_not_quarantined"
	end
	if not record.admission or record.admission.trainingEligible ~= false then return nil, "skill_support_training_gate_missing" end
	local buildState = record.buildState
	if tostring(buildState.dataVersion or "") ~= tostring(record.engine.dataVersion)
		or tostring(buildState.treeVersion or "") ~= tostring(record.engine.treeVersion) then
		return nil, "skill_support_build_version_mismatch"
	end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(buildState.configuration)
	if not scenarioSignature then return nil, "skill_support_scenario_invalid: " .. tostring(scenarioError) end
	if scenarioSignature ~= source.scenarioSignature then return nil, "skill_support_scenario_signature_mismatch" end

	local experiment = record.experiment
	local factorA, factorB = experiment.factorA, experiment.factorB
	local beforeSkill, afterSkill = factorA.before, factorA.after
	local beforeSupport, afterSupport = factorB.before, factorB.after
	local groupIndex = tonumber(factorA.groupIndex)
	local skillGemIndex = tonumber(factorA.gemIndex)
	local supportGroupIndex = tonumber(factorB.groupIndex)
	local supportGemIndex = tonumber(factorB.gemIndex)
	local function validIndex(value)
		return finite(value) and value >= 1 and value == math.floor(value)
	end
	if factorA.operation ~= "replace_selected_main_skill_gem" or factorB.operation ~= "replace_support_gem"
		or not validIndex(groupIndex) or not validIndex(skillGemIndex) or not validIndex(supportGroupIndex)
		or not validIndex(supportGemIndex) or groupIndex ~= supportGroupIndex or skillGemIndex == supportGemIndex
		or type(beforeSkill) ~= "table" or type(afterSkill) ~= "table"
		or type(beforeSupport) ~= "table" or type(afterSupport) ~= "table"
		or type(beforeSkill.gemId) ~= "string" or beforeSkill.gemId == ""
		or type(afterSkill.gemId) ~= "string" or afterSkill.gemId == ""
		or beforeSkill.gemId == afterSkill.gemId
		or type(beforeSupport.gemId) ~= "string" or beforeSupport.gemId == ""
		or type(afterSupport.gemId) ~= "string" or afterSupport.gemId == ""
		or beforeSupport.gemId == afterSupport.gemId
		or type(factorA.sourceEffectId) ~= "string" or factorA.sourceEffectId == ""
		or type(factorA.effectId) ~= "string" or factorA.effectId == ""
		or not finite(tonumber(beforeSkill.level)) or tonumber(beforeSkill.level) < 1
		or tonumber(beforeSkill.level) ~= tonumber(afterSkill.level)
		or not finite(tonumber(beforeSkill.quality)) or tonumber(beforeSkill.quality) < 0
		or tonumber(beforeSkill.quality) ~= tonumber(afterSkill.quality)
		or not finite(tonumber(beforeSupport.level)) or tonumber(beforeSupport.level) < 1
		or tonumber(beforeSupport.level) ~= tonumber(afterSupport.level)
		or not finite(tonumber(beforeSupport.quality)) or tonumber(beforeSupport.quality) < 0
		or tonumber(beforeSupport.quality) ~= tonumber(afterSupport.quality) then
		return nil, "skill_support_factor_context_invalid"
	end
	if experiment.socketStatus ~= "native_linked_group" and experiment.socketStatus ~= "unlinked_planning_group" then
		return nil, "skill_support_socket_link_context_invalid"
	end

	local expectedCells = {
		baseline = { skill = beforeSkill.gemId, effect = factorA.sourceEffectId, support = beforeSupport.gemId },
		factorA = { skill = afterSkill.gemId, effect = factorA.effectId, support = beforeSupport.gemId },
		factorB = { skill = beforeSkill.gemId, effect = factorA.sourceEffectId, support = afterSupport.gemId },
		combined = { skill = afterSkill.gemId, effect = factorA.effectId, support = afterSupport.gemId },
	}
	local referenceAppliedSupports, referenceSocketedSupports
	for _, name in ipairs(FACTOR_CELLS) do
		local cell = record.factorial.cells[name]
		if cell.exactCalculated ~= true or cell.evaluationMethod ~= "calcs_getMiscCalculator"
			or cell.socketStatus ~= experiment.socketStatus then
			return nil, "skill_support_cell_calculation_provenance_invalid_" .. name
		end
		local context = cell.evidenceContext
		if type(context) ~= "table" then return nil, "skill_support_cell_evidence_context_missing_" .. name end
		if tonumber(context.schemaVersion) ~= 1 or context.buildSignatureAlgorithm ~= "sha256"
			or tonumber(context.buildSignatureVersion) ~= 1 then
			return nil, "skill_support_cell_evidence_schema_invalid_" .. name
		end
		if context.buildSignature ~= source.buildSignature then return nil, "skill_support_cell_build_signature_mismatch_" .. name end
		if context.scenarioSignature ~= source.scenarioSignature then return nil, "skill_support_cell_scenario_signature_mismatch_" .. name end
		if not sameEngine(context.engine, record.engine) then return nil, "skill_support_cell_record_engine_mismatch_" .. name end
		if not sameEngine(context.engine, expected) then return nil, "skill_support_cell_current_engine_mismatch_" .. name end

		local selected = cell.selectedSkill
		local identity = expectedCells[name]
		if type(selected) ~= "table" or selected.isMainSkill ~= true
			or tonumber(selected.groupIndex) ~= groupIndex or tonumber(selected.gemIndex) ~= skillGemIndex
			or tostring(selected.gemId) ~= tostring(identity.skill) or tostring(selected.effectId) ~= tostring(identity.effect)
			or tostring(selected.supportGemId) ~= tostring(identity.support) or selected.supportApplied ~= true
			or tonumber(selected.level) ~= tonumber(beforeSkill.level)
			or tonumber(selected.quality) ~= tonumber(beforeSkill.quality)
			or tonumber(selected.supportLevel) ~= tonumber(beforeSupport.level)
			or tonumber(selected.supportQuality) ~= tonumber(beforeSupport.quality)
			or not validStringArray(selected.supportGemIds) or not validStringArray(selected.supportEffectIds)
			or #selected.supportGemIds ~= #selected.supportEffectIds
			or not validStringArray(selected.socketedSupportGemIds) then
			return nil, "skill_support_cell_identity_mismatch_" .. name
		end

		local function residualPackage(gemIds, effectIds, changedGemId)
			local package, removed = { }, false
			for index, gemId in ipairs(gemIds) do
				if gemId == changedGemId and not removed then
					removed = true
				else
					package[#package + 1] = gemId .. "\0" .. (effectIds and effectIds[index] or "")
				end
			end
			if not removed then return nil end
			table.sort(package)
			return table.concat(package, "\1")
		end
		local appliedPackage = residualPackage(selected.supportGemIds, selected.supportEffectIds, identity.support)
		local socketedPackage = residualPackage(selected.socketedSupportGemIds, nil, identity.support)
		if not appliedPackage or not socketedPackage then return nil, "skill_support_cell_selected_support_not_applied_" .. name end
		if referenceAppliedSupports and referenceAppliedSupports ~= appliedPackage then
			return nil, "skill_support_cell_other_supports_changed_" .. name
		end
		if referenceSocketedSupports and referenceSocketedSupports ~= socketedPackage then
			return nil, "skill_support_cell_socket_topology_changed_" .. name
		end
		referenceAppliedSupports = referenceAppliedSupports or appliedPackage
		referenceSocketedSupports = referenceSocketedSupports or socketedPackage
	end
	return true
end

local function validateSkillSkillCellContext(record, expected)
	local source = record.source
	local experiment = record.experiment
	if type(source) ~= "table" or type(source.buildSignature) ~= "string"
		or not StudyContext.IsFingerprint(source.buildSignature) then return nil, "skill_skill_source_build_signature_missing" end
	if not StudyContext.IsFingerprint(source.scenarioSignature) then return nil, "skill_skill_scenario_signature_missing" end
	if experiment.socketStatus ~= "native_linked_groups" then return nil, "skill_skill_socket_link_context_invalid" end
	local factors = { experiment.factorA, experiment.factorB }
	local identities = { }
	for index, factor in ipairs(factors) do
		local before, after = factor.before, factor.after
		local groupIndex, gemIndex = tonumber(factor.groupIndex), tonumber(factor.gemIndex)
		if factor.operation ~= "replace_full_dps_skill_gem"
			or not finite(groupIndex) or groupIndex < 1 or groupIndex ~= math.floor(groupIndex)
			or not finite(gemIndex) or gemIndex < 1 or gemIndex ~= math.floor(gemIndex)
			or type(before) ~= "table" or type(after) ~= "table"
			or type(before.gemId) ~= "string" or before.gemId == ""
			or type(after.gemId) ~= "string" or after.gemId == "" or before.gemId == after.gemId
			or type(before.effectId) ~= "string" or before.effectId == ""
			or type(after.effectId) ~= "string" or after.effectId == ""
			or not finite(tonumber(before.level)) or tonumber(before.level) < 1
			or tonumber(before.level) ~= tonumber(after.level)
			or not finite(tonumber(before.quality)) or tonumber(before.quality) < 0
			or tonumber(before.quality) ~= tonumber(after.quality)
			or not validStringArray(factor.socketedSupportGemIds) then
			return nil, "skill_skill_factor_identity_invalid_" .. tostring(index)
		end
		identities[index] = { groupIndex = groupIndex, gemIndex = gemIndex, before = before, after = after }
	end
	if identities[1].groupIndex == identities[2].groupIndex then return nil, "skill_skill_groups_must_be_distinct" end
	local expectedCells = {
		baseline = { a = identities[1].before, b = identities[2].before },
		factorA = { a = identities[1].after, b = identities[2].before },
		factorB = { a = identities[1].before, b = identities[2].after },
		combined = { a = identities[1].after, b = identities[2].after },
	}
	for _, name in ipairs(FACTOR_CELLS) do
		local cell = record.factorial.cells[name]
		if cell.exactCalculated ~= true or cell.evaluationMethod ~= "calcs_getMiscCalculator"
			or cell.socketStatus ~= "native_linked_groups" then
			return nil, "skill_skill_cell_calculation_provenance_invalid_" .. name
		end
		local context = cell.evidenceContext
		if type(context) ~= "table" or tonumber(context.schemaVersion) ~= 1
			or context.buildSignatureAlgorithm ~= "sha256" or tonumber(context.buildSignatureVersion) ~= 1 then
			return nil, "skill_skill_cell_evidence_schema_invalid_" .. name
		end
		if context.buildSignature ~= source.buildSignature then return nil, "skill_skill_cell_build_signature_mismatch_" .. name end
		if context.scenarioSignature ~= source.scenarioSignature then return nil, "skill_skill_cell_scenario_signature_mismatch_" .. name end
		if not sameEngine(context.engine, record.engine) or not sameEngine(context.engine, expected) then
			return nil, "skill_skill_cell_engine_mismatch_" .. name
		end
		local selectedSkills, expectedCell = cell.selectedSkills, expectedCells[name]
		if type(selectedSkills) ~= "table" then return nil, "skill_skill_cell_identities_missing_" .. name end
		for index, factorKey in ipairs({ "a", "b" }) do
			local selected = selectedSkills[index == 1 and "factorA" or "factorB"]
			local identity = expectedCell[factorKey]
			local factor = factors[index]
			if type(selected) ~= "table" or selected.fullDPSIncluded ~= true
				or tonumber(selected.groupIndex) ~= identities[index].groupIndex
				or tonumber(selected.gemIndex) ~= identities[index].gemIndex
				or tostring(selected.gemId) ~= identity.gemId or tostring(selected.effectId) ~= identity.effectId
				or tonumber(selected.level) ~= tonumber(identity.level)
				or tonumber(selected.quality) ~= tonumber(identity.quality)
				or type(selected.fullDPSActivityIdentity) ~= "string" or selected.fullDPSActivityIdentity == ""
				or not validStringArray(selected.socketedSupportGemIds)
				or not sameStringArray(selected.socketedSupportGemIds, factor.socketedSupportGemIds) then
				return nil, "skill_skill_cell_identity_mismatch_" .. name .. "_" .. factorKey
			end
		end
	end
	return true
end

local function factorialFactors(record)
	local experiment = record.experiment or { }
	local factorA, factorB = experiment.factorA, experiment.factorB
	if type(factorA) ~= "table" or type(factorB) ~= "table" then return nil, "typed_factors_missing" end
	if record.kind == "passive_factorial_interaction" and experiment.unit == "four_cell_passive_factorial" then
		local nodeA, nodeB = tonumber(factorA.nodeId), tonumber(factorB.nodeId)
		if not nodeA or nodeA < 1 or nodeA ~= math.floor(nodeA) or not nodeB or nodeB < 1 or nodeB ~= math.floor(nodeB) or nodeA == nodeB then
			return nil, "passive_factor_ids_invalid"
		end
		return { type = "passive_node", id = tostring(nodeA), nodeId = nodeA },
			{ type = "passive_node", id = tostring(nodeB), nodeId = nodeB }, "passive_node_x_passive_node"
	end
	if record.kind == "passive_support_factorial_interaction" and experiment.unit == "four_cell_passive_support_factorial" then
		local nodeId = tonumber(factorA.nodeId)
		local supportBefore, supportAfter = factorB.before, factorB.after
		if factorA.operation ~= "add_passive_node" or factorB.operation ~= "replace_support_gem"
			or not finite(nodeId) or nodeId < 1 or nodeId ~= math.floor(nodeId)
			or type(supportBefore) ~= "table" or type(supportAfter) ~= "table"
			or type(supportBefore.gemId) ~= "string" or supportBefore.gemId == ""
			or type(supportAfter.gemId) ~= "string" or supportAfter.gemId == ""
			or supportBefore.gemId == supportAfter.gemId then
			return nil, "passive_support_factor_ids_invalid"
		end
		return { type = "passive_node", id = tostring(nodeId), nodeId = nodeId }, {
			type = "support_gem", id = transitionId("support", supportBefore.gemId, supportAfter.gemId),
			fromGemId = supportBefore.gemId, toGemId = supportAfter.gemId,
		}, "passive_node_x_support_gem"
	end
	if record.kind == "skill_support_factorial_interaction" and experiment.unit == "four_cell_skill_support_factorial" then
		local skillBefore = factorA.before and factorA.before.gemId
		local skillAfter = factorA.after and factorA.after.gemId
		local effectBefore, effectAfter = factorA.sourceEffectId, factorA.effectId
		local supportBefore = factorB.before and factorB.before.gemId
		local supportAfter = factorB.after and factorB.after.gemId
		if factorA.operation ~= "replace_selected_main_skill_gem" or factorB.operation ~= "replace_support_gem"
			or type(skillBefore) ~= "string" or skillBefore == "" or type(skillAfter) ~= "string" or skillAfter == ""
			or type(effectBefore) ~= "string" or effectBefore == "" or type(effectAfter) ~= "string" or effectAfter == ""
			or type(supportBefore) ~= "string" or supportBefore == "" or type(supportAfter) ~= "string" or supportAfter == "" then
			return nil, "skill_support_factor_ids_invalid"
		end
		return {
			type = "main_skill_gem", id = transitionId("main_skill", skillBefore, skillAfter, effectBefore .. "->" .. effectAfter),
			fromGemId = skillBefore, toGemId = skillAfter, fromEffectId = effectBefore, toEffectId = effectAfter,
		}, {
			type = "support_gem", id = transitionId("support", supportBefore, supportAfter),
			fromGemId = supportBefore, toGemId = supportAfter,
		}, "main_skill_gem_x_support_gem"
	end
	if record.kind == "skill_skill_factorial_interaction" and experiment.unit == "four_cell_skill_skill_factorial" then
		local function skillTransition(factor)
			local before, after = factor.before, factor.after
			local groupIndex, gemIndex = tonumber(factor.groupIndex), tonumber(factor.gemIndex)
			if factor.operation ~= "replace_full_dps_skill_gem"
				or type(before) ~= "table" or type(after) ~= "table"
				or type(before.gemId) ~= "string" or before.gemId == ""
				or type(after.gemId) ~= "string" or after.gemId == "" or before.gemId == after.gemId
				or type(before.effectId) ~= "string" or before.effectId == ""
				or type(after.effectId) ~= "string" or after.effectId == ""
				or not finite(groupIndex) or groupIndex < 1 or groupIndex ~= math.floor(groupIndex)
				or not finite(gemIndex) or gemIndex < 1 or gemIndex ~= math.floor(gemIndex) then return nil end
			return {
				type = "active_skill_gem",
				id = transitionId("active_skill", before.gemId, after.gemId, tostring(before.effectId) .. "->" .. tostring(after.effectId)),
				fromGemId = before.gemId, toGemId = after.gemId,
				fromEffectId = before.effectId, toEffectId = after.effectId,
				groupIndex = groupIndex, gemIndex = gemIndex,
			}
		end
		local factorA, factorB = skillTransition(factorA), skillTransition(factorB)
		if not factorA or not factorB or factorA.groupIndex == factorB.groupIndex then return nil, "skill_skill_factor_ids_invalid" end
		return factorA, factorB, "active_skill_gem_x_active_skill_gem"
	end
	if record.kind == "skill_item_slot_factorial_interaction" and experiment.unit == "four_cell_skill_item_slot_factorial" then
		local skillBefore = factorA.before and factorA.before.gemId
		local skillAfter = factorA.after and factorA.after.gemId
		local effectBefore, effectAfter = factorA.sourceEffectId, factorA.effectId
		local itemBefore, itemAfter = factorB.before, factorB.after
		if factorA.operation ~= "replace_selected_main_skill_gem" or factorB.operation ~= "replace_item_in_slot"
			or type(skillBefore) ~= "string" or skillBefore == "" or type(skillAfter) ~= "string" or skillAfter == ""
			or type(effectBefore) ~= "string" or effectBefore == "" or type(effectAfter) ~= "string" or effectAfter == ""
			or type(factorB.slot) ~= "string" or factorB.slot == ""
			or type(itemBefore) ~= "table" or type(itemAfter) ~= "table"
			or not finite(tonumber(itemBefore.itemId)) or not finite(tonumber(itemAfter.itemId))
			or tonumber(itemBefore.itemId) == tonumber(itemAfter.itemId) then
			return nil, "skill_item_slot_factor_ids_invalid"
		end
		local beforeId, afterId = tonumber(itemBefore.itemId), tonumber(itemAfter.itemId)
		return {
			type = "main_skill_gem", id = transitionId("main_skill", skillBefore, skillAfter, effectBefore .. "->" .. effectAfter),
			fromGemId = skillBefore, toGemId = skillAfter, fromEffectId = effectBefore, toEffectId = effectAfter,
		}, {
			type = "item_slot", id = transitionId("item_slot:" .. factorB.slot, beforeId, afterId),
			slot = factorB.slot, fromItemId = beforeId, toItemId = afterId,
		}, "main_skill_gem_x_item_slot"
	end
	if record.kind == "passive_item_slot_factorial_interaction" and experiment.unit == "four_cell_passive_item_slot_factorial" then
		local nodeId = tonumber(factorA.nodeId)
		local beforeItem, afterItem = factorB.before, factorB.after
		if factorA.operation ~= "add_passive_node" or factorB.operation ~= "replace_item_in_slot"
			or not finite(nodeId) or nodeId < 1 or nodeId ~= math.floor(nodeId)
			or type(factorB.slot) ~= "string" or factorB.slot == ""
			or not validItemSnapshot(beforeItem) or not validItemSnapshot(afterItem)
			or tonumber(beforeItem.itemId) == tonumber(afterItem.itemId) then
			return nil, "passive_item_slot_factor_ids_invalid"
		end
		local beforeId, afterId = tonumber(beforeItem.itemId), tonumber(afterItem.itemId)
		return { type = "passive_node", id = tostring(nodeId), nodeId = nodeId }, {
			type = "item_slot", id = transitionId("item_slot:" .. factorB.slot, beforeId, afterId),
			slot = factorB.slot, fromItemId = beforeId, toItemId = afterId,
		}, "passive_node_x_item_slot"
	end
	return nil, "factorial_kind_unsupported"
end

local function validateRecord(record, expected)
	if type(record) ~= "table" or record.admission == nil or record.admission.exactCalculated ~= true then
		return nil, "not_exact_calculation"
	end
	local current, versionError = sameVersion(record, expected)
	if not current then return nil, versionError end
	local buildState = record.buildState
	if type(buildState) ~= "table" or type(buildState.class) ~= "table"
		or type(buildState.configuration) ~= "table" or type(buildState.configuration.values) ~= "table" then
		return nil, "build_or_scenario_context_missing"
	end
	local experiment, factorial = record.experiment, record.factorial
	if type(experiment) ~= "table" or experiment.factorialSchemaVersion ~= 1
		or experiment.formula ~= FORMULA or type(factorial) ~= "table" or factorial.formula ~= FORMULA then
		return nil, "factorial_schema_or_formula_mismatch"
	end
	local cells = factorial.cells
	if record.kind == "passive_factorial_interaction" and type(cells) == "table"
		and cells.baseline == nil and cells.combined == nil then
		-- Earlier passive factorial records store only factorA/factorB inside
		-- `factorial`; their exact baseline/combined are the record-level pair.
		cells = {
			baseline = record.baseline,
			factorA = cells.factorA,
			factorB = cells.factorB,
			combined = record.candidate,
		}
	end
	if type(cells) ~= "table" then return nil, "factorial_cells_missing" end
	for _, name in ipairs(FACTOR_CELLS) do
		if type(cells[name]) ~= "table" or type(cells[name].metrics) ~= "table" then return nil, "factorial_cell_missing_" .. name end
	end
	local recomputed, computeError = FactorialStudy.Compute(cells)
	if not recomputed then return nil, "factorial_metrics_invalid: " .. tostring(computeError) end
	if tonumber(factorial.metricCount) ~= recomputed.metricCount then return nil, "factorial_metric_count_mismatch" end
	local stored = factorial.interaction
	if type(stored) ~= "table" then return nil, "factorial_interaction_missing" end
	for _, metric in ipairs(recomputed.metricKeys) do
		local saved = stored[metric]
		if type(saved) ~= "table" or not near(saved.baseline, recomputed.metrics[metric].baseline)
			or not near(saved.factorA, recomputed.metrics[metric].factorA)
			or not near(saved.factorB, recomputed.metrics[metric].factorB)
			or not near(saved.combined, recomputed.metrics[metric].combined)
			or not near(saved.interaction, recomputed.metrics[metric].interaction) then
			return nil, "factorial_interaction_integrity_mismatch_" .. metric
		end
	end
	local factorA, factorB, edgeType = factorialFactors(record)
	if not factorA then return nil, factorB end
	local cells = factorial.cells
	if record.kind == "passive_support_factorial_interaction" then
		local valid, contextError = validatePassiveSupportCellContext(record, expected)
		if not valid then return nil, contextError end
	elseif record.kind == "skill_support_factorial_interaction" then
		local valid, contextError = validateSkillSupportCellContext(record, expected)
		if not valid then return nil, contextError end
	elseif record.kind == "skill_skill_factorial_interaction" then
		local valid, contextError = validateSkillSkillCellContext(record, expected)
		if not valid then return nil, contextError end
	elseif record.kind == "skill_item_slot_factorial_interaction" then
		local valid, contextError = validateSkillItemCellContext(record, expected)
		if not valid then return nil, contextError end
		local experimentA, experimentB = experiment.factorA, experiment.factorB
		local expected = {
			baseline = { skill = experimentA.before.gemId, effect = experimentA.sourceEffectId, item = experimentB.before.itemId },
			factorA = { skill = experimentA.after.gemId, effect = experimentA.effectId, item = experimentB.before.itemId },
			factorB = { skill = experimentA.before.gemId, effect = experimentA.sourceEffectId, item = experimentB.after.itemId },
			combined = { skill = experimentA.after.gemId, effect = experimentA.effectId, item = experimentB.after.itemId },
		}
		for name, identity in pairs(expected) do
			local selected, selectedItem = cells[name].selectedSkill, cells[name].selectedItem
			if type(selected) ~= "table" or tostring(selected.gemId) ~= tostring(identity.skill)
				or tostring(selected.effectId) ~= tostring(identity.effect)
				or type(selectedItem) ~= "table" or selectedItem.slot ~= experimentB.slot
				or tonumber(selectedItem.itemId) ~= tonumber(identity.item) then
				return nil, "skill_item_cell_identity_mismatch_" .. name
			end
		end
	elseif record.kind == "passive_item_slot_factorial_interaction" then
		local valid, contextError = validatePassiveItemCellContext(record, expected)
		if not valid then return nil, contextError end
		if experiment.socketStatus ~= "native_linked_group" then return nil, "passive_item_socket_link_context_invalid" end
	end
	if experiment.factorA and experiment.factorB then
		-- The type-specific parser above validates identifiers; this second check
		-- prevents the record from claiming a different set of factorial cells.
		if experiment.factorialSchemaVersion ~= 1 then return nil, "factorial_context_version_mismatch" end
	end
	return {
		edgeId = tostring(record.recordId or ""),
		edgeType = edgeType,
		nodeA = factorA,
		nodeB = factorB,
		metrics = recomputed.metrics,
		metricKeys = recomputed.metricKeys,
		metricCount = recomputed.metricCount,
		source = {
			recordId = tostring(record.recordId or ""),
			kind = record.kind,
			recordedAt = record.recordedAt,
			dataVersion = record.engine.dataVersion,
			treeVersion = record.engine.treeVersion,
			pobVersion = record.engine.pobVersion,
			pobBranch = record.engine.pobBranch,
			manifestFingerprint = record.engine.manifestFingerprint,
			buildSignature = record.source and record.source.buildSignature or nil,
			scenarioSignature = record.source and record.source.scenarioSignature or nil,
			class = buildState.class.class,
			mainSkill = buildState.mainSkill,
			scenario = {
				activeConfigSetId = buildState.configuration.activeConfigSetId,
				title = buildState.configuration.title,
				configuredValueCount = (function()
					local count = 0
					for _ in pairs(buildState.configuration.values) do count = count + 1 end
					return count
				end)(),
			},
			socketStatus = experiment.socketStatus,
		},
		trainingEligible = false,
		rankingEligible = false,
		sourceLabel = "exact_pob_four_cell",
	}
end

local function skillContext(record)
	local buildState = record.buildState or { }
	local class = buildState.class or { }
	local source = record.source or { }
	if source.buildSignatureAlgorithm ~= "sha256" or tonumber(source.buildSignatureVersion) ~= 1
		or not StudyContext.IsFingerprint(source.buildSignature) then
		return nil, "source_build_signature_missing"
	end
	if not StudyContext.IsFingerprint(source.scenarioSignature) then return nil, "scenario_signature_missing" end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(buildState.configuration)
	if not scenarioSignature then return nil, "scenario_context_invalid: " .. tostring(scenarioError) end
	if scenarioSignature ~= source.scenarioSignature then return nil, "scenario_signature_mismatch" end
	local className = class.class
	local ascendancy = class.ascendancy
	local level = tonumber(buildState.characterLevel)
	if type(className) ~= "string" or className == "" or type(ascendancy) ~= "string" or ascendancy == ""
		or not finite(level) or level < 1 or level > 100 or level ~= math.floor(level)
		or type(buildState.mainSkill) ~= "string" or buildState.mainSkill == "" then
		return nil, "aggregation_build_context_incomplete"
	end
	return {
		engine = {
			pobVersion = record.engine.pobVersion,
			pobBranch = record.engine.pobBranch,
			dataVersion = record.engine.dataVersion,
			treeVersion = record.engine.treeVersion,
			manifestFingerprint = record.engine.manifestFingerprint,
		},
		scenarioSignature = scenarioSignature,
		classId = tonumber(class.classId),
		class = className,
		ascendancyId = tonumber(class.ascendancyId),
		ascendancy = ascendancy,
		characterLevel = level,
		mainSkill = buildState.mainSkill,
	}
end

local function sortedSupportContext(record)
	local factorA, factorB = record.experiment.factorA, record.experiment.factorB
	local changed = { [factorB.before.gemId] = true, [factorB.after.gemId] = true }
	local expected, expectedKey
	for _, cellName in ipairs(FACTOR_CELLS) do
		local selected = record.factorial.cells[cellName].selectedSkill
		if type(selected) ~= "table" or not validStringArray(selected.supportGemIds) then
			return nil, "skill_support_package_context_missing"
		end
		local remaining = { }
		local removed = false
		for _, gemId in ipairs(selected.supportGemIds) do
			if changed[gemId] and not removed then
				removed = true
			else
				remaining[#remaining + 1] = gemId
			end
		end
		table.sort(remaining)
		local key, keyError = StudyContext.Fingerprint(remaining, "pob_synergy_support_package_v1")
		if not key then return nil, keyError end
		if expectedKey and expectedKey ~= key then return nil, "skill_support_package_context_mismatch" end
		expected, expectedKey = remaining, key
	end
	return expected
end

local function sortedPassiveSupportContext(record)
	local factorB = record.experiment.factorB
	local changed = { [factorB.before.gemId] = true, [factorB.after.gemId] = true }
	local expected, expectedKey
	for _, cellName in ipairs(FACTOR_CELLS) do
		local selected = record.factorial.cells[cellName].selectedSkill
		if type(selected) ~= "table" or not validStringArray(selected.supportGemIds) then
			return nil, "passive_support_package_context_missing"
		end
		local remaining, removed = { }, false
		for _, gemId in ipairs(selected.supportGemIds) do
			if changed[gemId] and not removed then removed = true
			else remaining[#remaining + 1] = gemId end
		end
		if not removed then return nil, "passive_support_factor_not_applied" end
		table.sort(remaining)
		local key, keyError = StudyContext.Fingerprint(remaining, "pob_synergy_support_package_v1")
		if not key then return nil, keyError end
		if expectedKey and expectedKey ~= key then return nil, "passive_support_package_context_mismatch" end
		expected, expectedKey = remaining, key
	end
	return expected
end

local function aggregationDescriptor(record, edge)
	local context, contextError = skillContext(record)
	if not context then return nil, contextError end
	local factorA, factorB = record.experiment.factorA, record.experiment.factorB
	local relation
	if edge.edgeType == "passive_node_x_passive_node" then
		relation = { factorA = edge.nodeA, factorB = edge.nodeB }
	elseif edge.edgeType == "passive_node_x_support_gem" then
		local supportPackage, supportError = sortedPassiveSupportContext(record)
		if not supportPackage then return nil, supportError end
		local selected = record.factorial.cells.baseline.selectedSkill
		relation = {
			factorA = edge.nodeA, factorB = edge.nodeB,
			factorBLevel = tonumber(factorB.before.level), factorBQuality = tonumber(factorB.before.quality),
			skillGroupIndex = tonumber(factorB.groupIndex), skillGemIndex = tonumber(factorB.skillGemIndex),
			skillGemId = selected.gemId, skillEffectId = selected.effectId,
			skillLevel = tonumber(selected.level), skillQuality = tonumber(selected.quality),
			supportGemIndex = tonumber(factorB.gemIndex), unchangedSupportGemIds = supportPackage,
			socketStatus = record.experiment.socketStatus,
		}
	elseif edge.edgeType == "main_skill_gem_x_support_gem" then
		local supportPackage, supportError = sortedSupportContext(record)
		if not supportPackage then return nil, supportError end
		relation = {
			factorA = edge.nodeA,
			factorALevel = tonumber(factorA.before.level),
			factorAQuality = tonumber(factorA.before.quality),
			factorB = edge.nodeB,
			factorBLevel = tonumber(factorB.before.level),
			factorBQuality = tonumber(factorB.before.quality),
			skillGroupIndex = tonumber(factorA.groupIndex),
		skillGemIndex = tonumber(factorA.gemIndex),
		supportGroupIndex = tonumber(factorB.groupIndex),
		supportGemIndex = tonumber(factorB.gemIndex),
			unchangedSupportGemIds = supportPackage,
		}
	elseif edge.edgeType == "active_skill_gem_x_active_skill_gem" then
		relation = {
			factorA = { id = edge.nodeA.id, groupIndex = edge.nodeA.groupIndex, gemIndex = edge.nodeA.gemIndex,
				level = tonumber(factorA.before.level), quality = tonumber(factorA.before.quality),
				socketedSupportGemIds = factorA.socketedSupportGemIds },
			factorB = { id = edge.nodeB.id, groupIndex = edge.nodeB.groupIndex, gemIndex = edge.nodeB.gemIndex,
				level = tonumber(factorB.before.level), quality = tonumber(factorB.before.quality),
				socketedSupportGemIds = factorB.socketedSupportGemIds },
			socketStatus = record.experiment.socketStatus,
		}
	elseif edge.edgeType == "main_skill_gem_x_item_slot" then
		local beforeText = factorB.before.poBItemText or ""
		local afterText = factorB.after.poBItemText or ""
		local beforeFingerprint, beforeError = StudyContext.Fingerprint(beforeText, "pob_synergy_item_snapshot_v1")
		if not beforeFingerprint then return nil, beforeError end
		local afterFingerprint, afterError = StudyContext.Fingerprint(afterText, "pob_synergy_item_snapshot_v1")
		if not afterFingerprint then return nil, afterError end
		relation = {
			factorA = edge.nodeA,
			factorALevel = tonumber(factorA.before.level),
			factorAQuality = tonumber(factorA.before.quality),
			factorB = { type = "item_slot", slot = factorB.slot,
				fromItemFingerprint = beforeFingerprint, toItemFingerprint = afterFingerprint },
			skillGroupIndex = tonumber(factorA.groupIndex),
			skillGemIndex = tonumber(factorA.gemIndex),
			socketedSupportGemIds = factorA.socketedSupportGemIds,
		}
	elseif edge.edgeType == "passive_node_x_item_slot" then
		local beforeText = factorB.before.poBItemText or ""
		local afterText = factorB.after.poBItemText or ""
		local beforeFingerprint, beforeError = StudyContext.Fingerprint(beforeText, "pob_synergy_item_snapshot_v1")
		if not beforeFingerprint then return nil, beforeError end
		local afterFingerprint, afterError = StudyContext.Fingerprint(afterText, "pob_synergy_item_snapshot_v1")
		if not afterFingerprint then return nil, afterError end
		relation = {
			factorA = edge.nodeA,
			factorB = { type = "item_slot", slot = factorB.slot,
				fromItemFingerprint = beforeFingerprint, toItemFingerprint = afterFingerprint },
			skillGroupIndex = tonumber(record.factorial.cells.baseline.selectedSkill.groupIndex),
			skillGemIndex = tonumber(record.factorial.cells.baseline.selectedSkill.gemIndex),
			skillGemId = record.factorial.cells.baseline.selectedSkill.gemId,
			skillEffectId = record.factorial.cells.baseline.selectedSkill.effectId,
			socketedSupportGemIds = record.factorial.cells.baseline.selectedSkill.socketedSupportGemIds,
		}
	else
		return nil, "unsupported_aggregation_relation"
	end
	local key, keyError = StudyContext.Fingerprint({ context = context, relation = relation }, "pob_synergy_relation_context_v1")
	if not key then return nil, keyError end
	return { key = key, context = context, relation = relation }
end

local function interactionSummaries(groups)
	local summaries = { }
	for _, group in pairs(groups) do
		local signatures, signatureCount = { }, 0
		for signature in pairs(group.sources) do
			signatureCount = signatureCount + 1
			signatures[#signatures + 1] = signature
		end
		table.sort(signatures)
		local metricKeys = { }
		for metric in pairs(group.metricSources) do metricKeys[#metricKeys + 1] = metric end
		table.sort(metricKeys)
		local metrics, anyHeterogeneous, totalConflicts = { }, false, 0
		for _, metric in ipairs(metricKeys) do
			local values, conflictCount = { }, 0
			for _, signature in ipairs(signatures) do
				local sourceMetric = group.metricSources[metric][signature]
				if sourceMetric then
					if sourceMetric.conflict then
						conflictCount = conflictCount + 1
					else
						values[#values + 1] = sourceMetric.value
					end
				end
			end
			table.sort(values)
			local positive, negative, zero = 0, 0, 0
			local sum = 0
			for _, value in ipairs(values) do
				sum = sum + value
				if value > 0 then positive = positive + 1
				elseif value < 0 then negative = negative + 1
				else zero = zero + 1 end
			end
			local signKinds = (positive > 0 and 1 or 0) + (negative > 0 and 1 or 0) + (zero > 0 and 1 or 0)
			local status
			if conflictCount > 0 then status = "within_source_conflict"
			elseif #values < 2 then status = "single_source_build"
			elseif positive == 0 and negative == 0 then status = "all_zero_across_distinct_build_signatures"
			elseif signKinds == 1 then status = "same_sign_across_distinct_build_signatures"
			else status = "heterogeneous_across_distinct_build_signatures" end
			if status == "heterogeneous_across_distinct_build_signatures" then anyHeterogeneous = true end
			totalConflicts = totalConflicts + conflictCount
			metrics[#metrics + 1] = {
				metric = metric,
				sampleCount = #values,
				distinctSourceBuildCount = #values,
				positiveSourceCount = positive,
				negativeSourceCount = negative,
				zeroSourceCount = zero,
				minimum = #values > 0 and values[1] or nil,
				maximum = #values > 0 and values[#values] or nil,
				mean = #values > 0 and (sum / #values) or nil,
				withinSourceConflictCount = conflictCount,
				status = status,
			}
		end
		local status = signatureCount < 2 and totalConflicts == 0 and "single_source_build"
			or totalConflicts > 0 and "within_source_conflict"
			or anyHeterogeneous and "heterogeneous_across_distinct_build_signatures"
			or "consistent_across_distinct_build_signatures"
		summaries[#summaries + 1] = {
			summaryId = group.key,
			edgeType = group.edgeType,
			factorA = group.relation.factorA,
			factorB = group.relation.factorB,
			context = group.context,
			recordCount = group.recordCount,
			distinctSourceBuildCount = signatureCount,
			repeatedSameSourceRecordCount = group.recordCount - signatureCount,
			withinSourceConflictCount = totalConflicts,
			metrics = metrics,
			status = status,
			descriptiveOnly = true,
			independentSamplesConfirmed = false,
			trainingEligible = false,
			rankingEligible = false,
			optimizerInput = false,
		}
	end
	table.sort(summaries, function(left, right) return left.summaryId < right.summaryId end)
	return summaries
end

function graph.Build(records, expectedEngine, limit)
	if type(records) ~= "table" or type(expectedEngine) ~= "table" then return nil, "Study records and current engine identity are required" end
	limit = tonumber(limit) or 25
	if not finite(limit) or limit ~= math.floor(limit) or limit < 1 or limit > 25 then return nil, "limit must be an integer from 1 to 25" end
	local edges, discarded, examined = { }, { }, 0
	local groups, excludedAggregation = { }, { }
	for _, record in ipairs(records) do
		if examined >= limit then break end
		examined = examined + 1
		local edge, reason = validateRecord(record, expectedEngine)
		if edge then
			edges[#edges + 1] = edge
			local descriptor, aggregationError = aggregationDescriptor(record, edge)
			if descriptor then
				local group = groups[descriptor.key]
				if not group then
					group = { key = descriptor.key, edgeType = edge.edgeType, relation = descriptor.relation,
						context = descriptor.context, recordCount = 0, sources = { }, metricSources = { } }
					groups[descriptor.key] = group
				end
				group.recordCount = group.recordCount + 1
				local signature = edge.source.buildSignature
				group.sources[signature] = true
				for metric, value in pairs(edge.metrics) do
					group.metricSources[metric] = group.metricSources[metric] or { }
					local sourceMetric = group.metricSources[metric][signature]
					if not sourceMetric then
						group.metricSources[metric][signature] = { value = value.interaction }
					elseif not near(sourceMetric.value, value.interaction) then
						sourceMetric.conflict = true
					end
				end
			else
				excludedAggregation[aggregationError] = (excludedAggregation[aggregationError] or 0) + 1
			end
		else discarded[#discarded + 1] = { recordId = tostring(record and record.recordId or ""), reason = reason } end
	end
	local summaries = interactionSummaries(groups)
	local excludedCount = 0
	for _, count in pairs(excludedAggregation) do excludedCount = excludedCount + count end
	return {
		status = "report_only_evidence_graph",
		schemaVersion = 1,
		examinedRecords = examined,
		edgeCount = #edges,
		discardedCount = #discarded,
		edges = edges,
		discarded = discarded,
		interactionSummaries = summaries,
		aggregationDiagnostics = {
			eligibleEdgeCount = #edges - excludedCount,
			excludedEdgeCount = excludedCount,
			excludedReasons = excludedAggregation,
			scope = "bounded recent records supplied to this query",
			independentSamplesConfirmed = false,
		},
		trainingEligible = false,
		rankingEligible = false,
		optimizerInput = false,
		exactPobRecalculated = false,
		graphSemantics = "recomputed difference-in-differences from stored exact PoB four-cell results; cross-build summaries are descriptive and do not establish causality",
	}
end

return graph
