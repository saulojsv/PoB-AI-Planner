-- Path of Building
--
-- Module: Isolated exact-calculation scenario profiles for the optimizer.
-- Profiles operate on cloned PoB inputs and slot state; the active build and its
-- UI controls are never edited while candidate calculations run.
--
local scenario = { }
local configurationChoices = require("Modules.Optimizer.ConfigurationChoices")

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- These are native ConfigOptions variables, not translated UI labels. Clearing
-- both input and placeholder prevents a stale manual value from winning over
-- the boss defaults rebuilt by ConfigTab:BuildModList().
local chassisAilmentFields = {
	"conditionEnemyChilled", "conditionEnemyChilledEffect", "conditionEnemyChilledByYourHits",
	"multiplierChilledByYouSeconds", "conditionEnemyOnChilledGround", "conditionEnemyInChillingArea",
	"conditionEnemyShocked", "conditionShockEffect", "ShockStacks", "conditionEnemyOnShockedGround",
	"conditionEnemyFrozen", "multiplierFrozenByYouSeconds", "HoarfrostStacks",
	"conditionEnemyScorched", "conditionScorchEffect", "ScorchStacks", "conditionEnemyOnScorchedGround",
	"conditionEnemyBrittle", "conditionBrittleEffect", "conditionEnemyOnBrittleGround",
	"conditionEnemySapped", "conditionSapEffect", "conditionEnemyOnSappedGround",
	"multiplierFreezeShockIgniteOnEnemy",
	-- These manual flags mean the build recently applied an ailment. The
	-- chassis profile has no event/uptime model, so they cannot be carried as
	-- guaranteed combat state either.
	"conditionFrozenEnemyRecently", "conditionChilledEnemyRecently", "conditionShatteredEnemyRecently",
	"conditionIgnitedEnemyRecently", "conditionShockedEnemyRecently", "conditionPoisonedEnemyRecently",
	"conditionCausedBleedingRecently", "conditionImpaledRecently",
	"multiplierIgniteAppliedRecently", "multiplierPoisonAppliedRecently",
	"multiplierShockedNonShockedEnemyRecently",
}
local chassisEnemyFields = {
	"enemyLevel", "enemyArmour", "enemyEvasion", "enemySpeed", "enemyCritChance", "enemyCritDamage",
	"enemyPhysicalDamage", "enemyFireDamage", "enemyColdDamage", "enemyLightningDamage", "enemyChaosDamage",
	"enemyFireResist", "enemyColdResist", "enemyLightningResist", "enemyChaosResist",
	"enemyPhysicalOverwhelm", "enemyFirePen", "enemyColdPen", "enemyLightningPen",
	"enemyPhysicalReduction", "enemyMaxResist", "enemyBlockChance",
	"presetBossSkills", "enemyDamageRollRange", "enemyDamageType",
}

function scenario.CalculationOverride(profile)
	if profile == "PinnacleChassis" then return { disableGuardBuffs = true } end
	return { }
end

function scenario.CheckOutput(profile, output)
	if profile ~= "PinnacleChassis" then return true end
	if not output or output.OptimizerGuardBuffsDisabled ~= true then
		return false, "PoB did not acknowledge the chassis guard-buff exclusion"
	end
	if output.GuardSkillActive ~= false then
		return false, "A Guard buff remains active in the exact chassis calculation"
	end
	return true
end

function scenario.CheckChargeAudit(profile, audit)
	if profile ~= "PinnacleUnbuffed" and profile ~= "PinnacleChassis" then return true end
	if type(audit) ~= "table" or audit.countsAreExactPoBOutput ~= true then
		return false, "PoB did not provide exact charge counts for the Pinnacle scenario"
	end
	if audit.uptimeCertified ~= true then
		return false, "The exact PoB result contains a charge state above its native minimum floor, or a charge state that could not be certified after manual stacks were cleared"
	end
	return true
end

local function isMagicUtilityFlask(item)
	local flask = item and item.base and item.base.flask
	return item and item.type == "Flask" and item.rarity == "MAGIC" and flask
		and not flask.life and not flask.mana
end

local function selectedAscendancyIsPathfinder(spec)
	for _, name in ipairs({ spec and spec.curAscendClassName, spec and spec.curSecondaryAscendClassName }) do
		if type(name) == "string" and name:lower() == "pathfinder" then return true end
	end
	return false
end

local function countSourceEnabledFlasks(itemsTab)
	local count = 0
	for _, slot in ipairs(itemsTab and itemsTab.orderedSlots or { }) do
		if type(slot.slotName) == "string" and slot.slotName:match("^Flask") and slot.active
			and tonumber(slot.selItemId) and tonumber(slot.selItemId) > 0 then
			count = count + 1
		end
	end
	return count
