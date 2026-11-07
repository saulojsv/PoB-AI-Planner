-- This module is used as a base that the other calc sections can `require` to add their functions to
---@class Calcs
local calcs = {}

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Return the native payable pool used by upfront skill-cost checks. Energy
-- Shield can pay Mana only when PoB's EnergyShieldProtectsMana flag is active.
function calcs.getSkillPayabilityPool(poolOutput, costKey, poolKey)
	poolOutput = poolOutput or { }
	local available = poolOutput[poolKey]
	if costKey == "ManaCost" then
		available = poolOutput.ManaCostPayablePool
		if available == nil then
			local unreservedMana = poolOutput.ManaUnreserved
			if isFinite(unreservedMana) then
				available = unreservedMana + (poolOutput.EnergyShieldProtectsMana and (isFinite(poolOutput.EnergyShield) and poolOutput.EnergyShield or 0) or 0)
			end
		end
	end
	return available
end

-- Shared exact passive/modifier calculation for a skill's summon limit.
-- Totem and ballista outputs use the same modifier keys in CalcOffence and
-- CalcPerform; keep other consumers on this engine-owned definition as well.
function calcs.getActiveTotemLimit(activeSkill)
	if not activeSkill or not activeSkill.skillModList then
		return 0
	end
	return activeSkill.skillModList:Sum("BASE", activeSkill.skillCfg, "ActiveTotemLimit", "ActiveBallistaLimit")
end

-- Shared exact skill-cost check used by normal build warnings and optimizer
-- certification. It consumes the cost and pool values produced by CalcOffence;
-- the only additional operation is the same reservation allowance used by
-- Calcs.buildOutput when it reports an affordability warning.
function calcs.checkSkillPayability(poolOutput, skillOutput, activeSkill)
	poolOutput = poolOutput or { }
	skillOutput = skillOutput or { }
	local violations = { }
	local costs = {
		{ key = "LifeCost", pool = "LifeUnreserved", rawPool = "Life", resource = "life", label = "Life" },
		{ key = "ManaCost", pool = "ManaUnreserved", rawPool = "Mana", resource = "mana", label = "Mana" },
		{ key = "ESCost", pool = "EnergyShield", rawPool = "EnergyShield", resource = "Energy Shield", label = "Energy Shield" },
		{ key = "RageCost", pool = "Rage", rawPool = "Rage", resource = "rage", label = "Rage" },
	}
	local function addViolation(entry, actual, cost, reason)
		violations[#violations + 1] = {
			key = "main_skill_payability",
			resource = entry.resource,
			label = entry.label .. " skill cost",
			actual = actual,
			required = cost,
			deficit = isFinite(actual) and isFinite(cost) and math.max(0, cost - actual) or 1,
			skill = activeSkill and activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect and activeSkill.activeEffect.grantedEffect.name or nil,
			reason = reason,
			warningKey = not entry.percent and (entry.key .. "Warning") or nil,
			warningListKey = entry.key .. "WarningList",
		}
	end
	for _, entry in ipairs(costs) do
		local cost = skillOutput[entry.key]
		if cost ~= nil and not isFinite(cost) then
			addViolation(entry, nil, nil, "PoB did not provide a finite exact skill cost")
		elseif isFinite(cost) and cost > 0 then
			local available = calcs.getSkillPayabilityPool(poolOutput, entry.key, entry.pool)
			if not isFinite(available) then
				addViolation(entry, nil, cost, "PoB did not provide a finite exact payable pool")
			elseif available < cost then
				local skillData = activeSkill and activeSkill.skillData or { }
				local reservation = skillData[entry.rawPool .. "ReservedPercent"]
				local rawPoolValue = poolOutput[entry.rawPool]
				local reservedAllowance = isFinite(reservation) and isFinite(rawPoolValue) and math.ceil((rawPoolValue * reservation) / 100) or 0
				if not reservation or available + reservedAllowance < cost then
					addViolation(entry, available, cost, string.format("PoB exact %s pool is below the skill's upfront cost", entry.label))
				end
			end
		end
	end
	local percentageCosts = {
		{ key = "LifePercentCost", pool = "LifeUnreservedPercent", resource = "life percentage", label = "Life percentage", percent = true },
		{ key = "ManaPercentCost", pool = "ManaUnreservedPercent", resource = "mana percentage", label = "Mana percentage", percent = true },
	}
	for _, entry in ipairs(percentageCosts) do
		local cost = skillOutput[entry.key]
		local available = poolOutput[entry.pool]
		if cost ~= nil and not isFinite(cost) then
			addViolation(entry, nil, nil, "PoB did not provide a finite exact skill cost")
		elseif isFinite(cost) and cost > 0 and not isFinite(available) then
			addViolation(entry, nil, cost, "PoB did not provide a finite exact payable pool")
		elseif isFinite(cost) and cost > 0 and available < cost then
			addViolation(entry, available, cost, string.format("PoB exact %s pool is below the skill's upfront cost", entry.label))
		end
	end
	return violations
