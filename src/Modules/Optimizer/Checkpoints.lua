-- Path of Building
--
-- Module: Reversible optimizer phase checkpoints.
-- Stores compact provenance for applied Tree / Skills / Equipment variations.
-- A checkpoint records exact PoB metrics and a fingerprint of the resulting
-- build state; it is progress metadata, never a training label or score.

local json = require("dkjson")
local Candidate = require("Modules.Optimizer.Candidate")
local Version = require("Modules.Optimizer.Version")

local checkpoints = { }
local metricKeys = {
	"CombinedDPS", "FullDPS", "FullDotDPS", "TotalEHP", "Life", "EnergyShield", "Ward", "ImpaleDPS",
	"PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken", "ChaosMaximumHitTaken",
	"SpellSuppressionChance", "BlockChance", "SpellBlockChance", "Armour", "Evasion",
	"FireResist", "ColdResist", "LightningResist", "ChaosResist",
}

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function checkpoints.Decode(encoded)
	if type(encoded) ~= "string" or encoded == "" then return { version = 1, phases = { } } end
	local ok, value = pcall(json.decode, encoded)
	if not ok or type(value) ~= "table" or value.version ~= 1 or type(value.phases) ~= "table" then
		return { version = 1, phases = { } }
	end
	return value
end

function checkpoints.Fingerprint(value)
	value = tostring(value or "")
	-- Two independent polynomial hashes keep the persisted checkpoint small while
	-- making accidental collisions in local build-state fingerprints unlikely.
	local first, second = 5381, 2166136261
	for index = 1, #value do
		local byte = value:byte(index)
		first = (first * 33 + byte) % 4294967291
		second = (second * 65599 + byte) % 4294967279
	end
	return tostring(first) .. ":" .. tostring(second)
end

function checkpoints.Record(encoded, phase, build, candidate, evaluation, objective, preferences)
	if phase ~= "tree" and phase ~= "skills" and phase ~= "equipment" and phase ~= "combined" then
		return nil, "Unsupported optimizer checkpoint phase"
	end
	local state = checkpoints.Decode(encoded)
	state.sequence = (tonumber(state.sequence) or 0) + 1
	local metrics = { }
	for _, key in ipairs(metricKeys) do
		local value = evaluation and evaluation.metrics and evaluation.metrics[key]
		if finite(value) then metrics[key] = value end
	end
	local signatureOk, signature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or type(signature) ~= "string" then return nil, "Could not fingerprint the applied PoB build variation" end
	local mainGroup = build.skillsTab and build.skillsTab.socketGroupList[build.mainSocketGroup]
	local mainSkill = mainGroup and mainGroup.displaySkillList and mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
	state.phases[phase] = {
		phase = phase,
		sequence = state.sequence,
		status = "applied_exact_variation",
		fingerprint = checkpoints.Fingerprint(signature),
		dataVersion = Version.Data(build),
		treeVersion = Version.Tree(build),
		characterLevel = build.characterLevel,
		class = build.spec and build.spec.curClassName,
		ascendancy = build.spec and build.spec.curAscendClassName,
		mainSkill = mainSkill and (mainSkill.name or mainSkill.activeEffect and mainSkill.activeEffect.grantedEffect and mainSkill.activeEffect.grantedEffect.name) or nil,
		objective = objective,
		objectiveValue = evaluation and evaluation.metrics and evaluation.metrics[objective],
		damageFocus = preferences and preferences.damageFocus or "Auto",
		defenseProfile = preferences and preferences.defenseProfile or "Auto",
		rankingPriority = preferences and preferences.rankingPriority or "ObjectiveFirst",
		candidateLabel = tostring(candidate and candidate.label or "PoB variation"):sub(1, 120),
		passivePointsUsed = evaluation and evaluation.passivePointsUsed,
		metrics = metrics,
		savedAt = os.time(),
	}
	local ok, serialized = pcall(json.encode, state)
	if not ok or type(serialized) ~= "string" or #serialized > 12288 then
		return nil, "Optimizer checkpoint exceeded its safe saved-size limit"
	end
	return serialized, state.phases[phase]
end

function checkpoints.GetSummary(encoded, build)
	local state = checkpoints.Decode(encoded)
	local result = { version = state.version, phases = { }, latestPhase = nil, latestStatus = "none" }
	local order = { "tree", "skills", "equipment", "combined" }
	local latestSequence = -1
	for _, phase in ipairs(order) do
		local entry = state.phases[phase]
		if type(entry) == "table" and (tonumber(entry.sequence) or 0) > latestSequence then
			latestSequence = tonumber(entry.sequence) or 0
			result.latestPhase = phase
		end
	end
	for _, phase in ipairs(order) do
		local entry = state.phases[phase]
		if type(entry) == "table" then
			local signatureOk, signature = pcall(Candidate.BuildSignature, build)
			local isLatest = phase == result.latestPhase
			local status = isLatest and signatureOk and checkpoints.Fingerprint(signature) == entry.fingerprint and "current" or isLatest and "stale" or "completed"
			result.phases[#result.phases + 1] = {
				phase = phase,
				status = status,
				objective = entry.objective,
				objectiveValue = entry.objectiveValue,
				candidateLabel = entry.candidateLabel,
				metrics = entry.metrics or { },
			}
			if isLatest then result.latestStatus = status end
		end
	end
	return result
end

return checkpoints
