-- Path of Building
--
-- Module: Optimizer Inputs
-- Converts the Matrix UI into immutable, typed constraints for one run.
--
local t_insert = table.insert
local json = require("dkjson")
local SpatialZones = require("Modules.Optimizer.SpatialZones")
local Equipment = require("Modules.Optimizer.Equipment")
local MarketBudget = require("Modules.Optimizer.MarketBudget")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local Ranking = require("Modules.Optimizer.Ranking")
local ConfigOptions = require("Modules.ConfigOptions")

local inputs = { }

inputs.scenarioProfiles = {
	Current = "Current",
	PinnacleUnbuffed = "PinnacleUnbuffed",
	PinnacleChassis = "PinnacleChassis",
}

inputs.scenarioEnemyPresets = { Active = "Active" }
for _, option in ipairs(ConfigOptions) do
	if option.var == "enemyIsBoss" then
		for _, choice in ipairs(option.list or { }) do
			if type(choice.val) == "string" then inputs.scenarioEnemyPresets[choice.val] = choice.val end
		end
		break
	end
end

inputs.generationPhases = {
	tree = "tree",
	skills = "skills",
	equipment = "equipment",
	combined = "combined",
}

inputs.damageFoci = {
	Auto = "Auto",
	PhysicalHit = "PhysicalHit",
	PhysicalImpale = "PhysicalImpale",
	PhysicalDoT = "PhysicalDoT",
	Fire = "Fire",
	Cold = "Cold",
	Lightning = "Lightning",
	ChaosPoison = "ChaosPoison",
	Minions = "Minions",
}

inputs.defenseProfiles = {
	Auto = "Auto",
	Life = "Life",
	EnergyShield = "EnergyShield",
	Hybrid = "Hybrid",
	Ward = "Ward",
	Armour = "Armour",
	Evasion = "Evasion",
	Block = "Block",
	SpellBlock = "SpellBlock",
	SpellSuppression = "SpellSuppression",
}

inputs.rankingPriorities = {
	ObjectiveFirst = "ObjectiveFirst",
	DefenseFirst = "DefenseFirst",
}

inputs.metricDefinitions = {
	{ key = "TotalEHP", label = "Minimum EHP", unit = "" },
	{ key = "Life", label = "Minimum Life", unit = "" },
	{ key = "EnergyShield", label = "Minimum Energy Shield", unit = "" },
	{ key = "Ward", label = "Minimum Ward", unit = "" },
	{ key = "Str", label = "Minimum Strength", unit = "" },
	{ key = "Dex", label = "Minimum Dexterity", unit = "" },
	{ key = "Int", label = "Minimum Intelligence", unit = "" },
	{ key = "Omni", label = "Minimum Omniscience", unit = "" },
	{ key = "LifeReserved", label = "Life reserved", unit = "" },
	{ key = "LifeReservedMax", metricKey = "LifeReserved", operator = "<=", label = "Life reserved max", unit = "" },
	{ key = "LifeUnreserved", label = "Unreserved life", unit = "" },
	{ key = "LifeReservedPercentMax", metricKey = "LifeReservedPercent", operator = "<=", label = "Life reserve max", unit = "%" },
	{ key = "ManaReserved", label = "Mana reserved", unit = "" },
	{ key = "ManaReservedMax", metricKey = "ManaReserved", operator = "<=", label = "Mana reserved max", unit = "" },
	{ key = "ManaUnreserved", label = "Unreserved mana", unit = "" },
	{ key = "ManaReservedPercentMax", metricKey = "ManaReservedPercent", operator = "<=", label = "Mana reserve max", unit = "%" },
	{ key = "LifeSustainMargin", label = "Selected-skill life regen-only margin", unit = "/s" },
	{ key = "ManaSustainMargin", label = "Selected-skill mana/ES regen-only margin", unit = "/s" },
	{ key = "LifeLeechGainRate", label = "Life leech/on-hit recovery", unit = "/s" },
	{ key = "ManaLeechGainRate", label = "Mana leech/on-hit recovery", unit = "/s" },
	{ key = "EnergyShieldLeechGainRate", label = "ES leech/on-hit recovery", unit = "/s" },
	{ key = "PhysicalMaximumHitTaken", label = "Physical max hit", unit = "" },
	{ key = "FireMaximumHitTaken", label = "Fire max hit", unit = "" },
	{ key = "ColdMaximumHitTaken", label = "Cold max hit", unit = "" },
	{ key = "LightningMaximumHitTaken", label = "Lightning max hit", unit = "" },
	{ key = "ChaosMaximumHitTaken", label = "Chaos max hit", unit = "" },
	{ key = "FireResist", label = "Fire resistance", unit = "%" },
	{ key = "ColdResist", label = "Cold resistance", unit = "%" },
	{ key = "LightningResist", label = "Lightning resistance", unit = "%" },
	{ key = "ChaosResist", label = "Chaos resistance", unit = "%" },
	{ key = "FireResistOverCap", label = "Minimum fire resistance overcap", unit = "%" },
	{ key = "ColdResistOverCap", label = "Minimum cold resistance overcap", unit = "%" },
	{ key = "LightningResistOverCap", label = "Minimum lightning resistance overcap", unit = "%" },
	{ key = "ChaosResistOverCap", label = "Minimum chaos resistance overcap", unit = "%" },
	{ key = "BlockChance", label = "Block chance", unit = "%" },
	{ key = "SpellBlockChance", label = "Spell block chance", unit = "%" },
	{ key = "SpellSuppressionChance", label = "Spell suppression", unit = "%" },
	{ key = "Armour", label = "Armour", unit = "" },
	{ key = "Evasion", label = "Evasion", unit = "" },
	{ key = "CombinedDPS", label = "Minimum selected-skill DPS", unit = "" },
	{ key = "FullDPS", label = "Minimum full-build DPS", unit = "" },
	{ key = "FullDotDPS", label = "Minimum full-build DoT DPS", unit = "" },
	{ key = "CritChance", label = "Critical strike chance", unit = "%" },
	{ key = "CritMultiplier", label = "Critical multiplier", unit = "x" },
	{ key = "ActionSpeedMod", label = "Action speed", unit = "x" },
	{ key = "Speed", label = "Attack / cast rate", unit = "/s" },
	{ key = "SkillTriggerRate", label = "Minimum trigger rate", unit = "/s" },
	{ key = "ImpaleDPS", label = "Minimum Impale DPS", unit = "" },
}

