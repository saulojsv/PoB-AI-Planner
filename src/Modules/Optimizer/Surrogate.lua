-- Path of Building
--
-- Module: optional local ranking surrogate.
-- A learned model may only reorder candidates. It cannot remove candidates,
-- approve feasibility, change hard constraints, or replace exact PoB results.
-- No trained model is shipped or enabled until a versioned dataset passes the
-- documented held-out quality gates.
--
local surrogate = { model = nil, enabled = false }
local Features = require("Modules.Optimizer.SurrogateFeatures")
local json = require("dkjson")

local requiredEngineFields = { "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }
local requiredFormat = "pob-optimizer-surrogate"
local requiredFeaturePolicy = "exact-pair-build-context-lineage-engine-manifest-v6"
local requiredGroupingPolicy = "reviewed-source-snapshot-union-v2"
local requiredSchemaVersion = 7
local minimumSpearman = 0.80
local minimumParetoRecall = 0.90
local minimumHoldoutCoverage = 0.80
local minimumTrainingGroups = 8
local minimumHoldoutGroups = 5
local minimumTrainingRows = 128
local minimumHoldoutRows = 50
local requiredModelType = "passive-one-node-build-context-mlp-v2"
local maximumArtifactBytes = 4194304

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function completeEngine(engine)
	if type(engine) ~= "table" then return false end
	for _, key in ipairs(requiredEngineFields) do
		if type(engine[key]) ~= "string" and type(engine[key]) ~= "number" then return false end
		if tostring(engine[key]) == "" then return false end
	end
	local fingerprint = engine.manifestFingerprint
	if type(fingerprint) ~= "string" or #fingerprint ~= 64 or not fingerprint:match("^[%da-f]+$") then return false end
	return true
end

local function validateModel(model)
	if type(model) ~= "table" then return false, "no_model" end
	if model.format ~= requiredFormat or model.schemaVersion ~= requiredSchemaVersion then
		return false, "unsupported_model_schema"
	end
	if model.featurePolicy ~= requiredFeaturePolicy then return false, "unsupported_feature_policy" end
	if model.groupingPolicy ~= requiredGroupingPolicy then return false, "unsupported_grouping_policy" end
	if model.deterministic ~= true then return false, "model_not_deterministic" end
	if type(model.Rank) ~= "function" or type(model.InDomain) ~= "function" then
		return false, "model_ranking_contract_missing"
	end
	if not completeEngine(model.engine) then return false, "model_engine_identity_incomplete" end
	local validation = model.validation
	if type(validation) ~= "table" or validation.status ~= "passed"
		or not finite(validation.heldOutSpearman) or validation.heldOutSpearman < minimumSpearman or validation.heldOutSpearman > 1
		or not finite(validation.topParetoRecall) or validation.topParetoRecall < minimumParetoRecall or validation.topParetoRecall > 1
		or not finite(validation.baselineInputOrderSpearman)
		or validation.baselineInputOrderSpearman < -1 or validation.baselineInputOrderSpearman > 1
		or not finite(validation.baselineInputOrderTopParetoRecall)
		or validation.baselineInputOrderTopParetoRecall < 0 or validation.baselineInputOrderTopParetoRecall > 1
		or validation.baselineNonRegression ~= true
		or validation.heldOutSpearman + 1e-12 < validation.baselineInputOrderSpearman
		or validation.topParetoRecall + 1e-12 < validation.baselineInputOrderTopParetoRecall
		or not finite(validation.baselineScoredSourceLineages)
		or validation.baselineScoredSourceLineages < minimumHoldoutGroups
		or validation.baselineScoredSourceLineages ~= math.floor(validation.baselineScoredSourceLineages)
		or not finite(validation.baselineParetoScoredGroups)
		or validation.baselineParetoScoredGroups < minimumHoldoutGroups
		or validation.baselineParetoScoredGroups ~= math.floor(validation.baselineParetoScoredGroups)
		or not finite(validation.baselineParetoUnscoredGroups)
		or validation.baselineParetoUnscoredGroups ~= 0
		or not finite(validation.heldOutCoverage) or validation.heldOutCoverage < minimumHoldoutCoverage or validation.heldOutCoverage > 1
		or not finite(validation.heldOutRows) or validation.heldOutRows < minimumHoldoutRows
		or validation.heldOutRows ~= math.floor(validation.heldOutRows)
		or not finite(validation.scoredSourceLineages) or validation.scoredSourceLineages < minimumHoldoutGroups
		or validation.scoredSourceLineages ~= math.floor(validation.scoredSourceLineages) then
		return false, "held_out_quality_gate_failed"
	end
	local trainingGroups = tonumber(model.trainingSourceLineages)
	local holdoutGroups = tonumber(model.holdoutSourceLineages)
	local trainingRows = tonumber(model.trainingRows)
	local holdoutRows = tonumber(model.holdoutRows)
	if not finite(trainingGroups) or trainingGroups < minimumTrainingGroups or trainingGroups ~= math.floor(trainingGroups)
		or not finite(holdoutGroups) or holdoutGroups < minimumHoldoutGroups or holdoutGroups ~= math.floor(holdoutGroups)
		or not finite(trainingRows) or trainingRows < minimumTrainingRows or trainingRows ~= math.floor(trainingRows)
		or not finite(holdoutRows) or holdoutRows < minimumHoldoutRows or holdoutRows ~= math.floor(holdoutRows) then
		return false, "source_lineage_holdout_missing"
	end
	if validation.baselineScoredSourceLineages > holdoutGroups
		or validation.baselineParetoScoredGroups > holdoutGroups
		or validation.baselineParetoScoredGroups + validation.baselineParetoUnscoredGroups ~= holdoutGroups
		or validation.scoredSourceLineages > holdoutGroups then
		return false, "held_out_quality_gate_failed"
	end
	return true
end

local function sameEngineVersion(modelEngine, currentEngine)
	if not completeEngine(currentEngine) then return false, "current_engine_identity_incomplete" end
	for _, key in ipairs(requiredEngineFields) do
		if tostring(modelEngine[key]) ~= tostring(currentEngine[key]) then
			return false, "engine_version_mismatch:" .. key
		end
	end
	return true
end

local function isDenseCandidateArray(candidates)
	if type(candidates) ~= "table" then return false end
	local count, highest = 0, 0
	for key, value in pairs(candidates) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or type(value) ~= "table" then return false end
		count = count + 1
		if key > highest then highest = key end
	end
	return count == highest
end

local function sameCandidateMultiset(original, ranked)
	if not isDenseCandidateArray(original) or not isDenseCandidateArray(ranked) or #ranked ~= #original then return false end
	local remaining = { }
	for _, candidate in ipairs(original) do remaining[candidate] = (remaining[candidate] or 0) + 1 end
	for _, candidate in ipairs(ranked) do
		local count = remaining[candidate]
		if not count or count < 1 then return false end
		remaining[candidate] = count - 1
	end
	for _, count in pairs(remaining) do if count ~= 0 then return false end end
	return true
end

local function copyCandidateArray(candidates)
	local copy = { }
	for index, candidate in ipairs(candidates) do copy[index] = candidate end
	return copy
end

function surrogate.IsCompatible(model, engine)
	local valid, reason = validateModel(model)
	if not valid then return false, reason end
	return sameEngineVersion(model.engine, engine)
end

function surrogate.Install(model)
	local valid, reason = validateModel(model)
	if not valid then
		surrogate.model = nil
		surrogate.enabled = false
		return false, reason
	end
	surrogate.model = model
	surrogate.enabled = true
	return true
end

local function integer(value, minimum, maximum)
	return finite(value) and value == math.floor(value) and value >= minimum and value <= maximum
end

local function validateSupportedMutations(values, maxCount)
	if type(values) ~= "table" then return nil end
	local count, highest = 0, 0
	for key in pairs(values) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
		count = count + 1
		highest = math.max(highest, key)
	end
	if count ~= highest or count < 1 or count > maxCount then return nil end
	local result, seen = { }, { }
	for index, mutation in ipairs(values) do
		if type(mutation) ~= "table" or not integer(mutation.classId, 1, 64)
			or not integer(mutation.ascendancyId, 0, 256) or not integer(mutation.changedNodeId, 1, 2147483647)
			or type(mutation.mainSkill) ~= "string" or mutation.mainSkill == "" or #mutation.mainSkill > 128
			or mutation.mainSkill:find("[%c]") then return nil end
		local classRows = seen[mutation.classId] or { }
		seen[mutation.classId] = classRows
		local ascendancyRows = classRows[mutation.ascendancyId] or { }
		classRows[mutation.ascendancyId] = ascendancyRows
		local skillRows = ascendancyRows[mutation.mainSkill] or { }
		ascendancyRows[mutation.mainSkill] = skillRows
		if skillRows[mutation.changedNodeId] then return nil end
		skillRows[mutation.changedNodeId] = true
		result[index] = {
			classId = mutation.classId,
			ascendancyId = mutation.ascendancyId,
			mainSkill = mutation.mainSkill,
			changedNodeId = mutation.changedNodeId,
		}
	end
	return result
end

local function denseFiniteVector(values, expectedLength, maxAbs)
	if type(values) ~= "table" or #values ~= expectedLength then return false end
	for index = 1, expectedLength do
		if not finite(values[index]) or math.abs(values[index]) > maxAbs then return false end
	end
	return true
end

local function makeArtifactModel(artifact)
	if type(artifact) ~= "table" or artifact.modelType ~= requiredModelType then return nil, "unsupported_model_type" end
	if not integer(artifact.featureDimension, 16, 4096) or not integer(artifact.hiddenSize, 1, 32) then
		return nil, "invalid_model_dimensions"
	end
	local inputSize = artifact.featureDimension + #Features.numericNames
	local weights = artifact.weights
	if type(weights) ~= "table" or type(weights.inputHidden) ~= "table" or #weights.inputHidden ~= inputSize
		or not denseFiniteVector(weights.biasHidden, artifact.hiddenSize, 100)
		or not denseFiniteVector(weights.hiddenOutput, artifact.hiddenSize, 100)
		or not finite(weights.biasOutput) or math.abs(weights.biasOutput) > 100 then
		return nil, "invalid_model_weights"
	end
	for inputIndex = 1, inputSize do
		if not denseFiniteVector(weights.inputHidden[inputIndex], artifact.hiddenSize, 100) then return nil, "invalid_model_weights" end
	end
	if not denseFiniteVector(artifact.numericMean, #Features.numericNames, 1000000000000000000)
		or not denseFiniteVector(artifact.numericScale, #Features.numericNames, 1000000000000000000) then
		return nil, "invalid_numeric_scaler"
	end
	for index = 1, #artifact.numericScale do if artifact.numericScale[index] <= 0 then return nil, "invalid_numeric_scaler" end end
	local sourceDomain = artifact.domain
	if type(sourceDomain) ~= "table" then return nil, "invalid_model_domain" end
	local domain = validateSupportedMutations(sourceDomain.supportedMutations, 10000)
	if not domain then return nil, "invalid_model_domain" end
	local categories = { }
	for _, mutation in ipairs(domain) do
		local classRows = categories[mutation.classId] or { }
		categories[mutation.classId] = classRows
		local ascendancyRows = classRows[mutation.ascendancyId] or { }
		classRows[mutation.ascendancyId] = ascendancyRows
		local skillRows = ascendancyRows[mutation.mainSkill] or { }
		ascendancyRows[mutation.mainSkill] = skillRows
		skillRows[mutation.changedNodeId] = true
	end

	local model = {
		format = artifact.format,
		schemaVersion = artifact.schemaVersion,
		featurePolicy = artifact.featurePolicy,
		groupingPolicy = artifact.groupingPolicy,
		modelType = artifact.modelType,
		deterministic = artifact.deterministic,
		engine = artifact.engine,
		validation = artifact.validation,
		trainingSourceLineages = artifact.trainingSourceLineages,
		holdoutSourceLineages = artifact.holdoutSourceLineages,
		trainingRows = artifact.trainingRows,
		holdoutRows = artifact.holdoutRows,
		objectiveMetric = artifact.objectiveMetric,
		featureDimension = artifact.featureDimension,
		hiddenSize = artifact.hiddenSize,
		numericMean = artifact.numericMean,
		numericScale = artifact.numericScale,
		weights = weights,
		domain = domain,
		_domain = categories,
	}

	local function supported(featureInput)
		if type(featureInput) ~= "table" or featureInput.featurePolicy ~= requiredFeaturePolicy
			or featureInput.objectiveMetric ~= model.objectiveMetric then return false end
		if not integer(featureInput.classId, 1, 64) or not integer(featureInput.ascendancyId, 0, 256)
			or type(featureInput.mainSkill) ~= "string" then return false end
		if type(featureInput.changedNodeIds) ~= "table" or #featureInput.changedNodeIds ~= 1 then return false end
		local classRows = categories[featureInput.classId]
		local ascendancyRows = classRows and classRows[featureInput.ascendancyId]
		local skillRows = ascendancyRows and ascendancyRows[featureInput.mainSkill]
		return skillRows and skillRows[featureInput.changedNodeIds[1]] == true or false
	end

	function model.InDomain(_, candidates)
		local supportedCount = 0
		for _, candidate in ipairs(candidates) do
			local featureInput = candidate.surrogateFeatures
			if featureInput then
				-- A bounded search may contain passive nodes unseen by this model.
				-- Keep those proposals in place and rank only the supported subset.
				if supported(featureInput) and Features.Vector(featureInput, model) then
					supportedCount = supportedCount + 1
				end
			end
		end
		return supportedCount > 0
	end

	function model.Rank(_, candidates)
		local positions, scored = { }, { }
		for index, candidate in ipairs(candidates) do
			local featureInput = candidate.surrogateFeatures
			if featureInput and supported(featureInput) then
				local vector = Features.Vector(featureInput, model)
				if vector then
					local activations = { }
					for hiddenIndex = 1, model.hiddenSize do
						local sum = weights.biasHidden[hiddenIndex]
						for inputIndex = 1, inputSize do
							local value = vector[inputIndex]
							if value ~= 0 then sum = sum + value * weights.inputHidden[inputIndex][hiddenIndex] end
						end
						if sum > 20 then activations[hiddenIndex] = 1
						elseif sum < -20 then activations[hiddenIndex] = -1
						else
							local exponent = math.exp(2 * sum)
							activations[hiddenIndex] = (exponent - 1) / (exponent + 1)
						end
					end
					local score = weights.biasOutput
					for hiddenIndex = 1, model.hiddenSize do score = score + activations[hiddenIndex] * weights.hiddenOutput[hiddenIndex] end
					if not finite(score) then error("non-finite passive surrogate score") end
					positions[#positions + 1] = index
					scored[#scored + 1] = { candidate = candidate, score = score, originalIndex = index }
				end
			end
		end
		if #scored < 2 then return candidates end
		table.sort(scored, function(left, right)
			if left.score ~= right.score then return left.score > right.score end
			return left.originalIndex < right.originalIndex
		end)
		local ranked = copyCandidateArray(candidates)
		for order, position in ipairs(positions) do ranked[position] = scored[order].candidate end
		return ranked
	end
	return model
end

function surrogate.InstallArtifact(artifact)
	local model, reason = makeArtifactModel(artifact)
	if not model then
		surrogate.model = nil
		surrogate.enabled = false
		return false, reason
	end
	return surrogate.Install(model)
end

function surrogate.LoadArtifactJson(encoded)
	if type(encoded) ~= "string" or #encoded == 0 or #encoded > maximumArtifactBytes then
		surrogate.Disable()
		return false, "artifact_size_invalid"
	end
	local ok, artifact = pcall(json.decode, encoded)
	if not ok or type(artifact) ~= "table" then
		surrogate.Disable()
		return false, "artifact_json_invalid"
	end
	return surrogate.InstallArtifact(artifact)
end

function surrogate.LoadFromUserPath(userPath)
	if type(userPath) ~= "string" or userPath == "" or userPath:find("[%c]") then
		surrogate.Disable()
		return false, "user_path_unavailable"
	end
	local separator = package.config and package.config:sub(1, 1) or "\\"
	userPath = userPath:gsub("[/\\]+$", "")
	local invalidationPath = userPath .. separator .. "OptimizerStudies" .. separator .. "training-artifacts-invalidated.json"
	local invalidationFile, invalidationError = io.open(invalidationPath, "rb")
	if invalidationFile then
		invalidationFile:close()
		surrogate.Disable()
		return false, "training_artifact_invalidated_by_study_withdrawal"
	end
	local invalidationMessage = tostring(invalidationError or ""):lower()
	if not (invalidationMessage:find("no such file", 1, true) or invalidationMessage:find("cannot find", 1, true)
		or invalidationMessage:find("does not exist", 1, true)) then
		surrogate.Disable()
		return false, "training_invalidation_marker_unreadable"
	end
	local modelPath = userPath .. separator .. "OptimizerModels" .. separator .. "active.json"
	local file, openError = io.open(modelPath, "rb")
	if not file then
		if tostring(openError):lower():find("no such file", 1, true) or tostring(openError):lower():find("cannot find", 1, true) then
			surrogate.Disable()
			return false, "artifact_missing"
		end
		surrogate.Disable()
		return false, "artifact_read_failed"
	end
	local size = file:seek("end") or 0
	if size <= 0 or size > maximumArtifactBytes then file:close() return false, "artifact_size_invalid" end
	file:seek("set", 0)
	local encoded = file:read("*a")
	file:close()
	return surrogate.LoadArtifactJson(encoded)
end

function surrogate.Disable()
	surrogate.model = nil
	surrogate.enabled = false
end

function surrogate.Rank(candidates, engine)
	local original = candidates
	if not isDenseCandidateArray(candidates) then return original, "invalid_candidate_array" end
	if not surrogate.enabled then return original, "disabled" end
	local compatible, reason = surrogate.IsCompatible(surrogate.model, engine)
	if not compatible then return original, reason end
	local ok, inDomain = pcall(surrogate.model.InDomain, surrogate.model, copyCandidateArray(candidates), engine)
	if not ok or inDomain ~= true then return original, "outside_model_domain" end
	-- Isolate in-place sorting of the proposal array from the source order. The
	-- candidate objects themselves are still treated as read-only model inputs.
	local rankedOk, ranked = pcall(surrogate.model.Rank, surrogate.model, copyCandidateArray(candidates), engine)
	if not rankedOk or not sameCandidateMultiset(original, ranked) then
		return original, "invalid_model_ranking"
	end
	return ranked, "ranked"
end

return surrogate
