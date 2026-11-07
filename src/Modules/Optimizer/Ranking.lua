-- Path of Building
--
-- Module: Exact optimizer candidate ranking.
-- Hard feasibility is decided separately by Validator; this module only orders
-- candidates that have already passed every exact PoB gate.
local ranking = { }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local defenseMetrics = {
	Auto = "TotalEHP",
	Life = "Life",
	EnergyShield = "EnergyShield",
	Hybrid = "TotalEHP",
	Ward = "Ward",
	Armour = "Armour",
	Evasion = "Evasion",
	Block = "BlockChance",
	SpellBlock = "SpellBlockChance",
	SpellSuppression = "SpellSuppressionChance",
}

-- These are exact native PoB outputs. Elemental focus intentionally uses the
-- per-hit contribution exposed by CalcOffence; it is not presented as isolated
-- elemental DPS. Unsupported focus domains remain proposal-order preferences.
local damageMetrics = {
	PhysicalHit = "PhysicalHitAverage",
	PhysicalImpale = "ImpaleDPS",
	PhysicalDoT = "BleedDPS",
	Fire = "FireHitAverage",
	Cold = "ColdHitAverage",
	Lightning = "LightningHitAverage",
	ChaosPoison = "PoisonDPS",
}

function ranking.DefenseMetricKey(defenseProfile)
	return defenseMetrics[defenseProfile or "Auto"] or defenseMetrics.Auto
end

function ranking.DamageFocusMetricKey(damageFocus)
	return damageMetrics[damageFocus]
end

local function rankingMetricKeys(objectiveKey, preferences)
	preferences = preferences or { }
	local keys = { }
	local seen = { }
	local function add(key)
		if type(key) == "string" and key ~= "" and not seen[key] then
			seen[key] = true
			keys[#keys + 1] = key
		end
	end
	if preferences.rankingPriority == "DefenseFirst" then
		add(ranking.DefenseMetricKey(preferences.defenseProfile))
		add(ranking.DamageFocusMetricKey(preferences.damageFocus))
		add(objectiveKey)
		add("TotalEHP")
		add("CombinedDPS")
	else
		-- Preserve the objective as the primary metric, then honor the exact
		-- selected damage-focus output and the selected defensive output.
		add(objectiveKey)
		add(ranking.DamageFocusMetricKey(preferences.damageFocus))
		add(ranking.DefenseMetricKey(preferences.defenseProfile))
		add("CombinedDPS")
	end
	return keys
end

function ranking.OrderingMetrics(objectiveKey, preferences)
	return rankingMetricKeys(objectiveKey, preferences)
end

local function metric(candidate, key)
	local evaluation = candidate and candidate.evaluation
	local metrics = evaluation and evaluation.metrics
	return metrics and metrics[key]
end

local function pointCount(candidate)
	return #(candidate and candidate.nodeIds or { })
end

function ranking.IsBetter(candidate, current, objectiveKey, preferences)
	if not current then return true end
	for _, key in ipairs(rankingMetricKeys(objectiveKey, preferences)) do
		local candidateValue = metric(candidate, key)
		local currentValue = metric(current, key)
		if isFinite(candidateValue) and isFinite(currentValue) and candidateValue ~= currentValue then
			return candidateValue > currentValue
		end
		if isFinite(candidateValue) ~= isFinite(currentValue) then
			return isFinite(candidateValue)
		end
	end
	return pointCount(candidate) < pointCount(current)
end

function ranking.Dominates(first, second, objectiveKey, preferences)
	local metricKeys = { objectiveKey }
	metricKeys[#metricKeys + 1] = ranking.DefenseMetricKey(preferences and preferences.defenseProfile)
	metricKeys[#metricKeys + 1] = ranking.DamageFocusMetricKey(preferences and preferences.damageFocus)
	local seen, strictlyBetter = { }, false
	for _, key in ipairs(metricKeys) do
		if not seen[key] then
			seen[key] = true
			local firstValue = metric(first, key)
			local secondValue = metric(second, key)
			if not isFinite(firstValue) or not isFinite(secondValue) then return false end
			if firstValue < secondValue then return false end
			if firstValue > secondValue then strictlyBetter = true end
		end
	end
	local firstPoints, secondPoints = pointCount(first), pointCount(second)
	if firstPoints > secondPoints then return false end
	if firstPoints < secondPoints then strictlyBetter = true end
	return strictlyBetter
end

return ranking