inputs.objectives = {
	CombinedDPS = "CombinedDPS",
	FullDPS = "FullDPS",
	FullDotDPS = "FullDotDPS",
	TotalEHP = "TotalEHP",
	Speed = "Speed",
}

local metricDefinitionByKey = { }
for _, definition in ipairs(inputs.metricDefinitions) do
	metricDefinitionByKey[definition.key] = definition
end

local function parseNumber(value)
	if value == nil then
		return nil
	end
	local text = tostring(value):gsub("%s", ""):gsub(",", ".")
	if text == "" then
		return nil
	end
	return tonumber(text)
end

local function parseActivityScheduleState(value)
	local text = tostring(value or "")
	if text == "" then return nil end
	if #text > 32768 then return nil, "Activity schedule exceeds the 32,768-character limit" end
	local ok, state, _, decodeError = pcall(json.decode, text)
	if not ok or type(state) ~= "table" then
		return nil, "Activity schedule must be valid JSON" .. (decodeError and (": " .. tostring(decodeError)) or "")
	end
	if state.optimizerGateEnabled ~= true then return nil end
	if state.version ~= 1 then return nil, "Optimizer activity schedule version must be 1" end
	local scope = state.optimizerGateScope
	if scope ~= "full_dps" and scope ~= "all_enabled_skills" then
		return nil, "Optimizer activity gate scope must be Full DPS or All enabled skills; Main Skill is diagnostic only"
	end
	local rows = type(state.scopes) == "table" and state.scopes[scope] or nil
	if type(rows) ~= "table" then return nil, "The selected optimizer activity gate has no saved schedule rows" end
	local count, highestIndex = 0, 0
	for key in pairs(rows) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			return nil, "Optimizer activity schedule rows must be a dense array"
		end
		count = count + 1
		highestIndex = math.max(highestIndex, key)
	end
	if count < 1 or count > 64 or count ~= highestIndex then
		return nil, "Optimizer activity schedule must contain 1 to 64 dense rows"
	end
	local activities, identities = { }, { }
	for index, row in ipairs(rows) do
		if type(row) ~= "table" then return nil, "Optimizer activity schedule row " .. index .. " must be an object" end
		local identity = row.identity
		if type(identity) ~= "string" or identity == "" or #identity > 256 then
			return nil, "Optimizer activity schedule row " .. index .. " has no valid PoB activity identity"
		end
		if identities[identity] then return nil, "Optimizer activity schedule repeats a PoB activity identity" end
		identities[identity] = true
		local mode = row.mode
		if mode ~= "continuous" and mode ~= "scheduled" and mode ~= "alternative" and mode ~= "setup" then
			return nil, "Optimizer activity schedule row " .. index .. " has an unsupported use mode"
		end
		local entry = { identity = identity, mode = mode }
		if mode ~= "continuous" then
			local ratePercent = parseNumber(row.ratePercentText or row.ratePercent)
			if type(ratePercent) ~= "number" or ratePercent ~= ratePercent
				or ratePercent == math.huge or ratePercent == -math.huge or ratePercent < 0 or ratePercent > 100 then
				return nil, "Optimizer activity schedule row " .. index .. " needs an average-use rate from 0 to 100%"
			end
			entry.ratePercent = ratePercent
		end
		if mode == "alternative" then
			local package = tostring(row.package or ""):match("^%s*(.-)%s*$")
			if package == "" or #package > 48 then
				return nil, "Optimizer alternative activity row " .. index .. " needs a package name of 1 to 48 characters"
			end
			entry.package = package
		end
		local requires = row.requires
		if type(requires) == "string" then
			requires = requires ~= "" and { requires } or nil
		end
		if requires ~= nil then
			if type(requires) ~= "table" or #requires < 1 or #requires > 8 then
				return nil, "Optimizer activity schedule row " .. index .. " has an invalid prerequisite list"
			end
			entry.requires = { }
			for _, requiredIdentity in ipairs(requires) do
				if type(requiredIdentity) ~= "string" or requiredIdentity == "" or #requiredIdentity > 256 then
					return nil, "Optimizer activity schedule row " .. index .. " has an invalid prerequisite identity"
				end
				entry.requires[#entry.requires + 1] = requiredIdentity
			end
		end
		activities[#activities + 1] = entry
	end
	return { scope = scope, activities = activities }
end

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- PoB does not persist Labyrinth quest completion in a build. Use a conservative
-- progression ceiling so a low-level plan cannot silently allocate endgame
-- ascendancy routes. Users may lower this ceiling when fewer Labs are complete.
function inputs.MaxAscendancyPointBudget(level)
	level = tonumber(level) or 1
	if not isFinite(level) then return 0 end
	level = math.floor(math.max(1, math.min(100, level)))
	if level >= 68 then return 8 end
	if level >= 50 then return 6 end
	if level >= 40 then return 4 end
	if level >= 33 then return 2 end
	return 0
end

function inputs.AscendancyPointBudgetAtLevel(level, requestedBudget)
	local levelBudget = inputs.MaxAscendancyPointBudget(level)
	if requestedBudget == nil then return levelBudget end
	return math.min(levelBudget, requestedBudget)
end

local function splitList(value)
	local result = { }
	local seen = { }
	for entry in tostring(value or ""):gmatch("[^,]+") do
		local name = entry:match("^%s*(.-)%s*$")
		if name ~= "" and not seen[name:lower()] then
			seen[name:lower()] = true
			t_insert(result, name)
		end
	end
	return result
end

local function splitNodeIds(value, label)
	local result, seen = { }, { }
	for _, entry in ipairs(splitList(value)) do
		local nodeId = tonumber(entry)
		if not nodeId or nodeId < 1 or nodeId ~= math.floor(nodeId) or nodeId > 2147483647 then
			return nil, label .. " must contain positive integer node IDs separated by commas"
		end
		if not seen[nodeId] then
			seen[nodeId] = true
			result[#result + 1] = nodeId
		end
		if #result > 32 then return nil, label .. " is limited to 32 node IDs per run" end
	end
	return result
end

function inputs.Parse(textValues)
	local parsed = {
		hard = { },
		objective = "CombinedDPS",
		scenarioProfile = "Current",
		targetNodeIds = { },
		conversion = { route = { }, minPercent = 100 },
		branch = {
			partition = "class",
			required = splitList(textValues.requiredRegions),
			allowed = splitList(textValues.allowedRegions),
			forbidden = splitList(textValues.forbiddenRegions),
		},
		search = { },
		preferences = { damageFocus = "Auto", defenseProfile = "Auto", rankingPriority = "ObjectiveFirst" },
	}
	local activitySchedule, activityScheduleError = parseActivityScheduleState(textValues.activityScheduleJson)
	if activityScheduleError then return nil, activityScheduleError end
	parsed.search.activitySchedule = activitySchedule
	local preferenceDefinitions = {
		{ key = "damageFocus", choices = inputs.damageFoci, label = "Damage focus", default = "Auto" },
		{ key = "defenseProfile", choices = inputs.defenseProfiles, label = "Defense profile", default = "Auto" },
		{ key = "rankingPriority", choices = inputs.rankingPriorities, label = "Candidate ranking priority", default = "ObjectiveFirst" },
	}
	for _, definition in ipairs(preferenceDefinitions) do
		local text = tostring(textValues[definition.key] or definition.default):gsub("^%s*(.-)%s*$", "%1")
		if text == "" then text = definition.default end
		local canonical
		for key, value in pairs(definition.choices) do
			if key:lower() == text:lower() then canonical = value break end
		end
		if not canonical then return nil, definition.label .. " is not a supported option" end
		parsed.preferences[definition.key] = canonical
	end
	local nodePotentialText = tostring(textValues.nodePotentialAnalysis or "false"):lower()
	if nodePotentialText == "true" then
		parsed.search.nodePotentialAnalysis = true
	elseif nodePotentialText == "false" or nodePotentialText == "" then
		parsed.search.nodePotentialAnalysis = false
	else
		return nil, "Node-potential analysis must be true or false"
	end
	local equipmentOverrides, equipmentError = Equipment.ParseOverrides(textValues.requiredItemsJson)
	if not equipmentOverrides then return nil, equipmentError end
	parsed.search.equipmentOverrides = equipmentOverrides
	local marketBudget, marketBudgetError = MarketBudget.Parse(textValues)
	if not marketBudget and marketBudgetError then return nil, marketBudgetError end
	parsed.search.currencyBudget = marketBudget
	for _, definition in ipairs(inputs.metricDefinitions) do
		local value = parseNumber(textValues[definition.key])
		if textValues[definition.key] and tostring(textValues[definition.key]):match("%S") and value == nil then
			return nil, definition.label .. " must be a number"
		end
		if value ~= nil and not isFinite(value) then
			return nil, definition.label .. " must be finite"
		end
		if value ~= nil then
			parsed.hard[definition.key] = {
				operator = definition.operator or ">=",
				metricKey = definition.metricKey or definition.key,
				value = value,
				label = definition.label,
			}
		end
	end
	local objective = tostring(textValues.objectiveMetric or "CombinedDPS"):gsub("^%s*(.-)%s*$", "%1")
	if objective == "" then objective = "CombinedDPS" end
	if not inputs.objectives[objective] then
		return nil, "Objective must be CombinedDPS, FullDPS, FullDotDPS, TotalEHP, or Speed"
	end
	parsed.objective = objective
	local scenarioText = tostring(textValues.scenarioProfile or "Current"):gsub("^%s*(.-)%s*$", "%1")
	if scenarioText == "" then scenarioText = "Current" end
	local scenarioProfile = inputs.scenarioProfiles[scenarioText]
	if not scenarioProfile then
		for key, value in pairs(inputs.scenarioProfiles) do
			if key:lower() == scenarioText:lower() then scenarioProfile = value end
		end
	end
	if not scenarioProfile then
		return nil, "Scenario profile must be Current, PinnacleUnbuffed, or PinnacleChassis"
	end
	parsed.scenarioProfile = scenarioProfile
	local enemyPresetText = tostring(textValues.scenarioEnemyPreset or "Active"):gsub("^%s*(.-)%s*$", "%1")
	if enemyPresetText == "" then enemyPresetText = "Active" end
	local scenarioEnemyPreset
	for key, value in pairs(inputs.scenarioEnemyPresets) do
		if key:lower() == enemyPresetText:lower() then scenarioEnemyPreset = value break end
	end
	if not scenarioEnemyPreset then
		return nil, "Enemy preset must be Active, None, Boss, Pinnacle, or Uber from PoB's native enemy options"
	end
	if scenarioProfile ~= "Current" and scenarioEnemyPreset ~= "Active"
		and scenarioEnemyPreset ~= "Pinnacle" and scenarioEnemyPreset ~= "Uber" then
		return nil, "Pinnacle scenario profiles require the native Pinnacle or Uber enemy preset"
	end
	parsed.scenarioEnemyPreset = scenarioEnemyPreset
	local enemyLevelText = tostring(textValues.scenarioEnemyLevel or ""):gsub("^%s*(.-)%s*$", "%1")
	if enemyLevelText ~= "" then
		local enemyLevel = tonumber(enemyLevelText)
		local nativeData = rawget(_G, "data")
		local maximumEnemyLevel = tonumber(nativeData and nativeData.misc and nativeData.misc.MaxEnemyLevel) or 85
		if not isFinite(enemyLevel) or enemyLevel ~= math.floor(enemyLevel) then
			return nil, "PoB enemy level must be a whole number"
		end
		if enemyLevel < 1 or enemyLevel > maximumEnemyLevel then
			return nil, "PoB enemy level must be between 1 and " .. tostring(maximumEnemyLevel)
		end
		parsed.scenarioEnemyLevel = enemyLevel
	end
	local generationPhaseText = tostring(textValues.generationPhase or "combined"):gsub("^%s*(.-)%s*$", "%1")
	if generationPhaseText == "" then generationPhaseText = "combined" end
	local generationPhase = generationPhaseText:lower()
	if not inputs.generationPhases[generationPhase] then
		return nil, "Generation phase must be tree, skills, equipment, or combined"
	end
	parsed.search.generationPhase = generationPhase
	local targetNodeValues = splitList(textValues.targetNodeIds)
	if #targetNodeValues > 1 then return nil, "Target one passive node per search; run separate searches to compare targets" end
	local seenTargetNodes = { }
	for _, value in ipairs(targetNodeValues) do
		local nodeId = tonumber(value)
		if not nodeId or nodeId < 1 or nodeId ~= math.floor(nodeId) or nodeId > 2147483647 then
			return nil, "Target passive node IDs must be positive integers separated by commas"
		end
		if not seenTargetNodes[nodeId] then
			seenTargetNodes[nodeId] = true
			t_insert(parsed.targetNodeIds, nodeId)
		end
	end
	for _, definition in ipairs({
		{ key = "addNodeIds", label = "Nodes to add" },
		{ key = "removeNodeIds", label = "Nodes to remove" },
		{ key = "requiredNodeIds", label = "Required nodes" },
		{ key = "forbiddenNodeIds", label = "Forbidden nodes" },
	}) do
		local nodeIds, nodeError = splitNodeIds(textValues[definition.key], definition.label)
		if not nodeIds then return nil, nodeError end
		parsed.search[definition.key] = nodeIds
	end
	local addSet, removeSet, requiredSet, forbiddenSet = { }, { }, { }, { }
	for _, id in ipairs(parsed.search.addNodeIds) do addSet[id] = true end
	for _, id in ipairs(parsed.search.removeNodeIds) do removeSet[id] = true end
	for _, id in ipairs(parsed.search.requiredNodeIds) do requiredSet[id] = true end
	for _, id in ipairs(parsed.search.forbiddenNodeIds) do forbiddenSet[id] = true end
	for id in pairs(addSet) do
		if removeSet[id] then return nil, "A node cannot be added and removed in the same run: " .. tostring(id) end
		if forbiddenSet[id] then return nil, "A node cannot be both added and forbidden: " .. tostring(id) end
	end
	for id in pairs(removeSet) do
		if requiredSet[id] then return nil, "A node cannot be both removed and required: " .. tostring(id) end
	end
	for id in pairs(requiredSet) do
		if forbiddenSet[id] then return nil, "A node cannot be both required and forbidden: " .. tostring(id) end
	end
	for id in pairs(seenTargetNodes) do
		if removeSet[id] then return nil, "A target node cannot also be explicitly removed: " .. tostring(id) end
		if forbiddenSet[id] then return nil, "A target node cannot also be forbidden: " .. tostring(id) end
	end

	local routeText = tostring(textValues.conversionRoute or ""):gsub("%s*%-%>%s*", ">")
	if routeText:match("%S") then
		if routeText:match("^>") or routeText:match(">$" ) or routeText:find(">>", 1, true) then
			return nil, "Conversion route contains an empty damage type"
		end
		local damageTypes = { physical = "Physical", lightning = "Lightning", cold = "Cold", fire = "Fire", chaos = "Chaos" }
		local damageOrder = { Physical = 1, Lightning = 2, Cold = 3, Fire = 4, Chaos = 5 }
		for _, damageType in ipairs(splitList(routeText:gsub(">", ","))) do
			local canonical = damageTypes[damageType:lower()]
			if not canonical then
				return nil, "Unsupported damage type in conversion route: " .. damageType
			end
			t_insert(parsed.conversion.route, canonical)
		end
		-- The route delimiter is significant; commas alone are not a damage route.
		if #parsed.conversion.route < 2 or not routeText:find(">", 1, true) then
			return nil, "Conversion route must use a chain such as Physical>Lightning>Cold"
		end
		for index = 2, #parsed.conversion.route do
			if damageOrder[parsed.conversion.route[index]] <= damageOrder[parsed.conversion.route[index - 1]] then
				return nil, "Conversion route must follow PoE order: Physical>Lightning>Cold>Fire>Chaos"
			end
		end
	end
	local conversionMin = parseNumber(textValues.conversionMin)
	if textValues.conversionMin and tostring(textValues.conversionMin):match("%S") and conversionMin == nil then
		return nil, "Conversion minimum must be a number"
	end
	if conversionMin ~= nil and not isFinite(conversionMin) then
		return nil, "Conversion minimum must be finite"
	end
	parsed.conversion.minPercent = conversionMin or 100
	if parsed.conversion.minPercent < 0 or parsed.conversion.minPercent > 100 then
		return nil, "Conversion minimum must be between 0 and 100"
	end
	local manualButtonText = tostring(textValues.maxManualButtons or ""):gsub("^%s*(.-)%s*$", "%1")
	if manualButtonText ~= "" then
		local maximum = parseNumber(manualButtonText)
		if not isFinite(maximum) or maximum < 0 or maximum > 24 or maximum ~= math.floor(maximum) then
			return nil, "Maximum manual skill buttons must be an integer from 0 to 24"
		end
		parsed.search.maxManualButtons = maximum
	end
	local manualDamageButtonText = tostring(textValues.maxManualDamageButtons or ""):gsub("^%s*(.-)%s*$", "%1")
	if manualDamageButtonText ~= "" then
		local maximum = parseNumber(manualDamageButtonText)
		if not isFinite(maximum) or maximum < 0 or maximum > 24 or maximum ~= math.floor(maximum) then
			return nil, "Maximum manual damage actions must be an integer from 0 to 24"
		end
		parsed.search.maxManualDamageButtons = maximum
	end
	local allClassesValue = textValues.searchAllClasses
	if allClassesValue == true or (type(allClassesValue) == "string" and allClassesValue:lower() == "true") then
		parsed.search.searchAllClasses = true
	elseif allClassesValue == nil or allClassesValue == false
		or (type(allClassesValue) == "string" and (allClassesValue == "" or allClassesValue:lower() == "false")) then
		parsed.search.searchAllClasses = false
	else
		return nil, "Search all classes must be true or false"
	end
	local storedItemsValue = textValues.searchStoredItems
	if storedItemsValue == nil or storedItemsValue == true
		or (type(storedItemsValue) == "string" and storedItemsValue:lower() == "true") then
		parsed.search.searchStoredItems = true
	elseif storedItemsValue == false or (type(storedItemsValue) == "string"
		and (storedItemsValue == "" or storedItemsValue:lower() == "false")) then
		parsed.search.searchStoredItems = false
	else
		return nil, "Search stored items must be true or false"
	end
	local syntheticGearValue = textValues.searchSyntheticGear
	if syntheticGearValue == true or (type(syntheticGearValue) == "string" and syntheticGearValue:lower() == "true") then
		parsed.search.searchSyntheticGear = true
	elseif syntheticGearValue == nil or syntheticGearValue == false
		or (type(syntheticGearValue) == "string" and (syntheticGearValue == "" or syntheticGearValue:lower() == "false")) then
		parsed.search.searchSyntheticGear = false
	else
		return nil, "Search synthetic gear must be true or false"
	end
	local syntheticLevelText = tostring(textValues.syntheticItemLevel or ""):gsub("^%s*(.-)%s*$", "%1")
	if syntheticLevelText ~= "" then
		local itemLevel = parseNumber(syntheticLevelText)
		if not isFinite(itemLevel) or itemLevel < 1 or itemLevel > 100 or itemLevel ~= math.floor(itemLevel) then
			return nil, "Synthetic item level must be an integer from 1 to 100"
		end
		parsed.search.syntheticItemLevel = itemLevel
	end
	local syntheticCostText = tostring(textValues.syntheticItemCostChaos or ""):gsub("^%s*(.-)%s*$", "%1")
	if syntheticCostText ~= "" then
		local itemCost = parseNumber(syntheticCostText)
		if not isFinite(itemCost) or itemCost < 0 or itemCost > 1000000000 then
			return nil, "Synthetic item cost must be a finite Chaos-equivalent amount from 0 to 1000000000"
		end
		parsed.search.syntheticItemCostChaos = itemCost
	end
	local catalystCostText = tostring(textValues.catalystCostChaos or ""):gsub("^%s*(.-)%s*$", "%1")
	if catalystCostText ~= "" then
		local catalystCost = parseNumber(catalystCostText)
		if not isFinite(catalystCost) or catalystCost < 0 or catalystCost > 1000000000 then
			return nil, "Catalyst cost must be a finite Chaos-equivalent amount from 0 to 1000000000"
		end
		parsed.search.catalystCostChaos = catalystCost
	end

	for key, defaultValue in pairs({ maxAddedPoints = 5, maxTotalPoints = 120, evaluationBudget = 120, seed = 1 }) do
		local value = parseNumber(textValues[key])
		if value == nil then
			value = defaultValue
		end
		if not isFinite(value) or value < 0 or value ~= math.floor(value) then
			return nil, key .. " must be a non-negative integer"
		end
		parsed.search[key] = value
	end
	local proposalBudget = parseNumber(textValues.proposalBudget)
	if proposalBudget == nil then proposalBudget = parsed.search.evaluationBudget end
	if not isFinite(proposalBudget) or proposalBudget < 1 or proposalBudget > 100000 or proposalBudget ~= math.floor(proposalBudget) then
		return nil, "Proposal budget must be an integer from 1 to 100000"
	end
	parsed.search.proposalBudget = math.max(proposalBudget, parsed.search.evaluationBudget)
	local timeoutSeconds = parseNumber(textValues.timeoutSeconds)
	if timeoutSeconds == nil then timeoutSeconds = 300 end
	if not isFinite(timeoutSeconds) or timeoutSeconds < 1 or timeoutSeconds > 3600 or timeoutSeconds ~= math.floor(timeoutSeconds) then
		return nil, "Route-search timeout must be an integer from 1 to 3600 seconds"
	end
	parsed.search.timeoutSeconds = timeoutSeconds
	local ascendancyBudgetText = tostring(textValues.ascendancyPointBudget or "auto"):gsub("^%s*(.-)%s*$", "%1")
	if ascendancyBudgetText ~= "" and ascendancyBudgetText:lower() ~= "auto" then
		local budget = parseNumber(ascendancyBudgetText)
		local supported = { [0] = true, [2] = true, [4] = true, [6] = true, [8] = true }
		if not isFinite(budget) or not supported[budget] then
			return nil, "Ascendancy point budget must be Auto, 0, 2, 4, 6, or 8"
		end
		parsed.search.ascendancyPointBudget = budget
	end
	for _, key in ipairs({ "baseClassId", "ascendancyId", "targetSkillGroupIndex", "targetSkillIndex" }) do
		local value = parseNumber(textValues[key])
		if textValues[key] and tostring(textValues[key]):match("%S") and value == nil then
			return nil, key .. " must be a non-negative integer"
		end
		if value ~= nil and (not isFinite(value) or value < 0 or value ~= math.floor(value)) then
			return nil, key .. " must be a non-negative integer"
		end
		parsed.search[key] = value
	end
	if parsed.search.ascendancyId ~= nil and generationPhase ~= "tree" and generationPhase ~= "combined" then
		return nil, "Ascendancy selection is only available in the tree foundation or combined phase"
	end
	local rawTargetSkillGemId = tostring(textValues.targetSkillGemId or "")
	if rawTargetSkillGemId:find("[%c]") then
		return nil, "targetSkillGemId must be a loaded PoB gem ID up to 100 printable characters"
	end
	local targetSkillGemId = rawTargetSkillGemId:gsub("^%s*(.-)%s*$", "%1")
	if #targetSkillGemId > 100 then
		return nil, "targetSkillGemId must be a loaded PoB gem ID up to 100 printable characters"
	end
	if targetSkillGemId ~= "" then parsed.search.targetSkillGemId = targetSkillGemId end
	local targetGroup, targetSkill = parsed.search.targetSkillGroupIndex, parsed.search.targetSkillIndex
	if parsed.search.searchAllClasses and parsed.search.baseClassId ~= nil then
		return nil, "Choose one base class or all classes, not both"
	end
	if parsed.search.searchAllClasses and parsed.search.ascendancyId ~= nil then
		return nil, "Choose one base class and ascendancy or all base classes, not both"
	end
	if parsed.search.searchAllClasses and generationPhase ~= "tree" and generationPhase ~= "combined" then
		return nil, "All-class search is available only in the tree foundation or combined phase"
	end
	if parsed.search.nodePotentialAnalysis and generationPhase ~= "combined" then
		return nil, "Node-potential analysis requires the Combined phase to preserve the current build as its baseline"
	end
	if parsed.search.nodePotentialAnalysis and parsed.search.ascendancyId ~= nil then
		return nil, "Node-potential analysis cannot lock or replace the current build's ascendancy"
	end
	if generationPhase == "tree" and #parsed.search.removeNodeIds > 0 then
		return nil, "Tree foundation starts from the selected class root; removeNodeIds is not valid in this phase"
	end
	if generationPhase ~= "tree" and generationPhase ~= "combined" then
		if #parsed.targetNodeIds > 0 or #parsed.search.addNodeIds > 0 or #parsed.search.removeNodeIds > 0
			or #parsed.search.requiredNodeIds > 0 or #parsed.search.forbiddenNodeIds > 0
			or #parsed.branch.required > 0 or #parsed.branch.allowed > 0 or #parsed.branch.forbidden > 0 then
			return nil, "Passive-node and branch constraints can only be used in the tree foundation or combined phase"
		end
	end
	if (generationPhase == "tree" or generationPhase == "skills") and next(parsed.search.equipmentOverrides) then
		return nil, "Equipment overrides can only be applied in the equipment or combined phase"
	end
	if (targetGroup == nil) ~= (targetSkill == nil) then
		return nil, "Select both a target skill group and active skill"
	end
	if parsed.search.targetSkillGemId and targetGroup == nil then
		return nil, "Select a target socket group before choosing a Main Skill gem"
	end
	if targetGroup ~= nil and (targetGroup < 1 or targetSkill < 1) then
		return nil, "Target skill group and active skill indexes must be positive"
	end
	if parsed.search.maxAddedPoints > 120 then
		return nil, "Maximum added points per proposal must be between 0 and 120"
	end
	if parsed.search.maxTotalPoints < 1 or parsed.search.maxTotalPoints > 130 then
		return nil, "Strict total passive-point cap must be between 1 and 130; PoB's exact level and quest limit is checked separately"
	end
	if parsed.search.evaluationBudget < 1 or parsed.search.evaluationBudget > 10000 then
		return nil, "Evaluation budget must be between 1 and 10000"
	end
	if parsed.search.seed > 2147483646 then
		return nil, "Seed must be less than 2147483647"
	end

	return parsed
end

local selectedSkillMetrics = {
	CombinedDPS = true,
	ImpaleDPS = true,
	CritChance = true,
	CritMultiplier = true,
	ActionSpeedMod = true,
	Speed = true,
	SkillTriggerRate = true,
	LifeSustainMargin = true,
	ManaSustainMargin = true,
	LifeLeechGainRate = true,
	ManaLeechGainRate = true,
	EnergyShieldLeechGainRate = true,
}

local function requiresSelectedSkill(parsed)
	if not parsed then return true end
	if parsed.objective == "CombinedDPS" or parsed.objective == "Speed" then return true end
	if parsed.preferences and parsed.preferences.damageFocus ~= "Auto" then return true end
	if parsed.conversion and #(parsed.conversion.route or { }) > 0 then return true end
	for key, constraint in pairs(parsed.hard or { }) do
		if selectedSkillMetrics[constraint.metricKey or key] then return true end
	end
	return false
end

function inputs.ValidateBuild(build, parsed)
	if not build or not build.spec or not build.skillsTab then
		return false, "Open a build before starting the optimizer"
	end
	if parsed and parsed.preferences and parsed.preferences.rankingPriority == "DefenseFirst" then
		local defenseMetric = Ranking.DefenseMetricKey(parsed.preferences.defenseProfile)
		local output = build.calcsTab and build.calcsTab.mainOutput
		if not isFinite(output and output[defenseMetric]) then
			return false, "PoB does not expose a finite exact " .. defenseMetric .. " metric for the selected defense-first ranking"
		end
	end
	local activeLevel = tonumber(build.characterLevel) or 1
	if build.characterLevelAutoMode and build.GetEstimatedLevelForPoints then
		local pointsUsed = build.spec.CountAllocNodes and select(1, build.spec:CountAllocNodes()) or 0
		local extra = build.calcsTab and build.calcsTab.mainOutput and build.calcsTab.mainOutput.ExtraPoints or 0
		activeLevel = build:GetEstimatedLevelForPoints(pointsUsed, extra)
	end
	local levelBudget = inputs.MaxAscendancyPointBudget(activeLevel)
	local requestedBudget = parsed and parsed.search and parsed.search.ascendancyPointBudget
	if requestedBudget ~= nil and requestedBudget > levelBudget then
		return false, string.format("Ascendancy point budget %d exceeds the conservative level %d progression ceiling of %d; PoB does not store Labyrinth completion, so lower the cap or set the character level in PoB", requestedBudget, activeLevel, levelBudget)
	end
	if parsed and parsed.search then
		parsed.search.activeCharacterLevel = activeLevel
		parsed.search.activeAscendancyPointBudget = inputs.AscendancyPointBudgetAtLevel(activeLevel, requestedBudget)
	end
	local equipmentOverrides = parsed and parsed.search and parsed.search.equipmentOverrides or { }
	if parsed and parsed.search and parsed.search.nodePotentialAnalysis and next(equipmentOverrides) then
		return false, "Node-potential analysis holds the current equipment fixed; clear equipment overrides first"
	end
	if next(equipmentOverrides) then
		local equipmentValid, equipmentError = Equipment.Validate(build, equipmentOverrides)
		if not equipmentValid then return false, equipmentError end
		local currentSet = Equipment.ActiveItemSet(build.itemsTab)
		for slotName, itemId in pairs(equipmentOverrides) do
			if currentSet and currentSet[slotName] and currentSet[slotName].selItemId == itemId then
				equipmentOverrides[slotName] = nil
			end
		end
	end
	if not requiresSelectedSkill(parsed) and not (parsed and parsed.search
		and (parsed.search.targetSkillGroupIndex or parsed.search.targetSkillGemId)) then
		-- FullDPS/FullDotDPS and defensive objectives can use the active PoB groups
		-- without an arbitrary Main Skill selector. Selected-skill constraints still
		-- require exact skill context below.
		return true
	end
	local groupIndex = parsed and parsed.search and parsed.search.targetSkillGroupIndex or build.mainSocketGroup
	local group = build.skillsTab.socketGroupList and build.skillsTab.socketGroupList[groupIndex]
	local skillIndex = parsed and parsed.search and parsed.search.targetSkillIndex or (group and group.mainActiveSkill) or 1
	local selectedSkill = group and group.displaySkillList and group.displaySkillList[skillIndex]
	local selectedSkillResolved = selectedSkill and selectedSkill.activeEffect ~= nil
	if not group or group.enabled == false or group.slotEnabled == false then
		return false, "Select an enabled Main Skill for the selected-skill objective, conversion route, or skill-specific hard constraints"
	end
	if not selectedSkillResolved then
		local repairGemId = parsed.search.targetSkillGemId
		local currentGemId = SkillCatalog.CurrentMainGemId(build, groupIndex, skillIndex)
		local repairGemData = repairGemId and build.data and build.data.gems and build.data.gems[repairGemId]
		local repairPlan = parsed.search.allowSocketRepair == true and repairGemId ~= nil
			and currentGemId == repairGemId and SkillCatalog.IsActiveSkillGem(repairGemData)
			and SkillCatalog.PlanSocketRepair(build, groupIndex, group) or nil
		if not repairPlan then
			return false, "Select an enabled Main Skill for the selected-skill objective, conversion route, or skill-specific hard constraints"
		end
	end
	if parsed and parsed.search and parsed.search.targetSkillGemId then
		local phase = tostring(parsed.search.generationPhase or "tree"):lower()
		local allowUnlinkedPlanning = phase == "tree" or phase == "skills"
		local currentGemId = SkillCatalog.CurrentMainGemId(build, groupIndex, skillIndex)
		if (phase == "equipment" or phase == "combined") and currentGemId
			and currentGemId ~= parsed.search.targetSkillGemId then
			return false, "Apply the selected Main Skill in the Skills phase first; Equipment and Combined must evaluate the gem that will remain installed when their item or tree result is applied"
		end
		local targetGem, targetGemError = SkillCatalog.ResolveTarget(
			build, groupIndex, skillIndex, parsed.search.targetSkillGemId,
			{ allowUnlinkedPlanning = allowUnlinkedPlanning,
				allowSocketRepair = parsed.search.allowSocketRepair == true })
		if not targetGem then
			if (phase == "equipment" or phase == "combined")
				and (type(group.slot) ~= "string" or group.slot == "")
				and not group.source then
				return false, "Apply the selected Main Skill in the Skills phase first; this unlinked seed needs a real socketed PoB item before Equipment can certify it"
			end
			return false, targetGemError
		end
	end
	return true
end

function inputs.ValidateObjective(build, parsed)
	if parsed.objective ~= "FullDPS" and parsed.objective ~= "FullDotDPS" then
		return true
	end
	local output = build and build.calcsTab and build.calcsTab.mainOutput
	local value = output and output[parsed.objective]
	if not isFinite(value) then
		return false, "PoB did not provide a finite " .. parsed.objective .. " value for this build"
	end
	if value > 0 then
		return true
	end
	if parsed.objective == "FullDPS" then
		local hasIncludedGroup = false
		for _, group in ipairs(build.skillsTab and build.skillsTab.socketGroupList or { }) do
			if group.includeInFullDPS and group.enabled ~= false and group.slotEnabled ~= false then
				hasIncludedGroup = true
				break
			end
		end
		if not hasIncludedGroup then
			return false, "PoB FullDPS is 0: enable Include in Full DPS on an active damage group in the Skills tab"
		end
	end
	return false, "PoB " .. parsed.objective .. " is 0 under the current skill-group and enemy configuration"
end

function inputs.ValidateAgainstTree(parsed, tree)
	local available = { }
	for _, class in pairs(tree.classes or { }) do
		if class.name then
			available[class.name:lower()] = class.name
		end
	end
	local spatialMode, classMode = false, false
	local collections = { parsed.branch.required, parsed.branch.allowed, parsed.branch.forbidden }
	for _, collection in ipairs(collections) do
		for _, name in ipairs(collection) do
			local key = name:lower()
			if SpatialZones.CanonicalRegionName(key) then
				spatialMode = true
			elseif available[key] then
				classMode = true
			else
				return false, "Unknown passive-tree region: " .. name
			end
		end
	end
	if spatialMode and classMode then
		return false, "Use either class-start regions or spatial zones in one search, not both"
	end
	parsed.branch.partition = spatialMode and "spatial" or "class"
	for _, collection in ipairs(collections) do
		for index, name in ipairs(collection) do
			local key = name:lower()
			collection[index] = SpatialZones.CanonicalRegionName(key) or available[key]
		end
	end
	for _, nodeId in ipairs(parsed.targetNodeIds or { }) do
		local node = tree.nodes and tree.nodes[nodeId]
		if not node then return false, "Target passive node does not exist in this tree version: " .. tostring(nodeId) end
		if node.type == "ClassStart" or node.type == "AscendClassStart" or node.type == "Mastery" or node.type == "Socket" then
			return false, "Target passive node type is not supported by direct path targeting: " .. tostring(nodeId)
		end
	end
	if parsed.search.baseClassId ~= nil and not (tree.classes and tree.classes[parsed.search.baseClassId]) then
		return false, "Selected base class is unavailable in this PoB tree version"
	end
	for _, key in ipairs({ "addNodeIds", "removeNodeIds", "requiredNodeIds", "forbiddenNodeIds" }) do
		for _, nodeId in ipairs(parsed.search[key] or { }) do
			local node = tree.nodes and tree.nodes[nodeId]
			if not node then return false, "Passive node does not exist in this tree version: " .. tostring(nodeId) end
			if node.type == "ClassStart" or node.type == "AscendClassStart" then
				return false, "Class and ascendancy start nodes are controlled by PoB class selection, not passive mutations: " .. tostring(nodeId)
			end
			if key == "addNodeIds" and (node.type == "Mastery" or node.type == "Socket" or node.isProxy or node.isMultipleChoiceOption or node.isTattoo) then
				return false, "Direct node addition does not support this passive type: " .. tostring(nodeId)
			end
		end
	end
	local required = { }
	for _, name in ipairs(parsed.branch.required) do
		required[name:lower()] = true
	end
	local allowed = { }
	for _, name in ipairs(parsed.branch.allowed) do
		allowed[name:lower()] = true
	end
	if next(allowed) then
		for _, name in ipairs(parsed.branch.required) do
			if not allowed[name:lower()] then
				return false, "Required region is outside the allowed branch filter: " .. name
			end
		end
	end
	for _, name in ipairs(parsed.branch.forbidden) do
		if required[name:lower()] then
			return false, "Region cannot be both required and forbidden: " .. name
		end
		if allowed[name:lower()] then
			return false, "Region cannot be both allowed and forbidden: " .. name
		end
	end
	return true
end

function inputs.ValidateAgainstBuild(parsed, spec)
	if not spec or not spec.allocNodes then return false, "The active passive spec is unavailable" end
	local requestedAscendancy
	if parsed.search.ascendancyId ~= nil then
		local classId = parsed.search.baseClassId or spec.curClassId
		local class = spec.tree.classes and spec.tree.classes[classId]
		if not class then return false, "Selected base class is unavailable for ascendancy selection" end
		requestedAscendancy = class.classes and class.classes[parsed.search.ascendancyId]
		if not requestedAscendancy then
			return false, "Selected ascendancy is unavailable to the chosen base class in this PoB tree version"
		end
	end
	local function nodeMatchesAscendancy(node, ascendancy)
		if not node or not node.ascendancyName or not ascendancy then return false end
		return node.ascendancyName == ascendancy.name or node.ascendancyName == ascendancy.id
			or node.ascendancyName == ascendancy.internalId
	end
	if parsed.search.generationPhase ~= "tree" and parsed.search.generationPhase ~= "combined"
		and parsed.search.baseClassId ~= nil and parsed.search.baseClassId ~= spec.curClassId then
		return false, "Base-class changes are only available in the tree foundation or combined phase"
	end
	if parsed.search.generationPhase == "combined" and parsed.search.baseClassId ~= nil and parsed.search.baseClassId ~= spec.curClassId
		and (#(parsed.search.removeNodeIds or { }) > 0 or #(parsed.search.addNodeIds or { }) > 0) then
		return false, "Explicit node additions/removals cannot be combined with switching to a different base class"
	end
	for _, nodeId in ipairs(parsed.search.removeNodeIds or { }) do
		if not spec.allocNodes[nodeId] then return false, "Node selected for removal is not allocated: " .. tostring(nodeId) end
	end
	for _, nodeId in ipairs(parsed.search.addNodeIds or { }) do
		local node = spec.nodes[nodeId]
		if node and node.ascendancyName then
			local selected = nodeMatchesAscendancy(node, requestedAscendancy)
				or spec.curAscendClass and spec.curAscendClass.name == node.ascendancyName
				or spec.curSecondaryAscendClass and spec.curSecondaryAscendClass.name == node.ascendancyName
			if not selected then return false, "Select the matching ascendancy in PoB before adding its passive nodes: " .. tostring(nodeId) end
		end
	end
	for _, nodeId in ipairs(parsed.search.requiredNodeIds or { }) do
		local node = spec.nodes[nodeId]
		if node and node.ascendancyName then
			local selected = nodeMatchesAscendancy(node, requestedAscendancy)
				or spec.curAscendClass and spec.curAscendClass.name == node.ascendancyName
				or spec.curSecondaryAscendClass and spec.curSecondaryAscendClass.name == node.ascendancyName
			if not selected then
				return false, "Required ascendancy node needs the matching native ascendancy selected: " .. tostring(nodeId)
			end
		end
	end
	for _, nodeId in ipairs(parsed.search.requiredNodeIds or { }) do
		local node = spec.nodes[nodeId]
		if node and not spec.allocNodes[nodeId]
			and (node.type == "Mastery" or node.type == "Socket" or node.isProxy or node.isMultipleChoiceOption or node.isTattoo) then
			return false, "Required node type needs an existing PoB allocation or a dedicated typed control: " .. tostring(nodeId)
		end
	end
	return true
end

function inputs.GetMetricDefinition(key)
	return metricDefinitionByKey[key]
end

return inputs
