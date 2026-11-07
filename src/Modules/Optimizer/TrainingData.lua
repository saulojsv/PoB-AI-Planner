-- Path of Building
--
-- Module: fail-closed preparation and audit for supervised optimizer studies.
-- Exact PoB result pairs are labels; public popularity/provenance is never a
-- model feature. This module prepares a local, build-grouped dataset only after
-- independent scenario, activity, lookup-table, version, and review gates pass.

local json = require("dkjson")
local trainingData = { }

local RECORD_SCHEMA_VERSION = 2
local DATASET_SCHEMA_VERSION = 6
local FEATURE_POLICY = "exact-pair-build-context-lineage-engine-manifest-v6"
local GROUPING_POLICY = "reviewed-source-snapshot-union-v2"
local MAX_ELIGIBLE_ROWS = 10000
local MAX_EXPORT_BYTES = 16777216
local MAX_EXPORT_ROW_BYTES = 65536
local HOLDOUT_FRACTION = 0.2
local ENGINE_IDENTITY_KEYS = { "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function safeText(value, maxLength)
	if type(value) ~= "string" or value == "" or #value > maxLength or value:find("[%c]") then return nil end
	return value
end

local function safeMetricKey(value)
	return type(value) == "string" and #value <= 96 and value:match("^[%w_%.%-]+$") ~= nil
end

local function addReason(reasons, key)
	reasons[key] = (reasons[key] or 0) + 1
end

local function canonicalValue(value, stack)
	if type(value) ~= "table" or value == json.null then
		local encoded, encodeError = json.encode(value)
		if type(encoded) ~= "string" then return nil, encodeError or "Could not encode build group identity" end
		return encoded
	end
	stack = stack or { }
	if stack[value] then return nil, "Build group identity contains a cycle" end
	stack[value] = true
	local count, maxIndex, isArray = 0, 0, true
	for key in pairs(value) do
		count = count + 1
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			isArray = false
		elseif key > maxIndex then
			maxIndex = key
		end
	end
	local parts = { }
	if isArray and maxIndex == count then
		for index = 1, count do
			local encoded, encodeError = canonicalValue(value[index], stack)
			if not encoded then stack[value] = nil return nil, encodeError end
			parts[#parts + 1] = encoded
		end
		stack[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = { }
	for key in pairs(value) do
		if type(key) == "string" then
			keys[#keys + 1] = { kind = "s", value = key }
		elseif isFinite(key) then
			keys[#keys + 1] = { kind = "n", value = key }
		else
			stack[value] = nil
			return nil, "Build group identity has an unsupported object key"
		end
	end
	table.sort(keys, function(left, right)
		if left.kind ~= right.kind then return left.kind < right.kind end
		return left.value < right.value
	end)
	for _, key in ipairs(keys) do
		local normalizedKey = key.kind .. ":" .. (key.kind == "s" and key.value or string.format("%.17g", key.value))
		local encodedKey, keyError = json.encode(normalizedKey)
		local encodedValue, valueError = canonicalValue(value[key.value], stack)
		if type(encodedKey) ~= "string" or not encodedValue then
			stack[value] = nil
			return nil, keyError or valueError or "Could not encode build group identity"
		end
		parts[#parts + 1] = encodedKey .. ":" .. encodedValue
	end
	stack[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

local function groupIdentity(record)
	if type(record.buildState) ~= "table" then return nil, "missing_build_state" end
	local lineage = record.lineage
	if type(lineage) ~= "table" or lineage.schemaVersion ~= 1
		or type(lineage.fingerprint) ~= "string" or #lineage.fingerprint ~= 64
		or not lineage.fingerprint:match("^[%da-f]+$")
		or type(lineage.snapshotFingerprint) ~= "string" or #lineage.snapshotFingerprint ~= 64
		or not lineage.snapshotFingerprint:match("^[%da-f]+$")
		or (lineage.basis ~= "public_source_url" and lineage.basis ~= "exact_build_snapshot") then
		return nil, "source_lineage_or_snapshot_missing"
	end
	local sourceIdentity, sourceError = canonicalValue({
		engine = record.engine,
		sourceLineage = lineage.fingerprint,
	})
	if not sourceIdentity then return nil, sourceError end
	local snapshotIdentity, snapshotError = canonicalValue({
		engine = {
			pobVersion = record.engine.pobVersion,
			pobBranch = record.engine.pobBranch,
			dataVersion = record.engine.dataVersion,
			treeVersion = record.engine.treeVersion,
			manifestFingerprint = record.engine.manifestFingerprint,
		},
		snapshotFingerprint = lineage.snapshotFingerprint,
	})
	if not snapshotIdentity then return nil, snapshotError end
	return sourceIdentity, nil, snapshotIdentity
end

local function certificationFailures(record, expectedEngine, reviewPreview)
	local failures = { }
	if type(record) ~= "table" or record.schemaVersion ~= RECORD_SCHEMA_VERSION then
		return { "unsupported_record_schema" }
	end
	local engine = record.engine
	if type(engine) ~= "table" then
		failures[#failures + 1] = "missing_engine_identity"
	else
		for _, key in ipairs(ENGINE_IDENTITY_KEYS) do
			if not safeText(engine[key], 80) then
				failures[#failures + 1] = "missing_engine_" .. key
			elseif expectedEngine and expectedEngine[key] ~= nil and tostring(engine[key]) ~= tostring(expectedEngine[key]) then
				failures[#failures + 1] = "engine_version_mismatch"
				break
			end
		end
		if type(engine.manifestFingerprint) == "string"
			and (#engine.manifestFingerprint ~= 64 or not engine.manifestFingerprint:match("^[%da-f]+$")) then
			failures[#failures + 1] = "invalid_engine_manifest_fingerprint"
		end
	end
	if type(expectedEngine) ~= "table" then
		failures[#failures + 1] = "current_engine_identity_missing"
	else
		for _, key in ipairs(ENGINE_IDENTITY_KEYS) do
			if not safeText(expectedEngine[key], 80) then
				failures[#failures + 1] = "current_engine_identity_incomplete"
				break
			end
		end
	end
	local lineage = record.lineage
	if type(lineage) ~= "table" or lineage.schemaVersion ~= 1
		or type(lineage.fingerprint) ~= "string" or #lineage.fingerprint ~= 64
		or not lineage.fingerprint:match("^[%da-f]+$")
		or type(lineage.snapshotFingerprint) ~= "string" or #lineage.snapshotFingerprint ~= 64
		or not lineage.snapshotFingerprint:match("^[%da-f]+$")
		or (lineage.basis ~= "public_source_url" and lineage.basis ~= "exact_build_snapshot") then
		failures[#failures + 1] = "source_lineage_or_snapshot_missing"
	end
	if not reviewPreview then
		if record.trainingEligible ~= true then failures[#failures + 1] = "not_admitted" end
		if type(record.quarantine) ~= "table" or record.quarantine.status ~= "approved" then
			failures[#failures + 1] = "quarantine_not_cleared"
		end
		local review = record.certification
		if type(review) ~= "table" or review.reviewStatus ~= "approved"
			or type(review.reviewId) ~= "string" or review.reviewId == ""
			or type(review.reviewedAt) ~= "string" or review.reviewedAt == "" then
			failures[#failures + 1] = "independent_review_missing"
		elseif type(review.attestations) ~= "table" or review.attestations.localTrainingConsent ~= true then
			failures[#failures + 1] = "local_training_consent_missing"
		elseif review.reviewSchemaVersion ~= 3 then
			failures[#failures + 1] = "source_rights_evidence_missing"
		elseif review.attestations.sourceRightsVerified ~= true then
			failures[#failures + 1] = "source_rights_unverified"
		elseif type(review.sourceRights) ~= "table"
			or (review.sourceRights.basis ~= "user_authored" and review.sourceRights.basis ~= "creator_permission" and review.sourceRights.basis ~= "open_license")
			or review.sourceRights.scope ~= "offline_local_model_training"
			or (review.sourceRights.basis == "open_license" and not safeText(review.sourceRights.licenseId, 80)) then
			failures[#failures + 1] = "source_rights_evidence_missing"
		end
	end
	local admission = record.admission
	if type(admission) ~= "table" then
		failures[#failures + 1] = "admission_missing"
	else
		if admission.exactCalculated ~= true then failures[#failures + 1] = "exact_calculation_unverified" end
		if admission.useRequirementsFeasible ~= true then failures[#failures + 1] = "requirements_not_certified" end
		if reviewPreview then
			if admission.activityRatesFeasible ~= true or admission.activityStatus ~= "pass" then
				failures[#failures + 1] = "activity_output_not_feasible"
			end
		else
			if admission.scenarioConditionsCertified ~= true then failures[#failures + 1] = "scenario_not_certified" end
			if admission.activitySustainCertified ~= true or admission.activityRatesFeasible ~= true or admission.activityStatus ~= "pass" then
				failures[#failures + 1] = "activity_not_certified"
			end
			if admission.lookupTablesCertified ~= true then failures[#failures + 1] = "lookup_tables_not_certified" end
		end
	end
	if not reviewPreview and type(engine) == "table" and engine.lookupTableStatus ~= "certified" then
		failures[#failures + 1] = "lookup_table_version_not_certified"
	end
	if type(record.baseline) ~= "table" or type(record.baseline.metrics) ~= "table"
		or type(record.candidate) ~= "table" or type(record.candidate.metrics) ~= "table"
		or type(record.metricDelta) ~= "table" then
		failures[#failures + 1] = "exact_metric_pair_missing"
	else
		local pairedLabels = 0
		for key, delta in pairs(record.metricDelta) do
			local before = record.baseline.metrics[key]
			local after = record.candidate.metrics[key]
			if not safeMetricKey(key) then
				failures[#failures + 1] = "invalid_metric_key"
				break
			end
			if not isFinite(delta) or not isFinite(before) or not isFinite(after) then
				failures[#failures + 1] = "invalid_exact_metric_pair"
				break
			end
			local recomputed = after - before
			local tolerance = math.max(1e-9, math.abs(recomputed) * 1e-12)
			if math.abs(delta - recomputed) > tolerance then
				failures[#failures + 1] = "metric_delta_mismatch"
				break
			end
			pairedLabels = pairedLabels + 1
		end
		if pairedLabels == 0 then failures[#failures + 1] = "no_exact_numeric_labels" end
	end
	if type(record.buildState) ~= "table" or type(record.buildState.class) ~= "table"
		or type(record.buildState.class.class) ~= "string" or type(record.buildState.mainSkill) ~= "string"
		or type(record.buildState.allocatedNodeIds) ~= "table" or #record.buildState.allocatedNodeIds > 4096 then
		failures[#failures + 1] = "build_context_incomplete"
	else
		local seen = { }
		for index, nodeId in ipairs(record.buildState.allocatedNodeIds) do
			if not isFinite(nodeId) or nodeId < 1 or nodeId ~= math.floor(nodeId) or nodeId > 2147483647 or seen[nodeId] then
				failures[#failures + 1] = "build_tree_features_invalid"
				break
			end
			seen[nodeId] = true
			if index > 4096 then failures[#failures + 1] = "build_tree_features_invalid" break end
		end
	end
	if type(record.buildState) == "table" then
		local configuration = record.buildState.configuration
		if type(configuration) ~= "table" or type(configuration.values) ~= "table" then
			failures[#failures + 1] = "scenario_context_missing"
		end
	end
	local experimentUnits = {
		passive_node_pair = "one_passive_node",
		gem_variant_pair = "one_gem_parameter",
		item_slot_pair = "one_item_slot",
		mastery_effect_pair = "one_mastery_effect",
	}
	-- Factorial interaction rows have a different target (difference-in-differences)
	-- and feature contract from one-factor deltas. Keep them quarantined until a
	-- separately versioned dataset schema and grouped holdout policy are designed.
	if record.kind == "passive_factorial_interaction" or record.kind == "skill_support_factorial_interaction"
		or record.kind == "skill_skill_factorial_interaction"
		or record.kind == "passive_support_factorial_interaction"
		or record.kind == "skill_item_slot_factorial_interaction"
		or record.kind == "passive_item_slot_factorial_interaction" then
		failures[#failures + 1] = "factorial_training_schema_unsupported"
	end
	if type(record.experiment) ~= "table" or experimentUnits[record.kind] ~= record.experiment.unit then
		failures[#failures + 1] = "experiment_context_incomplete"
	end
	if record.kind == "mastery_effect_pair" and type(record.experiment) == "table" then
		local experiment = record.experiment
		local nodeId = tonumber(experiment.masteryNodeId)
		local beforeEffect = tonumber(type(experiment.before) == "table" and experiment.before.effectId)
		local afterEffect = tonumber(type(experiment.after) == "table" and experiment.after.effectId)
		local nodeAllocated = false
		for _, allocatedId in ipairs(type(record.buildState) == "table" and record.buildState.allocatedNodeIds or { }) do
			if tonumber(allocatedId) == nodeId then nodeAllocated = true break end
		end
		local selectedEffect = type(record.buildState) == "table" and type(record.buildState.masterySelections) == "table"
			and tonumber(record.buildState.masterySelections[nodeId] or record.buildState.masterySelections[tostring(nodeId)]) or nil
		if not isFinite(nodeId) or nodeId < 1 or nodeId ~= math.floor(nodeId) or nodeId > 2147483647
			or not isFinite(beforeEffect) or beforeEffect < 1 or beforeEffect ~= math.floor(beforeEffect) or beforeEffect > 2147483647
			or not isFinite(afterEffect) or afterEffect < 1 or afterEffect ~= math.floor(afterEffect) or afterEffect > 2147483647
			or beforeEffect == afterEffect or not nodeAllocated or selectedEffect ~= beforeEffect then
			failures[#failures + 1] = "invalid_mastery_effect_pair"
		end
	end
	if type(record.baseline) == "table" and type(record.candidate) == "table" then
		if type(record.baseline.requirements) ~= "table" or record.baseline.requirements.feasible ~= true
			or type(record.candidate.requirements) ~= "table" or record.candidate.requirements.feasible ~= true then
			failures[#failures + 1] = "exact_requirements_not_feasible"
		end
		if type(record.baseline.activitySustain) ~= "table" or record.baseline.activitySustain.status ~= "pass"
			or type(record.candidate.activitySustain) ~= "table" or record.candidate.activitySustain.status ~= "pass" then
			failures[#failures + 1] = "exact_activity_outputs_not_certified"
		end
	end
	return failures
end

function trainingData.AssessReview(record, expectedEngine)
	local failures = certificationFailures(record, expectedEngine, true)
	return {
		status = #failures == 0 and "ready_for_human_review" or "blocked",
		canApprove = #failures == 0,
		blockers = failures,
		requiredAttestations = {
			"exactPair",
			"scenario",
			"activity",
			"lookupTables",
			"localTrainingConsent",
			"sourceRightsVerified",
		},
	}
end

local function copyScalarFields(source, allowed)
	local result = { }
	if type(source) ~= "table" then return result end
	for _, key in ipairs(allowed) do
		local value = source[key]
		if type(value) == "string" then
			local safeValue = safeText(value, key == "gemId" and 160 or 96)
			if safeValue and safeValue:match("^[%w _%-%./]+$") then result[key] = safeValue end
		elseif type(value) == "boolean" or isFinite(value) then
			result[key] = value
		end
	end
	return result
end

local function copyNodeIds(values)
	if type(values) ~= "table" or #values > 4096 then return { } end
	local result = { }
	for index, nodeId in ipairs(values) do
		if not isFinite(nodeId) or nodeId < 1 or nodeId ~= math.floor(nodeId) or nodeId > 2147483647 then return { } end
		result[index] = nodeId
	end
	table.sort(result)
	return result
end

local function copyMasteries(values)
	local result = { }
	if type(values) ~= "table" then return result end
	for nodeId, effectId in pairs(values) do
		local numericNodeId, numericEffectId = tonumber(nodeId), tonumber(effectId)
		if isFinite(numericNodeId) and numericNodeId > 0 and numericNodeId == math.floor(numericNodeId)
			and isFinite(numericEffectId) and numericEffectId > 0 and numericEffectId == math.floor(numericEffectId) then
			result[#result + 1] = { nodeId = numericNodeId, effectId = numericEffectId }
		end
	end
	table.sort(result, function(left, right) return left.nodeId < right.nodeId end)
	return result
end

local function copySkillGroups(groups)
	local result = { }
	if type(groups) ~= "table" then return result end
	for groupIndex, group in ipairs(groups) do
		if groupIndex > 48 then break end
		if type(group) == "table" then
			local groupFeature = {
				groupIndex = group.groupIndex or groupIndex,
				slot = safeText(group.slot, 64),
				enabled = group.enabled == true,
				slotEnabled = group.slotEnabled == true,
				includeInFullDPS = group.includeInFullDPS == true,
				selectedMainGroup = group.selectedMainGroup == true,
				mainActiveSkill = safeText(group.mainActiveSkill, 128),
				supportProfileVersion = group.supportProfileVersion == 2 and 2 or group.supportProfileVersion == 1 and 1 or nil,
				socketValidation = type(group.socketValidation) == "table" and {
					valid = group.socketValidation.valid == true,
					status = safeText(group.socketValidation.status, 32),
				} or nil,
				gems = { },
				skills = { },
			}
			for gemIndex, gem in ipairs(group.gems or { }) do
				if gemIndex > 12 then break end
				if type(gem) == "table" then
					groupFeature.gems[#groupFeature.gems + 1] = {
						gemId = safeText(gem.gemId, 160),
						gameId = safeText(gem.gameId, 200),
						variantId = safeText(gem.variantId, 200),
						skillId = safeText(gem.skillId, 160),
						level = isFinite(gem.level) and gem.level or nil,
						quality = isFinite(gem.quality) and gem.quality or nil,
						enabled = gem.enabled == true,
						count = isFinite(gem.count) and gem.count or nil,
						isSupport = gem.isSupport == true,
						socketMatched = gem.socketMatched == true,
					}
				end
			end
			for skillIndex, skill in ipairs(group.skills or { }) do
				if skillIndex > 12 then break end
				if type(skill) == "table" then
					local skillFeature = {
						skillIndex = isFinite(skill.skillIndex) and skill.skillIndex or skillIndex,
						name = safeText(skill.name, 120),
						selectedMainSkill = skill.selectedMainSkill == true,
						supportProfileVersion = skill.supportProfileVersion == 2 and 2 or skill.supportProfileVersion == 1 and 1 or nil,
						effects = { },
						supports = { },
					}
					for effectIndex, effect in ipairs(skill.effects or { }) do
						if effectIndex > 16 then break end
						if type(effect) == "table" then
							skillFeature.effects[#skillFeature.effects + 1] = {
								effectId = safeText(effect.effectId, 180),
								selected = effect.selected == true,
							}
						end
					end
					for supportIndex, support in ipairs(skill.supports or { }) do
						if supportIndex > 64 then break end
						if type(support) == "table" then
							local fingerprint = safeText(support.sourceItemFingerprint, 64)
							if fingerprint and (#fingerprint ~= 64 or not fingerprint:match("^[%da-fA-F]+$")) then fingerprint = nil end
							skillFeature.supports[#skillFeature.supports + 1] = {
								gemId = safeText(support.gemId, 160),
								gameId = safeText(support.gameId, 200),
								variantId = safeText(support.variantId, 200),
								skillId = safeText(support.skillId, 180),
								effectId = safeText(support.effectId, 180),
								name = safeText(support.name, 120),
								level = isFinite(support.level) and support.level or nil,
								quality = isFinite(support.quality) and support.quality or nil,
								origin = safeText(support.origin, 32),
								sourceSlot = safeText(support.sourceSlot, 64),
								sourceItemFingerprint = fingerprint,
								targetGroupIndex = isFinite(support.targetGroupIndex) and support.targetGroupIndex or nil,
								targetSkillIndex = isFinite(support.targetSkillIndex) and support.targetSkillIndex or nil,
								targetEffectId = safeText(support.targetEffectId, 180),
								active = support.active == true,
								configured = support.configured == true,
								calculatorApplied = support.calculatorApplied == true,
								socketMatched = support.socketMatched == true,
								socketState = safeText(support.socketState, 32),
								linkState = safeText(support.linkState, 32),
								groupState = safeText(support.groupState, 32),
								playableActive = support.playableActive == true,
								supportProfileVersion = support.supportProfileVersion == 2 and 2 or support.supportProfileVersion == 1 and 1 or nil,
							}
						end
					end
					groupFeature.skills[#groupFeature.skills + 1] = skillFeature
				end
			end
			result[#result + 1] = groupFeature
		end
	end
	return result
end

local function copyEquippedItemSlots(buildState)
	local result, itemRows = { }, type(buildState and buildState.items) == "table" and buildState.items or { }
	for _, equipped in ipairs(type(buildState and buildState.equippedSlots) == "table" and buildState.equippedSlots or { }) do
		local slot = safeText(equipped.slot, 64)
		local itemId = tonumber(equipped.itemId)
		local item = itemId and (itemRows[itemId] or itemRows[tostring(itemId)])
		if slot and type(item) == "table" then
			local base = safeText(item.base, 96)
			local rarity = safeText(tostring(item.rarity or ""), 32)
			local fingerprint = safeText(item.itemFingerprint, 64)
			if fingerprint and (#fingerprint ~= 64 or not fingerprint:match("^[%da-fA-F]+$")) then fingerprint = nil end
			if base or rarity or fingerprint then result[#result + 1] = { slot = slot, base = base, rarity = rarity, itemFingerprint = fingerprint } end
		end
	end
	table.sort(result, function(left, right)
		if left.slot ~= right.slot then return left.slot < right.slot end
		if tostring(left.base or "") ~= tostring(right.base or "") then return tostring(left.base or "") < tostring(right.base or "") end
		return tostring(left.rarity or "") < tostring(right.rarity or "")
	end)
	return result
end

local function buildFeatures(record)
	local buildState = record.buildState
	local experiment = record.experiment or { }
	local features = {
		class = safeText(buildState.class.class, 32),
		classId = buildState.class.classId,
		ascendancy = safeText(buildState.class.ascendancy, 64),
		ascendancyId = buildState.class.ascendancyId,
		characterLevel = isFinite(buildState.characterLevel) and buildState.characterLevel or nil,
		mainSkill = safeText(buildState.mainSkill, 128),
		supportFeatureSchemaVersion = buildState.supportFeatureSchemaVersion == 2 and 2 or buildState.supportFeatureSchemaVersion == 1 and 1 or nil,
		allocatedNodeIds = copyNodeIds(buildState.allocatedNodeIds),
		masterySelections = copyMasteries(buildState.masterySelections),
		skillGroups = copySkillGroups(buildState.skillGroups),
		itemSlots = copyEquippedItemSlots(buildState),
		kind = safeText(record.kind, 32),
		experiment = {
			unit = safeText(experiment.unit, 32),
			slot = safeText(experiment.slot, 64),
			changedParameter = safeText(experiment.changedParameter, 32),
			masteryNodeId = isFinite(experiment.masteryNodeId) and experiment.masteryNodeId or nil,
			before = copyScalarFields(experiment.before, { "gemId", "level", "quality", "itemId", "base", "rarity", "effectId" }),
			after = copyScalarFields(experiment.after, { "gemId", "level", "quality", "itemId", "base", "rarity", "effectId" }),
		},
		baselineMetrics = { },
	}
	local baselineMetrics = record.baseline.metrics
	for key, value in pairs(baselineMetrics) do
		if safeMetricKey(key) and isFinite(value) and isFinite(record.candidate.metrics[key]) and isFinite(record.metricDelta[key]) then
			features.baselineMetrics[key] = value
		end
	end
	if type(experiment.addedNodeIds) == "table" then features.experiment.addedNodeIds = copyNodeIds(experiment.addedNodeIds) end
	if type(experiment.removedNodeIds) == "table" then features.experiment.removedNodeIds = copyNodeIds(experiment.removedNodeIds) end
	-- Deliberately exclude source URL, provider, import rank, labels, and all
	-- public popularity/meta signals. No raw item text or free-form notes enter.
	return features
end

local function exactLabels(record)
	local labels = { }
	for key, delta in pairs(record.metricDelta or { }) do
		local before, after = record.baseline.metrics[key], record.candidate.metrics[key]
		if safeMetricKey(key) and isFinite(delta) and isFinite(before) and isFinite(after) then labels[key] = delta end
	end
	return labels
end

local function stableOrderKey(value)
	local hash = 5381
	for index = 1, #value do hash = (hash * 33 + value:byte(index)) % 4294967296 end
	return string.format("%08x", hash)
end

function trainingData.Prepare(records, expectedEngine)
	records = type(records) == "table" and records or { }
	local eligibleRows, excludedReasons = { }, { }
	local parent, rank, identityOwners = { }, { }, { }
	local totalRecords, admittedRecords = 0, 0
	local function find(index)
		if parent[index] ~= index then parent[index] = find(parent[index]) end
		return parent[index]
	end
	local function union(left, right)
		local leftRoot, rightRoot = find(left), find(right)
		if leftRoot == rightRoot then return end
		if rank[leftRoot] < rank[rightRoot] then
			parent[leftRoot] = rightRoot
		elseif rank[leftRoot] > rank[rightRoot] then
			parent[rightRoot] = leftRoot
		else
			parent[rightRoot] = leftRoot
			rank[leftRoot] = rank[leftRoot] + 1
		end
	end
	for _, record in ipairs(records) do
		totalRecords = totalRecords + 1
		local failures = certificationFailures(record, expectedEngine)
		if #failures > 0 then
			local uniqueFailures = { }
			for _, reason in ipairs(failures) do
				if not uniqueFailures[reason] then addReason(excludedReasons, reason) uniqueFailures[reason] = true end
			end
		else
			admittedRecords = admittedRecords + 1
			if #eligibleRows >= MAX_ELIGIBLE_ROWS then
				addReason(excludedReasons, "dataset_row_limit")
			else
				local sourceIdentity, identityError, snapshotIdentity = groupIdentity(record)
				if not sourceIdentity then
					addReason(excludedReasons, identityError or "invalid_build_group")
				else
					local row = {
						recordId = record.recordId,
						sourceIdentity = sourceIdentity,
						snapshotIdentity = snapshotIdentity,
						features = buildFeatures(record),
						labels = exactLabels(record),
						engine = {
							pobVersion = record.engine.pobVersion,
							pobBranch = record.engine.pobBranch,
							dataVersion = record.engine.dataVersion,
							treeVersion = record.engine.treeVersion,
							manifestFingerprint = record.engine.manifestFingerprint,
							lookupTableStatus = record.engine.lookupTableStatus,
						},
					}
					eligibleRows[#eligibleRows + 1] = row
					local rowIndex = #eligibleRows
					parent[rowIndex], rank[rowIndex] = rowIndex, 0
					for _, identity in ipairs({ sourceIdentity, snapshotIdentity }) do
						local owner = identityOwners[identity]
						if owner then union(rowIndex, owner) else identityOwners[identity] = rowIndex end
					end
				end
			end
		end
	end

	local clusters, groupKeys, clusterIdentityByRoot = { }, { }, { }
	for index, row in ipairs(eligibleRows) do
		local root = find(index)
		local cluster = clusters[root]
		if not cluster then
			cluster = { identity = row.sourceIdentity, members = { } }
			clusters[root] = cluster
		end
		if row.snapshotIdentity < cluster.identity then cluster.identity = row.snapshotIdentity end
		cluster.members[#cluster.members + 1] = row
	end
	for root, cluster in pairs(clusters) do
		groupKeys[#groupKeys + 1] = cluster.identity
		clusterIdentityByRoot[root] = cluster.identity
	end
	table.sort(groupKeys, function(left, right)
		local leftHash, rightHash = stableOrderKey(left), stableOrderKey(right)
		if leftHash ~= rightHash then return leftHash < rightHash end
		return left < right
	end)
	local holdoutGroupCount = #groupKeys >= 2 and math.max(1, math.floor(#groupKeys * HOLDOUT_FRACTION)) or 0
	if holdoutGroupCount >= #groupKeys then holdoutGroupCount = #groupKeys - 1 end
	local holdoutKeys = { }
	for index = 1, holdoutGroupCount do holdoutKeys[groupKeys[index]] = true end
	local trainRows, holdoutRows = { }, { }
	local sourceGroupIds = { }
	for index, key in ipairs(groupKeys) do sourceGroupIds[key] = "source-" .. tostring(index) end
	for index, row in ipairs(eligibleRows) do
		local identity = clusterIdentityByRoot[find(index)]
		row.sourceGroupId = sourceGroupIds[identity]
		row.sourceIdentity = nil
		row.snapshotIdentity = nil -- private full lineage and snapshot keys never leave this module
		if #groupKeys >= 2 then
			if holdoutKeys[identity] then
				holdoutRows[#holdoutRows + 1] = row
			else
				trainRows[#trainRows + 1] = row
			end
		end
	end
	local status
	if #eligibleRows == 0 then
		status = "blocked_no_certified_records"
	elseif #groupKeys < 2 then
		status = "blocked_source_lineage_holdout"
	else
		status = "dataset_ready_for_offline_evaluation"
	end
	return {
		datasetSchemaVersion = DATASET_SCHEMA_VERSION,
		featurePolicy = FEATURE_POLICY,
		groupingPolicy = GROUPING_POLICY,
		status = status,
		totalRecords = totalRecords,
		admittedRecords = admittedRecords,
		eligibleRows = #eligibleRows,
		sourceLineages = #groupKeys,
		trainingSourceLineages = #groupKeys - holdoutGroupCount,
		holdoutSourceLineages = holdoutGroupCount,
		trainingRows = #trainRows,
		holdoutRows = #holdoutRows,
		excludedReasons = excludedReasons,
		popularityFeaturesExcluded = true,
		modelTrainingEnabled = false,
		qualityGate = { minimumSpearman = 0.80, minimumTopParetoRecall = 0.90 },
		rows = eligibleRows,
		training = trainRows,
		holdout = holdoutRows,
	}
end

function trainingData.Summary(dataset)
	if type(dataset) ~= "table" then return nil end
	return {
		datasetSchemaVersion = dataset.datasetSchemaVersion,
		featurePolicy = dataset.featurePolicy,
		groupingPolicy = dataset.groupingPolicy,
		status = dataset.status,
		totalRecords = dataset.totalRecords,
		admittedRecords = dataset.admittedRecords,
		eligibleRows = dataset.eligibleRows,
		sourceLineages = dataset.sourceLineages,
		trainingSourceLineages = dataset.trainingSourceLineages,
		holdoutSourceLineages = dataset.holdoutSourceLineages,
		trainingRows = dataset.trainingRows,
		holdoutRows = dataset.holdoutRows,
		excludedReasons = dataset.excludedReasons,
		popularityFeaturesExcluded = dataset.popularityFeaturesExcluded,
		modelTrainingEnabled = dataset.modelTrainingEnabled,
		qualityGate = dataset.qualityGate,
	}
end

function trainingData.EncodeJsonl(dataset)
	if type(dataset) ~= "table" or dataset.status ~= "dataset_ready_for_offline_evaluation"
		or type(dataset.training) ~= "table" or type(dataset.holdout) ~= "table"
		or #dataset.training == 0 or #dataset.holdout == 0 then
		return nil, "No dataset exported: at least two consented origin/snapshot groups and non-empty train/holdout partitions are required"
	end
	local firstRow = dataset.rows and dataset.rows[1]
	if type(firstRow) ~= "table" or type(firstRow.engine) ~= "table" then
		return nil, "No dataset exported: the prepared dataset has no versioned engine identity"
	end
	local lines, byteCount = { }, 0
	local function appendLine(value)
		local encoded, encodeError = json.encode(value)
		if type(encoded) ~= "string" then return nil, encodeError or "Could not encode the sanitized dataset row" end
		if #encoded > MAX_EXPORT_ROW_BYTES then return nil, "No dataset exported: a sanitized row exceeds the 64 KiB row limit" end
		byteCount = byteCount + #encoded + 1
		if byteCount > MAX_EXPORT_BYTES then return nil, "No dataset exported: the sanitized corpus exceeds the 16 MiB export limit" end
		lines[#lines + 1] = encoded
		return true
	end
	local headerOk, headerError = appendLine({
		recordType = "dataset_header",
		format = "pob-optimizer-supervised-pairs",
		datasetSchemaVersion = DATASET_SCHEMA_VERSION,
		featurePolicy = FEATURE_POLICY,
		groupingPolicy = GROUPING_POLICY,
		engine = firstRow.engine,
		sourceLineages = dataset.sourceLineages,
		trainingSourceLineages = dataset.trainingSourceLineages,
		holdoutSourceLineages = dataset.holdoutSourceLineages,
		trainingRows = #dataset.training,
		holdoutRows = #dataset.holdout,
		popularityFeaturesExcluded = true,
		modelTrainingEnabled = false,
		qualityGate = dataset.qualityGate,
	})
	if not headerOk then return nil, headerError end
	for _, split in ipairs({ { name = "train", rows = dataset.training }, { name = "holdout", rows = dataset.holdout } }) do
		for _, row in ipairs(split.rows) do
			local rowOk, rowError = appendLine({
				recordType = "exact_pair",
				split = split.name,
				sourceGroupId = row.sourceGroupId,
				engine = row.engine,
				features = row.features,
				labels = row.labels,
			})
			if not rowOk then return nil, rowError end
		end
	end
	return table.concat(lines, "\n") .. "\n", {
		bytes = byteCount,
		rows = #dataset.training + #dataset.holdout,
		trainingRows = #dataset.training,
		holdoutRows = #dataset.holdout,
		sourceLineages = dataset.sourceLineages,
		trainingSourceLineages = dataset.trainingSourceLineages,
		holdoutSourceLineages = dataset.holdoutSourceLineages,
		datasetSchemaVersion = DATASET_SCHEMA_VERSION,
		featurePolicy = FEATURE_POLICY,
		groupingPolicy = GROUPING_POLICY,
	}
end

trainingData.DATASET_SCHEMA_VERSION = DATASET_SCHEMA_VERSION
trainingData.RECORD_SCHEMA_VERSION = RECORD_SCHEMA_VERSION
trainingData.FEATURE_POLICY = FEATURE_POLICY
trainingData.GROUPING_POLICY = GROUPING_POLICY
trainingData.MAX_ELIGIBLE_ROWS = MAX_ELIGIBLE_ROWS
trainingData.MAX_EXPORT_BYTES = MAX_EXPORT_BYTES

return trainingData
