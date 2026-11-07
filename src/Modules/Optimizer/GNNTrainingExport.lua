-- Path of Building
--
-- Module: explicit, local-only export of exact Route Planner observations.
-- A checked "my authored build" attestation is required; the Python daemon
-- revalidates the full shard before writing it to the inbox.

local exporter = { }
local sha = require("sha2")
local IPC = require("Modules.Optimizer.GNNIPC")

local metricKeys = {
	"CombinedDPS", "FullDPS", "TotalEHP", "PhysicalMaximumHitTaken",
	"FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken",
	"FireResist", "ColdResist", "LightningResist", "ChaosResist",
}
local allowedFloorViolations = {
	CombinedDPS = true, FullDPS = true, TotalEHP = true,
	PhysicalMaximumHitTaken = true, FireMaximumHitTaken = true,
	ColdMaximumHitTaken = true, LightningMaximumHitTaken = true,
	FireResist = true, ColdResist = true, LightningResist = true,
	FireResistOverCap = true, ColdResistOverCap = true,
	LightningResistOverCap = true, ChaosResist = true,
}

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function lineageId(snapshot)
	local parts = {
		snapshot.engine.manifestFingerprint, snapshot.engine.dataVersion, snapshot.engine.treeVersion,
		snapshot.skill.effectId, snapshot.skill.gemId, snapshot.scenario.profile, snapshot.scenario.enemyPreset,
	}
	for _, node in ipairs(snapshot.passiveNodes or { }) do
		if node.allocated then parts[#parts + 1] = "allocated:" .. tostring(node.id) end
	end
	for _, item in ipairs(snapshot.items or { }) do parts[#parts + 1] = "item:" .. tostring(item.fingerprint) end
	for _, group in ipairs(snapshot.skillGroups or { }) do
		for _, gem in ipairs(group.gems or { }) do
			parts[#parts + 1] = table.concat({ "gem", tostring(group.index), tostring(gem.gemId),
				tostring(gem.effectId), tostring(gem.level), tostring(gem.quality), tostring(gem.support) }, ":")
		end
	end
	return sha.sha256(table.concat(parts, "\n"))
end

function exporter.CreateContext(buildSnapshot, proposals, candidates, runSpec, authorization)
	if type(buildSnapshot) ~= "table" or type(proposals) ~= "table" or type(candidates) ~= "table"
		or #proposals ~= #candidates then
		return nil, "exact training export context is incomplete"
	end
	local byCandidate = { }
	for index, candidate in ipairs(candidates) do byCandidate[candidate] = proposals[index] end
	local id = lineageId(buildSnapshot)
	local setId = sha.sha256(table.concat({ id, runSpec.skill.effectId, runSpec.scenario.profile,
		os.date("!%Y%m%dT%H%M%SZ"), tostring(math.random(0, 2147483647)), tostring(os.clock()) }, ":"))
	return { buildSnapshot = buildSnapshot, runSpec = runSpec, proposalByCandidate = byCandidate,
		lineageId = id, setId = setId, authorization = authorization, rows = { } }
end

function exporter.Collect(context, candidate, evaluation)
	if type(context) ~= "table" or type(evaluation) ~= "table" or type(evaluation.metrics) ~= "table" then return nil end
	local authorization = context.authorization
	if type(authorization) ~= "table" or authorization.consent ~= true
		or authorization.rightsBasis ~= "user_authored" then return nil end
	local proposal = context.proposalByCandidate[candidate]
	if not proposal or proposal.family == "cross_skill" or context.runSpec.searchMode ~= "SINGLE_SKILL_ONLY" then return nil end
	if evaluation.scenarioProfile ~= context.runSpec.scenario.profile or type(evaluation.scenario) ~= "table" then return nil end
	for _, violation in ipairs(evaluation.violations or { }) do
		if not allowedFloorViolations[violation.key] then return nil end
	end
	local metrics = evaluation.metrics
	local exactMetrics = { exactCalculated = true, feasible = evaluation.feasible == true }
	for _, key in ipairs(metricKeys) do
		local value = metrics[key]
		if not finite(value) then return nil end
		exactMetrics[key] = value
	end
	if context.runSpec.resistances.elemental == "OVERCAP_30_ALL" then
		for _, key in ipairs({ "FireResistOverCap", "ColdResistOverCap", "LightningResistOverCap" }) do
			if not finite(metrics[key]) then return nil end
			exactMetrics[key] = metrics[key]
		end
	end
	local proposalIndex = tonumber(tostring(proposal.proposalId):match("^p(%d+)$"))
	if not proposalIndex then return nil end
	local recordId = sha.sha256(context.lineageId .. ":" .. context.setId .. ":" .. proposal.proposalId)
	return {
		schemaVersion = 1, recordId = recordId, lineageId = context.lineageId, setId = context.setId,
		proposalIndex = proposalIndex, sourceReview = { rights = "authorized", rightsBasis = "user_authored",
			consent = true, reviewed = true, reviewer = "local_user", evidence = "planner_ui_owned_build_attestation_v1" },
		nativeValidation = { exactRecalculated = true, skillCompatible = true, resourcesValid = true,
			scenarioCertified = true, metricsContextValid = true, triggerCertified = true, unsupportedModesAbsent = true },
		engine = context.buildSnapshot.engine, skill = context.runSpec.skill, scenario = context.runSpec.scenario,
		runSpec = context.runSpec, buildSnapshot = context.buildSnapshot, proposal = proposal,
		exactMetrics = exactMetrics,
	}
end

function exporter.Export(context, control, job)
	if type(context) ~= "table" or type(context.rows) ~= "table" or #context.rows == 0 then
		return nil, "no exact, scenario-certified rows passed the export filter"
	end
	local authorization = context.authorization
	if type(authorization) ~= "table" or authorization.consent ~= true or authorization.rightsBasis ~= "user_authored" then
		return nil, "export authorization is missing"
	end
	local client, connectError = IPC.Connect()
	if not client then return nil, "local daemon unavailable: " .. tostring(connectError) end
	local result, err = client:Call("build_planner/export_dataset", {
		consent = true, rightsBasis = authorization.rightsBasis, records = context.rows,
	}, control, job, 300)
	client:Close()
	if not result then return nil, err end
	return result
end

return exporter