end

-- The chassis profiles deactivate ordinary flask slots. CalcPerform has an
-- explicit Mageblood implementation which may reactivate magic utility flasks
-- independently of slot.active; audit that exact runtime state and fail closed
-- if anything else slipped into the unbuffed result. Pathfinder is deliberately
-- not treated as proof of uptime: PoB exposes rate estimates, not an exact
-- encounter event schedule, so its source-active flasks remain disabled.
function scenario.AuditFlasks(profile, env, spec, sourceItemsTab)
	local audit = {
		profile = tostring(profile or "Current"),
		status = "current_native",
		certified = true,
		activeCount = 0,
		activeNames = { },
		magebloodPermanentCount = 0,
		unexpectedActiveCount = 0,
		pathfinder = selectedAscendancyIsPathfinder(spec),
		sourceEnabledCount = countSourceEnabledFlasks(sourceItemsTab),
	}
	if audit.profile == "Current" then return audit end

	local modDB = env and env.player and env.player.modDB
	local leftPermanent = modDB and type(modDB.Sum) == "function"
		and tonumber(modDB:Sum("BASE", nil, "LeftActiveMagicUtilityFlasks")) or 0
	local rightPermanent = modDB and type(modDB.Sum) == "function"
		and tonumber(modDB:Sum("BASE", nil, "RightActiveMagicUtilityFlasks")) or 0
	audit.nativePermanentCapacity = math.max(0, leftPermanent or 0) + math.max(0, rightPermanent or 0)
	for item, active in pairs(env and env.flasks or { }) do
		if active then
			audit.activeCount = audit.activeCount + 1
			audit.activeNames[#audit.activeNames + 1] = tostring(item.title or item.name or item.baseName or "Unknown flask")
			if isMagicUtilityFlask(item) then
				audit.magebloodPermanentCount = audit.magebloodPermanentCount + 1
			else
				audit.unexpectedActiveCount = audit.unexpectedActiveCount + 1
			end
		end
	end
	table.sort(audit.activeNames)
	if audit.unexpectedActiveCount > 0 or audit.activeCount > audit.nativePermanentCapacity then
		audit.status = "unsupported_active_flask"
		audit.certified = false
		audit.reason = "A Pinnacle scenario contains active flask effects outside PoB's native permanent magic-utility allowance"
	elseif audit.activeCount > 0 then
		audit.status = "native_permanent_magic_utility"
	else
		audit.status = "all_flasks_disabled"
	end
	if audit.pathfinder and audit.sourceEnabledCount > 0 and audit.magebloodPermanentCount == 0 then
		audit.pathfinderPolicy = "disabled_without_exact_uptime_model"
	elseif audit.pathfinder then
		audit.pathfinderPolicy = "only_native_permanent_flasks_retained"
	else
		audit.pathfinderPolicy = "not_applicable"
	end
	return audit
end

local chargeOutputRows = {
	{ key = "Power", current = "PowerCharges", minimum = "PowerChargesMin", maximum = "PowerChargesMax", duration = "PowerChargesDuration" },
	{ key = "Frenzy", current = "FrenzyCharges", minimum = "FrenzyChargesMin", maximum = "FrenzyChargesMax", duration = "FrenzyChargesDuration" },
	{ key = "Endurance", current = "EnduranceCharges", minimum = "EnduranceChargesMin", maximum = "EnduranceChargesMax", duration = "EnduranceChargesDuration" },
}

local alternateChargeOutputRows = {
	{ key = "Absorption", current = "AbsorptionCharges", minimum = "AbsorptionChargesMin", maximum = "AbsorptionChargesMax" },
	{ key = "Affliction", current = "AfflictionCharges", minimum = "AfflictionChargesMin", maximum = "AfflictionChargesMax" },
	{ key = "Brutal", current = "BrutalCharges", minimum = "BrutalChargesMin", maximum = "BrutalChargesMax" },
	{ key = "Brine", current = "BrineCharges", maximum = "BrineChargesMax" },
	{ key = "Siphoning", current = "SiphoningCharges", maximum = "SiphoningChargesMax" },
	{ key = "Challenger", current = "ChallengerCharges", maximum = "ChallengerChargesMax" },
	{ key = "Blitz", current = "BlitzCharges", maximum = "BlitzChargesMax" },
	{ key = "Inspiration", current = "InspirationCharges", maximum = "InspirationChargesMax" },
	{ key = "Ghost Shroud", current = "GhostShrouds" },
	{ key = "Blood", current = "BloodCharges", maximum = "BloodChargesMax" },
	{ key = "Spirit", current = "SpiritCharges", maximum = "SpiritChargesMax" },
	{ key = "Spirit Infusion", current = "SpiritInfusions", maximum = "SpiritInfusionsMax" },
	{ key = "Crab Barrier", current = "CrabBarriers", maximum = "CrabBarriersMax" },
}

local function shockAssumptions(assumptions)
	local rows = { }
	for _, row in ipairs(assumptions or { }) do
		local key = tostring(row.key or ""):lower()
		if key:find("shock", 1, true) and (key:find("enemy", 1, true)
			or key == "conditionshockeffect" or key == "shockstacks") then
			rows[#rows + 1] = row
		end
	end
	return rows
end

function scenario.AuditCharges(output, assumptions, clearedState)
	local audit = {
		status = "exact_output_unavailable",
		countsAreExactPoBOutput = false,
		generationConsumptionSimulated = false,
		uptimeCertified = false,
		hasUnverifiedTransientCharges = true,
		charges = { },
		alternateCharges = { },
		configuredFields = { },
		clearedConfiguredFields = clearedState or { },
	}
	for _, assumption in ipairs(assumptions or { }) do
		local value = assumption.value
		local active = value == true or type(value) == "number" and value > 0
			or type(value) == "string" and value ~= "" and value ~= "0"
		if assumption.category == "charges" and active then
			audit.configuredFields[#audit.configuredFields + 1] = {
				key = assumption.key, value = value, source = assumption.source,
			}
		end
	end
	if type(output) ~= "table" then return audit end
	audit.countsAreExactPoBOutput = true
	local hasActiveCount = false
	local hasUnverifiedTransientCharges = false
	local function collect(target, definitions)
		for _, definition in ipairs(definitions) do
			local current = tonumber(output[definition.current]) or 0
			local minimum = definition.minimum and (tonumber(output[definition.minimum]) or 0) or nil
			local maximum = definition.maximum and (tonumber(output[definition.maximum]) or 0) or nil
			local duration = definition.duration and (tonumber(output[definition.duration]) or 0) or nil
			if current > 0 then hasActiveCount = true end
			if current > (minimum or 0) then hasUnverifiedTransientCharges = true end
			target[#target + 1] = {
				key = definition.key, current = current, minimum = minimum,
				maximum = maximum, duration = duration,
			}
		end
	end
	collect(audit.charges, chargeOutputRows)
	collect(audit.alternateCharges, alternateChargeOutputRows)
	audit.hasUnverifiedTransientCharges = hasUnverifiedTransientCharges
	audit.uptimeCertified = not hasUnverifiedTransientCharges and #audit.configuredFields == 0
	if not audit.uptimeCertified then
		audit.status = "static_counts_only_uptime_unverified"
	elseif hasActiveCount then
		audit.status = "native_minimum_charge_floor_only"
	else
		audit.status = "no_active_charge_count_in_exact_output"
	end
	audit.clearedChargeStateCount = #audit.clearedConfiguredFields
	audit.note = "Current/minimum/maximum values are exact PoB output. Counts at or below native minimum floors do not require generated charge stacks; this static calculation does not simulate charge gain, spending, or encounter uptime."
	return audit
end

function scenario.AuditShock(output, assumptions)
	local audit = {
		status = "exact_output_unavailable",
		configuredAssumptions = shockAssumptions(assumptions),
		effectivePoBOutput = nil,
		uptimeCertified = false,
	}
	if type(output) ~= "table" or not isFinite(tonumber(output.CurrentShock)) then return audit end
	audit.effectivePoBOutput = tonumber(output.CurrentShock)
	if #audit.configuredAssumptions > 0 then
		audit.status = "configured_shock_with_exact_pob_output"
	elseif audit.effectivePoBOutput > 0 then
		audit.status = "native_shock_with_exact_pob_output"
	else
		audit.status = "no_shock_in_exact_output"
		audit.uptimeCertified = true
	end
	audit.note = "The Shock value is the exact PoB output for this static configuration; this audit does not establish application chance or uptime against an encounter."
	return audit
end

local function shallowCopy(source)
	local copy = { }
	for key, value in pairs(source or { }) do copy[key] = value end
	return copy
end

local function cloneCustomMods(source)
	local copy = { }
	for index, block in ipairs(source or { }) do
		copy[index] = shallowCopy(block)
	end
	return copy
end

local function stripKillLines(text)
	local kept = { }
	local removed = 0
	local retained = 0
	for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
		-- Match a kill-related word at a word boundary. A plain substring search
		-- also matches "skill" and would silently discard legitimate modifiers.
		if not line:lower():match("%f[%a]kill%a*") then
			kept[#kept + 1] = line
			if line:match("%S") then retained = retained + 1 end
		else
			removed = removed + 1
		end
	end
	return table.concat(kept, "\n"), removed, retained
end

local function conditionalCategory(key)
	local name = tostring(key or ""):lower()
	if name:gsub("recharge", ""):find("charge", 1, true) then return "charges" end
	if name:find("overkill", 1, true) then return "mechanic_parameter" end
	if name:find("kill", 1, true) then return "kill_state" end
	if name:find("shock", 1, true) or name:find("chill", 1, true) or name:find("freeze", 1, true)
		or name:find("ignite", 1, true) or name:find("scorch", 1, true) or name:find("brittle", 1, true)
		or name:find("sap", 1, true) then
		if name:find("enemy", 1, true) or name == "conditionshockeffect" or name == "shockstacks" then
			return "enemy_ailment"
		end
		return "player_ailment"
	end
	if name:find("stack", 1, true) then return "stacks" end
	if name:find("buff", 1, true) then return "buff_state" end
	if name:find("condition", 1, true) then return "condition" end
	return "multiplier"
end

local function isConditionalField(key)
	local name = tostring(key or ""):lower()
	local chargeName = name:gsub("recharge", "")
	return key ~= "enemyIsBoss" and key ~= "conditionUsingFlask" and key ~= "customMods"
		and (name:find("condition", 1, true) or name:find("buff", 1, true) or chargeName:find("charge", 1, true)
			or name:find("stack", 1, true) or name:find("multiplier", 1, true) or name:find("overkill", 1, true))
end

local function isNumericConfigType(configType)
	return configType == "count" or configType == "integer" or configType == "countAllowZero" or configType == "float"
end

local function inputValueIsApplied(value, configType)
	if configType == "check" then return value == true end
	if isNumericConfigType(configType) then
		return type(value) == "number" and (value ~= 0 or configType == "countAllowZero")
	end
	if configType == "list" or configType == "text" then return value ~= nil and value ~= false and value ~= "" end
	return value ~= nil and value ~= false and value ~= 0 and value ~= ""
end

local function placeholderValueIsApplied(value, configType)
	return isNumericConfigType(configType) and type(value) == "number"
		and (value ~= 0 or configType == "countAllowZero")
end

local zeroDefaultMaxChargeState = {
	-- CalcPerform defaults these counts to their maximum when the config value is
	-- absent. A static Pinnacle calculation has no event model to prove generation.
	overrideInspirationCharges = true,
	overrideBloodCharges = true,
	overrideCrabBarriers = true,
}

local function isChargeStateOption(var)
	-- "Recharge" conditions are not charge-stack assumptions; remove that word
	-- before matching so Energy Shield recharge controls stay untouched.
	local name = tostring(var or ""):lower():gsub("recharge", "")
	return name:find("charge", 1, true) ~= nil
		or name:find("ghostshroud", 1, true) ~= nil
		or name:find("crabbarrier", 1, true) ~= nil
		or name:find("spiritinfusion", 1, true) ~= nil
end

local function clearChargeState(configTab, options)
	local configSet = configTab.configSets[configTab.activeConfigSetId]
	local input, placeholder = configSet.input, configSet.placeholder
	local removed, seen = { }, { }
	for _, option in ipairs(options or { }) do
		local key = option.var
		if type(key) == "string" and isChargeStateOption(key) then
			local inputValue, placeholderValue = input[key], placeholder[key]
			local inputApplied = inputValueIsApplied(inputValue, option.type)
			local placeholderApplied = placeholderValueIsApplied(placeholderValue, option.type)
			local forceZero = zeroDefaultMaxChargeState[key] == true
			if inputApplied or placeholderApplied or forceZero then
				local entry = seen[key]
				if not entry then
					entry = { key = key, policy = forceZero and "forced_zero" or "cleared" }
					seen[key] = entry
					removed[#removed + 1] = entry
				end
				if inputApplied then entry.inputValue = inputValue end
				if placeholderApplied then entry.placeholderValue = placeholderValue end
			end
			input[key], placeholder[key] = nil, nil
			if forceZero then input[key] = 0 end
		end
	end
	table.sort(removed, function(left, right) return left.key < right.key end)
	return removed
end

local function collectConditionalAssumptions(configTab, options)
	local configSet = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	local input, placeholder = configSet and configSet.input or { }, configSet and configSet.placeholder or { }
	local configTypes, assumptions, seen = { }, { }, { }
	for _, option in ipairs(options or { }) do
		if type(option.var) == "string" then configTypes[option.var] = option.type end
	end
	local function add(key, value, source, configType)
		if not isConditionalField(key) or type(value) ~= "boolean" and type(value) ~= "number" and type(value) ~= "string" then return end
		assumptions[#assumptions + 1] = {
			key = tostring(key), value = value, source = source,
			configType = tostring(configType or type(value)),
			category = conditionalCategory(key),
			certification = "configured_state_only",
		}
		seen[key] = true
	end
	for key, value in pairs(input) do
		local configType = configTypes[key]
		if inputValueIsApplied(value, configType) then add(key, value, "input", configType) end
	end
	for key, value in pairs(placeholder) do
		local configType = configTypes[key]
		if not seen[key] and placeholderValueIsApplied(value, configType) then add(key, value, "placeholder", configType) end
	end
	table.sort(assumptions, function(left, right) return left.key < right.key end)
	local fields = { }
	for _, row in ipairs(assumptions) do fields[#fields + 1] = row.key end
	return assumptions, fields
end

local function cloneConfigTab(source, proxyBuild, varList, configSetId)
	if not source or type(source.configSets) ~= "table" then
		return nil, "The active PoB configuration set cannot be cloned"
	end
	local activeId = source.activeConfigSetId
	if configSetId ~= nil then activeId = configSetId end
	local sourceSet = source.configSets[activeId]
	if not sourceSet then
		return nil, "The active PoB configuration set is unavailable"
	end

	local configTab = shallowCopy(source)
	setmetatable(configTab, getmetatable(source))
	local configSets = shallowCopy(source.configSets)
	local configSet = shallowCopy(sourceSet)
	configSet.input = shallowCopy(sourceSet.input)
	configSet.placeholder = shallowCopy(sourceSet.placeholder)
	configSet.customModsList = cloneCustomMods(sourceSet.customModsList)
	local varTypes = { }
	for _, option in ipairs(varList or { }) do
		if option.var then varTypes[option.var] = option.type end
	end

	local varControls = { }
	for var, original in pairs(source.varControls or { }) do
		local control = shallowCopy(original)
		setmetatable(control, getmetatable(original))
		-- PoB's normal control closure points to the live ConfigTab. Replace it on
		-- the clone so boss defaults are written only to this candidate profile.
		control.SetPlaceholder = function(self, value, notify)
			self.placeholder = tostring(value)
			if notify then
				if varTypes[var] == "text" then
					configSet.placeholder[var] = tostring(value)
				else
					configSet.placeholder[var] = tonumber(value)
				end
			end
		end
		varControls[var] = control
	end
	setmetatable(varControls, {
		__index = function(controls, var)
			-- Headless builds may not instantiate hidden UI controls. Boss-option
			-- callbacks still need an isolated SetPlaceholder sink.
			local control = {
				SetPlaceholder = function(self, value, notify)
					self.placeholder = tostring(value)
					if notify then configSet.placeholder[var] = tonumber(value) end
				end,
			}
			rawset(controls, var, control)
			return control
		end,
	})

	configSets[activeId] = configSet
	configTab.configSets = configSets
	configTab.activeConfigSetId = activeId
	configTab.input = configSet.input
	configTab.placeholder = configSet.placeholder
	configTab.varControls = varControls
	configTab.build = proxyBuild
	if proxyBuild then proxyBuild.configTab = configTab end
	return configTab
end

local function applyConfigurationChoices(configTab, variant)
	if variant == nil then return true end
	local valid, validationError = configurationChoices.Validate(variant)
	if not valid then return false, validationError end
	local configSet = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	if not configSet or type(configSet.input) ~= "table" then
		return false, "The isolated PoB configuration choices are unavailable"
	end
	for key, value in pairs(variant) do
		configSet.input[key] = value
		if configSet.placeholder then configSet.placeholder[key] = nil end
	end
	configTab.input = configSet.input
	configTab.placeholder = configSet.placeholder
	return true
end

local function validateEnemyPreset(preset, options)
	if preset == nil or preset == "" or preset == "Active" then return true end
	for _, option in ipairs(options or { }) do
		if option.var == "enemyIsBoss" then
			for _, choice in ipairs(option.list or { }) do
				if choice.val == preset then return true end
			end
		end
	end
	return false, "Enemy preset is not present in the loaded PoB ConfigOptions"
end

local function resolvedEnemyPreset(configTab, options)
	local configSet = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	local inputValue = configSet and configSet.input and configSet.input.enemyIsBoss
	if type(inputValue) == "string" and inputValue ~= "" then return inputValue end
	local control = configTab and configTab.varControls and configTab.varControls.enemyIsBoss
	local selected = control and control.list and control.list[control.selIndex]
	if selected and type(selected.val) == "string" then return selected.val end
	for _, option in ipairs(options or { }) do
		if option.var == "enemyIsBoss" then
			local default = option.list and option.list[option.defaultIndex or 1]
			if default and type(default.val) == "string" then return default.val end
		end
	end
	return "None"
end

local function applyEnemyPreset(configTab, preset)
	if preset == nil or preset == "" or preset == "Active" then return true end
	local configSet = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	if not configSet or type(configSet.input) ~= "table" then
		return false, "The isolated PoB configuration cannot accept an enemy preset"
	end
	configSet.input.enemyIsBoss = preset
	if configSet.placeholder then configSet.placeholder.enemyIsBoss = nil end
	configTab.input = configSet.input
	configTab.placeholder = configSet.placeholder
	return true
end

local function validateEnemyLevel(level, proxyBuild)
	if level == nil or level == "" then return nil end
	level = tonumber(level)
	local nativeData = proxyBuild and proxyBuild.data
	local maximumEnemyLevel = tonumber(nativeData and nativeData.misc and nativeData.misc.MaxEnemyLevel)
	if not maximumEnemyLevel then
		return nil, "PoB's native maximum enemy level is unavailable; the scenario cannot be certified"
	end
	if not isFinite(level) or level ~= math.floor(level) or level < 1 or level > maximumEnemyLevel then
		return nil, "PoB enemy level must be a whole number from 1 to " .. tostring(maximumEnemyLevel)
	end
	return level
end

local function applyEnemyLevel(configTab, level)
	if level == nil then return true end
	local configSet = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	if not configSet or type(configSet.input) ~= "table" or type(configSet.placeholder) ~= "table" then
		return false, "The isolated PoB configuration cannot accept an enemy-level override"
	end
	configSet.input.enemyLevel = level
	configSet.placeholder.enemyLevel = nil
	configTab.input = configSet.input
	configTab.placeholder = configSet.placeholder
	return true
end

function scenario.CloneConfiguration(source, proxyBuild, variant, options, configSetId, enemyPreset, enemyLevel)
	options = options or require("Modules.ConfigOptions")
	local presetValid, presetError = validateEnemyPreset(enemyPreset, options)
	if not presetValid then return nil, presetError end
	local validatedEnemyLevel, enemyLevelError = validateEnemyLevel(enemyLevel, proxyBuild)
	if enemyLevelError then return nil, enemyLevelError end
	local configTab, cloneError = cloneConfigTab(source, proxyBuild, options, configSetId)
	if not configTab then return nil, cloneError end
	local applied, applyError = applyConfigurationChoices(configTab, variant)
	if not applied then return nil, applyError end
	local enemyApplied, enemyError = applyEnemyPreset(configTab, enemyPreset)
	if not enemyApplied then return nil, enemyError end
	local enemyLevelApplied, enemyLevelApplyError = applyEnemyLevel(configTab, validatedEnemyLevel)
	if not enemyLevelApplied then return nil, enemyLevelApplyError end
	if type(configTab.BuildModList) ~= "function" then
		return nil, "PoB cannot rebuild the isolated configuration choices"
	end
	local ok, err = pcall(configTab.BuildModList, configTab)
	if not ok then
		return nil, "PoB rejected the isolated configuration choices: " .. tostring(err)
	end
	configTab.build = proxyBuild
	return configTab
end

local function cloneItemsTab(source, itemSetId, disableFlasks)
	if not source or type(source.orderedSlots) ~= "table" then
		return nil, "The equipped item-slot state cannot be cloned"
	end
	local activeId = itemSetId or source.activeItemSetId
	local sourceSet = source.itemSets and source.itemSets[activeId]
	if not sourceSet and activeId == source.activeItemSetId then sourceSet = source.activeItemSet end
	if not sourceSet then
		return nil, "The selected PoB item set is unavailable"
	end
	if disableFlasks == nil then disableFlasks = true end

	local itemsTab = shallowCopy(source)
	setmetatable(itemsTab, getmetatable(source))
	itemsTab.items = shallowCopy(source.items)
	for itemId, item in pairs(itemsTab.items) do
		if item and item.jewelData then
			local itemCopy = shallowCopy(item)
			itemCopy.jewelData = shallowCopy(item.jewelData)
			itemCopy.jewelData.limitDisabled = nil
			setmetatable(itemCopy, getmetatable(item))
			itemsTab.items[itemId] = itemCopy
		end
	end
	local itemSet = shallowCopy(sourceSet)
	for key, value in pairs(sourceSet) do
		if type(value) == "table" then itemSet[key] = shallowCopy(value) end
	end
	local itemSets = shallowCopy(source.itemSets)
	itemSets[activeId] = itemSet
	itemsTab.itemSets = itemSets
	itemsTab.activeItemSetId = activeId
	itemsTab.activeItemSet = itemSet
	itemsTab.orderedSlots = { }
	local disabled = 0
	for index, slot in ipairs(source.orderedSlots) do
		local slotCopy = shallowCopy(slot)
		local key = slot.slotName or slot.nodeId
		local selected = key and itemSet[key]
		if selected then
			slotCopy.selItemId = selected.selItemId
			slotCopy.active = selected.active
		end
		local item = source.items and source.items[slotCopy.selItemId]
		if disableFlasks and item and (item.type == "Flask" or item.type == "Tincture") then
			if slotCopy.active then disabled = disabled + 1 end
			slotCopy.active = false
			if selected then selected.active = false end
		end
		itemsTab.orderedSlots[index] = slotCopy
	end
	return itemsTab, nil, disabled
end

-- Return an isolated native ItemsTab for a specified item set. Progression
-- audits keep flasks active; Pinnacle scenarios retain the historical default
-- of disabling them through Scenario.Create below.
function scenario.CloneItemsTab(source, itemSetId, disableFlasks)
	return cloneItemsTab(source, itemSetId, disableFlasks == true)
end

local function killConfigOption(var)
	local name = tostring(var or ""):lower()
	return (name:match("^condition.*kill") or name:match("^multiplier.*kill")) ~= nil
end

function scenario.Create(build, profile, proxyBuild, options, configurationVariant, requestedEnemyPreset, requestedEnemyLevel)
	profile = tostring(profile or "Current")
	options = options or require("Modules.ConfigOptions")
	requestedEnemyPreset = tostring(requestedEnemyPreset or "Active")
	local presetValid, presetError = validateEnemyPreset(requestedEnemyPreset, options)
	if not presetValid then return nil, nil, nil, presetError end
	local enemyLevelOverride, enemyLevelError = validateEnemyLevel(requestedEnemyLevel, proxyBuild)
	if enemyLevelError then return nil, nil, nil, enemyLevelError end
	if profile == "Current" then
		local configTab = build.configTab
		if configurationVariant or requestedEnemyPreset ~= "Active" or enemyLevelOverride then
			local cloneError
			configTab, cloneError = scenario.CloneConfiguration(build.configTab, proxyBuild, configurationVariant, options, nil, requestedEnemyPreset, enemyLevelOverride)
			if not configTab then return nil, nil, nil, cloneError end
		end
		local assumptions, fields = collectConditionalAssumptions(configTab, options)
		local enemyIsBoss = resolvedEnemyPreset(configTab, options)
		return configTab, build.itemsTab, {
			profile = "Current",
			description = requestedEnemyPreset ~= "Active"
				and ("Uses the current PoB configuration and active item slots with the isolated native enemy preset " .. enemyIsBoss .. ".")
				or configurationVariant and "Uses an isolated native PoB Bandit/Pantheon configuration variant and the active item slots."
				or "Uses the currently selected PoB configuration and active item slots.",
			configurationVariant = configurationVariant and configurationChoices.Label(configurationVariant) or nil,
			requestedEnemyPreset = requestedEnemyPreset,
			enemyIsBoss = enemyIsBoss,
			enemyLevelOverride = enemyLevelOverride,
			resolvedEnemyLevel = tonumber(configTab.enemyLevel),
			enemyLevelScope = enemyLevelOverride and "native_enemy_level_only_no_area_specific_monster_data" or nil,
			preservedConditionalAssumptions = assumptions,
			preservedConditionalFields = fields,
		}
	end
	if profile ~= "PinnacleUnbuffed" and profile ~= "PinnacleChassis" then
		return nil, nil, nil, "Unsupported scenario profile: " .. profile
	end
	if requestedEnemyPreset ~= "Active" and requestedEnemyPreset ~= "Pinnacle" and requestedEnemyPreset ~= "Uber" then
		return nil, nil, nil, "Pinnacle scenario profiles require the native Pinnacle or Uber enemy preset"
	end
	local enemyIsBoss = requestedEnemyPreset == "Active" and "Pinnacle" or requestedEnemyPreset

	local configTab, configError = cloneConfigTab(build.configTab, proxyBuild, options)
	if not configTab then return nil, nil, nil, configError end
	local choicesApplied, choicesError = applyConfigurationChoices(configTab, configurationVariant)
	if not choicesApplied then return nil, nil, nil, choicesError end
	local itemsTab, itemError, disabledFlasks = cloneItemsTab(build.itemsTab, nil, true)
	if not itemsTab then return nil, nil, nil, itemError end

	local input = configTab.configSets[configTab.activeConfigSetId].input
	local placeholder = configTab.configSets[configTab.activeConfigSetId].placeholder
	local chassis = profile == "PinnacleChassis"
	local clearedAilmentFields, clearedEnemyFields = { }, { }
	local clearedChargeState = clearChargeState(configTab, options)
	local function clearFields(fields, cleared)
		for _, key in ipairs(fields) do
			if input[key] ~= nil or placeholder[key] ~= nil then cleared[#cleared + 1] = key end
			input[key], placeholder[key] = nil, nil
		end
	end
	if chassis then
		clearFields(chassisAilmentFields, clearedAilmentFields)
		clearFields(chassisEnemyFields, clearedEnemyFields)
	end
	local enemyLevelApplied, enemyLevelApplyError = applyEnemyLevel(configTab, enemyLevelOverride)
	if not enemyLevelApplied then return nil, nil, nil, enemyLevelApplyError end
	input.enemyIsBoss = enemyIsBoss
	placeholder.enemyIsBoss = nil
	input.conditionUsingFlask = nil
	local disabledKillOptions = 0
	for _, option in ipairs(options) do
		if killConfigOption(option.var) then
			if input[option.var] ~= nil or placeholder[option.var] ~= nil then disabledKillOptions = disabledKillOptions + 1 end
			input[option.var] = nil
			placeholder[option.var] = nil
		end
	end
	local removedCustomModLines = 0
	local retainedCustomModLines = 0
	for _, block in ipairs(configTab.configSets[configTab.activeConfigSetId].customModsList or { }) do
		local removed, retained
		block.text, removed, retained = stripKillLines(block.text)
		removedCustomModLines = removedCustomModLines + removed
		retainedCustomModLines = retainedCustomModLines + retained
	end
	if input.customMods then
		local removed, retained
		input.customMods, removed, retained = stripKillLines(input.customMods)
		removedCustomModLines = removedCustomModLines + removed
		retainedCustomModLines = retainedCustomModLines + retained
	end
	local disabledCustomModLines = 0
	if chassis then
		-- Unparsed user formulae can force arbitrary enemy states or guard-like
		-- protection. A chassis profile must not silently certify those claims.
		disabledCustomModLines = retainedCustomModLines
		for _, block in ipairs(configTab.configSets[configTab.activeConfigSetId].customModsList or { }) do
			block.text, block.enabled = "", false
		end
		input.customMods = nil
		retainedCustomModLines = 0
	end

	if type(configTab.BuildModList) ~= "function" then
		return nil, nil, nil, "PoB cannot rebuild the isolated Pinnacle configuration"
	end
	local ok, err = pcall(configTab.BuildModList, configTab)
	if not ok then
		return nil, nil, nil, "PoB rejected the isolated Pinnacle configuration: " .. tostring(err)
	end
	configTab.build = proxyBuild
	local assumptions, fields = collectConditionalAssumptions(configTab, options)
	return configTab, itemsTab, {
		profile = profile,
		configurationVariant = configurationVariant and configurationChoices.Label(configurationVariant) or nil,
		requestedEnemyPreset = requestedEnemyPreset,
		enemyLevelOverride = enemyLevelOverride,
		resolvedEnemyLevel = tonumber(configTab.enemyLevel),
		enemyLevelScope = enemyLevelOverride and "native_enemy_level_only_no_area_specific_monster_data" or nil,
		description = chassis
			and ("Exact PoB " .. (enemyIsBoss == "Uber" and "Uber pinnacle" or "Pinnacle") .. " defaults; ordinary flask/tincture slots, kill states, Guard buffs, manual ailment overrides, manual charge counts, charge-like event stacks, and custom modifiers are disabled. Native minimum charge floors remain. PoB may retain only its native permanent magic utility flasks (such as Mageblood); Pathfinder alone does not certify flask uptime. Hit-derived ailment and generated-charge uptime are not simulated.")
			or ("Exact PoB " .. (enemyIsBoss == "Uber" and "Uber pinnacle" or "Pinnacle") .. " calculation with ordinary flask/tincture slots, kill states, manually configured charge counts, and charge-like event stacks disabled. Native minimum charge floors remain. PoB may retain only its native permanent magic utility flasks (such as Mageblood); Pathfinder alone does not certify flask uptime. Other configured conditions and custom modifiers are preserved. Generated-charge and hit-derived ailment uptime are not simulated."),
		disabledFlasks = disabledFlasks,
		disabledKillOptions = disabledKillOptions,
		removedCustomModLines = removedCustomModLines,
		retainedCustomModLines = retainedCustomModLines,
		disabledCustomModLines = disabledCustomModLines,
		clearedAilmentFields = clearedAilmentFields,
		clearedEnemyFields = clearedEnemyFields,
		clearedChargeState = clearedChargeState,
		chargePolicy = "manual_charge_stacks_removed_native_minimum_floors_retained",
		guardBuffsExcluded = chassis,
		ailmentPolicy = chassis and "native_guaranteed_no_manual_overrides" or "current_configuration",
		preservedConditionalAssumptions = assumptions,
		preservedConditionalFields = fields,
		enemyIsBoss = input.enemyIsBoss,
	}
end

return scenario