end

return calcs

---@class Output
---@field MainHand Output
---@field OffHand Output
---@field Minion Output?
---@field ActivePhantasmLimit number?
---@field ActiveSpectreLimit number?
---@field BattleCryExertsCount number?
---@field BattleMageCryCastTime number?
---@field BattleMageCryCooldown number?
---@field BattleMageCryDuration number?
---@field BattlemageUpTimeRatio number?
---@field BleedDamage number?
---@field ChaosHitAverage number?
---@field ChaosResist number?
---@field ColdHitAverage number?
---@field ColdResistOverCap number?
---@field ColdResistTotal number?
---@field CullMultiplier number?
---@field Dex number?
---@field EffectiveBlockChance number?
---@field EffectiveProjectileBlockChance number?
---@field EffectiveSpellBlockChance number?
---@field EffectiveSpellProjectileBlockChance number?
---@field EnergyShieldLeechDuration number?
---@field EnergyShieldRecoupRecoveryAvg number?
---@field EnergyShieldRegenRecovery number?
---@field ESCost  number?
---@field FireHitAverage  number?
---@field FireResistOverCap number?
---@field FireResistTotal number?
---@field FreezeChanceOnCrit number?
---@field FreezeChanceOnHit number?
---@field GlobalWarcryUptimeRatio number?
---@field IgniteAvoidChance number?
---@field IgniteChanceOnCrit number?
---@field IgniteChanceOnHit number?
---@field InfernalCryCastTime number?
---@field InfernalCryCooldown number?
---@field InfernalCryDuration number?
---@field InfernalExertsCount number?
---@field InfernalUpTimeRatio number?
---@field Int number?
---@field LifeCancellableReservation  number?
---@field LifeCost  number?
---@field LifeLeechDuration number?
---@field LifeRecoupRecoveryAvg number?
---@field LifeRegenRecovery number?
---@field LifeReservedPercent number?
---@field LifeUnreserved number?
---@field LightningHitAverage number?
---@field LightningResist number?
---@field LightningResistOverCap number?
---@field LightningResistTotal number?
---@field ManaCost number?
---@field ManaCostRaw number?
---@field ManaHasCost boolean?
---@field ManaLeechDuration number?
---@field ManaRecoupRecoveryAvg number?
---@field ManaRegenRecovery number?
---@field ManaUnreserved number?
---@field PhysicalTakenDamage number?
---@field PhysicalTakenHit number?
---@field PoisonAvoidChance number?
---@field RageCost number?
---@field ReservationDpsMultiplier number?
---@field ReturnChance number?
---@field SelfIgniteDuration number?
---@field SelfIgniteEffect number?
---@field SelfPoisonDuration number?
---@field SelfPoisonEffect number?
---@field Str number?
---@field TotalVaalRejuvenationTotemLife number?
---@field TotemChaosResist number?
---@field TotemLife number?

---@class Breakdown
---@field MainHand Breakdown?
---@field OffHand Breakdown?

---@class Actor
---@field output Output
---@field modDB ModDB
---@field enemy Actor?
---@field breakdown? Breakdown?

---@class ActiveSkill
---@field skillModList ModList
---@field skillCfg ModCfg
