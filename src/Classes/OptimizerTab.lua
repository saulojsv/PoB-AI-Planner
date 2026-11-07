-- Path of Building
--
-- Class: Optimizer Tab
-- Strict constraint Matrix and coroutine-driven exact-engine optimizer UI.
--
local t_insert = table.insert
local t_sort = table.sort

local OptimizerTabClass = newClass("OptimizerTab", "ControlHost", "Control")

local defaultStatusMessage = "Exact PoB gates. FullDPS uses included groups. Existing Items-tab gear choices can be evaluated; no crafting."

local Inputs = require("Modules.Optimizer.Inputs")
local RoutePlanner = require("Modules.Optimizer.RoutePlanner")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local ClassSearch = require("Modules.Optimizer.ClassSearch")
local Candidate = require("Modules.Optimizer.Candidate")
local ClassRoots = require("Modules.Optimizer.ClassRoots")
local Activity = require("Modules.Optimizer.Activity")
local SpatialZones = require("Modules.Optimizer.SpatialZones")
local Equipment = require("Modules.Optimizer.Equipment")
local Ranking = require("Modules.Optimizer.Ranking")
local StudyRecords = require("Modules.Optimizer.StudyRecords")
local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local BuildReviewPair = require("Modules.Optimizer.BuildReviewPair")
local BuildIngestionStatus = require("Modules.Optimizer.BuildIngestionStatus")
local Version = require("Modules.Optimizer.Version")
local GNNIPC = require("Modules.Optimizer.GNNIPC")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local SkillSeed = require("Modules.Optimizer.SkillSeed")
local Progression = require("Modules.Optimizer.Progression")
local Checkpoints = require("Modules.Optimizer.Checkpoints")
local BuildReadiness = require("Modules.Optimizer.BuildReadiness")
local DisplayText = require("Modules.Optimizer.DisplayText")
local ConfigOptions = require("Modules.ConfigOptions")
local json = require("dkjson")
local sha = require("sha2")

local RESULT_FRESHNESS_CHECK_INTERVAL = 0.5

local function drawPlannerString(x, y, align, fontSize, fontFace, text)
	DrawString(x, y, align, fontSize, fontFace, DisplayText.Native(text))
end

local function currentOptimizerContext(build)
	local spec = build and build.spec
	local groupIndex = tonumber(build and build.mainSocketGroup) or 1
	local group = build and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	local skillIndex = tonumber(group and group.mainActiveSkill) or 1
	return {
		classId = tonumber(spec and spec.curClassId),
		ascendancyId = tonumber(spec and spec.curAscendClassId) or 0,
		treeVersion = tostring(spec and spec.treeVersion or ""),
		groupIndex = group and groupIndex or nil,
		skillIndex = group and skillIndex or nil,
		gemId = group and SkillCatalog.CurrentMainGemId(build, groupIndex, skillIndex) or "",
	}
end

local function contextMatches(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	for _, key in ipairs({ "classId", "ascendancyId", "treeVersion", "groupIndex", "skillIndex", "gemId" }) do
		if tostring(left[key] or "") ~= tostring(right[key] or "") then return false end
	end
	return true
end

local function contextFromXML(attrib)
	if type(attrib) ~= "table" or tonumber(attrib.version) ~= 1 then return nil end
	return {
		classId = tonumber(attrib.classId),
		ascendancyId = tonumber(attrib.ascendancyId) or 0,
		treeVersion = tostring(attrib.treeVersion or ""),
		groupIndex = tonumber(attrib.groupIndex),
		skillIndex = tonumber(attrib.skillIndex),
		gemId = tostring(attrib.gemId or ""),
	}
end

local function optimizerContextLabel(build, context)
	local class = context and build and build.spec and build.spec.tree
		and build.spec.tree.classes[context.classId]
	local group = context and context.groupIndex and build and build.skillsTab
		and build.skillsTab.socketGroupList[context.groupIndex]
	local skill = group and context.skillIndex and group.displaySkillList
		and group.displaySkillList[context.skillIndex]
	local skillName = skill and (skill.name or skill.activeEffect and skill.activeEffect.grantedEffect
		and skill.activeEffect.grantedEffect.name)
	if (not skillName or skillName == "") and context and context.gemId and build and build.data and build.data.gems then
		local gemData = build.data.gems[context.gemId]
		skillName = gemData and gemData.name
	end
	return tostring(class and class.name or "current class") .. "/" .. tostring(skillName or "current Main Skill")
end

local function rebindOptimizerContext(tab, context, previous, legacy)
	local classChanged = legacy or not previous or tostring(previous.classId or "") ~= tostring(context.classId or "")
	local treeChanged = legacy or not previous or tostring(previous.treeVersion or "") ~= tostring(context.treeVersion or "")
	local skillChanged = legacy or not previous
		or tostring(previous.groupIndex or "") ~= tostring(context.groupIndex or "")
		or tostring(previous.skillIndex or "") ~= tostring(context.skillIndex or "")
		or tostring(previous.gemId or "") ~= tostring(context.gemId or "")
	local ascendancyChanged = legacy or not previous
		or tostring(previous.ascendancyId or "") ~= tostring(context.ascendancyId or "")
	local changed = classChanged or treeChanged or skillChanged or ascendancyChanged
	if not changed then
		tab.contextAnchor = context
		return false
	end
	tab.nodeEvidence = nil

	-- An older saved Matrix has no source identity. Rebase its class and skill
	-- selectors once; a matching versioned context preserves intentional choices
	-- such as searching a different class or a replacement skill gem.
	if legacy or classChanged or treeChanged then
		tab.textValues.baseClassId = context.classId ~= nil and tostring(context.classId) or ""
		tab.textValues.ascendancyId = ""
		for _, key in ipairs({ "allowedRegions", "requiredRegions", "forbiddenRegions" }) do
			tab.textValues[key] = ""
			local control = tab.controls and tab.controls["text_" .. key]
			if control then control:SetText("", false) end
		end
	end
	if legacy or classChanged or treeChanged or skillChanged then
		tab.textValues.targetSkillGroupIndex = context.groupIndex and tostring(context.groupIndex) or ""
		tab.textValues.targetSkillIndex = context.skillIndex and tostring(context.skillIndex) or ""
		tab.textValues.targetSkillGemId = tostring(context.gemId or "")
	end
	if ascendancyChanged and not (legacy or classChanged or treeChanged) then
		tab.textValues.ascendancyId = ""
	end
	if tab.directionClassControls and (legacy or classChanged or treeChanged) then
		tab.directionSelectedClassId = context.classId
		for classId, control in pairs(tab.directionClassControls) do
			control.state = classId == context.classId
		end
	end

	tab.contextAnchor = context
	tab.contextNotice = "AI Planner context refreshed to " .. optimizerContextLabel(tab.build, context)
		.. "; hard gates and build preferences were preserved."
	tab.statusMessage = tab.contextNotice
	tab.result = nil
	tab.modFlag = true
	return true
end

local function formatMCPStatus(bridge)
	if not bridge then return "Local MCP: bridge unavailable" end
	local health = type(bridge.GetConnectionHealth) == "function" and bridge:GetConnectionHealth() or { }
	local healthStatus = type(health) == "table" and health.status or "unknown"
	if healthStatus == "fresh" then
		return "Local MCP: online; UI loop responding"
	elseif healthStatus == "stale" then
		return "Local MCP: online; UI loop stalled"
	elseif healthStatus == "offline" then
		local status = tostring(type(bridge.GetStatus) == "function" and bridge:GetStatus() or "")
		local reason = status:match("^MCP offline:%s*(.*)$")
		if reason and reason ~= "" then
			if #reason > 42 then reason = reason:sub(1, 39) .. "..." end
			return "Local MCP offline: " .. reason
		end
		return "Local MCP: offline; chat cannot connect"
	end
	local status = tostring(type(bridge.GetStatus) == "function" and bridge:GetStatus() or "Not started")
	if #status > 38 then status = status:sub(1, 35) .. "..." end
	return "Local MCP: " .. status .. "; UI loop not confirmed"
end

OptimizerTabClass.FormatMCPStatus = formatMCPStatus

local function mcpStatusBadge(bridge)
	if not bridge then return "MCP unavailable" end
	local health = type(bridge.GetConnectionHealth) == "function" and bridge:GetConnectionHealth() or { }
	local status = type(health) == "table" and health.status or "unknown"
	if status == "fresh" then return "MCP online" end
	if status == "stale" then return "MCP stalled" end
	if status == "offline" then return "MCP offline" end
	return "MCP checking"
end

local function measuredTextWidth(text, fontSize)
	if DrawStringWidth then
		local ok, width = pcall(DrawStringWidth, fontSize, "VAR", text)
		if ok and type(width) == "number" and width > 0 then
			-- Keep clipping conservative when the headless renderer supplies a
			-- placeholder width instead of the native UI font measurement.
			return math.max(width, #text * fontSize * 0.5)
		end
	end
	return #text * fontSize * 0.55
end

local function clipStatusText(text, width, fontSize)
	text = DisplayText.Native(tostring(text or "")):gsub("%s+", " ")
	if width <= 0 or measuredTextWidth(text, fontSize) <= width then return text end
	local suffix = "..."
	while #text > 0 and measuredTextWidth(text .. suffix, fontSize) > width do
		text = text:sub(1, -2)
	end
	return text .. suffix
end

local function optimizerInputPayload(values)
	if type(values) ~= "table" then return nil, "Optimizer inputs are unavailable" end
	local keys, parts = { }, { }
	for key, value in pairs(values) do
		if type(key) ~= "string" then return nil, "Optimizer input keys must be text" end
		local valueType = type(value)
		if valueType ~= "string" and valueType ~= "number" and valueType ~= "boolean" then
			return nil, "Optimizer input values must be scalar"
		end
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local value = values[key]
		local encoded = tostring(value)
		parts[#parts + 1] = string.format("%d:%s:%s:%d:%s", #key, key, type(value), #encoded, encoded)
	end
	return table.concat(parts, "\n")
end

local function optimizerInputSignature(values)
	local payload, err = optimizerInputPayload(values)
	if not payload then return nil, err end
	return sha.sha256(payload)
end

OptimizerTabClass.ComputeInputSignature = optimizerInputSignature

local function quickBuildMarker(build)
	local spec = build and build.spec or { }
	local allocatedCount, masteryCount, jewelCount = 0, 0, 0
	for _ in pairs(spec.allocNodes or { }) do allocatedCount = allocatedCount + 1 end
	for _ in pairs(spec.masterySelections or { }) do masteryCount = masteryCount + 1 end
	for _ in pairs(spec.jewels or { }) do jewelCount = jewelCount + 1 end
	return table.concat({
		tostring(build and build.characterLevel or ""),
		tostring(spec.curClassId or ""),
		tostring(spec.curAscendClassId or ""),
		tostring(spec.curSecondaryAscendClassId or ""),
		tostring(spec.treeVersion or ""),
		tostring(allocatedCount), tostring(masteryCount), tostring(jewelCount),
		tostring(build and build.mainSocketGroup or ""),
		tostring(build and build.skillsTab and build.skillsTab.activeSkillSetId or ""),
	}, ":")
end

function OptimizerTabClass.RefreshResultFreshness(tab, force)
	if type(tab) ~= "table" or type(tab.result) ~= "table" then
		if type(tab) == "table" then tab.resultFreshness = nil end
		return "none"
	end
	-- Synthetic formatter fixtures without a source build retain their direct
	-- formatting contract. Every native tab has a build and must prove freshness.
	if not tab.build then return "not_applicable" end
	local now = os.clock()
	local expectedInputSignature = tab.result.inputSignature or tab.resultInputSignature
	local inputPayload, inputError = optimizerInputPayload(tab.textValues or { })
	if not inputPayload then
		tab.resultFreshness = { result = tab.result, status = "unverified",
			reason = inputError or "The current Matrix inputs could not be fingerprinted.", checkedAt = now }
		return "unverified", tab.resultFreshness.reason
	end
	local marker = quickBuildMarker(tab.build)
	local cached = tab.resultFreshness
	if not force and cached and cached.result == tab.result
		and cached.quickBuildMarker == marker and cached.inputPayload == inputPayload
		and now - (cached.checkedAt or -1) < RESULT_FRESHNESS_CHECK_INTERVAL then
		return cached.status
	end
	local status, reason = "current", nil
	local expectedBuildSignature = tab.result.sourceSignature
		or tab.result.candidate and tab.result.candidate.sourceSignature
	if type(expectedBuildSignature) ~= "string" or expectedBuildSignature == "" then
		status, reason = "unverified", "The result has no source-build signature."
	else
		local ok, currentSignature = pcall(Candidate.BuildSignature, tab.build)
		if not ok or type(currentSignature) ~= "string" or currentSignature == "" then
			status, reason = "unverified", "The active PoB build signature could not be read."
		elseif currentSignature ~= expectedBuildSignature then
			status, reason = "stale", "The PoB build changed after this search."
		end
	end
	if status == "current" then
		if type(expectedInputSignature) ~= "string" or expectedInputSignature == "" then
			status, reason = "unverified", "The result has no Matrix input signature."
		elseif sha.sha256(inputPayload) ~= expectedInputSignature then
			status, reason = "stale", "The Matrix changed after this search."
		end
	end
	tab.resultFreshness = { result = tab.result, status = status, reason = reason,
		checkedAt = now, quickBuildMarker = marker, inputPayload = inputPayload }
	return status, reason
end

local metricDisplayNames = {
	CombinedDPS = "Combined DPS", FullDPS = "Full DPS", FullDotDPS = "Full DoT DPS",
	PhysicalHitAverage = "Physical average hit", FireHitAverage = "Fire average hit",
	ColdHitAverage = "Cold average hit", LightningHitAverage = "Lightning average hit",
	ChaosHitAverage = "Chaos average hit", BleedDPS = "Bleed DPS", PoisonDPS = "Poison DPS",
	TotalEHP = "Effective HP (EHP)", Life = "Life", EnergyShield = "Energy shield", Ward = "Ward",
	PhysicalMaximumHitTaken = "Physical maximum hit", FireMaximumHitTaken = "Fire maximum hit",
	ColdMaximumHitTaken = "Cold maximum hit", LightningMaximumHitTaken = "Lightning maximum hit",
	ChaosMaximumHitTaken = "Chaos maximum hit", FireResist = "Fire resistance", ColdResist = "Cold resistance",
	LightningResist = "Lightning resistance", ChaosResist = "Chaos resistance",
	SpellSuppressionChance = "Spell suppression chance", BlockChance = "Block chance",
	SpellBlockChance = "Spell block chance", CritChance = "Critical strike chance",
	CritMultiplier = "Critical strike multiplier", Armour = "Armour", Evasion = "Evasion",
	ImpaleDPS = "Impale DPS", Mana = "Mana",
}

local function metricDisplayName(key)
	if metricDisplayNames[key] then return metricDisplayNames[key] end
	local label = tostring(key or "Metric"):gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
	label = label:gsub("(%a)(%d)", "%1 %2")
	return label
end

local function expandScientificNumber(value)
	local mantissa, exponentText = value:match("^([%+%-]?[%d%.]+)[eE]([%+%-]?%d+)$")
	if not mantissa then return value end
	local exponent = tonumber(exponentText) or 0
	local sign = ""
	if mantissa:sub(1, 1) == "-" then
		sign, mantissa = "-", mantissa:sub(2)
	elseif mantissa:sub(1, 1) == "+" then
		mantissa = mantissa:sub(2)
	end
	local decimalAt = mantissa:find(".", 1, true)
	local integerDigits = decimalAt and (decimalAt - 1) or #mantissa
	local digits = mantissa:gsub("%.", "")
	local newDecimalAt = integerDigits + exponent
	if newDecimalAt <= 0 then
		return sign .. "0." .. string.rep("0", -newDecimalAt) .. digits
	elseif newDecimalAt >= #digits then
		return sign .. digits .. string.rep("0", newDecimalAt - #digits)
	end
	return sign .. digits:sub(1, newDecimalAt) .. "." .. digits:sub(newDecimalAt + 1)
end

local function shortestRoundTripNumber(value)
	local absolute = math.abs(value)
	local shortest
	for precision = 1, 17 do
		local candidate = string.format("%." .. tostring(precision) .. "g", absolute)
		if tonumber(candidate) == absolute then
			shortest = candidate
			break
		end
	end
	return expandScientificNumber(shortest or string.format("%.17g", absolute))
end

local function groupDecimalText(value)
	local integer, fraction = value:match("^(%d+)%.(%d+)$")
	if not integer then integer, fraction = value, "" end
	integer = integer:gsub("^0+", "")
	if integer == "" then integer = "0" end
	fraction = fraction:gsub("0+$", "")
	local grouped = integer:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return grouped .. (fraction ~= "" and ("." .. fraction) or "")
end

local function groupedNumber(value)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return "unavailable" end
	local sign = value < 0 and "-" or ""
	return sign .. groupDecimalText(shortestRoundTripNumber(value))
end

local function metricDisplaySuffix(key)
	local suffix = ""
	if tostring(key):match("Resist$") or tostring(key):match("Chance$") or key == "CritMultiplier" then suffix = "%" end
	return suffix
end

local function metricDisplayValue(key, value)
	return groupedNumber(value) .. metricDisplaySuffix(key)
end

local function normalizeDigits(value)
	value = value:gsub("^0+", "")
	return value == "" and "0" or value
end

local function comparePositiveIntegers(first, second)
	first, second = normalizeDigits(first), normalizeDigits(second)
	if #first ~= #second then return #first < #second and -1 or 1 end
	if first == second then return 0 end
	return first < second and -1 or 1
end

local function addPositiveIntegers(first, second)
	local left, right, carry, result = #first, #second, 0, ""
	while left > 0 or right > 0 or carry > 0 do
		local sum = (tonumber(first:sub(left, left)) or 0) + (tonumber(second:sub(right, right)) or 0) + carry
		result = string.char(48 + (sum % 10)) .. result
		carry = math.floor(sum / 10)
		left, right = left - 1, right - 1
	end
	return normalizeDigits(result)
end

local function subtractPositiveIntegers(first, second)
	local left, right, borrow, result = #first, #second, 0, ""
	while left > 0 do
		local digit = (tonumber(first:sub(left, left)) or 0) - borrow - (tonumber(second:sub(right, right)) or 0)
		if digit < 0 then digit, borrow = digit + 10, 1 else borrow = 0 end
		result = string.char(48 + digit) .. result
		left, right = left - 1, right - 1
	end
	return normalizeDigits(result)
end

local function exactDecimalParts(value)
	local fixed = shortestRoundTripNumber(math.abs(value))
	local integer, fraction = fixed:match("^(%d+)%.(%d+)$")
	if not integer then integer, fraction = fixed, "" end
	fraction = fraction:gsub("0+$", "")
	local digits = normalizeDigits(integer .. fraction)
	local sign = value < 0 and -1 or value > 0 and 1 or 0
	return sign, digits, #fraction
end

local function exactDecimalMagnitude(digits, scale)
	digits = normalizeDigits(digits)
	if scale > 0 and #digits <= scale then digits = string.rep("0", scale - #digits + 1) .. digits end
	local integer = scale > 0 and digits:sub(1, #digits - scale) or digits
	local fraction = scale > 0 and digits:sub(#digits - scale + 1) or ""
	integer = normalizeDigits(integer)
	fraction = fraction:gsub("0+$", "")
	return integer .. (fraction ~= "" and ("." .. fraction) or "")
end

local function exactDecimalDifference(after, before)
	local afterSign, afterDigits, afterScale = exactDecimalParts(after)
	local beforeSign, beforeDigits, beforeScale = exactDecimalParts(before)
	beforeSign = -beforeSign
	local scale = math.max(afterScale, beforeScale)
	afterDigits = afterDigits .. string.rep("0", scale - afterScale)
	beforeDigits = beforeDigits .. string.rep("0", scale - beforeScale)
	if afterSign == 0 then return beforeSign, exactDecimalMagnitude(beforeDigits, scale) end
	if beforeSign == 0 then return afterSign, exactDecimalMagnitude(afterDigits, scale) end
	if afterSign == beforeSign then
		return afterSign, exactDecimalMagnitude(addPositiveIntegers(afterDigits, beforeDigits), scale)
	end
	local comparison = comparePositiveIntegers(afterDigits, beforeDigits)
	if comparison == 0 then return 0, "0" end
	if comparison > 0 then
		return afterSign, exactDecimalMagnitude(subtractPositiveIntegers(afterDigits, beforeDigits), scale)
	end
	return beforeSign, exactDecimalMagnitude(subtractPositiveIntegers(beforeDigits, afterDigits), scale)
end

local function metricDisplayDelta(key, after, before)
	if type(after) ~= "number" or type(before) ~= "number"
		or after ~= after or before ~= before or math.abs(after) == math.huge or math.abs(before) == math.huge then
		return "unavailable"
	end
	local sign, magnitude = exactDecimalDifference(after, before)
	local prefix = sign < 0 and "-" or "+"
	return prefix .. groupDecimalText(magnitude) .. metricDisplaySuffix(key)
end

local function isFiniteMetric(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function metricDisplaySummaryValue(key, value)
	if not isFiniteMetric(value) then return "unavailable" end
	return metricDisplayValue(key, value)
end

local function metricDisplaySummaryDelta(key, after, before)
	if not isFiniteMetric(after) or not isFiniteMetric(before) then return "unavailable" end
	return metricDisplayDelta(key, after, before)
end

local function metricDisplaySummaryLine(key, value, baseline)
	local line = metricDisplayName(key) .. ": " .. metricDisplaySummaryValue(key, value)
	if isFiniteMetric(baseline) then
		line = line .. " (Δ " .. metricDisplaySummaryDelta(key, value, baseline) .. ")"
	end
	return line
end

local function metricDisplayLine(key, value, baseline)
	local line = metricDisplayName(key) .. ": " .. metricDisplayValue(key, value)
	if type(baseline) == "number" and baseline == baseline and baseline ~= math.huge and baseline ~= -math.huge then
		line = line .. " (Δ " .. metricDisplayDelta(key, value, baseline) .. ")"
	end
	return line
end

local function routePlannerComparisonBaseline(result)
	if type(result) ~= "table" then return nil, nil end
	local searchBaseline = result.searchBaseline
	if type(searchBaseline) == "table" and searchBaseline.exact == true
		and type(searchBaseline.metrics) == "table" then
		return searchBaseline.metrics, "exact_search", searchBaseline
	end
	if result.routePlanner ~= true then return nil, nil end
	local sourceBaseline = result.sourceBuildBaseline
	if type(sourceBaseline) == "table" and sourceBaseline.comparisonOnly == true
		and type(sourceBaseline.metrics) == "table" then
		return sourceBaseline.metrics, "loaded_build_comparison", sourceBaseline
	end
	return nil, nil
end

local function routePlannerProposalUsesFlask(build, proposal)
	if Equipment.HasFlaskMutation(build, proposal) then return true end
	if type(proposal) ~= "table" then return false end
	if Equipment.DescribesFlaskMutation(proposal.label)
		or Equipment.DescribesFlaskMutation(proposal.candidateLabel) then return true end
	for _, change in ipairs(proposal.changes or { }) do
		if Equipment.DescribesFlaskMutation(change) then return true end
	end
	return false
end

local function formatOptimizerStatus(tab)
	local result = tab.result
	if tab.job and tab.job.status == "running" then
		local progress = tab.job.progress or { }
		local phase = ({ tree = "Tree", skills = "Skills", equipment = "Equipment", combined = "Combined" })[
			tostring(tab.textValues and tab.textValues.generationPhase or "tree"):lower()] or "Optimizer"
		local searchPhase = tostring(progress.phase or "Search")
		local processed = type(progress.processed) == "number" and progress.processed or 0
		local total = type(progress.total) == "number" and progress.total or 0
		local countLabel = searchPhase:lower():find("exact", 1, true) and " exact" or ""
		local progressLabel
		if progress.counterValid == false or (total > 0 and processed > total) then
			progressLabel = string.format("contador inconsistente %d > %d", processed, total)
		else
			progressLabel = string.format("%d/%d%s", processed, total, countLabel)
		end
		local current = type(progress.current) == "string" and progress.current ~= "" and (" — " .. progress.current) or ""
		if progress.counterValid == false or (total > 0 and processed > total) then
			local currentShort = tostring(progress.current or "")
				:gsub("plano%s+(%d+/%d+)", "P%1")
				:gsub("NorthWest", "NW"):gsub("NorthEast", "NE")
				:gsub("SouthWest", "SW"):gsub("SouthEast", "SE")
				:gsub("%s*/%s*", "/"):gsub(";%s*%d+ nodes expanded", "")
			return string.format("Searching %s - %s %d>%d! %s", phase, searchPhase, processed, total, currentShort), false
		end
		return string.format("Searching %s - %s %s%s", phase, searchPhase, progressLabel, current), false
	end
	if result and type(tab.build) == "table" then
		local freshness, reason = OptimizerTabClass.RefreshResultFreshness(tab)
		if freshness == "stale" then
			return "Optimizer result is stale: " .. tostring(reason or "the build or Matrix changed"), true
		elseif freshness == "unverified" then
			return "Optimizer result not verified for the current build: " .. tostring(reason or "missing provenance"), true
		end
	end
	if result and result.status == "no_feasible_candidate" then
		local violation = result.bestObservedViolations and result.bestObservedViolations[1]
		local deficit
		if violation and tostring(violation.key or ""):find("activity_sustain", 1, true) then
			local reason = tostring(violation.reason or "")
			local recovery, cost = reason:match("Exact PoB recovery ([^%s]+) is below recurring activity cost ([^%s]+)")
			if recovery and cost then
				deficit = tostring(violation.label or "Resource sustain") .. " " .. recovery .. " < " .. cost
			end
		end
		deficit = deficit or (violation and OptimizerTabClass.FormatViolation(violation)) or "No candidate passed every hard gate"
		return "No feasible: " .. deficit .. " (" .. tostring(tonumber(result.evaluations) or 0) .. " exact)", true
	end
	if result and result.status == "feasible" and result.evaluation then
		local evaluation = result.evaluation
		local objective = tostring(evaluation.objective or "CombinedDPS")
		local value = evaluation.metrics and evaluation.metrics[objective]
		local valueText = type(value) == "number" and metricDisplayValue(objective, value) or "exact value unavailable"
		local className = tostring(evaluation.selectedBaseClassName or tab.build and tab.build.spec and tab.build.spec.curClassName or "Build")
		return string.format("Feasible: %s %s %s; %d passives", className, metricDisplayName(objective), valueText,
			type(evaluation.passivePointsUsed) == "number" and evaluation.passivePointsUsed or 0), false
	end
	local message = tostring(tab.statusMessage or "")
	if message == "" or message == defaultStatusMessage then return nil, false end
	local failed = message:find("Cannot optimize:", 1, true) == 1
		or message:find("Invalid Matrix:", 1, true) == 1
		or message:find("Invalid objective:", 1, true) == 1
		or message:find("Optimizer error:", 1, true) == 1
		or message:find("MCP request was not queued:", 1, true) == 1
	return message, failed
end

local function importedNodeEvidenceStatus(evidence)
	if type(evidence) ~= "table" then return nil end
	local buildCount = math.max(0, math.floor(tonumber(evidence.compatibleBuildCount) or 0))
	local nodeCount = #(evidence.nodes or { })
	local edgeCount = #(evidence.edges or { })
	if evidence.status == "ready" then
		return string.format("%d builds compatíveis; %d nós e %d ligações observados. Prioridade de exploração apenas; o PoB decide os resultados.",
			buildCount, nodeCount, edgeCount)
	end
	local messages = {
		no_archive = "Ainda não há builds importadas no arquivo local; a busca continua pelo grafo nativo do PoB.",
		no_compatible_builds = "Nenhuma build importada corresponde a esta skill, classe e versão exatas; a busca continua pelo grafo nativo.",
		single_build_only = "Só existe uma build compatível; é pouca evidência para priorizar rotas.",
		scan_limit_reached = "O arquivo excedeu o limite de leitura; evidência parcial não é usada para priorizar rotas.",
		unavailable = "A memória importada não pôde ser validada; a busca continua pelo grafo nativo.",
	}
	return messages[evidence.status] or messages.unavailable
end

local function sanitizeDetailText(value)
	return tostring(value or ""):gsub("[%c]", " "):gsub("%s+", " "):gsub("%^%d", "")
end

local function isFiniteDisplayNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function OptimizerTabClass.FormatVisibleStatus(tab, bridge, viewportWidth)
	local message, failed = formatOptimizerStatus(tab)
	local routePlannerOnly = tab and ((tab.job and tab.job.routePlannerRun == true)
		or (tab.result and tab.result.routePlanner == true)) or false
	if not message and routePlannerOnly then return "", false end
	local badge = mcpStatusBadge(bridge)
	if not message then return formatMCPStatus(bridge), false end
	local fontSize = 14
	local availableWidth = math.max(0, (tonumber(viewportWidth) or 700) - 24)
	if routePlannerOnly then return clipStatusText(message, availableWidth, fontSize), failed end
	local suffix = " | " .. badge
	local clipped = clipStatusText(message, math.max(0, availableWidth - measuredTextWidth(suffix, fontSize)), fontSize)
	return clipped .. suffix, failed
end

function OptimizerTabClass.FormatGuidedWorkflowDiagnostics(tab, readiness)
	if tab and ((tab.job and tab.job.routePlannerRun == true)
		or (tab.result and tab.result.routePlanner == true)) then
		return OptimizerTabClass.FormatGuidedWorkflow(tab, readiness)
	end
	local values = tab and tab.textValues or { }
	local parsed, parseError = Inputs.Parse(values)
	local build = tab and tab.build
	local classId = tonumber(values.baseClassId)
	local selectedClass = classId and build and build.spec and build.spec.tree
		and build.spec.tree.classes[classId]
	local className = selectedClass and selectedClass.name or readiness and readiness.identity and readiness.identity.class or "não selecionada"
	local loadedSkillName = readiness and readiness.skill and readiness.skill.name or "não selecionada"
	local selectedGemId = tostring(values.targetSkillGemId or "")
	local selectedGem = selectedGemId ~= "" and build and build.data and build.data.gems and build.data.gems[selectedGemId]
	local skillName = selectedGem and selectedGem.name or loadedSkillName
	local objective = parsed and parsed.objective or tostring(values.objectiveMetric or "CombinedDPS")
	local phaseNames = { tree = "fundação da árvore", skills = "skills e suportes", equipment = "equipamentos", combined = "busca combinada" }
	local phase = tostring(values.generationPhase or "tree"):lower()
	local lines = { }
	local function step(letter, title, state, detail)
		lines[#lines + 1] = string.format("%s. %s — %s: %s", letter, title, state, detail)
	end

	local identity = readiness and readiness.identity or { }
	local setupStatus = readiness and readiness.label or "diagnóstico indisponível"
	local structureStatus = readiness and readiness.componentCoverage and readiness.componentCoverage.status or "não verificada"
	local engine = identity.engine or { }
	local engineIdentityLabels = {
		pending = "a verificar", verified = "validada", mismatch = "divergente do manifest",
		unavailable = "não verificada", available = "inventário disponível",
	}
	local engineIdentity = engineIdentityLabels[engine.manifestFingerprintStatus] or "não informada"
	local dataSource = identity.patchEvidence == "pob_loaded_data_table_version" and "tabela PoB carregada"
		or identity.patchEvidence == "tree_compatibility_key" and "compatibilidade da árvore" or "fonte de dados não verificada"
	local dataVersion = engine.dataVersion or identity.treeVersion or "não verificados"
	local treeVersion = engine.treeVersion or identity.treeVersion
	local sourceMetadata = identity.sourceMetadata or { }
	local league = sourceMetadata.league or { status = "not_recorded" }
	local leagueLabels = {
		not_recorded = "não registrada", source_declared_unverified = tostring(league.value or "declarada") .. " (origem, não verificada)",
		saved_metadata_unverified = tostring(league.value or "salva") .. " (não verificada)",
		conflicting_sources = "fontes em conflito",
	}
	step("A", "Build carregada", setupStatus,
		string.format("PoE 1; PoB %s; dados %s (%s%s); liga na origem %s; modo/plataforma não confirmados. %s/%s, nível %s; Integridade estrutural ativa: %s; métricas exatas limitadas à skill selecionada; identidade do motor %s.",
			tostring(engine.pobVersion or "não verificado"), tostring(dataVersion), dataSource,
			treeVersion and (", árvore " .. tostring(treeVersion)) or "", leagueLabels[league.status] or "não verificada",
			tostring(identity.class or className), tostring(identity.ascendancy or "sem ascendência confirmada"), tostring(identity.level or "não verificado"), structureStatus,
			engineIdentity))
	local calculationStatus = readiness and readiness.calculation and readiness.calculation.status or "unavailable"
	local calculationLabels = { current = "cálculo PoB atual", pending = "cálculo pendente", unavailable = "cálculo indisponível" }
	local socketStatus = readiness and readiness.skill and readiness.skill.sockets and readiness.skill.sockets.status or "missing"
	local socketLabels = {
		linked = "link físico validado",
		granted = "skill concedida por item",
		unlinked_planning_group = "sem link físico (grupo de planeamento, não jogável)",
		invalid = "socket/link inválido",
		missing = "vínculo não verificado",
	}
	step("B", "Objetivo", objective,
		string.format("classe direcionada %s; Main Skill %s; skill carregada %s; %s; %s; fase %s.",
			tostring(className), tostring(skillName), tostring(loadedSkillName), calculationLabels[calculationStatus] or calculationStatus,
			socketLabels[socketStatus] or socketStatus, phaseNames[phase] or "inválida"))

	if parsed then
		local hardCount, requiredRegions, forbiddenRegions = 0, #(parsed.branch.required or { }), #(parsed.branch.forbidden or { })
		for _ in pairs(parsed.hard or { }) do hardCount = hardCount + 1 end
		local floors = hardCount == 0 and "nenhum piso métrico rígido definido" or (tostring(hardCount) .. " pisos métricos rígidos")
		step("C", "Restrições", "válidas",
			string.format("%s; teto de %d pontos; regiões obrigatórias/proibidas %d/%d. Foco de dano e defesa são preferências.",
				floors, parsed.search.maxTotalPoints or 120, requiredRegions, forbiddenRegions))
		step("D", "Cenário", tostring(parsed.scenarioProfile),
			string.format("inimigo %s; configuração ativa %s; flags não certificam uptime.", tostring(parsed.scenarioEnemyPreset or "não verificado"),
				tostring(readiness and readiness.scenario and readiness.scenario.configTitle or "PoB atual")))
	else
		step("C", "Restrições", "corrigir Matrix", tostring(parseError or "entradas inválidas"))
		step("D", "Cenário", "não validado", "corrija as entradas inválidas antes de iniciar uma busca.")
	end

	local job = tab and tab.job
	if job and job.status == "running" then
		local progress = job.progress or { }
		step("E", "Busca", "em execução", string.format("%s de %s avaliações concluídas; pode cancelar.",
			tostring(progress.processed or 0), tostring(progress.total or "?")))
		step("F", "Resultado", "aguardando", "nenhuma proposta fica aplicada automaticamente; reveja o candidato e use Apply separadamente.")
	else
		step("E", "Busca", tab and tab.result and "concluída" or "por iniciar",
			tab and tab.result and "inspecione o estado e a cobertura da busca." or "Otimizar executa o cálculo exato do PoB e respeita o orçamento configurado.")
		local result = tab and tab.result
		if result and result.status == "feasible" then
			step("F", "Resultado", "candidato aprovado",
				"passou os hard gates no cálculo exato do PoB; confira diferenças e trade-offs. Só a ação explícita em Apply cria uma variação.")
		elseif result and result.status == "no_feasible_candidate" then
			step("F", "Resultado", "sem candidato viável",
				"nenhuma solução viável dentro do orçamento; consulte os déficits observados. Não há fallback entregável.")
		elseif result then
			step("F", "Resultado", tostring(result.status or "não certificado"),
				"revise o diagnóstico; somente um candidato que passe todos os hard gates pode ser aplicado.")
		else
			step("F", "Resultado", "ainda não disponível", "a build ativa permanece intacta até uma aplicação explícita.")
		end
	end
	local evidence = tab and tab.nodeEvidence
	if evidence then
		if evidence.status == "disabled" then
			if evidence.reason == "class_specific_prior_disabled_for_all_class_comparison" then
				step("G", "Memória de builds", "suspensa na comparação das classes",
					"O prior é específico de uma classe; a busca equitativa das sete classes usa propostas sem essa preferência.")
			else
				step("G", "Memória de builds", "desligada", "A busca usa o grafo nativo da árvore do PoB sem prioridade de builds importadas.")
			end
		else
			local evidenceDetail = importedNodeEvidenceStatus(evidence)
			if evidenceDetail then
				step("G", "Memória de builds", evidence.status == "ready" and "prioridade ativa" or "sem prior utilizável", evidenceDetail)
			end
		end
	end
	return lines
end

function OptimizerTabClass.FormatGuidedWorkflow(tab, readiness)
	local job = tab and tab.job
	if job and job.status == "running" then
		local progress = job.progress or { }
		local phase = tostring(progress.phase or "Gerando combinações")
		local phaseLabels = {
			Pathfinding = "Busca de caminhos",
			["Exact calculations"] = "Recálculos exatos",
			["Candidate reconstruction"] = "Reconstrução de propostas",
			["Tree validation"] = "Validação da árvore",
			["Generating native ascendancy routes"] = "Geração de rotas de ascendência",
			["Generating native Cluster Jewel candidates"] = "Geração de combinações de cluster jewels",
			["Preparing native ascendancy routes"] = "Preparação de rotas de ascendência",
			["Loading path memory"] = "Preparando combinações",
			["Mining path patterns"] = "Explorando conexões do grafo",
			["Applying contextual path evidence"] = "Ordenando rotas candidatas",
		}
	local displayPhase = phaseLabels[phase] or phase
		local processed = tonumber(progress.processed) or 0
		local total = tonumber(progress.total) or 0
		local countLabel = phase:lower():find("exact", 1, true) and "recálculos"
			or phase:lower():find("pathfinding", 1, true) and "etapas de caminho"
			or phase:lower():find("candidat", 1, true) and "combinações" or "etapas"
		local lines = { }
		if progress.counterValid == false or (total > 0 and processed > total) then
			lines[#lines + 1] = "Gerando rotas — " .. displayPhase .. "; progresso em reconciliação."
		else
			lines[#lines + 1] = string.format("Gerando combinações e rotas — %s · %s/%s %s", displayPhase,
				groupedNumber(processed), total > 0 and groupedNumber(total) or "a calcular", countLabel)
		end
		local generated = tonumber(progress.generatedProposals)
		local unique = tonumber(progress.uniqueProposals)
		local retained = tonumber(progress.retainedProposals)
		if generated or unique or retained then
			lines[#lines + 1] = string.format("Combinações: %s propostas · %s únicas · %s na fila de cálculo",
				groupedNumber(generated or 0), groupedNumber(unique or 0), groupedNumber(retained or 0))
		end
		local familyLabels = {
			baseline = "base", equipment = "equipamentos", skills = "gemas/suportes",
			combined = "rotas combinadas", tree = "passivas", configuration = "configuração", other = "outros",
		}
		local familyOrder = { "baseline", "equipment", "skills", "combined", "tree", "configuration", "other" }
		local function formatFamilyCounts(counts, order)
			local parts, seen = { }, { }
			for _, family in ipairs(order or familyOrder) do
				local count = tonumber(counts and counts[family])
				if count and count > 0 then
					parts[#parts + 1] = tostring(familyLabels[family] or family) .. " " .. groupedNumber(math.floor(count))
					seen[family] = true
				end
			end
			for family, value in pairs(counts or { }) do
				local count = tonumber(value)
				if not seen[family] and count and count > 0 then
					parts[#parts + 1] = tostring(familyLabels[family] or family) .. " " .. groupedNumber(math.floor(count))
				end
			end
			return #parts > 0 and table.concat(parts, ", ") or "nenhuma ainda"
		end
		local familyPlan = progress.exactEvaluationPlan
		if type(familyPlan) == "table" then
			lines[#lines + 1] = "Fila exata planejada (" .. groupedNumber(tonumber(familyPlan.windowSize) or 0)
				.. "): " .. formatFamilyCounts(familyPlan.windowFamilyCounts, familyPlan.familyOrder)
		end
		if type(progress.exactEvaluationsByFamily) == "table" then
			lines[#lines + 1] = "Recálculos exatos por família: "
				.. formatFamilyCounts(progress.exactEvaluationsByFamily, familyOrder)
		end
		local archiveDirectGenerated = tonumber(progress.archiveRoutesGenerated) or 0
		local archiveLineages = tonumber(progress.archiveCompatibleLineages) or 0
		local archivePatterns = tonumber(progress.archivePatternsAvailable) or 0
		local archiveComposedGenerated = tonumber(progress.archiveCompositionsGenerated) or 0
		local archiveDirectExact = tonumber(progress.archiveDirectExact) or 0
		local archiveComposedExact = tonumber(progress.archiveCompositionsExact) or 0
		local archiveRepairsGenerated = tonumber(progress.archiveGateRepairsGenerated) or 0
		local archiveRepairsExact = tonumber(progress.archiveGateRepairsExact) or 0
		local archiveRepairsFeasible = tonumber(progress.archiveGateRepairsFeasible) or 0
		if archiveDirectGenerated > 0 or archiveComposedGenerated > 0
			or archiveDirectExact > 0 or archiveComposedExact > 0 then
			lines[#lines + 1] = string.format("Memória de builds: %s linhagens / %s padrões · %s rotas diretas · %s combinações compostas · recálculos nativos: %s diretas / %s compostas.",
				groupedNumber(archiveLineages), groupedNumber(archivePatterns), groupedNumber(archiveDirectGenerated),
				groupedNumber(archiveComposedGenerated),
				groupedNumber(archiveDirectExact), groupedNumber(archiveComposedExact))
		end
		if archiveRepairsGenerated > 0 or archiveRepairsExact > 0 then
			lines[#lines + 1] = string.format("Ajustes de rotas arquivadas após falha exata: %s gerados · %s recalculados · %s passaram todos os pisos.",
				groupedNumber(archiveRepairsGenerated), groupedNumber(archiveRepairsExact), groupedNumber(archiveRepairsFeasible))
		end
		if type(progress.paretoRoutes) == "number" then
			local routeCount = math.max(0, math.floor(progress.paretoRoutes))
			lines[#lines + 1] = "Fronteira Pareto atual: " .. groupedNumber(routeCount) .. (routeCount == 1 and " rota" or " rotas")
		end
		if type(progress.exactFeasibleMutations) == "number" then
			lines[#lines + 1] = "Combinações exatas aprovadas: " .. groupedNumber(math.max(0, math.floor(progress.exactFeasibleMutations)))
		end
		local bestRoute = progress.bestExactRoute
		if type(bestRoute) == "table" and type(bestRoute.label) == "string" then
			lines[#lines + 1] = "Melhor rota aprovada até agora: " .. sanitizeDetailText(bestRoute.label)
			if bestRoute.archiveDerivedPassiveRoute == true then
				local origin = bestRoute.archivedRouteComposition == true
					and "inclui rota passiva arquivada combinada com outras alterações"
					or "usa um padrão passivo observado em builds arquivadas"
				lines[#lines + 1] = "Origem da rota: " .. origin .. "; métricas recalculadas pelo motor nativo do PoB."
			end
			local shownMetrics, seenMetrics = 0, { }
			local function addProgressMetric(key, value, baseline)
				if shownMetrics >= 3 or type(key) ~= "string" or key == "" or seenMetrics[key]
					or not isFiniteDisplayNumber(value) then return end
				seenMetrics[key] = true
				lines[#lines + 1] = metricDisplaySummaryLine(key, value, baseline)
				shownMetrics = shownMetrics + 1
			end
			addProgressMetric(bestRoute.objectiveKey, bestRoute.objectiveValue, bestRoute.objectiveBaseline)
			addProgressMetric(bestRoute.focusMetricKey, bestRoute.focusMetricValue, bestRoute.focusMetricBaseline)
			addProgressMetric(bestRoute.defenseMetricKey, bestRoute.defenseMetricValue, bestRoute.defenseMetricBaseline)
		end
		local current = type(progress.current) == "string" and sanitizeDetailText(progress.current) or ""
		current = current:gsub("NorthWest", "Noroeste"):gsub("NorthEast", "Nordeste")
			:gsub("SouthWest", "Sudoeste"):gsub("SouthEast", "Sudeste")
			:gsub("nodes expanded", "nós expandidos"):gsub("node ", "nó ")
			:gsub("plan ", "plano "):gsub("socket ", "soquete "):gsub("item ", "item ")
		local loweredCurrent = current:lower()
		if loweredCurrent:find("memory", 1, true) or loweredCurrent:find("evidence", 1, true)
			or loweredCurrent:find("memória", 1, true) or loweredCurrent:find("evidência", 1, true) then
			current = ""
		end
		if current ~= "" then lines[#lines + 1] = "Combinação em análise: " .. current end
		lines[#lines + 1] = "Somente rotas recalculadas pelo PoB e aprovadas nos requisitos aparecem como opções."
		return lines
	end

	local result = tab and tab.result
	local function exactRouteCount(candidateResult)
		if type(candidateResult) ~= "table" then return 0 end
		local count, seen = 0, { }
		local function include(candidate)
			if type(candidate) ~= "table" or seen[candidate] or candidate.feasible ~= true
				or candidate.sourceSignature ~= candidateResult.sourceSignature
				or type(candidate.evaluation) ~= "table" or candidate.evaluation.feasible ~= true
				or type(candidate.evaluation.metrics) ~= "table"
				or routePlannerProposalUsesFlask(tab and tab.build, candidate)
				or not Candidate.HasMutation(candidate) then return end
			seen[candidate] = true
			count = count + 1
		end
		include(candidateResult.candidate)
		for _, candidate in ipairs(candidateResult.paretoFront or { }) do include(candidate) end
		return count
	end
	if type(result) ~= "table" then
		local values = tab and tab.textValues or { }
		local routeControl = tab and tab.controls and tab.controls.overviewRoutes
		local routeReady = readiness and readiness.skill and readiness.skill.status == "resolved"
		if routeControl and type(routeControl.enabled) == "function" then routeReady = routeControl.enabled() end
		if not routeReady then
			return { "Selecione uma Main Skill e uma gema alvo válidas para habilitar Gerar rotas." }
		end
		local readinessLabel = readiness and readiness.label
		if readinessLabel == "Blocked" or readinessLabel == "Indisponível" then
			return { "Não foi possível iniciar a geração de rotas com a configuração atual da build." }
		end
		local skillName = readiness and readiness.skill and readiness.skill.name
		local build = tab and tab.build
		local groupIndex, skillIndex = tonumber(values.targetSkillGroupIndex), tonumber(values.targetSkillIndex)
		local group = groupIndex and build and build.skillsTab and build.skillsTab.socketGroupList[groupIndex]
		local skill = group and group.displaySkillList and group.displaySkillList[skillIndex or group.mainActiveSkill or 1]
		if not skillName or skillName == "" then
			skillName = skill and (skill.name or skill.activeEffect and skill.activeEffect.grantedEffect
				and skill.activeEffect.grantedEffect.name)
		end
		if (not skillName or skillName == "") and values.targetSkillGemId and build and build.data and build.data.gems then
			local gem = build.data.gems[values.targetSkillGemId]
			skillName = gem and gem.name
		end
		local suffix = skillName and skillName ~= "" and (" para " .. sanitizeDetailText(skillName)) or " para a Main Skill selecionada"
		return { "Pronto para gerar combinações e rotas" .. suffix .. " com as prioridades configuradas." }
	end

	if result.status ~= "feasible" or result.routePlanner ~= true then
		local evaluations = groupedNumber(tonumber(result.evaluations) or 0)
		local preservedRoutes = exactRouteCount(result)
		if result.status == "no_feasible_candidate" then
			local bestNearMiss, exactNearMissCount
			exactNearMissCount = 0
			for _, nearMiss in ipairs(result.nearMisses or { }) do
				if type(nearMiss) == "table" and nearMiss.exact == true and nearMiss.feasible == false
					and type(nearMiss.metrics) == "table" and not routePlannerProposalUsesFlask(tab and tab.build, nearMiss) then
					exactNearMissCount = exactNearMissCount + 1
					if not bestNearMiss then bestNearMiss = nearMiss end
				end
			end
			if bestNearMiss then
				local lines = { "Busca concluída — 0 rotas aprovadas; " .. groupedNumber(exactNearMissCount)
					.. " quase-rotas recalculadas pelo PoB." }
				lines[#lines + 1] = "Melhor quase-rota: " .. sanitizeDetailText(bestNearMiss.label or "Proposta exata")
					.. " — não aplicável; ainda falha em hard gates."
				local baselineMetrics, baselineKind, baselineRecord = routePlannerComparisonBaseline(result)
				local values = tab and tab.textValues or { }
				local objective = tostring(result.objectiveMetric or values.objectiveMetric or "CombinedDPS")
				local focusMetric = Ranking.DamageFocusMetricKey(tostring(values.damageFocus or "Auto"))
				local defenseKey = ({ Auto = "TotalEHP", Life = "Life", EnergyShield = "EnergyShield", Hybrid = "TotalEHP",
					Ward = "Ward", Armour = "Armour", Evasion = "Evasion", Block = "BlockChance",
					SpellBlock = "SpellBlockChance", SpellSuppression = "SpellSuppressionChance" })[
					tostring(values.defenseProfile or "Auto")]
				local shown, seenMetrics = 0, { }
				local function addNearMissMetric(key)
					if shown >= 3 or type(key) ~= "string" or key == "" or seenMetrics[key]
						or not isFiniteDisplayNumber(bestNearMiss.metrics[key]) then return end
					seenMetrics[key] = true
					lines[#lines + 1] = metricDisplaySummaryLine(key, bestNearMiss.metrics[key],
						baselineMetrics and baselineMetrics[key])
					shown = shown + 1
				end
			addNearMissMetric(objective)
			addNearMissMetric(focusMetric)
			addNearMissMetric(defenseKey)
			if shown == 0 then lines[#lines + 1] = "Métricas exatas indisponíveis para comparação resumida." end
			if baselineKind == "loaded_build_comparison" then
				local socketNote = baselineRecord and baselineRecord.socketRepairRequired == true
					and " A Main Skill da build tem sockets/links para reparar." or ""
				lines[#lines + 1] = "Referência: saída nativa da build carregada, somente para comparação; não aprova gates." .. socketNote
			elseif not baselineMetrics then
				lines[#lines + 1] = "Sem baseline exata nesta execução; deltas indisponíveis."
			end
			lines[#lines + 1] = "Não pode ser aplicada. Abra Ver resultado para ver os gates pendentes e a ficha completa."
			return lines
		end
		return { "Busca concluída — " .. groupedNumber(preservedRoutes) .. " rotas exatas aprovadas.",
			"Recálculos nativos: " .. evaluations .. "; nenhuma proposta exata passou pelos hard gates." }
		elseif result.status == "cancelled" or result.status == "timed_out"
			or result.searchInterrupted == true or result.searchTimedOut == true then
			local interruptionLabel = result.searchTimedOut == true and "Prazo atingido" or "Busca interrompida"
			return { interruptionLabel .. " — " .. groupedNumber(preservedRoutes) .. " rotas exatas preservadas.",
				"Recálculos nativos concluídos: " .. evaluations .. "; abra Ver resultado para escolher uma rota." }
		end
		return { "Busca concluída — " .. groupedNumber(preservedRoutes) .. " rotas exatas aprovadas.",
			"Recálculos nativos: " .. evaluations .. "; consulte Ver resultado para escolher uma rota." }
	end

	local selectedRoute = tab.selectedRouteResult == result and tab.selectedRouteCandidate or nil
	local route = selectedRoute or result.candidate
	local evaluation = type(route) == "table" and route.evaluation or result.evaluation
	local metrics = type(evaluation) == "table" and evaluation.metrics or nil
	if type(metrics) ~= "table" or evaluation.feasible ~= true
		or routePlannerProposalUsesFlask(tab.build, route) or not Candidate.HasMutation(route) then
		return { "Busca concluída — nenhuma rota exata válida para exibir.",
			"Nenhum ganho aplicável foi confirmado nesta busca." }
	end

	local routeCount = exactRouteCount(result)

	local lines = { string.format("Busca concluída — %s rotas exatas aprovadas · %s recálculos nativos.",
		groupedNumber(routeCount), groupedNumber(tonumber(result.evaluations) or 0)) }
	local candidateLabel = sanitizeDetailText(evaluation.candidateLabel or route.label or "Rota selecionada")
	lines[#lines + 1] = "Rota selecionada: " .. candidateLabel .. " — aprovada pelo PoB; não aplicada."

	local baselineMetrics, baselineKind, baselineRecord = routePlannerComparisonBaseline(result)
	local values = tab.textValues or { }
	local objective = tostring(evaluation.objective or result.objectiveMetric or values.objectiveMetric or "CombinedDPS")
	local shown, seenMetrics = 0, { }
	local function addMetric(key)
		if shown >= 3 or type(key) ~= "string" or key == "" or seenMetrics[key]
			or not isFiniteDisplayNumber(metrics[key]) then return end
		seenMetrics[key] = true
		lines[#lines + 1] = metricDisplaySummaryLine(key, metrics[key], baselineMetrics and baselineMetrics[key])
		shown = shown + 1
	end
	addMetric(objective)
	local focusMetric = Ranking.DamageFocusMetricKey(tostring(values.damageFocus or "Auto"))
	if focusMetric and focusMetric ~= objective then addMetric(focusMetric) end
	local defenseMetrics = { Auto = "TotalEHP", Life = "Life", EnergyShield = "EnergyShield", Hybrid = "TotalEHP",
		Ward = "Ward", Armour = "Armour", Evasion = "Evasion", Block = "BlockChance",
		SpellBlock = "SpellBlockChance", SpellSuppression = "SpellSuppressionChance" }
	addMetric(defenseMetrics[tostring(values.defenseProfile or "Auto")])
	if shown == 0 then lines[#lines + 1] = "Ganho numérico indisponível para as métricas exatas desta rota." end
	if baselineKind == "loaded_build_comparison" then
		local socketNote = baselineRecord and baselineRecord.socketRepairRequired == true
			and " A Main Skill da build tem sockets/links para reparar." or ""
		lines[#lines + 1] = "Referência: saída nativa da build carregada, somente para comparação; não aprova gates." .. socketNote
	elseif type(baselineMetrics) ~= "table" then
		lines[#lines + 1] = "Sem baseline exata nesta execução; deltas não calculados."
	end
	return lines
end

local function popupTopLeftAnchor()
	return { "TOPLEFT", nil, "TOPLEFT" }
end

local function drawWrappedPopupLabel(control, fontSize)
	local x, y = control:GetPos()
	local width, height = control:GetSize()
	local lines = { }
	for sourceLine in (DisplayText.Native(tostring(control:GetProperty("label") or "")) .. "\n"):gmatch("(.-)\n") do
		for _, line in ipairs(main:WrapString(sourceLine, fontSize, width)) do
			lines[#lines + 1] = line
		end
	end
	SetViewport(x, y, width, height)
	for index, line in ipairs(lines) do
		local lineY = (index - 1) * fontSize
		if lineY + fontSize > height then break end
		drawPlannerString(0, lineY, "LEFT", fontSize, "VAR", line)
	end
	SetViewport()
end

local function setClippedPopupLabel(control, width, fontSize)
	-- LabelControl normally replaces the requested rect width with the measured
	-- text width. Restore the popup's actual column width before drawing so both
	-- WrapString and the viewport clip use the intended bounds.
	control.width = width
	control.Draw = function(label) drawWrappedPopupLabel(label, fontSize) end
end

local fieldChoices = {
	objectiveMetric = {
		{ val = "CombinedDPS", label = "Selected skill DPS" },
		{ val = "FullDPS", label = "Included groups DPS" },
		{ val = "FullDotDPS", label = "Included groups DoT" },
		{ val = "TotalEHP", label = "Effective health pool" },
		{ val = "Speed", label = "Attack / cast rate" },
	},
	scenarioProfile = {
		{ val = "Current", label = "Current settings" },
		{ val = "PinnacleUnbuffed", label = "Pinnacle unbuffed" },
		{ val = "PinnacleChassis", label = "Pinnacle chassis" },
	},
}

local rankingPriorityChoices = {
	{ val = "ObjectiveFirst", label = "Offense objective first" },
	{ val = "DefenseFirst", label = "Preferred defense first" },
}

local function nativeChoiceLabels(choices)
	local displayChoices = { }
	for index, choice in ipairs(choices or { }) do
		if type(choice) == "table" then
			local copy = { }
			for key, value in pairs(choice) do
				copy[key] = key == "label" and DisplayText.Native(value) or value
			end
			displayChoices[index] = copy
		else
			displayChoices[index] = DisplayText.Native(choice)
		end
	end
	return displayChoices
end

local nativeEnemyOptions
for _, option in ipairs(ConfigOptions) do
	if option.var == "enemyIsBoss" then nativeEnemyOptions = option.list or { } break end
end

local function enemyPresetChoices(scenarioProfile)
	local choices = {
		{ val = "Active", label = scenarioProfile == "Current" and "Active PoB setting" or "Profile default" },
	}
	for _, option in ipairs(nativeEnemyOptions or { }) do
		if scenarioProfile == "Current" or option.val == "Pinnacle" or option.val == "Uber" then
			local labels = { None = "No boss", Boss = "Standard boss", Pinnacle = "Pinnacle", Uber = "Uber pinnacle" }
			choices[#choices + 1] = { val = option.val, label = labels[option.val] or option.label or option.val }
		end
	end
	return choices
end

local function setFieldControl(control, value)
	if control.optimizerChoices then
		control:ResetSearch()
		control.dropped = false
		local normalized = tostring(value or ""):gsub("^%s*(.-)%s*$", "%1"):lower()
		for index, choice in ipairs(control.optimizerChoices) do
			if choice.val:lower() == normalized then
				control:SetSel(index, true)
				return choice.val
			end
		end
		-- Older saved Matrix values could contain empty/invalid free text. The
		-- native selector migrates those to its first explicit supported value.
		control:SetSel(1, true)
		return control.optimizerChoices[1].val
	end
	control:SetText(value)
	return value
end

local treeOnlyPhaseFields = {
	"targetNodeIds", "addNodeIds", "removeNodeIds", "requiredNodeIds", "forbiddenNodeIds",
	"allowedRegions", "requiredRegions", "forbiddenRegions",
}
local treeOnlyPhaseFieldSet = { maxAddedPoints = true }
for _, key in ipairs(treeOnlyPhaseFields) do treeOnlyPhaseFieldSet[key] = true end

local function prepareGenerationPhase(tab, phase)
	phase = tostring(phase or "tree"):lower()
	tab.textValues.generationPhase = phase
	if phase == "tree" or phase == "combined" then return end

	tab.textValues.searchAllClasses = false
	tab.textValues.baseClassId = tostring(tab.build.spec.curClassId or "")
	tab.textValues.ascendancyId = ""
	tab.textValues.maxAddedPoints = "0"
	for _, key in ipairs(treeOnlyPhaseFields) do
		tab.textValues[key] = ""
		local control = tab.controls and tab.controls["text_" .. key]
		if control then control:SetText("", false) end
	end
	local pointControl = tab.controls and tab.controls.text_maxAddedPoints
	if pointControl then pointControl:SetText("0", false) end
	if tab.directionAllClassesControl then tab.directionAllClassesControl.state = false end
	tab.directionSelectedClassId = tab.build.spec.curClassId
	for classId, control in pairs(tab.directionClassControls or { }) do
		control.state = classId == tab.build.spec.curClassId
	end
end

local function guidedPassiveBudget(tab)
	local build = tab and tab.build
	if not build or type(build.GetPassivePointLimitForLevel) ~= "function" then return 130 end
	if build.characterLevelAutoMode then return 130 end
	local output = build.calcsTab and build.calcsTab.mainOutput or { }
	local extraPoints = tonumber(output.ExtraPoints) or 0
	local limit = build:GetPassivePointLimitForLevel(build.characterLevel or 1, extraPoints)
	if type(limit) ~= "number" or limit ~= limit then return 130 end
	return math.max(0, math.min(130, math.floor(limit)))
end

local function applyGuidedTreeBudget(tab, mode)
	mode = tostring(mode or "level"):lower()
	tab.textValues.treeBudgetMode = mode
	if mode == "level" then
		local pointLimit = guidedPassiveBudget(tab)
		local strictCap = tonumber(tab.textValues.maxTotalPoints) or 120
		tab.textValues.maxAddedPoints = tostring(math.min(pointLimit, math.max(0, strictCap)))
	elseif mode == "local" then
		tab.textValues.maxAddedPoints = "5"
	end
	local matrixControl = tab.controls and tab.controls.text_maxAddedPoints
	if matrixControl then matrixControl:SetText(tab.textValues.maxAddedPoints, false) end
	tab.modFlag = true
end

local compactMetricLabels = {
	TotalEHP = "Min EHP",
	LifeReserved = "Life reserved",
	LifeReservedMax = "Max life reserve",
	LifeUnreserved = "Free life",
	LifeReservedPercentMax = "Max life reserve",
	ManaReserved = "Mana reserved",
	ManaReservedMax = "Max mana reserve",
	ManaUnreserved = "Free mana",
	ManaReservedPercentMax = "Max mana reserve",
	LifeSustainMargin = "Life regen margin",
	ManaSustainMargin = "Mana/ES regen",
	LifeLeechGainRate = "Life recovery",
	ManaLeechGainRate = "Mana recovery",
	EnergyShieldLeechGainRate = "ES recovery",
	PhysicalMaximumHitTaken = "Physical max hit",
	FireMaximumHitTaken = "Fire max hit",
	ColdMaximumHitTaken = "Cold max hit",
	LightningMaximumHitTaken = "Lightning max hit",
	ChaosMaximumHitTaken = "Chaos max hit",
	FireResist = "Fire resistance",
	ColdResist = "Cold resistance",
	LightningResist = "Lightning resist",
	ChaosResist = "Chaos resistance",
	FireResistOverCap = "Fire res overcap",
	ColdResistOverCap = "Cold res overcap",
	LightningResistOverCap = "Lightning overcap",
	ChaosResistOverCap = "Chaos res overcap",
	BlockChance = "Block chance",
	SpellBlockChance = "Spell block chance",
	SpellSuppressionChance = "Spell suppression",
	Armour = "Armour",
	Evasion = "Evasion",
	CombinedDPS = "Selected skill DPS",
	FullDPS = "Full build DPS",
	FullDotDPS = "Full build DoT",
	CritChance = "Crit chance",
	CritMultiplier = "Crit multiplier",
	ActionSpeedMod = "Action speed",
	Speed = "Attack/cast rate",
	SkillTriggerRate = "Trigger rate",
	ImpaleDPS = "Impale DPS",
	Life = "Life floor",
	EnergyShield = "ES floor",
	Ward = "Ward floor",
	Str = "Min Strength",
	Dex = "Min Dexterity",
	Int = "Min Intelligence",
	Omni = "Min Omniscience",
}

local narrowMetricLabels = {
	TotalEHP = "Min EHP", LifeReserved = "Life reserve", LifeReservedMax = "Life res max",
	LifeUnreserved = "Free life", LifeReservedPercentMax = "Life res max",
	ManaReserved = "Mana reserve", ManaReservedMax = "Mana res max", ManaUnreserved = "Free mana",
	ManaReservedPercentMax = "Mana res max", LifeSustainMargin = "Life regen", ManaSustainMargin = "Mana/ES net",
	LifeLeechGainRate = "Life recov", ManaLeechGainRate = "Mana recov", EnergyShieldLeechGainRate = "ES recov",
	PhysicalMaximumHitTaken = "Phys max hit", FireMaximumHitTaken = "Fire max hit", ColdMaximumHitTaken = "Cold max hit",
	LightningMaximumHitTaken = "Ltng max hit", ChaosMaximumHitTaken = "Chaos max hit",
	FireResist = "Fire resist", ColdResist = "Cold resist", LightningResist = "Ltng resist", ChaosResist = "Chaos resist",
	FireResistOverCap = "Fire overcap", ColdResistOverCap = "Cold overcap",
	LightningResistOverCap = "Ltng overcap", ChaosResistOverCap = "Chaos over",
	BlockChance = "Block chance", SpellBlockChance = "Spell block", SpellSuppressionChance = "Spell supp.",
	Armour = "Armour", Evasion = "Evasion",
	CombinedDPS = "Skill DPS", FullDPS = "Build DPS", FullDotDPS = "Build DoT",
	CritChance = "Crit chance", CritMultiplier = "Crit multi", ActionSpeedMod = "Action speed",
	Speed = "Attack/cast", SkillTriggerRate = "Trigger", ImpaleDPS = "Impale DPS",
	Life = "Life", EnergyShield = "Energy Shield", Ward = "Ward",
	Str = "Min Str", Dex = "Min Dex", Int = "Min Int", Omni = "Min Omni",
}

local wideMetricFallbacks = {
	LifeSustainMargin = "Life regen margin",
	ManaSustainMargin = "Mana/ES regen margin",
	FireResistOverCap = "Fire res overcap",
	ColdResistOverCap = "Cold res overcap",
	LightningResistOverCap = "Lightning res overcap",
	ChaosResistOverCap = "Chaos res overcap",
}

local textFieldDefinitions = {
	{ key = "conversionRoute", hidden = true },
	{ key = "activityScheduleJson", hidden = true, default = "{}" },
	{ key = "maxManualDamageButtons", hidden = true },
	{ key = "currencyBudgetAmount", hidden = true, default = "" },
	{ key = "currencyBudgetUnit", hidden = true, default = "Chaos" },
	{ key = "currencyBudgetMode", hidden = true, default = "Trade" },
	{ key = "currencyBudgetLeague", hidden = true, default = "" },
	{ key = "currencyBudgetDivineChaosRate", hidden = true, default = "" },
	{ key = "useImportedRouteMemory", hidden = true, default = "true" },
	{ key = "marketQuotesJson", hidden = true, default = "{}" },
	{ key = "manualItemPricesJson", hidden = true, default = "{}" },
	{ key = "maxManualButtons", label = "Max manual actions", compactLabel = "Total action cap", x = 12, y = 292, width = 126, placeholder = "0-24; optional" },
	{ key = "conversionMin", label = "Edge minimum (%)", compactLabel = "Edge min (%)", x = 354, y = 292, width = 126, placeholder = "100" },
	{ key = "allowedRegions", label = "Allowed regions", x = 12, y = 314, width = 126, placeholder = "Class or NW/NE/SW/SE/Hub" },
	{ key = "requiredRegions", label = "Required regions", compactLabel = "Required regions", x = 354, y = 314, width = 126, placeholder = "Class or quadrant" },
	{ key = "forbiddenRegions", label = "Forbidden regions", x = 12, y = 336, width = 126, placeholder = "Class or quadrant" },
	{ key = "maxAddedPoints", label = "Max new points", compactLabel = "Max new points", x = 354, y = 336, width = 126, default = "5" },
	{ key = "maxTotalPoints", label = "Point cap (1-130)", compactLabel = "Point cap", x = 12, y = 358, width = 126, default = "120" },
	{ key = "evaluationBudget", label = "Exact budget", x = 354, y = 358, width = 126, default = "120" },
	{ key = "objectiveMetric", label = "Optimize", compactLabel = "Objective", x = 12, y = 380, width = 126, default = "CombinedDPS", placeholder = "DPS / FullDPS / FullDotDPS" },
	{ key = "seed", label = "Search seed", x = 354, y = 380, width = 126, default = "1" },
	{ key = "targetNodeIds", label = "Target node ID", compactLabel = "Target node", x = 12, y = 402, width = 126, placeholder = "Optional; use search" },
	{ key = "addNodeIds", label = "Add node IDs", x = 354, y = 402, width = 126, placeholder = "Comma-separated PoB IDs" },
	{ key = "removeNodeIds", label = "Remove node IDs", x = 12, y = 424, width = 126, placeholder = "Allocated PoB IDs" },
	{ key = "requiredNodeIds", label = "Required node IDs", compactLabel = "Required nodes", x = 354, y = 424, width = 126, placeholder = "Must remain allocated" },
	{ key = "forbiddenNodeIds", label = "Forbidden node IDs", compactLabel = "Forbidden nodes", x = 12, y = 446, width = 126, placeholder = "Unallocated only" },
		{ key = "scenarioProfile", label = "Scenario profile", compactLabel = "Scenario", x = 354, y = 446, width = 126, default = "Current", placeholder = "Current / PinnacleChassis" },
	{ key = "scenarioEnemyPreset", hidden = true, default = "Active" },
	{ key = "scenarioEnemyLevel", hidden = true, default = "" },
	{ key = "baseClassId", hidden = true },
	{ key = "ascendancyId", hidden = true, default = "" },
	{ key = "ascendancyPointBudget", hidden = true, default = "auto" },
	{ key = "guidedProfile", hidden = true, default = "beginner" },
	{ key = "treeBudgetMode", hidden = true, default = "level" },
	{ key = "searchAllClasses", hidden = true },
	{ key = "generationPhase", hidden = true, default = "tree" },
	{ key = "damageFocus", hidden = true, default = "Auto" },
	{ key = "defenseProfile", hidden = true, default = "Auto" },
	{ key = "rankingPriority", hidden = true, default = "ObjectiveFirst" },
	{ key = "nodePotentialAnalysis", hidden = true, default = "false" },
	{ key = "phaseCheckpointsJson", hidden = true, default = "{}" },
	{ key = "targetSkillGroupIndex", hidden = true },
	{ key = "targetSkillIndex", hidden = true },
	{ key = "targetSkillGemId", hidden = true },
	{ key = "proposalBudget", hidden = true, default = "120" },
	{ key = "timeoutSeconds", hidden = true, default = "300" },
	{ key = "routePlannerModelMode", hidden = true, default = "approved_or_fallback" },
	{ key = "routePlannerModelPackageId", hidden = true, default = "" },
	{ key = "routePlannerSearchMode", hidden = true, default = "SINGLE_SKILL_ONLY" },
	{ key = "routePlannerDpsTier", hidden = true, default = "TIER_10M_TO_25M" },
	{ key = "routePlannerEhpTier", hidden = true, default = "TIER_50K_TO_100K" },
	{ key = "routePlannerElementalHitTier", hidden = true, default = "TIER_10K_TO_20K" },
	{ key = "routePlannerPhysicalHitTier", hidden = true, default = "TIER_10K_TO_20K" },
	{ key = "routePlannerElementalResists", hidden = true, default = "CAP_EFFECTIVE" },
	{ key = "routePlannerChaosResist", hidden = true, default = "POSITIVE_OR_CAP" },
	{ key = "routePlannerCrossSkillMode", hidden = true, default = "SINGLE_SKILL_ONLY" },
	{ key = "routePlannerAggressiveness", hidden = true, default = "BALANCED_LOCAL_SEARCH" },
	{ key = "routePlannerGraphRadius", hidden = true, default = "4" },
	{ key = "routePlannerProposalLimit", hidden = true, default = "40000" },
	{ key = "routePlannerExactEvaluationBudget", hidden = true, default = "5000" },
	{ key = "routePlannerConversionRoute", hidden = true, default = "NONE" },
	{ key = "routePlannerConversionMinimum", hidden = true, default = "100" },
	{ key = "routePlannerTargetNodeId", hidden = true, default = "" },
	{ key = "routePlannerTargetNodeName", hidden = true, default = "" },
	{ key = "routePlannerTargetTreeVersion", hidden = true, default = "" },
	{ key = "routePlannerUseNodePower", hidden = true, default = "true" },
	{ key = "routePlannerScenario", hidden = true, default = "Current" },
	{ key = "requiredItemsJson", hidden = true, default = "{}" },
	{ key = "searchStoredItems", hidden = true, default = "true" },
	{ key = "searchSyntheticGear", hidden = true, default = "false" },
	{ key = "syntheticItemLevel", hidden = true, default = "" },
	{ key = "syntheticItemCostChaos", hidden = true, default = "" },
	{ key = "catalystCostChaos", hidden = true, default = "" },
}

local conversionTypes = { "Physical", "Lightning", "Cold", "Fire", "Chaos" }

local function parsePositiveIndex(value)
	local number = tonumber(value)
	return number and number == math.floor(number) and number > 0 and number or nil
end

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function boundedNodeEvidencePriorities(values)
	local result, count = { }, 0
	for rawId, rawPriority in pairs(type(values) == "table" and values or { }) do
		local nodeId, priority = tonumber(rawId), tonumber(rawPriority)
		if nodeId and nodeId > 0 and nodeId <= 2147483647 and nodeId == math.floor(nodeId)
			and isFiniteNumber(priority) and count < 512 then
			result[nodeId] = math.max(0, math.min(1, priority))
			count = count + 1
		end
	end
	return result
end

local function boundedEdgeEvidencePriorities(values)
	local result, count = { }, 0
	for rawKey, rawPriority in pairs(type(values) == "table" and values or { }) do
		local leftText, rightText
		if type(rawKey) == "string" then leftText, rightText = rawKey:match("^(%d+):(%d+)$") end
		local left, right, priority = tonumber(leftText), tonumber(rightText), tonumber(rawPriority)
		if left and right and left > 0 and right > left and right <= 2147483647
			and left == math.floor(left) and right == math.floor(right)
			and isFiniteNumber(priority) and count < 1024 then
			result[tostring(left) .. ":" .. tostring(right)] = math.max(0, math.min(1, priority))
			count = count + 1
		end
	end
	return result
end

local function boundedArchiveRoutePatterns(values, compatibleBuildCount)
	local result = { }
	if (tonumber(compatibleBuildCount) or 0) < 2 or type(values) ~= "table" then return result end
	for _, rawPattern in ipairs(values) do
		if #result >= 24 then break end
		if type(rawPattern) == "table" and type(rawPattern.nodeIds) == "table" then
			local nodeIds, seen = { }, { }
			for _, rawId in ipairs(rawPattern.nodeIds) do
				local nodeId = tonumber(rawId)
				if nodeId and nodeId > 0 and nodeId <= 2147483647 and nodeId == math.floor(nodeId)
					and not seen[nodeId] and #nodeIds < 4096 then
					seen[nodeId] = true
					nodeIds[#nodeIds + 1] = nodeId
				end
			end
			if #nodeIds > 0 then
				local supportCount = tonumber(rawPattern.supportCount) or 0
				local sampleCount = tonumber(rawPattern.sampleCount) or tonumber(compatibleBuildCount) or 0
				local similarity = tonumber(rawPattern.similarity) or 0
				if isFiniteNumber(supportCount) and isFiniteNumber(sampleCount) and isFiniteNumber(similarity)
					and supportCount >= 1 and sampleCount >= 2 then
					result[#result + 1] = {
						nodeIds = nodeIds,
						supportCount = math.min(math.floor(supportCount), 1000000),
						sampleCount = math.min(math.floor(sampleCount), 1000000),
						similarity = math.max(0, math.min(1, similarity)),
					}
				end
			end
		end
	end
	return result
end

local function parseRegionList(value)
	local result, seen = { }, { }
	for entry in tostring(value or ""):gmatch("[^,]+") do
		local name = entry:match("^%s*(.-)%s*$")
		if name ~= "" then
			local canonical = SpatialZones.CanonicalRegionName(name)
			local key = (canonical or name):lower()
			if not seen[key] then
				seen[key] = true
				result[#result + 1] = canonical or name
			end
		end
	end
	return result
end

local function regionSet(values)
	local result = { }
	for _, value in ipairs(values) do result[value:lower()] = true end
	return result
end

local function removeRegion(values, name)
	local result = { }
	for _, value in ipairs(values) do
		if value:lower() ~= name:lower() then result[#result + 1] = value end
	end
	return result
end

local function addRegion(values, name)
	local set = regionSet(values)
	if not set[name:lower()] then values[#values + 1] = name end
	return values
end

local function orderedRegionText(values)
	local set = regionSet(values)
	local result = { }
	for _, name in ipairs(SpatialZones.RegionNames()) do
		if set[name:lower()] then result[#result + 1] = name end
	end
	-- Preserve non-spatial names so a validation issue is never silently lost.
	for _, name in ipairs(values) do
		if not SpatialZones.CanonicalRegionName(name) then result[#result + 1] = name end
	end
	return table.concat(result, ",")
end

function OptimizerTabClass:CanEditSpatialZones()
	if not self.build or not self.build.spec or not self.build.spec.tree then
		return false, "Open a build with an active passive tree before editing spatial zones"
	end
	if self.job and self.job.status == "running" then
		return false, "Cancel or finish the active optimization before changing its Matrix"
	end
	local classNames = { }
	for _, class in pairs(self.build.spec.tree.classes or { }) do
		if class.name then classNames[class.name:lower()] = true end
	end
	local parsedRegions = { }
	for _, key in ipairs({ "allowedRegions", "requiredRegions", "forbiddenRegions" }) do
		parsedRegions[key] = parseRegionList(self.textValues[key])
		for _, name in ipairs(parsedRegions[key]) do
			if not SpatialZones.CanonicalRegionName(name) then
				if classNames[name:lower()] then
					return false, "Clear class-start filters before using the spatial tree editor; the two filter modes cannot be mixed"
				end
				return false, "Unknown passive-tree region in " .. key .. ": " .. name
			end
		end
	end
	local allowed = regionSet(parsedRegions.allowedRegions)
	local required = regionSet(parsedRegions.requiredRegions)
	local forbidden = regionSet(parsedRegions.forbiddenRegions)
	for _, name in ipairs(SpatialZones.RegionNames()) do
		local key = name:lower()
		if required[key] and forbidden[key] then
			return false, "A spatial zone cannot be both required and forbidden: " .. name
		end
		if allowed[key] and forbidden[key] then
			return false, "A spatial zone cannot be both allowed and forbidden: " .. name
		end
		if next(allowed) and required[key] and not allowed[key] then
			return false, "A required zone is outside the current allow-list: " .. name
		end
	end
	return true
end

function OptimizerTabClass:GetSpatialRegionState(region)
	local canonical = SpatialZones.CanonicalRegionName(region)
	if not canonical then return "unknown" end
	local allowed = parseRegionList(self.textValues.allowedRegions)
	local required = parseRegionList(self.textValues.requiredRegions)
	local forbidden = parseRegionList(self.textValues.forbiddenRegions)
	local allowedSet, requiredSet, forbiddenSet = regionSet(allowed), regionSet(required), regionSet(forbidden)
	local key = canonical:lower()
	if forbiddenSet[key] then return "forbidden" end
	if requiredSet[key] then return "required" end
	if #allowed > 0 then
		if allowedSet[key] then return "allowed" end
		if key == "hub" and next(allowedSet) then return "transit" end
		return "excluded"
	end
	return "open"
end

function OptimizerTabClass:ToggleSpatialRegion(region, action)
	local canonical = SpatialZones.CanonicalRegionName(region)
	if not canonical then return false, "Unknown spatial region: " .. tostring(region) end
	if action ~= "allow" and action ~= "require" and action ~= "forbid" then
		return false, "Spatial zone action must be allow, require, or forbid"
	end
	local editable, editError = self:CanEditSpatialZones()
	if not editable then return false, editError end

	local allowed = parseRegionList(self.textValues.allowedRegions)
	local required = parseRegionList(self.textValues.requiredRegions)
	local forbidden = parseRegionList(self.textValues.forbiddenRegions)
	local key = canonical:lower()
	local allowedSet, requiredSet, forbiddenSet = regionSet(allowed), regionSet(required), regionSet(forbidden)
	if action == "allow" then
		if allowedSet[key] then
			allowed = removeRegion(allowed, canonical)
			required = removeRegion(required, canonical)
		else
			allowed = addRegion(allowed, canonical)
			forbidden = removeRegion(forbidden, canonical)
		end
	elseif action == "require" then
		if requiredSet[key] then
			required = removeRegion(required, canonical)
		else
			required = addRegion(required, canonical)
			forbidden = removeRegion(forbidden, canonical)
			-- Required waypoints must remain reachable when an allow-list exists.
			if #allowed > 0 then allowed = addRegion(allowed, canonical) end
		end
	else
		if forbiddenSet[key] then
			forbidden = removeRegion(forbidden, canonical)
		else
			forbidden = addRegion(forbidden, canonical)
			allowed = removeRegion(allowed, canonical)
			required = removeRegion(required, canonical)
		end
	end

	local newValues = {
		allowedRegions = orderedRegionText(allowed),
		requiredRegions = orderedRegionText(required),
		forbiddenRegions = orderedRegionText(forbidden),
	}
	for field, value in pairs(newValues) do
		self.textValues[field] = value
		local control = self.controls["text_" .. field]
		if control then control:SetText(value, false) end
	end
	self.modFlag = true
	self.result = nil -- a candidate evaluated under the old branch mask is no longer applicable
	self.statusMessage = "Spatial Matrix updated. Run the optimizer to evaluate the new mask."
	return true
end

function OptimizerTabClass.FormatViolation(violation)
	if type(violation) ~= "table" then return "Unknown optimizer constraint failure" end
	local label = tostring(violation.label or violation.key or "Optimizer constraint")
	local reason = type(violation.reason) == "string" and violation.reason or ""
	if violation.key == "conversion_route" or violation.key == "trigger_breakpoint" or violation.key == "branch_filter"
		or violation.key == "branch_or_point_limit" or violation.key == "candidate_reconstruction"
		or violation.key == "skill_entity_limit" or tostring(violation.key):find("activity_sustain", 1, true) then
		return reason ~= "" and (label .. ": " .. reason) or label
	end
	if isFiniteNumber(violation.actual) and isFiniteNumber(violation.required) then
		if reason == "Above strict maximum" or reason == "Above PoB's native level and act-quest point limit" then
			return string.format("%s: %s > %s", label, metricDisplayValue(violation.key, violation.actual), metricDisplayValue(violation.key, violation.required))
		end
		return string.format("%s: %s < %s", label, metricDisplayValue(violation.key, violation.actual), metricDisplayValue(violation.key, violation.required))
	end
	return reason ~= "" and (label .. ": " .. reason) or label
end

local function appendDetailRows(rows, text, width, color, fontSize)
	fontSize = fontSize or 14
	local source = DisplayText.Native(sanitizeDetailText(text))
	if source == "" then
		rows[#rows + 1] = { "", height = 6 }
		return
	end
	local wrapped = main:WrapString(source, fontSize, math.max(120, width))
	if type(wrapped) ~= "table" or #wrapped == 0 then wrapped = { source } end
	for _, line in ipairs(wrapped) do
		rows[#rows + 1] = { (color or "^7") .. line, height = fontSize + 1 }
	end
end

function OptimizerTabClass.FormatResultDetails(tab, viewWidth, selectedRoute)
	local result = tab and tab.result
	local rows = { }
	local width = math.max(260, (tonumber(viewWidth) or 760) - 52)
	local function add(text, color, fontSize) appendDetailRows(rows, text, width, color, fontSize) end
	local function heading(text)
		add(text, "^7", 15)
		add(string.rep("-", math.min(72, math.max(12, math.floor(width / 8)))), "^8", 12)
	end
	if type(result) ~= "table" then
		add("No optimizer result is available. Run the optimizer first.", "^8")
		return rows
	end
	if type(tab.build) == "table" then
		local freshness, reason = OptimizerTabClass.RefreshResultFreshness(tab, true)
		if freshness == "stale" then
			add("This optimizer result is stale and cannot describe the active build.", "^1", 16)
			add(tostring(reason or "The build or Matrix changed after the search."), "^8")
			add("The previous metrics and deficits are hidden. Run the optimizer again to produce a result for the current state.", "^8")
			return rows
		elseif freshness == "unverified" then
			add("This optimizer result is not verified for the active build.", "^1", 16)
			add(tostring(reason or "The result is missing build or Matrix provenance."), "^8")
			add("The previous metrics and deficits are hidden. Run the optimizer again to produce a verifiable result.", "^8")
			return rows
		end
	end
	if result.routePlanner == true and (routePlannerProposalUsesFlask(tab.build, result.candidate)
		or routePlannerProposalUsesFlask(tab.build, result.bestObservedIdentity)) then
		add("Esta rota foi descartada: o AI Planner não permite alterar frascos. Execute a busca novamente para obter resultados válidos.", "^1", 15)
		return rows
	end

	local status = tostring(result.status or "unknown")
	if status == "no_feasible_candidate" then
		add("No candidate passed every hard requirement in this bounded search.", "^1", 16)
		if result.failureEvidence == "structural_validation" then
			add("Evidence: structural validation only; no candidate reached the exact PoB calculator. This does not prove mathematical infeasibility.", "^8")
		elseif result.failureEvidence == "exact_calculation" then
			add("Evidence: at least one legal candidate reached the exact PoB calculator. This bounded search does not prove a global optimum or infeasibility.", "^8")
		else
			add("Evidence type: " .. status .. ". A bounded search cannot prove global infeasibility.", "^8")
		end
	elseif status == "feasible" then
		add("A candidate passed every strict gate. Review the exact metrics and scenario before applying it as a reversible variation.", "^2", 16)
	else
		add("Optimizer result status: " .. status, "^8", 16)
	end

	local values = tab.textValues or { }
	local build = tab.build or { }
	local spec = build.spec or { }
	local tree = spec.tree or { }
	local selectedClassId = tostring(values.baseClassId or spec.curClassId or "unknown")
	local selectedClassName = "class ID " .. selectedClassId
	for name, classId in pairs(tree.classNameMap or { }) do
		if tostring(classId) == selectedClassId then selectedClassName = tostring(name); break end
	end
	local activeClassName = tostring(spec.curClassName or "unknown")
	local ascendancyConstraint = sanitizeDetailText(values.ascendancyId or "")
	local ascendancyConstraintName = ascendancyConstraint ~= "" and ("ID " .. ascendancyConstraint) or "auto-selected by exact search"
	local selectedClass = tree.classes and tree.classes[tonumber(selectedClassId)]
	local selectedAscendancy = selectedClass and selectedClass.classes and selectedClass.classes[tonumber(ascendancyConstraint)]
	if selectedAscendancy and selectedAscendancy.name then ascendancyConstraintName = selectedAscendancy.name .. " (" .. ascendancyConstraintName .. ")" end
	local groupIndex = tonumber(values.targetSkillGroupIndex)
	local skillIndex = tonumber(values.targetSkillIndex)
	local targetGroup = groupIndex and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	local targetSkill = targetGroup and targetGroup.displaySkillList and targetGroup.displaySkillList[skillIndex or targetGroup.mainActiveSkill or 1]
	local gemName = targetSkill and (targetSkill.name or targetSkill.activeEffect and targetSkill.activeEffect.grantedEffect
		and targetSkill.activeEffect.grantedEffect.name)
	local gemId = tostring(values.targetSkillGemId or "")
	if (not gemName or gemName == "") and gemId ~= "" and build.data and build.data.gems then
		local gemData = build.data.gems[gemId]
		gemName = gemData and gemData.name
	end
	local skillText = gemName or gemId ~= "" and gemId or "not selected"
	if groupIndex then skillText = skillText .. " (group " .. tostring(groupIndex) .. ", skill " .. tostring(skillIndex or 1) .. ")" end
	heading("Build direction and search")
	add("Active PoB: " .. activeClassName .. " / " .. tostring(spec.curAscendClassName or "None")
		.. "; optimizer base class: " .. selectedClassName .. "; ascendancy constraint: " .. ascendancyConstraintName)
	add("Target skill: " .. skillText .. "; phase: " .. tostring(values.generationPhase or "tree")
		.. "; scenario: " .. tostring(result.scenarioProfile or values.scenarioProfile or "Current"))
	add("Exact evaluations: " .. tostring(tonumber(result.evaluations) or 0) .. " / " .. tostring(values.evaluationBudget or "unknown")
		.. "; search seed: " .. tostring(values.seed or "1")
		.. "; best normalized deficit: " .. (isFiniteNumber(result.bestObservedDeficit) and groupedNumber(result.bestObservedDeficit) or "not available"))
	local observedIdentity = result.bestObservedIdentity
	local detailLevel = result.evaluation and result.evaluation.characterLevel
		or observedIdentity and observedIdentity.characterLevel or build.characterLevel or 1
	local detailBudget = result.evaluation and result.evaluation.ascendancyPointBudget
		or observedIdentity and observedIdentity.ascendancyPointBudget
		or Inputs.MaxAscendancyPointBudget(detailLevel)
	add("PoB character level: " .. tostring(detailLevel) .. "; ascendancy points permitted per route: "
		.. tostring(detailBudget) .. " (Labyrinth completion is not stored in PoB; the level ceiling is conservative).", "^8")
	if type(observedIdentity) == "table" then
		add("Best observed candidate: " .. tostring(observedIdentity.candidateLabel or "exact candidate")
			.. "; " .. tostring(observedIdentity.baseClass or "unknown") .. " / "
			.. tostring(observedIdentity.ascendancy or "None") .. " / "
			.. tostring(observedIdentity.secondaryAscendancy or "None")
			.. "; passives " .. tostring(observedIdentity.passivePointsUsed or "unknown")
			.. "; ascendancy points " .. tostring(observedIdentity.ascendancyPointsUsed or "unknown")
			.. "; level " .. tostring(observedIdentity.characterLevel or detailLevel), "^8")
	else
		add("Best observed candidate identity: unavailable; no exact candidate established it.", "^8")
	end
	add("Candidate application: " .. (status == "feasible" and "not applied by opening this panel" or "unavailable; no candidate passed every hard gate"), "^8")

	local baseline = result.searchBaseline
	local baselineIsExact = type(baseline) == "table" and baseline.exact == true and type(baseline.metrics) == "table"
	local baselineMetrics, baselineKind, comparisonBaselineRecord = routePlannerComparisonBaseline(result)
	local displayedEvaluation = selectedRoute and selectedRoute.evaluation or result.evaluation
	local displayedCandidate = selectedRoute or result.candidate
	local observedMetrics = status == "feasible"
		and displayedEvaluation and displayedEvaluation.metrics
		or result.failureEvidence == "exact_calculation" and result.bestObservedMetrics
	local objectiveKey = tostring(values.objectiveMetric or result.objectiveMetric or "CombinedDPS")
	if not Inputs.objectives[objectiveKey] then objectiveKey = "CombinedDPS" end
	local damageFocus = tostring(values.damageFocus or "Auto")
	local defenseProfile = tostring(values.defenseProfile or "Auto")
	local damageFocusMetric = Ranking.DamageFocusMetricKey(damageFocus)
	local profileMetricKeys = {
		Auto = { "TotalEHP", "Life", "EnergyShield" },
		Life = { "Life", "TotalEHP", "LifeUnreserved" },
		EnergyShield = { "EnergyShield", "TotalEHP" },
		Hybrid = { "Life", "EnergyShield", "TotalEHP" },
		Ward = { "Ward", "TotalEHP" },
		Armour = { "Armour" },
		Evasion = { "Evasion" },
		Block = { "BlockChance" },
		SpellBlock = { "SpellBlockChance" },
		SpellSuppression = { "SpellSuppressionChance" },
	}
	local comparisonMetricKeys, seenComparisonMetrics = { }, { }
	local function addComparisonMetric(key)
		local limit = result.routePlanner == true and 14 or 6
		if #comparisonMetricKeys >= limit or type(key) ~= "string" or seenComparisonMetrics[key] then return end
		seenComparisonMetrics[key] = true
		comparisonMetricKeys[#comparisonMetricKeys + 1] = key
	end
	addComparisonMetric(objectiveKey)
	if result.routePlanner == true then
		addComparisonMetric(damageFocusMetric)
		for _, key in ipairs({ "CombinedDPS", "FullDPS", "TotalEHP", "Life", "EnergyShield",
			"PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken",
			"FireResist", "ColdResist", "LightningResist", "ChaosResist" }) do
			addComparisonMetric(key)
		end
	else
		if objectiveKey ~= "CombinedDPS" then addComparisonMetric("CombinedDPS") end
		for _, key in ipairs(profileMetricKeys[defenseProfile] or profileMetricKeys.Auto) do addComparisonMetric(key) end
		addComparisonMetric("SpellSuppressionChance")
		addComparisonMetric("BlockChance")
	end
	heading("Compact comparison cards — exact PoB, same scenario")
	add("Objective: " .. metricDisplayName(objectiveKey) .. "; defense focus: " .. defenseProfile .. "; scenario: "
		.. tostring(result.scenarioProfile or values.scenarioProfile or "Current")
		.. ". Deltas are absolute candidate minus baseline; only shared finite metrics are compared.", "^8", 13)
	if result.routePlanner == true then
		add("Damage focus: " .. damageFocus .. " guides proposal generation and exact ranking; hard gates still use native "
			.. metricDisplayName(objectiveKey) .. " and the selected floors.", "^8", 13)
		if damageFocusMetric then
			local elementalFocus = damageFocus == "Fire" or damageFocus == "Cold" or damageFocus == "Lightning"
			local focusScope = elementalFocus and "native average damage per hit, not isolated elemental DPS"
				or "the exact native PoB focus output"
			add("Focus ranking metric: " .. metricDisplayName(damageFocusMetric) .. " (" .. focusScope
				.. "); exact baseline and candidate values are shown below.", "^8", 13)
		elseif damageFocus ~= "Auto" then
			add("PoB does not expose a compatible exact focus metric for " .. damageFocus
				.. " in this result; it guides proposal order only and does not replace total DPS ranking.", "^8", 13)
		end
	end
	local rankingInfo = displayedEvaluation and displayedEvaluation.ranking or result.ranking
	if type(rankingInfo) == "table" then
		local orderedMetrics = { }
		for _, key in ipairs({ rankingInfo.primaryMetric, rankingInfo.secondaryMetric, rankingInfo.tertiaryMetric }) do
			if type(key) == "string" and key ~= "" then orderedMetrics[#orderedMetrics + 1] = metricDisplayName(key) end
		end
		if #orderedMetrics == 0 then orderedMetrics[1] = metricDisplayName(objectiveKey) end
		add("Winner ordering: " .. tostring(rankingInfo.priority or "ObjectiveFirst") .. " — "
			.. table.concat(orderedMetrics, " → ") .. ". Hard gates are unchanged.", "^8", 13)
	end
	if baselineIsExact then
		local baselineState = baseline.feasible == true and "PASS" or "FAIL"
		local violationCount = isFiniteNumber(baseline.violationCount) and tostring(math.max(0, math.floor(baseline.violationCount))) or "count unavailable"
		add("Baseline card — " .. sanitizeDetailText(baseline.label or "search baseline") .. " — "
			.. baselineState .. " strict gates (" .. violationCount .. " violations).", baseline.feasible and "^2" or "^1", 14)
	elseif baselineKind == "loaded_build_comparison" then
		local socketNote = comparisonBaselineRecord and comparisonBaselineRecord.socketRepairRequired == true
			and "; Main Skill sockets/links require repair" or ""
		add("Comparison reference — loaded build's native PoB output only; it is not a gate-validated search baseline"
			.. socketNote .. ".", "^8", 14)
	else
		add("Baseline card — no exact same-run baseline; deltas are unavailable.", "^8", 14)
	end
	local function addCardMetrics(metrics, compareToBaseline)
		if type(metrics) ~= "table" then
			add("Exact metric snapshot unavailable.", "^8", 13)
			return
		end
		local shown = 0
		for _, key in ipairs(comparisonMetricKeys) do
			local value = metrics[key]
			if isFiniteNumber(value) then
				local before = compareToBaseline and baselineMetrics and baselineMetrics[key]
				if isFiniteNumber(before) then
					add(metricDisplayLine(key, value, before), "^7", 13)
				else
					add(metricDisplayLine(key, value), "^7", 13)
				end
				shown = shown + 1
			end
		end
		if shown == 0 then add("No shared finite comparison metrics are available.", "^8", 13) end
	end
	if baselineMetrics then addCardMetrics(baselineMetrics, false) end
	if status == "feasible" and type(observedMetrics) == "table" then
		local evaluation = displayedEvaluation or { }
		local candidate = displayedCandidate or { }
		local candidateLabel = sanitizeDetailText(evaluation.candidateLabel or candidate.label or "feasible candidate")
		add((selectedRoute and "Selected exact route — " or "Winner card — ") .. candidateLabel .. " — PASS all hard gates; not applied.", "^2", 14)
		if result.routePlanner == true then
			if candidate.archiveDerivedPassiveRoute == true then
				local origin = candidate.archivedRouteComposition == true
					and "Rota composta a partir de padrão passivo observado em builds arquivadas; alterações recalculadas no PoB."
					or "Rota passiva derivada de padrão observado em builds arquivadas; recalculada no PoB."
				add("Origem: " .. origin, "^8", 13)
			end
			local routeChanges, seenRouteChanges = { }, { }
			local function addRouteChange(value)
				if #routeChanges < 12 and type(value) == "string" and value ~= "" and not seenRouteChanges[value] then
					seenRouteChanges[value] = true
					routeChanges[#routeChanges + 1] = value
				end
			end
			local gear = candidate.gearVariant
			if type(gear) == "table" then
				local itemBySlot, slots, seenSlots = { }, { }, { }
				for _, item in ipairs(gear.items or { }) do
					local slot = type(item) == "table" and (item.slot or item.slotName)
					if type(slot) == "string" then itemBySlot[slot] = item end
				end
				for _, slot in ipairs(gear.changedSlots or { }) do
					if type(slot) == "string" and not seenSlots[slot] then
						seenSlots[slot] = true
						slots[#slots + 1] = slot
					end
				end
				if #slots == 0 then
					for _, item in ipairs(gear.items or { }) do
						local slot = type(item) == "table" and (item.slot or item.slotName)
						if type(slot) == "string" and not seenSlots[slot] then
							seenSlots[slot] = true
							slots[#slots + 1] = slot
						end
					end
				end
				for _, slot in ipairs(slots) do
					local item = itemBySlot[slot]
					local name = item and (item.name or item.baseName or item.fullName) or "equipment reformulado"
					local suffix = item and item.socketRepair == true and " (sockets/links reconfigurados)"
						or item and item.synthetic == true and item.affixCount
						and (" (raro teórico; " .. tostring(item.affixCount) .. "/4 afixos)") or ""
					addRouteChange(tostring(slot) .. " → " .. tostring(name) .. suffix)
				end
				for _, generated in ipairs(gear.generatedItems or { }) do
					local item = generated and generated.item
					local slot = tostring(generated and (generated.slotName or generated.slot) or "equipamento")
					if generated.kind ~= "socket_repair" then
						for _, modLine in ipairs(item and item.explicitModLines or { }) do
							if type(modLine) == "table" and type(modLine.line) == "string" then
								addRouteChange("Afixo em " .. slot .. " → " .. modLine.line)
							end
						end
					end
				end
			end
			local function appendNodeChanges(nodeIds, prefix)
				for _, nodeId in ipairs(nodeIds or { }) do
					local node = build.spec and build.spec.nodes
						and (build.spec.nodes[nodeId] or build.spec.nodes[tonumber(nodeId)]) or nil
					addRouteChange(prefix .. " " .. tostring(node and (node.dn or node.name) or ("passiva #" .. tostring(nodeId))))
				end
			end
			appendNodeChanges(candidate.nodeIds, "Adicionar passiva")
			appendNodeChanges(candidate.removeNodeIds, "Remover passiva")
			for _, variant in ipairs(candidate.gemVariants or (candidate.gemVariant and { candidate.gemVariant }) or { }) do
				local gemData = build.data and build.data.gems and build.data.gems[variant.gemId]
				local gemName = variant.name or (gemData and gemData.name) or variant.gemId or "gema"
				addRouteChange("Gema do grupo " .. tostring(variant.groupIndex or "?")
					.. " → " .. tostring(gemName))
			end
			if #routeChanges > 0 then
				heading("Alterações exatas contra a build base")
				for _, change in ipairs(routeChanges) do add("Alteração: " .. sanitizeDetailText(change), "^7", 13) end
			end
		end
		addCardMetrics(observedMetrics, true)
		local activityResult = evaluation.activitySustain
		if type(activityResult) == "table" and activityResult.optimizerScheduleApplied then
			add("Strict activity-sustain gate: " .. tostring(activityResult.scope)
				.. "; exact PoB per-skill resource rates scaled by the saved average-use schedule."
				.. " This does not recalculate or certify scheduled damage, event timing, or encounter uptime.", "^8", 13)
		end
		if isFiniteNumber(evaluation.passivePointsUsed) then
			add("Passive points used: " .. tostring(evaluation.passivePointsUsed) .. ".", "^8", 13)
		end
		local alternativeCount = 0
		for _, alternative in ipairs(result.paretoFront or { }) do
			if alternative ~= displayedCandidate and alternative ~= result.candidate
				and type(alternative) == "table" and type(alternative.evaluation) == "table"
				and type(alternative.evaluation.metrics) == "table"
				and not (result.routePlanner == true and routePlannerProposalUsesFlask(build, alternative)) then
				alternativeCount = alternativeCount + 1
				if not selectedRoute and alternativeCount <= 5 then
					local alternativeLabel = sanitizeDetailText(alternative.evaluation.candidateLabel or alternative.label or "Pareto candidate")
					add("Pareto alternative #" .. tostring(alternativeCount) .. " — " .. alternativeLabel
						.. " — PASS hard gates; not applied.", "^7", 14)
					addCardMetrics(alternative.evaluation.metrics, true)
					if isFiniteNumber(alternative.evaluation.passivePointsUsed) then
						add("Passive points used: " .. tostring(alternative.evaluation.passivePointsUsed) .. ".", "^8", 13)
					end
				end
			end
		end
		if alternativeCount == 0 then add("No additional exact Pareto alternatives were returned.", "^8", 13)
		elseif selectedRoute then
			add(tostring(alternativeCount) .. " other exact alternatives are available in the route selector. Each selector label shows DPS/EHP delta against the exact baseline.", "^8", 13)
		elseif alternativeCount > 5 then
			add("Showing the first 5 of " .. tostring(alternativeCount) .. " exact alternatives; choose any route above to see its full exact delta card.", "^8", 13)
		end
	elseif result.failureEvidence == "exact_calculation" and type(observedMetrics) == "table" then
		local identity = result.bestObservedIdentity or { }
		local label = sanitizeDetailText(identity.candidateLabel or "Best observed exact candidate")
		local violationCount = #(result.bestObservedViolations or result.violations or { })
		local stateText = violationCount > 0 and ("NOT DELIVERABLE; " .. tostring(violationCount) .. " hard-gate violations.")
			or "NOT DELIVERABLE; strict feasibility was not established."
		add("Best observed card — " .. label .. " — " .. stateText, "^1", 14)
		addCardMetrics(observedMetrics, true)
	else
		add("No exact candidate card is available; the structural result is not a deliverable build.", "^8", 13)
	end
	if result.routePlanner == true and type(result.nearMisses) == "table" then
		local shownNearMisses = 0
		for _, proposal in ipairs(result.nearMisses) do
			if proposal.exact == true and proposal.feasible == false
				and not routePlannerProposalUsesFlask(build, proposal) then
				shownNearMisses = shownNearMisses + 1
				if shownNearMisses == 1 then
					if status == "feasible" then
						heading("Combinações exatas adicionais — não aprovadas")
						add("A rota aprovada acima passou por todos os gates. Estas propostas também foram recalculadas pelo PoB, mas ainda falham em uma ou mais metas e não podem ser carregadas.", "^8", 13)
					else
						heading("Combinações recalculadas pelo PoB — ainda abaixo de metas")
						add("Estas propostas são exatas e ajudam a orientar o próximo ajuste. Nenhuma passou por todos os objetivos; não são rotas aprovadas e não podem ser carregadas daqui.", "^8", 13)
					end
				end
				add("Proposta exata #" .. tostring(shownNearMisses) .. " — "
					.. sanitizeDetailText(proposal.label or "Combinação")
					.. " — NÃO APROVADA; déficit normalizado "
					.. (isFiniteNumber(proposal.normalizedDeficit) and groupedNumber(proposal.normalizedDeficit) or "indisponível"), "^1", 14)
				if proposal.archiveDerivedPassiveRoute == true then
					add("Origem: padrão passivo observado em builds arquivadas; métricas recalculadas pelo motor nativo do PoB.", "^8", 13)
				end
				for _, change in ipairs(proposal.changes or { }) do
					add("Alteração: " .. sanitizeDetailText(change), "^7", 13)
				end
				addCardMetrics(proposal.metrics, true)
				for index, violation in ipairs(proposal.violations or { }) do
					if index > 3 then break end
					add("Meta pendente: " .. sanitizeDetailText(OptimizerTabClass.FormatViolation(violation)), "^1", 13)
				end
			end
		end
		if shownNearMisses == 0 and result.failureEvidence == "exact_calculation" then
			add("O cálculo exato encontrou déficits, mas nenhuma combinação alterada foi preservada como proposta resumida.", "^8", 13)
		end
	end

	heading("Hard requirements saved in the Matrix")
	local hardCount = 0
	for _, definition in ipairs(Inputs.metricDefinitions) do
		local raw = sanitizeDetailText(values[definition.key] or "")
		if raw ~= "" then
			hardCount = hardCount + 1
			local operator = definition.operator == "<=" and "maximum <= " or "minimum >= "
			add(definition.label .. ": " .. operator .. raw .. (definition.unit ~= "" and (" " .. definition.unit) or ""))
		end
	end
	if hardCount == 0 then add("No numeric hard floors or ceilings are set in the Matrix.", "^8") end
	local conversionRoute = sanitizeDetailText(values.conversionRoute or "")
	if conversionRoute ~= "" then
		add("Hard conversion route: " .. conversionRoute:gsub(">", " -> ") .. "; minimum on each edge: "
			.. sanitizeDetailText(values.conversionMin or "100") .. "%")
	else
		add("Hard conversion route: none")
	end
	for _, field in ipairs({
		{ "Allowed regions", "allowedRegions" }, { "Required regions", "requiredRegions" },
		{ "Forbidden regions", "forbiddenRegions" }, { "Required node IDs", "requiredNodeIds" },
		{ "Forbidden node IDs", "forbiddenNodeIds" },
	}) do
		local raw = sanitizeDetailText(values[field[2]] or "")
		if raw ~= "" then add(field[1] .. ": " .. raw) end
	end
	add("Point cap: " .. tostring(values.maxTotalPoints or "120") .. "; maximum new points: "
		.. tostring(values.maxAddedPoints or "5"), "^8")

	heading("Best observed hard-gate deficits")
	local violations = result.bestObservedViolations or result.violations or { }
	if #violations == 0 then
		add("No structured violation row was returned.", "^8")
	else
		for index, violation in ipairs(violations) do
			add("[" .. tostring(index) .. "] " .. OptimizerTabClass.FormatViolation(violation), "^1")
			if violation.key then add("Constraint: " .. metricDisplayName(violation.key), "^8", 12) end
			if isFiniteNumber(violation.actual) and isFiniteNumber(violation.required) then
				local operator = violation.operator or (violation.reason == "Above strict maximum" or violation.reason == "Above PoB's native level and act-quest point limit") and "<=" or ">="
				add("Exact observed value: " .. metricDisplayValue(violation.key, violation.actual)
					.. "; required " .. operator .. " " .. metricDisplayValue(violation.key, violation.required), "^8", 13)
			end
			if type(violation.reason) == "string" and violation.reason ~= "" then add("Reason: " .. violation.reason, "^8", 13) end
		end
	end

	heading("Exact baseline-to-candidate comparison")
	if type(baseline) == "table" and baseline.exact == true and type(baseline.metrics) == "table"
		and type(observedMetrics) == "table" then
		local baselineGate = baseline.feasible and "passes all current strict gates" or "does not pass all current strict gates"
		local candidateLabel = status == "feasible"
			and displayedEvaluation and displayedEvaluation.candidateLabel
			or result.bestObservedIdentity and result.bestObservedIdentity.candidateLabel
			or "best observed exact candidate"
		local candidateGate = status == "feasible" and "passes all strict gates" or "fails at least one strict gate"
		add("Native PoB exact outputs under the selected scenario; candidate minus search baseline.", "^8")
		add("Baseline: " .. tostring(baseline.label or "search baseline") .. " — " .. baselineGate
			.. " (" .. tostring(baseline.violationCount or 0) .. " violations).", "^8")
		add("Candidate: " .. tostring(candidateLabel) .. " — " .. candidateGate .. ".", "^8")
		local comparisonKeys = { }
		for key, before in pairs(baseline.metrics) do
			if type(key) == "string" and isFiniteNumber(before) and isFiniteNumber(observedMetrics[key]) then
				comparisonKeys[#comparisonKeys + 1] = key
			end
		end
		t_sort(comparisonKeys)
		if #comparisonKeys == 0 then
			add("No shared finite exact metrics were returned for this comparison.", "^8")
		else
			for _, key in ipairs(comparisonKeys) do
				local before, after = baseline.metrics[key], observedMetrics[key]
				add(metricDisplayName(key) .. ": " .. metricDisplayValue(key, before) .. " -> "
					.. metricDisplayValue(key, after) .. " (Δ " .. metricDisplayDelta(key, after, before) .. ")", "^7", 13)
			end
		end
	else
		add("A same-run exact baseline and candidate snapshot were not both available; this search budget or failure path did not establish a comparison.", "^8")
	end

	heading(selectedRoute and "Exact PoB metrics for the selected route" or "Exact PoB metrics for the best observed candidate")
	local metrics = observedMetrics or result.bestObservedMetrics or result.evaluation and result.evaluation.metrics or { }
	local metricKeys = { }
	for key, value in pairs(metrics) do
		if type(key) == "string" and isFiniteNumber(value) then metricKeys[#metricKeys + 1] = key end
	end
	t_sort(metricKeys)
	if #metricKeys == 0 then
		add("No exact metric snapshot was returned; inspect the structural reason above.", "^8")
	else
		add("Displayed values preserve the native result's round-trip decimal precision; no display rounding is applied.", "^8", 12)
		for _, key in ipairs(metricKeys) do add(metricDisplayName(key) .. " = " .. metricDisplayValue(key, metrics[key]), "^7", 13) end
	end

	local coverage = result.searchCoverage or { }
	if result.routePlanner == true then
		local evidence = type(tab.nodeEvidence) == "table" and tab.nodeEvidence or { }
		local evidenceStatus = tostring(evidence.status or "not calculated")
		local evidenceCount = tonumber(evidence.compatibleBuildCount) or 0
		local archiveCoverage = type(coverage.phase) == "table"
			and type(coverage.phase.archivedRoutePatterns) == "table" and coverage.phase.archivedRoutePatterns or { }
		heading("Compatible build examples")
		if evidenceStatus == "ready" and evidenceCount > 0 then
			local sourceLabel = evidence.archiveSourceMode == "local_fallback" and "local fallback archive"
				or evidence.archiveSourceMode == "local_archive" and "local archive" or "project archive"
			local directGenerated = tonumber(archiveCoverage.generatedCandidates) or 0
			local composedGenerated = tonumber(archiveCoverage.generatedComposedCandidates) or 0
			local directRetained = tonumber(archiveCoverage.retainedDirectCandidates) or 0
			local composedRetained = tonumber(archiveCoverage.retainedComposedCandidates) or 0
			local directExact = tonumber(archiveCoverage.exactDirectEvaluations) or 0
			local composedExact = tonumber(archiveCoverage.exactComposedEvaluations) or 0
			local directPassed = tonumber(archiveCoverage.exactDirectFeasible) or 0
			local composedPassed = tonumber(archiveCoverage.exactComposedFeasible) or 0
			add(string.format("%s builds do mesmo patch/árvore e classe-base (%s); %s padrões passivos no %s.",
				groupedNumber(evidenceCount),
				evidence.skillScope == "class_tree" and "qualquer Main Skill nativa" or "mesma Main Skill",
				groupedNumber(tonumber(archiveCoverage.availablePatterns) or tonumber(evidence.routePatternCount) or 0),
				sourceLabel), "^8", 13)
			add(string.format("Rotas diretas: %s geradas / %s retidas. Combinações compostas com mutações: %s geradas / %s retidas.",
				groupedNumber(directGenerated), groupedNumber(directRetained),
				groupedNumber(composedGenerated), groupedNumber(composedRetained)), "^8", 13)
			add(string.format("Recálculos nativos exatos: %s (%s diretas, %s compostas); passaram todos os pisos: %s (%s diretas, %s compostas).",
				groupedNumber(tonumber(archiveCoverage.exactEvaluations) or (directExact + composedExact)),
				groupedNumber(directExact), groupedNumber(composedExact),
				groupedNumber(tonumber(archiveCoverage.exactFeasible) or (directPassed + composedPassed)),
				groupedNumber(directPassed), groupedNumber(composedPassed)), "^8", 13)
			local gateRepairGenerated = tonumber(archiveCoverage.adaptiveGateRepairGenerated) or 0
			local gateRepairExact = tonumber(archiveCoverage.adaptiveGateRepairExactEvaluations) or 0
			local gateRepairPassed = tonumber(archiveCoverage.adaptiveGateRepairFeasible) or 0
			if gateRepairGenerated > 0 or gateRepairExact > 0 then
				add(string.format("Ajustes dirigidos pelas falhas exatas: %s gerados / %s recalculados / %s passaram todos os pisos.",
					groupedNumber(gateRepairGenerated), groupedNumber(gateRepairExact), groupedNumber(gateRepairPassed)), "^8", 13)
			end
		elseif evidenceStatus == "disabled" then
			add("Archived route examples are disabled. Candidate generation and exact PoB calculations still run from the active build.", "^8", 13)
		else
			local sourceLabel = evidence.archiveSourceMode == "local_fallback" and "local fallback archive"
				or evidence.archiveSourceMode == "local_archive" and "local archive" or "project archive"
			add("No exact-compatible archive patterns were available (" .. evidenceStatus .. ") in the " .. sourceLabel .. ". Native candidate generation still runs from the active build.", "^8", 13)
		end
	end
	local phaseCoverage = coverage.phase
	if type(phaseCoverage) == "table" then
		heading("Search coverage")
		if result.routePlanner == true and type(phaseCoverage.exactEvaluationPlan) == "table" then
			local plan = phaseCoverage.exactEvaluationPlan
			local plannedParts, actualParts = { }, { }
			local seenFamilies = { }
			local familyLabels = { baseline = "baseline", equipment = "equipamentos", skills = "gemas/suportes",
				combined = "combinações", tree = "árvore", configuration = "configuração", other = "outros" }
			local function appendFamilyCount(parts, counts, family)
				local count = tonumber(counts and counts[family]) or 0
				if count > 0 and not seenFamilies[family] then
					seenFamilies[family] = true
					parts[#parts + 1] = tostring(familyLabels[family] or family) .. " " .. tostring(count)
				end
			end
		for _, family in ipairs(plan.familyOrder or { }) do appendFamilyCount(plannedParts, plan.windowFamilyCounts, family) end
		for family, count in pairs(plan.windowFamilyCounts or { }) do
			if (tonumber(count) or 0) > 0 and not seenFamilies[family] then
				seenFamilies[family] = true
				plannedParts[#plannedParts + 1] = tostring(familyLabels[family] or family) .. " " .. tostring(count)
			end
		end
		local exactCounts = phaseCoverage.exactEvaluationsByFamily or { }
		local actualFamilies = { }
		for family, count in pairs(exactCounts) do if (tonumber(count) or 0) > 0 then actualFamilies[#actualFamilies + 1] = family end end
		t_sort(actualFamilies)
		for _, family in ipairs(actualFamilies) do
			actualParts[#actualParts + 1] = tostring(familyLabels[family] or family) .. " " .. tostring(exactCounts[family])
		end
		add("Plano do lote exato (" .. tostring(plan.windowSize or 0) .. "): "
			.. (#plannedParts > 0 and table.concat(plannedParts, ", ") or "sem propostas")
			.. "; " .. tostring(plan.windowFamilyDiversity or 0) .. " famílias representadas.", "^8", 13)
		if #actualParts > 0 then
			add("Cálculos exatos concluídos por família: " .. table.concat(actualParts, ", ") .. ".", "^8", 13)
		end
		seenFamilies = nil
	end
		local nodePowerCoverage = phaseCoverage.nodePower
		if type(nodePowerCoverage) == "table" then
			local nodePowerStat = metricDisplayName(nodePowerCoverage.stat or "")
			if nodePowerCoverage.status == "used" then
				add("Show Node Power: native " .. nodePowerStat .. " guided target order for "
					.. tostring(nodePowerCoverage.prioritizedTargets or 0) .. " of "
					.. tostring(nodePowerCoverage.targets or 0) .. " legal targets. It did not replace exact route metrics or gates.", "^8", 13)
			else
				add("Show Node Power: not used for ranking" .. (nodePowerCoverage.reason and (" — " .. tostring(nodePowerCoverage.reason)) or "."), "^8", 13)
			end
		end
		if result.routePlanner == true then
			add(string.format("Frascos preservados: %d slots ignorados e %d mutações de frasco descartadas.",
				tonumber(phaseCoverage.excludedFlaskSlots) or 0,
				tonumber(phaseCoverage.flaskMutationCandidatesRejected) or 0), "^8", 13)
		end
		if phaseCoverage.uniqueCandidates ~= nil then
			local baselineState = phaseCoverage.baselineEvaluated == true
				and ("exact at evaluation " .. tostring(phaseCoverage.baselineEvaluationIndex or "?"))
				or phaseCoverage.baselineReserved == true and "reserved first; not exactly evaluated"
				or "not reserved"
			add(string.format("Initial proposal pool: %s composed; %s unique; %s duplicates; %s cut by proposal cap",
				tostring(phaseCoverage.composedCandidates or 0), tostring(phaseCoverage.uniqueCandidates or 0),
				tostring(phaseCoverage.duplicateCandidatesDiscarded or 0),
				tostring(phaseCoverage.discardedByProposalBudget or 0)), "^8", 13)
			add(string.format("Final candidate pool: %s retained; %s exact evaluations; baseline %s",
				tostring(phaseCoverage.retainedCandidates or 0), tostring(phaseCoverage.exactEvaluations or 0), baselineState), "^8", 13)
			if (tonumber(phaseCoverage.canonicalizationFallbacks) or 0) > 0 then
				add("Some proposals were kept without deduplication because canonicalization could not prove their identity.", "^8", 13)
			end
			if (tonumber(phaseCoverage.repairPassGeneratedCandidates) or 0) > 0 then
				add(string.format("Deterministic post-baseline gear repair: %s selected; %s new unique; %s duplicates removed; %s cut by proposal cap; %s retained (not GNN-ranked)",
					tostring(phaseCoverage.repairPassGeneratedCandidates),
					tostring(phaseCoverage.repairPassUniqueCandidates or 0),
					tostring(phaseCoverage.repairPassDuplicateCandidatesDiscarded or 0),
					tostring(phaseCoverage.repairPassDiscardedByProposalBudget or 0),
					tostring(phaseCoverage.repairPassRetainedCandidates or 0)), "^8", 13)
			end
		end
		local phaseNames = { }
		for name in pairs(phaseCoverage) do phaseNames[#phaseNames + 1] = tostring(name) end
		t_sort(phaseNames)
		for _, name in ipairs(phaseNames) do
			local entry = phaseCoverage[name]
			if type(entry) == "table" and name ~= "proposalFamilyCountsBefore" and name ~= "proposalFamilyCountsAfter"
				and name ~= "nodePower" and name ~= "exactEvaluationPlan" and name ~= "exactEvaluationsByFamily" then
				add(string.format("%s: generated %s; exact %s; rejected %s", name,
					tostring(entry.generated or entry.proposed or 0), tostring(entry.exact or entry.evaluated or 0),
					tostring(entry.rejected or entry.incompatible or 0)), "^8", 13)
			end
		end
	end
	add("No feasible result within this search budget is not a proof that no valid build exists.", "^8")
	return rows
end

function OptimizerTabClass:OpenResultDetails()
	if type(self.result) ~= "table" then return false, "No optimizer result is available" end
	local screenWidth = tonumber(main.screenW) or 1024
	local screenHeight = tonumber(main.screenH) or 768
	local popupWidth = math.min(900, math.max(540, screenWidth - 32))
	local popupHeight = math.min(620, math.max(360, screenHeight - 32))
	local controls = { }
	local result = self.result
	local routeChoices = { }
	local selectedRoute
	if result.routePlanner == true and result.status == "feasible"
		and not routePlannerProposalUsesFlask(self.build, result.candidate) then
		local seen, metricVectorRoutes = { }, { }
		local damageFocusMetric = Ranking.DamageFocusMetricKey(tostring(self.textValues.damageFocus or "Auto"))
		local routeMetricKeys = { "CombinedDPS", "FullDPS", "FullDotDPS", "TotalEHP", "Life", "EnergyShield",
			"PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken",
			"FireResist", "ColdResist", "LightningResist", "ChaosResist", "SpellSuppressionChance",
			"BlockChance", "Armour", "Evasion" }
		if damageFocusMetric then routeMetricKeys[#routeMetricKeys + 1] = damageFocusMetric end
		local function metricVector(metrics)
			local values = { }
			for _, key in ipairs(routeMetricKeys) do
				local value = metrics[key]
				values[#values + 1] = key .. "=" .. (isFiniteNumber(value) and string.format("%.17g", value) or "-")
			end
			return table.concat(values, "|")
		end
		local function addRoute(route)
			if #routeChoices >= 25 or type(route) ~= "table" or seen[route]
				or route.feasible ~= true or route.sourceSignature ~= result.sourceSignature
				or type(route.evaluation) ~= "table" or route.evaluation.feasible ~= true
				or type(route.evaluation.metrics) ~= "table" or not Candidate.HasMutation(route)
				or routePlannerProposalUsesFlask(self.build, route) then return end
			seen[route] = true
			local evaluation = route.evaluation
			local metrics = evaluation.metrics
			local signature = metricVector(metrics)
			local label = sanitizeDetailText(evaluation.candidateLabel or route.label or "Exact Pareto route")
			local objective = tostring(evaluation.objective or result.objectiveMetric or "CombinedDPS")
			local dps = metrics[objective]
			local ehp = metrics.TotalEHP
			local baselineMetrics = routePlannerComparisonBaseline(result)
			local routeNumber = #routeChoices + 1
			local summary = string.format("%d. %s", routeNumber, label)
			-- Equal metrics do not make two concrete gear/skill/tree mutations interchangeable.
			local sameMetricsAs = metricVectorRoutes[signature]
			if sameMetricsAs then
				summary = summary .. " | mesmas métricas avaliadas da rota " .. tostring(sameMetricsAs) .. "; alteração diferente"
			else
				metricVectorRoutes[signature] = routeNumber
			end
			if isFiniteNumber(dps) then summary = summary .. " | " .. metricDisplayName(objective) .. " " .. metricDisplayValue(objective, dps) end
			if baselineMetrics and isFiniteNumber(dps) and isFiniteNumber(baselineMetrics[objective]) then
				summary = summary .. " (Δ " .. metricDisplayDelta(objective, dps, baselineMetrics[objective]) .. ")"
			end
			if damageFocusMetric and damageFocusMetric ~= objective and isFiniteNumber(metrics[damageFocusMetric]) then
				summary = summary .. " | " .. metricDisplayName(damageFocusMetric) .. " "
					.. metricDisplayValue(damageFocusMetric, metrics[damageFocusMetric])
				if baselineMetrics and isFiniteNumber(baselineMetrics[damageFocusMetric]) then
					summary = summary .. " (Δ " .. metricDisplayDelta(damageFocusMetric, metrics[damageFocusMetric], baselineMetrics[damageFocusMetric]) .. ")"
				end
			end
			if isFiniteNumber(ehp) and objective ~= "TotalEHP" then
				summary = summary .. " | " .. metricDisplayName("TotalEHP") .. " " .. metricDisplayValue("TotalEHP", ehp)
				if baselineMetrics and isFiniteNumber(baselineMetrics.TotalEHP) then
					summary = summary .. " (Δ " .. metricDisplayDelta("TotalEHP", ehp, baselineMetrics.TotalEHP) .. ")"
				end
			end
			local defenseMetrics = { Auto = "TotalEHP", Life = "Life", EnergyShield = "EnergyShield", Hybrid = "TotalEHP",
				Ward = "Ward", Armour = "Armour", Evasion = "Evasion", Block = "BlockChance",
				SpellBlock = "SpellBlockChance", SpellSuppression = "SpellSuppressionChance" }
			local defenseKey = defenseMetrics[tostring(self.textValues.defenseProfile or "Auto")]
			if defenseKey and defenseKey ~= objective and defenseKey ~= "TotalEHP"
				and isFiniteNumber(metrics[defenseKey]) and baselineMetrics and isFiniteNumber(baselineMetrics[defenseKey]) then
				summary = summary .. " | Δ " .. metricDisplayName(defenseKey) .. " "
					.. metricDisplayDelta(defenseKey, metrics[defenseKey], baselineMetrics[defenseKey])
			end
			routeChoices[#routeChoices + 1] = { val = tostring(#routeChoices + 1), label = summary, candidate = route }
		end
		addRoute(result.candidate)
		for _, route in ipairs(result.paretoFront or { }) do addRoute(route) end
		selectedRoute = routeChoices[1] and routeChoices[1].candidate
	end
	self.selectedRouteResult = selectedRoute and result or nil
	self.selectedRouteCandidate = selectedRoute
	self.readinessLayoutWidth = nil
	if self.innerView == "overview" then self:RefreshReadiness() end
	local detailsHeight = popupHeight - ( #routeChoices > 0 and 122 or 68 )
	controls.details = new("TextListControl"):TextListControl(popupTopLeftAnchor(),
		{ 12, 24, popupWidth - 24, detailsHeight })
	controls.details.list = OptimizerTabClass.FormatResultDetails(self, popupWidth, selectedRoute)
	if #routeChoices > 0 then
		controls.routeLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(),
			{ 12, popupHeight - 86, 92, 20 }, DisplayText.Native("Rota exata"))
		controls.routeSelect = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(),
			{ 104, popupHeight - 90, popupWidth - 244, 22 }, nativeChoiceLabels(routeChoices), function(_, selected)
			selectedRoute = selected and selected.candidate or nil
			controls.details.list = OptimizerTabClass.FormatResultDetails(self, popupWidth, selectedRoute)
			self.selectedRouteResult = selectedRoute and result or nil
			self.selectedRouteCandidate = selectedRoute
			self.readinessLayoutWidth = nil
			if self.innerView == "overview" then self:RefreshReadiness() end
		end)
		controls.routeSelect.enableDroppedWidth = true
		controls.routeSelect:SelByValue("1", "val")
		local applyFeedbackText = ""
		controls.applyRoute = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(),
			{ popupWidth - 132, popupHeight - 90, 120, 22 }, DisplayText.Native("Aplicar rota"), function()
			local function reportApplyFailure(message)
				applyFeedbackText = "Rota não aplicada: " .. tostring(message or "o PoB recusou esta variação")
				self.statusMessage = applyFeedbackText
			end
			if self.result ~= result or not selectedRoute then
				reportApplyFailure("a rota selecionada já não pertence ao resultado atual")
				return
			end
			local freshness, freshnessError = OptimizerTabClass.RefreshResultFreshness(self, true)
			if freshness ~= "current" then
				reportApplyFailure(freshness == "stale"
					and ("Cannot apply stale optimizer result: " .. tostring(freshnessError or "the build or Matrix changed"))
					or ("Cannot apply optimizer result not verified for the current build: " .. tostring(freshnessError or "missing provenance")))
				return
			end
			local selectedRouteIndex
			for index, choice in ipairs(routeChoices) do
				if choice.candidate == selectedRoute then selectedRouteIndex = index break end
			end
			if not selectedRouteIndex or selectedRoute.feasible ~= true
				or routePlannerProposalUsesFlask(self.build, selectedRoute)
				or selectedRoute.sourceSignature ~= result.sourceSignature then
				reportApplyFailure(routePlannerProposalUsesFlask(self.build, selectedRoute)
					and "o AI Planner não altera frascos; gere novamente as combinações permitidas"
					or "a rota deixou de ter proveniência de validação exata")
				return
			end
			local applied, applyMessage = self:ApplyCandidate(selectedRoute)
			if not applied then
				reportApplyFailure(applyMessage or self.statusMessage)
				return
			end
			applyFeedbackText = "Rota " .. tostring(selectedRouteIndex)
				.. " aplicada como variação reversível. Confira a árvore, gemas e equipamentos no PoB."
			if applyMessage and applyMessage ~= "" then
				applyFeedbackText = applyFeedbackText .. " " .. sanitizeDetailText(applyMessage)
			end
			self.statusMessage = applyFeedbackText
		end)
		controls.applyRoute.enabled = function()
			return self.result == result and selectedRoute ~= nil and selectedRoute.feasible == true
				and not routePlannerProposalUsesFlask(self.build, selectedRoute)
		end
		controls.applyFeedback = new("LabelControl"):LabelControl(popupTopLeftAnchor(),
			{ 12, popupHeight - 58, popupWidth - 24, 18 }, function()
			return DisplayText.Native(applyFeedbackText)
		end)
		setClippedPopupLabel(controls.applyFeedback, popupWidth - 24, 11)
	end
	controls.close = new("ButtonControl"):ButtonControl({ "BOTTOM", nil, "BOTTOM" }, { 0, -12, 90, 20 }, "Close", function()
		main:ClosePopup()
	end)
	local detailsTitle = "AI Planner — Result details"
	if result.routePlanner == true then
		if routePlannerProposalUsesFlask(self.build, result.candidate)
			or routePlannerProposalUsesFlask(self.build, result.bestObservedIdentity) then
			detailsTitle = "AI Planner — Resultado descartado"
		elseif result.status == "feasible" then
			if type(result.nearMisses) == "table" and #result.nearMisses > 0 then
				detailsTitle = "AI Planner — Rotas e propostas exatas"
			else
				detailsTitle = "AI Planner — Rotas aprovadas pelo PoB"
			end
		elseif type(result.nearMisses) == "table" and #result.nearMisses > 0 then
			detailsTitle = "AI Planner — Propostas exatas não aprovadas"
		else
			detailsTitle = "AI Planner - Detalhes de combinações"
		end
	end
	local popup = main:OpenPopup(popupWidth, popupHeight, DisplayText.Native(detailsTitle), controls, "close", nil, "close")
	return popup
end

function OptimizerTabClass.FormatZoneOutcomeSummary(zones, feasible)
	if type(zones) ~= "table" or type(zones.zoneResults) ~= "table" then return nil end
	local order = {
		{ "Hub", "Hub" },
		{ "NorthWest", "NW" },
		{ "NorthEast", "NE" },
		{ "SouthWest", "SW" },
		{ "SouthEast", "SE" },
	}
	local values = { }
	for _, entry in ipairs(order) do
		local result = zones.zoneResults[entry[1]]
		local value
		if result then
			if feasible then value = result.bestObjectiveDeltaFromBaseline
			else value = result.bestNormalizedDeficit end
		end
		if isFiniteNumber(value) then
			local formatted = groupedNumber(value)
			if feasible and value > 0 then formatted = "+" .. formatted end
			values[#values + 1] = entry[2] .. " " .. formatted
		end
	end
	if #values == 0 then return nil end
	local label = feasible and "Zone delta" or "Best zone deficit"
	return string.format("%s: %s (%d exact/%d combined)", label, table.concat(values, " "),
		tonumber(zones.exactEvaluations) or 0, tonumber(zones.exactCombinedEvaluations) or 0)
end

function OptimizerTabClass.FormatRequirementRepairSummary(repair)
	if type(repair) ~= "table" or repair.active ~= true then return nil end
	local exact = tonumber(repair.exactCandidateEvaluations) or 0
	local proposals = tonumber(repair.scheduledCandidates) or 0
	local improved = tonumber(repair.improvedExactEvaluations) or 0
	local cleared = tonumber(repair.fullyRepairedExactEvaluations) or 0
	return string.format("Local gear repair: %d exact/%d proposals, %d improved, %d target deficit%s cleared",
		exact, proposals, improved, cleared, cleared == 1 and "" or "s")
end

function OptimizerTabClass.FormatCatalystSearchSummary(catalysts)
	if type(catalysts) ~= "table" or (tonumber(catalysts.generatedCandidates) or 0) <= 0 then return nil end
	local exact = tonumber(catalysts.exactEvaluations) or 0
	local generated = tonumber(catalysts.generatedCandidates) or 0
	local unpriced = tonumber(catalysts.unpricedCandidates) or 0
	local priceNote = unpriced > 0 and ("; " .. tostring(unpriced) .. " strict-budget price gap(s)") or ""
	return string.format("Catalyst repairs: %d exact/%d proposals%s", exact, generated, priceNote)
end

function OptimizerTabClass.FormatSyntheticGearSummary(coverage)
	if type(coverage) ~= "table" or (tonumber(coverage.generatedCandidates) or 0) <= 0 then return nil end
	local summary = string.format("Synthetic gear: %d singles/%d pairs/%d triples; %d exact (%d pairs/%d triples)",
		type(coverage.generatedSingleCandidates) == "number" and coverage.generatedSingleCandidates or 0,
		type(coverage.generatedPairedCandidates) == "number" and coverage.generatedPairedCandidates or 0,
		type(coverage.generatedTripleCandidates) == "number" and coverage.generatedTripleCandidates or 0,
		type(coverage.exactEvaluations) == "number" and coverage.exactEvaluations or 0,
		type(coverage.exactPairedEvaluations) == "number" and coverage.exactPairedEvaluations or 0,
		type(coverage.exactTripleEvaluations) == "number" and coverage.exactTripleEvaluations or 0)
	local socketBound = tonumber(coverage.socketBoundCandidates) or 0
	if socketBound > 0 then
		summary = summary .. string.format("; %d linked-skill proposal(s), %d exact",
			socketBound, tonumber(coverage.exactSocketBoundEvaluations) or 0)
	end
	local exact = coverage.lastExactEvaluation
	local blocker = exact and not exact.feasible and exact.violations and exact.violations[1]
	if blocker then
		summary = summary .. "; last exact blocker: " .. tostring(blocker.key or "PoB gate")
			.. " — " .. tostring(blocker.reason or "rejected by exact calculation"):sub(1, 120)
	end
	return summary
end

function OptimizerTabClass.FormatFlaskExceptionSummary(audit)
	if type(audit) ~= "table" then return nil end
	local labels = { }
	local magebloodCount = tonumber(audit.magebloodPermanentCount) or 0
	if magebloodCount > 0 then
		labels[#labels + 1] = "native permanent utility flasks " .. tostring(magebloodCount)
	end
	if audit.pathfinderPolicy == "disabled_without_exact_uptime_model" then
		labels[#labels + 1] = "Pathfinder flasks off (uptime unsupported)"
	end
	if audit.certified == false then
		labels[#labels + 1] = "Pinnacle flask audit failed"
	end
	if #labels == 0 then return nil end
	return table.concat(labels, "; ")
end

function OptimizerTabClass.FormatScenarioAssumptionSummary(scenarioDetails)
	if type(scenarioDetails) ~= "table" then return nil end
	local labels = { }
	local enemyPreset = scenarioDetails.enemyIsBoss or scenarioDetails.requestedEnemyPreset
	if type(enemyPreset) == "string" and enemyPreset ~= "" then
		local enemyLabels = { None = "No boss", Boss = "Standard boss", Pinnacle = "Pinnacle", Uber = "Uber pinnacle", Active = "Active PoB enemy" }
		labels[#labels + 1] = "Enemy " .. (enemyLabels[enemyPreset] or enemyPreset)
	end
	local enemyLevel = tonumber(scenarioDetails.resolvedEnemyLevel or scenarioDetails.enemyLevelOverride)
	if enemyLevel then
		labels[#labels + 1] = "PoB enemy level " .. tostring(enemyLevel)
			.. (scenarioDetails.enemyLevelOverride and " (explicit; no area-specific stats)" or "")
	end
	local chargeAudit = scenarioDetails.chargeAudit
	if type(chargeAudit) == "table" and chargeAudit.countsAreExactPoBOutput then
		local abbreviations = { Power = "P", Frenzy = "F", Endurance = "E" }
		local counts = { }
		for _, charge in ipairs(chargeAudit.charges or { }) do
			local key = abbreviations[charge.key]
			if key then
				local maximum = tonumber(charge.maximum) or 0
				local minimum = tonumber(charge.minimum) or 0
				local current = tonumber(charge.current) or 0
				if maximum > 0 or current > 0 or minimum > 0 then
					local range = maximum > 0 and ("/" .. tostring(maximum)) or ""
					if minimum > 0 then range = range .. " min " .. tostring(minimum) end
					counts[#counts + 1] = key .. " " .. tostring(current) .. range
				end
			end
		end
		for _, charge in ipairs(chargeAudit.alternateCharges or { }) do
			local current = tonumber(charge.current) or 0
			local maximum = tonumber(charge.maximum) or 0
			if current > 0 then
				counts[#counts + 1] = tostring(charge.key) .. " " .. tostring(current)
					.. (maximum > 0 and ("/" .. tostring(maximum)) or "")
			end
		end
		local configured = { }
		for _, row in ipairs(chargeAudit.configuredFields or { }) do
			if type(row) == "table" and type(row.key) == "string"
				and row.key:match("^[%a][%w_]*$") and (type(row.value) == "boolean" or type(row.value) == "number") then
				configured[#configured + 1] = row.key .. "=" .. tostring(row.value)
			end
		end
		local chargeText = #counts > 0 and ("PoB charges " .. table.concat(counts, " ")) or "PoB charge counts 0"
		if #configured > 0 then chargeText = chargeText .. "; config " .. table.concat(configured, ", ") end
		local cleared = { }
		for _, row in ipairs(chargeAudit.clearedConfiguredFields or { }) do
			if type(row) == "table" and type(row.key) == "string" and row.key:match("^[%a][%w_]*$") then
				cleared[#cleared + 1] = row.key .. (row.policy == "forced_zero" and "=0" or " cleared")
			end
		end
		if #cleared > 0 then chargeText = chargeText .. "; Pinnacle charge policy: " .. table.concat(cleared, ", ") end
		if chargeAudit.uptimeCertified == false then
			chargeText = chargeText .. "; gain/spend/uptime unverified"
		end
		labels[#labels + 1] = chargeText
	end
	local shockAudit = scenarioDetails.shockAudit
	if type(shockAudit) == "table" and shockAudit.effectivePoBOutput ~= nil then
		local shock = { }
		for _, row in ipairs(shockAudit.configuredAssumptions or { }) do
			if type(row.key) == "string" and row.key:match("^[%a][%w_]*$")
				and (type(row.value) == "number" or type(row.value) == "boolean") then
				shock[#shock + 1] = row.key .. "=" .. tostring(row.value)
			end
		end
		local text = string.format("Shock PoB %.4g%%", shockAudit.effectivePoBOutput)
		if #shock > 0 then text = text .. " (" .. table.concat(shock, ", ") .. ")" end
		if shockAudit.uptimeCertified == false then text = text .. "; application/uptime unverified" end
		labels[#labels + 1] = text
	end
	local assumptions = scenarioDetails.preservedConditionalAssumptions
	if type(assumptions) == "table" and #assumptions > 0 then
		local other = { }
		for _, row in ipairs(assumptions) do
			local isShock = type(row.key) == "string" and row.key:lower():find("shock", 1, true)
			if row.category ~= "charges" and not isShock and type(row.key) == "string"
				and row.key:match("^[%a][%w_]*$") then
				local value = row.value
				local formattedValue = (type(value) == "number" or type(value) == "boolean")
					and ("=" .. tostring(value)) or ""
				other[#other + 1] = row.key .. formattedValue
			end
		end
		if #other > 0 then
			local shown = { }
			for index = 1, math.min(3, #other) do shown[#shown + 1] = other[index] end
			local text = "Preserved configured conditions (uptime unverified): " .. table.concat(shown, ", ")
			if #other > #shown then text = text .. string.format(" (+%d more)", #other - #shown) end
			labels[#labels + 1] = text
		end
	end
	if #labels == 0 then return nil end
	return table.concat(labels, " | ")
end

function OptimizerTabClass.FormatLearningRankerSummary(ranker)
	if type(ranker) ~= "table" then return nil end
	if ranker.active == true and ranker.status == "ranked" then
		return "Learned ranker active; exact PoB gates remain authoritative"
	end
	if ranker.status == "outside_model_domain" then return "Learned ranker off: no in-domain passive proposals" end
	if type(ranker.status) == "string" and ranker.status:find("engine_version_mismatch", 1, true) then
		return "Learned ranker off: PoB or tree version mismatch"
	end
	return "Learned ranker off: no validated model available"
end

function OptimizerTabClass.FormatPathExperienceSummary(coverage)
	if type(coverage) ~= "table" then return nil end
	local records = tonumber(coverage.compatibleRecords) or 0
	local motifs = tonumber(coverage.patternCount) or 0
	local reordered = tonumber(coverage.reorderedCandidates) or 0
	local explored = tonumber(coverage.preservedExploration) or 0
	local promoted = tonumber(coverage.promotedExploration) or 0
	local stored = tonumber(coverage.storedThisRun) or 0
	if coverage.contextStatus and coverage.contextStatus ~= "ready" then
		return "Path learning off: optimizer context is incomplete"
	end
	if coverage.storageStatus == "engine_identity_incomplete" then
		return "Path learning off: PoB version identity is incomplete"
	end
	local storageMessages = {
		corrupt = "Path learning paused: local history failed integrity checks",
		read_error = "Path learning paused: local history could not be read",
		store_limit_exceeded = "Path learning paused: local history reached its size limit",
		directory_creator_unavailable = "Path learning paused: PoB could not create the local study folder",
		directory_error = "Path learning paused: local study folder could not be created",
		write_error = "Path learning paused: exact outcomes could not be saved",
		record_invalid = "Path learning paused: an exact outcome failed record validation",
		user_path_unavailable = "Path learning off: PoB user data path is unavailable",
	}
	if storageMessages[coverage.storageStatus] then return storageMessages[coverage.storageStatus] end
	if records == 0 and stored == 0 then
		return "Path learning: collecting exact baseline and route evidence"
	end
	return string.format("Path learning: %d exact records, %d motifs; %d reordered, %d exploration routes kept, %d promoted early%s",
		records, motifs, reordered, explored, promoted, stored > 0 and ("; " .. tostring(stored) .. " saved") or "")
end

function OptimizerTabClass.FormatLearningCoverage(coverage)
	if type(coverage) ~= "table" then return "Learning coverage unavailable; skill combinations are not certified." end
	local versions = coverage.versionRows or { }
	return string.format("Exact pairs %d | unverified rows %d | engine current %d, stale %d, unknown %d.",
		type(coverage.exactPairRows) == "number" and coverage.exactPairRows or 0,
		type(coverage.unverifiedPairRows) == "number" and coverage.unverifiedPairRows or 0,
		type(versions.current) == "number" and versions.current or 0,
		type(versions.mismatch) == "number" and versions.mismatch or 0,
		type(versions.unverified) == "number" and versions.unverified or 0)
end

function OptimizerTabClass.FormatLearningCoverageContext(coverage)
	if type(coverage) ~= "table" then return "No coverage summary available." end
	local families = coverage.experimentFamilies or { }
	local context = coverage.contextDiversity or { }
	local factorials = (tonumber(families.passiveFactorialInteractions) or 0)
		+ (tonumber(families.skillSupportFactorialInteractions) or 0)
		+ (tonumber(families.skillItemFactorialInteractions) or 0)
		+ (tonumber(families.passiveItemFactorialInteractions) or 0)
		+ (tonumber(families.otherFactorialInteractions) or 0)
	return string.format("Studies P%d/G%d/M%d/I%d/F%d | contexts %d source, %d/7 classes, %d skills, %d scenarios.",
		type(families.passiveNodePairs) == "number" and families.passiveNodePairs or 0,
		type(families.gemVariantPairs) == "number" and families.gemVariantPairs or 0,
		type(families.masteryEffectPairs) == "number" and families.masteryEffectPairs or 0,
		type(families.itemSlotPairs) == "number" and families.itemSlotPairs or 0, factorials,
		type(context.sourceBuildStatesObserved) == "number" and context.sourceBuildStatesObserved or 0,
		type(context.classStartsObserved) == "number" and context.classStartsObserved or 0,
		type(context.mainSkillContextsObserved) == "number" and context.mainSkillContextsObserved or 0,
		type(context.scenarioContextsObserved) == "number" and context.scenarioContextsObserved or 0)
end

function OptimizerTabClass.FormatLearningCoverageSafety(coverage)
	if type(coverage) ~= "table" then return "Skill-combination coverage not measured; graph report-only; neural model disabled." end
	return string.format("Combination coverage %s; graph %s; neural model %s.",
		tostring(coverage.combinationCoverage or "not_measured"), tostring(coverage.graphRole or "report_only"),
		coverage.modelTrainingEnabled == true and "enabled" or "disabled")
end

function OptimizerTabClass.FormatSupportPackageSummary(phaseCoverage)
	local packages = phaseCoverage and phaseCoverage.supportPackages
	if type(packages) ~= "table" then return nil end
	local rows, exactTotal, compatibleTotal = { }, 0, 0
	for _, entry in ipairs({ { "add", packages.additions }, { "replace", packages.swaps } }) do
		for arity, row in ipairs(entry[2] or { }) do
			local exact = tonumber(row.exact) or 0
			local compatible = tonumber(row.compatible) or 0
			if exact > 0 then
				rows[#rows + 1] = string.format("%s %d: %d/%d", entry[1], arity, exact, compatible)
				exactTotal = exactTotal + exact
				compatibleTotal = compatibleTotal + compatible
			end
		end
	end
	if exactTotal == 0 then return nil end
	return string.format("Support arities exact/compatible (%d/%d): %s",
		exactTotal, compatibleTotal, table.concat(rows, ", "))
end

local function metricColumnCount(viewWidth)
	-- The full hard-gate set uses three columns. Sixteen compact rows fit above
	-- the advanced Matrix fields while keeping enough label width at 1026px.
	if #Inputs.metricDefinitions > 35 then return 3 end
	return 2
end

local function metricPosition(index, viewWidth)
	local columns = metricColumnCount(viewWidth)
	local rowsPerColumn = math.ceil(#Inputs.metricDefinitions / columns)
	local column = math.floor((index - 1) / rowsPerColumn)
	local row = (index - 1) % rowsPerColumn
	local baseX, inputOffset
	local inputWidth = 104
	local rowSpacing = 14
	if columns > 2 then
		local width = viewWidth or 800
		local gap = 8
		local columnWidth = (width - 24 - gap * (columns - 1)) / columns
		inputWidth = width < 700 and 82 or 98
		baseX = 12 + column * (columnWidth + gap)
		inputOffset = columnWidth - inputWidth
		rowSpacing = columns == 3 and 15 or 17
	elseif viewWidth and viewWidth < 700 then
		local columnWidth = (viewWidth - 24 - 12) / 2
		baseX = 12 + column * (columnWidth + 12)
		inputOffset = columnWidth - 104
	else
		baseX = 12 + column * 350
		inputOffset = 190
	end
	return baseX, 48 + row * rowSpacing, baseX + inputOffset, inputWidth, inputOffset - 8
end

local function metricLabel(definition, width, compact, fontSize)
	local label = compact and (compactMetricLabels[definition.key] or definition.label) or definition.label
	if definition.unit ~= "" then label = label .. " (" .. definition.unit .. ")" end
	if not width or width <= 0 then return label end
	if measuredTextWidth(label, fontSize) <= width then return label end
	if not compact and wideMetricFallbacks[definition.key] then
		local fallback = wideMetricFallbacks[definition.key]
		if definition.unit ~= "" then fallback = fallback .. " (" .. definition.unit .. ")" end
		if measuredTextWidth(fallback, fontSize) <= width then return fallback end
	end
	local compactLabel = compactMetricLabels[definition.key] or definition.label
	if definition.unit ~= "" then compactLabel = compactLabel .. " (" .. definition.unit .. ")" end
	if measuredTextWidth(compactLabel, fontSize) <= width then return compactLabel end
	local narrowLabel = narrowMetricLabels[definition.key] or compactLabel
	if definition.unit ~= "" then narrowLabel = narrowLabel .. " " .. definition.unit end
	-- Keep a readable metric name visible; the tooltip below retains its full name.
	return narrowLabel
end

function OptimizerTabClass:OptimizerTab(build)
	self:ControlHost()
	self:Control()
	self.build = build
	self.modFlag = false
	self.textValues = { }
	self.controls = { }
	self.fieldLabels = { }
	self.textFieldLabels = { }
	self.layoutWidth = nil
	self.innerView = "overview"
	self.readinessDetailsExpanded = false
	self.statusMessage = defaultStatusMessage
	self.aiRequestId = nil
	self.aiRequestData = nil
	self.classRootJob = nil
	self.classRootResult = nil
	self.loadedOptimizerContext = nil
	self.hasPersistedOptimizerInputs = false
	self.contextAnchor = currentOptimizerContext(build)
	for _, definition in ipairs(Inputs.metricDefinitions) do
		self.textValues[definition.key] = ""
	end
	for index, definition in ipairs(textFieldDefinitions) do
		self.textValues[definition.key] = definition.default or ""
	end
	self.textValues.baseClassId = tostring(build.spec.curClassId)
	self.textValues.searchAllClasses = false
	self.textValues.activityScheduleJson = ""
	local initialGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	local initialSkillIndex = initialGroup and (initialGroup.mainActiveSkill or 1)
	local initialSkill = initialGroup and initialGroup.displaySkillList and initialGroup.displaySkillList[initialSkillIndex]
	self.textValues.targetSkillGroupIndex = initialSkill and tostring(build.mainSocketGroup) or ""
	self.textValues.targetSkillIndex = initialSkill and tostring(initialSkillIndex) or ""
	self.textValues.targetSkillGemId = initialSkill
		and (SkillCatalog.CurrentMainGemId(build, build.mainSocketGroup, initialSkillIndex) or "") or ""

	for index, definition in ipairs(Inputs.metricDefinitions) do
		local labelX, y, inputX, inputWidth, labelWidth = metricPosition(index)
		local denseLayout = metricColumnCount() > 2
		local labelFontSize = denseLayout and 12 or 14
		local label = metricLabel(definition, labelWidth, denseLayout, labelFontSize)
		self.fieldLabels[#self.fieldLabels + 1] = { x = labelX, y = y, text = label, fontSize = labelFontSize }
		local control = new("EditControl"):EditControl({ "TOPLEFT", self, "TOPLEFT" }, { inputX, y - 1, inputWidth, 14 }, "", "", "^%d%.%-,", 24, function(buf)
			self.textValues[definition.key] = buf
			self.modFlag = true
		end, nil, nil, true)
		control.tooltipText = "Hard minimum using the exact PoB " .. (definition.metricKey or definition.key) .. " output. "
			.. definition.label .. (definition.unit ~= "" and (" (" .. definition.unit .. ")") or "")
		if definition.key:find("ResistOverCap", 1, true) then
			control.tooltipText = control.tooltipText .. " This is percentage points above the current PoB maximum resistance."
		end
		self.controls["metric_" .. definition.key] = control
	end
	for _, definition in ipairs(textFieldDefinitions) do
		if definition.hidden then
			self.controls["text_" .. definition.key] = nil
		else
			local label = { x = definition.x, y = definition.y, text = definition.label }
			self.fieldLabels[#self.fieldLabels + 1] = label
			self.textFieldLabels[definition.key] = label
		local control
		if fieldChoices[definition.key] then
			control = new("DropDownControl"):DropDownControl({ "TOPLEFT", self, "TOPLEFT" }, { definition.x + definition.width + 8, definition.y - 2, 190, 20 }, fieldChoices[definition.key], function(index, choice)
				self.textValues[definition.key] = choice.val
				self.modFlag = true
			end)
			control.optimizerChoices = fieldChoices[definition.key]
			control.enableDroppedWidth = true
			self.textValues[definition.key] = setFieldControl(control, self.textValues[definition.key])
		elseif definition.key == "maxTotalPoints" then
			control = new("EditControl"):EditControl({ "TOPLEFT", self, "TOPLEFT" }, { definition.x + definition.width + 8, definition.y - 2, 42, 20 }, self.textValues[definition.key], "120", "^%d", 3, function(buf)
				self.textValues[definition.key] = buf
				local value = tonumber(buf)
				if value and value >= 1 and value <= 130 and value == math.floor(value) then
					self.controls.pointCapSlider.val = (value - 1) / 129
				end
				self.modFlag = true
			end, nil, nil, true)
			self.controls.pointCapSlider = new("SliderControl"):SliderControl({ "TOPLEFT", self, "TOPLEFT" }, { definition.x + definition.width + 54, definition.y - 1, 136, 18 }, function(value)
				local pointCap = 1 + math.floor(value * 129 + 0.5)
				self.textValues.maxTotalPoints = tostring(pointCap)
				self.controls.text_maxTotalPoints:SetText(self.textValues.maxTotalPoints, false)
				self.modFlag = true
			end)
			local initialPointCap = tonumber(self.textValues.maxTotalPoints) or 120
			self.controls.pointCapSlider.val = (math.max(1, math.min(130, initialPointCap)) - 1) / 129
		else
			control = new("EditControl"):EditControl({ "TOPLEFT", self, "TOPLEFT" }, { definition.x + definition.width + 8, definition.y - 2, definition.placeholder and 190 or 100, 20 }, self.textValues[definition.key], definition.placeholder or "", "^%C", 120, function(buf)
				self.textValues[definition.key] = buf
				if definition.key == "maxAddedPoints" then self.textValues.treeBudgetMode = "custom" end
				self.modFlag = true
			end, nil, nil, true)
		end
		if definition.key == "scenarioProfile" then
		control.tooltipText = "Current uses the selected PoB configuration. PinnacleUnbuffed disables flasks/tinctures, kill states, manual charge counts, and charge-like event stacks (Ghost Shrouds, Crab Barriers, Spirit Infusions); native minimum charge floors remain. Other configured conditions and custom modifiers are preserved and reported, but their uptime is not certified. PinnacleChassis also restores native boss stats and removes Guard buffs, manual ailment and recent ailment-application flags, and custom modifiers. Generated charge and hit-derived ailment uptime are not simulated."
		elseif definition.key == "maxTotalPoints" then
			control.tooltipText = "Solver budget: choose 1–130 total passive points with the slider or number field. PoB separately checks the exact character-level and quest-point limit. This is not currency."
		elseif definition.key == "evaluationBudget" then
			control.tooltipText = "Search budget: maximum candidate evaluations through PoB's exact calculator. It is separate from the passive-point ceiling and is not currency or crafting cost."
		elseif definition.key == "maxManualButtons" then
			control.tooltipText = "Optional strict cap for distinct enabled manual skills in PoB socket groups. It counts damage and utility actions, excludes triggered skills and persistent reservations, and does not infer keyboard bindings or actions per minute."
		elseif definition.key == "allowedRegions" or definition.key == "requiredRegions" or definition.key == "forbiddenRegions" then
			control.tooltipText = "Use class regions (for example Witch or Templar) or spatial zones NW/NE/SW/SE/Hub in one run; do not mix the two. Spatial zones are derived from the active PoB tree. The Hub remains ordinary point-costed transit to an allowed quadrant and never creates a free connection or another class start."
		end
		if treeOnlyPhaseFieldSet[definition.key] then
			control.enabled = function()
				local phase = tostring(self.textValues.generationPhase or "tree"):lower()
				return phase == "tree" or phase == "combined"
			end
		end
		self.controls["text_" .. definition.key] = control
		end
	end

	self.controls.run = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 468, 110, 22 }, "Run optimizer", function()
		self:RunOptimizer()
	end)
	self.controls.cancel = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.run, "RIGHT" }, { 8, 0, 90, 22 }, "Cancel", function()
		if self.job then self.job:Cancel() end
	end)
	self.controls.apply = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.cancel, "RIGHT" }, { 8, 0, 130, 22 }, "Apply as variation", function()
		self:ApplyResult()
	end)
	self.controls.cancel.enabled = function() return self.job and self.job.status == "running" end
	self.controls.apply.enabled = function() return self.result and self.result.status == "feasible" and Candidate.HasMutation(self.result.candidate) end
	self.controls.aiRequest = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.apply, "RIGHT" }, { 8, 0, 94, 22 }, "Ask AI", function()
		self:OpenAIRequest()
	end)
	self.controls.direction = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.apply, "RIGHT" }, { 8, 0, 110, 22 }, "Build direction", function()
		self:OpenBuildDirection()
	end)
	self.controls.mcpRequest = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.aiRequest, "RIGHT" }, { 6, 0, 92, 22 }, "MCP queue", function()
		self:OpenMCPRequest()
	end)
	self.controls.compareRoots = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.mcpRequest, "RIGHT" }, { 6, 0, 118, 22 }, "Compare roots", function()
		if self.classRootJob and self.classRootJob.status == "running" then
			self.classRootJob:Cancel()
		elseif self.classRootResult then
			self:OpenClassRootsResult()
		else
			self:StartClassRootComparison()
		end
	end)
	self.controls.activitySchedule = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 494, 112, 22 }, "Activity schedule", function()
		self:OpenActivitySchedule()
	end)
	self.controls.activitySchedule.tooltipText = "Inspect Main Skill, FullDPS, or all enabled skills against exact PoB resource rates. The all-skills scope includes utility skills and estimates recurring resource sustain only; it does not estimate damage, key bindings, or actions per minute."
	self.controls.equipment = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 250, 494, 150, 22 }, "Equipment choices", function()
		self:OpenEquipmentChoices()
	end)
	self.controls.equipment.tooltipText = "Choose existing PoB items or prepare bounded native rare/socket proposals for the selected skill. Every item, socket link and candidate is checked by PoB; previews do not mutate the active build."
	self.controls.classResults = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 410, 494, 142, 22 }, "Class results", function()
		self:OpenClassSearchResults()
	end)
	self.controls.classResults.enabled = function()
		return self.result and self.result.classSearch and #(self.result.classSearch.results or { }) > 0
	end
	self.controls.classResults.tooltipText = "Inspect each class's best exact candidate, equal evaluation quota, main/Bloodline route coverage, and strict-gate deficit."
	self.controls.marketBudget = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 570, 494, 122, 22 }, "Market budget", function()
		self:OpenMarketBudget()
	end)
	self.controls.marketBudget.tooltipText = "Set a strict item-acquisition budget. Trade prices come from the documented poe.ninja economy API through the local MCP companion; missing rare-item prices must be supplied explicitly."
	self.controls.studyRecords = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 704, 494, 90, 22 }, "Study", function()
		self:OpenStudyRecords()
	end)
	self.controls.studyRecords.tooltipText = "Review exact local experiment pairs and their version, scenario, activity, and lookup-table evidence. Only explicit local human review can clear a record from quarantine; this does not train or enable a model."
	self.controls.resultDetails = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 800, 494, 92, 22 }, "Details", function()
		self:OpenResultDetails()
	end)
	self.controls.resultDetails.enabled = function() return type(self.result) == "table" end
	self.controls.resultDetails.tooltipText = "Open the complete scrollable result: every strict deficit, the saved Matrix constraints, exact PoB metrics, search evidence and its limits."
	self.controls.pageMatrix = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 0, 8, 84, 22 }, DisplayText.Native("Ajustes"), function()
		self.innerView = "matrix"
	end)
	self.controls.pageMatrix.enabled = function() return self.innerView ~= "matrix" end
	self.controls.pageOverview = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 0, 8, 78, 22 }, DisplayText.Native("Combinar"), function()
		self.innerView = "overview"
	end)
	self.controls.pageOverview.enabled = function() return self.innerView ~= "overview" end
	self.controls.pageNodePotential = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 0, 8, 92, 22 }, DisplayText.Native("Cobertura"), function()
		self.innerView = "nodes"
	end)
	self.controls.pageNodePotential.enabled = function() return self.innerView ~= "nodes" end
	self.controls.nodeAnalyze = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 74, 200, 24 }, "Analisar skill selecionada", function()
		self:RunNodePotential()
	end)
	self.controls.nodeAnalyze.tooltipText = "Compara a build atual com rotas limitadas da árvore. Cada variação é recalculada pelo PoB; esta análise não aloca pontos na build."
	self.controls.nodeAnalyze.enabled = function() return not (self.job and self.job.status == "running") end
	self.controls.nodeCancel = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 220, 74, 90, 24 }, "Cancelar", function()
		if self.job then self.job:Cancel() end
	end)
	self.controls.nodeCancel.enabled = function() return self.job and self.job.status == "running" end
	-- Import and Ask AI already have dedicated native entry points; keep these
	-- legacy callbacks intact but hide them from the route-first overview.
	self.controls.overviewImport = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 240, 82, 22 }, "Importar", function()
		self.build.viewMode = "IMPORT"
	end)
	self.controls.overviewImport.shown = false
	self.controls.overviewDirection = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 102, 240, 122, 22 }, "Configurar build", function() self:OpenGuidedSetup() end)
	self.controls.overviewDirection.tooltipText = "Abre diretamente o fluxo curto para escolher classe, Main Skill e prioridades. Pisos, conversão e orçamento detalhado ficam nas opções avançadas."
	self.controls.overviewAI = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 232, 240, 72, 22 }, "Ask AI", function() self:OpenAIRequest() end)
	self.controls.overviewAI.shown = false
	self.controls.overviewRun = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 450, 240, 86, 22 }, "Otimizar", function()
		self:RunOptimizer()
	end)
	self.controls.overviewRun.shown = false
	self.controls.overviewRun.enabled = function()
		return not (self.job and self.job.status == "running")
			and self.overviewSkillHasOptions and self.overviewGemHasOptions
			and parsePositiveIndex(self.textValues.targetSkillGroupIndex) ~= nil
			and parsePositiveIndex(self.textValues.targetSkillIndex) ~= nil
			and tostring(self.textValues.targetSkillGemId or "") ~= ""
	end
	self.controls.overviewRun.tooltipText = "Otimização geral da Matrix; a busca de rotas no botão Gerar rotas é o fluxo recomendado para comparar combinações."
	self.controls.overviewRoutes = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 236, 240, 132, 22 }, DisplayText.Native("Gerar rotas"), function()
		self:OpenRoutePlanner()
	end)
	self.controls.overviewRoutes.enabled = function()
		return self.controls.overviewRun and type(self.controls.overviewRun.enabled) == "function"
			and self.controls.overviewRun.enabled()
	end
	self.controls.overviewRoutes.tooltipText = "Gera rotas a partir desta build, recalcula cada proposta no PoB e mostra só rotas aprovadas ou propostas exatas com os déficits identificados. Nada é aplicado automaticamente."
	self.controls.overviewAdvanced = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 268, 132, 22 }, DisplayText.Native("Opções avançadas"), function() self:OpenBuildDirection() end)
	self.controls.overviewAdvanced.shown = false
	self.controls.overviewRefresh = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 152, 268, 164, 22 }, DisplayText.Native("Atualizar detalhes"), function() self:RefreshReadiness(true) end)
	self.controls.overviewRefresh.shown = false
	self.controls.overviewCancel = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 540, 268, 82, 22 }, DisplayText.Native("Cancelar busca"), function()
		if self.job then self.job:Cancel() end
	end)
	self.controls.overviewCancel.enabled = function() return self.job and self.job.status == "running" end
	self.controls.overviewResult = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 324, 268, 112, 22 }, function()
		if self.result and self.result.routePlanner == true then
			if self.result.status == "feasible" then return "Ver rotas" end
			if type(self.result.nearMisses) == "table" and #self.result.nearMisses > 0 then return "Ver candidatas" end
			return "Resumo da busca"
		end
		return "Ver resultado"
	end, function() self:OpenResultDetails() end)
	self.controls.overviewResult.enabled = function() return self.result ~= nil end
	self.controls.overviewResult.shown = function() return self.result ~= nil end
	self.controls.overviewDetails = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 444, 268, 92, 22 }, function()
		return self.readinessDetailsExpanded and "Voltar" or "Detalhes"
	end, function()
		self.readinessDetailsExpanded = not self.readinessDetailsExpanded
		self.readinessLayoutWidth = nil
		self:RefreshReadiness()
	end)
	self.controls.overviewDetails.shown = false
	self.controls.overviewDetails.tooltipText = "Abre ou fecha os detalhes técnicos. A tela principal fica dedicada à busca de rotas e aos ganhos exatos da rota selecionada."
	self.controls.overviewCancel.shown = function() return self.job and self.job.status == "running" end
	self.controls.overviewDirectionTitle = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 48, 0, 18 }, DisplayText.Native("^7Escolha classe, Main Skill e prioridades; o PoB valida cada rota"))
	self.controls.overviewClassLabel = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 67, 0, 16 }, DisplayText.Native("^7Classe de início"))
	self.controls.overviewSkillLabel = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 125, 0, 16 }, DisplayText.Native("^7Main Skill"))
	self.controls.overviewGemLabel = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 284, 125, 0, 16 }, DisplayText.Native("^7Gema alvo"))
	self.controls.overviewDamageLabel = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 174, 0, 16 }, DisplayText.Native("^7Rota de dano preferida"))
	self.controls.overviewDefenseLabel = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 284, 174, 0, 16 }, DisplayText.Native("^7Perfil defensivo preferido"))
	self.controls.overviewAscendancy = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 218, 0, 16 }, DisplayText.Native("^8Ascendência: Auto — o solver escolhe uma opção legal da classe e valida no PoB."))
	self.controls.overviewPriorityLabel = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 218, 0, 16 }, DisplayText.Native("^7Prioridade principal da busca"))

	local damageChoices = {
		{ val = "Auto", label = "Auto" },
		{ val = "PhysicalHit", label = "Phys hit" },
		{ val = "PhysicalImpale", label = "Phys + Impale" },
		{ val = "PhysicalDoT", label = "Phys DoT/Bleed" },
		{ val = "Fire", label = "Fire" },
		{ val = "Cold", label = "Cold" },
		{ val = "Lightning", label = "Lightning" },
		{ val = "ChaosPoison", label = "Chaos/Poison" },
		{ val = "Minions", label = "Minions" },
	}
	local defenseChoices = {
		{ val = "Auto", label = "Auto" },
		{ val = "Life", label = "Life" },
		{ val = "EnergyShield", label = "ES/CI" },
		{ val = "Hybrid", label = "Life + ES" },
		{ val = "Ward", label = "Ward" },
		{ val = "Armour", label = "Armour" },
		{ val = "Evasion", label = "Evasion" },
		{ val = "Block", label = "Block" },
		{ val = "SpellBlock", label = "Spell block" },
		{ val = "SpellSuppression", label = "Suppression" },
	}

	local function createOverviewRadioGroup(key, choices, selectedValue, onSelected, tooltipText)
		local group = { choices = choices, options = { }, selectedValue = tostring(selectedValue or "") }
		local help = tooltipText or "Escolhe uma opção para orientar a busca. A legalidade e as métricas finais continuam a ser validadas pelo PoB."
		function group:SetValue(value)
			self.selectedValue = tostring(value or "")
			for _, option in ipairs(self.options) do option.control.state = option.value == self.selectedValue end
		end
		for _, choice in ipairs(choices) do
			local value = tostring(choice.val)
			local control
			control = new("CheckBoxControl"):CheckBoxControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 85, 16 }, DisplayText.Native(choice.label), function(checked)
				if not checked then
					group:SetValue(group.selectedValue)
					return
				end
				group:SetValue(value)
				onSelected(value)
			end, help, group.selectedValue == value)
			control.labelRight = true
			control.labelWidth = 108
			control.choiceValue = value
			control.tooltipText = help
			self.controls["overview" .. key .. "_" .. value] = control
			group.options[#group.options + 1] = { value = value, control = control }
		end
		group:SetValue(selectedValue)
		return group
	end
	local function normalizedOverviewChoice(choices, value, defaultValue)
		value = tostring(value or "")
		for _, choice in ipairs(choices) do
			if tostring(choice.val) == value then return value end
		end
		return defaultValue
	end
	self.textValues.damageFocus = normalizedOverviewChoice(damageChoices, self.textValues.damageFocus, "Auto")
	self.textValues.defenseProfile = normalizedOverviewChoice(defenseChoices, self.textValues.defenseProfile, "Auto")
	self.overviewDamageGroup = createOverviewRadioGroup("Damage", damageChoices, self.textValues.damageFocus, function(value)
		self.textValues.damageFocus = value
		self.modFlag = true
		self:RefreshReadiness(true)
	end, "Preferência para ordenar rotas, não conversão forçada. Phys + Impale continua separado das rotas elementais; limites rígidos e métricas são calculados pelo PoB.")
	self.overviewDefenseGroup = createOverviewRadioGroup("Defense", defenseChoices, self.textValues.defenseProfile, function(value)
		self.textValues.defenseProfile = value
		self.modFlag = true
		self:RefreshReadiness(true)
	end, "Preferência de ranking, não garantia de defesa. Life, Energy Shield/CI, híbrido, Ward, Armour, Evasion, Block e Spell Suppression dependem dos outputs exatos do PoB.")
	local function updateOverviewAscendancySummary()
		local class = self.build.spec.tree.classes[tonumber(self.textValues.baseClassId)]
		local selectedAscendancy = tostring(self.textValues.ascendancyId or "")
		if selectedAscendancy == "" then
			self.controls.overviewAscendancy.label = DisplayText.Native("^8Ascendência: Auto — o solver escolhe uma opção legal"
				.. (class and (" de " .. tostring(class.name)) or " da classe selecionada") .. " e valida no PoB.")
		else
			self.controls.overviewAscendancy.label = DisplayText.Native("^8Ascendência: seleção avançada bloqueada (ID " .. selectedAscendancy .. "); o PoB ainda valida a legalidade.")
		end
	end
	local classChoices = { }
	for id in pairs(self.build.spec.tree.classes or { }) do classChoices[#classChoices + 1] = id end
	table.sort(classChoices)
	local classOptions = { }
	for _, id in ipairs(classChoices) do
		local class = self.build.spec.tree.classes[id]
		classOptions[#classOptions + 1] = { val = tostring(id), label = class.name }
	end
	self.overviewClassGroup = createOverviewRadioGroup("Class", classOptions, self.textValues.baseClassId, function(classId)
		self.textValues.baseClassId = classId
		self.textValues.searchAllClasses = false
		self.textValues.ascendancyId = ""
		self.nodeEvidence = nil
		self.modFlag = true
		updateOverviewAscendancySummary()
		self:RefreshReadiness(true)
	end)
	for _, option in ipairs(self.overviewClassGroup.options) do
		option.control.enabled = function()
			local phase = tostring(self.textValues.generationPhase or "tree"):lower()
			return phase == "tree" or phase == "combined"
		end
	end
	local priorityChoices = {
		{ val = "ObjectiveFirst", label = "Dano primeiro" },
		{ val = "DefenseFirst", label = "Defesa primeiro" },
	}
	self.overviewPriorityGroup = createOverviewRadioGroup("Priority", priorityChoices,
		self.textValues.rankingPriority or "ObjectiveFirst", function(value)
			self.textValues.rankingPriority = value
			self.modFlag = true
			self:RefreshReadiness(true)
		end, "Ordenação entre candidatos que já passaram todos os limites rígidos. Isto não substitui os pisos da Matrix.")
	local importedRoutesEnabled = tostring(self.textValues.useImportedRouteMemory or "true"):lower() == "true"
	self.controls.overviewUseImportedRoutes = new("CheckBoxControl"):CheckBoxControl({ "TOPLEFT", self, "TOPLEFT" }, { 288, 237, 16 },
		DisplayText.Native("Usar rotas de builds compatíveis"), function(checked)
			self.textValues.useImportedRouteMemory = checked and "true" or "false"
			self.nodeEvidence = nil
			self.modFlag = true
			self:RefreshReadiness(true)
		end,
		"Quando ativa, prioriza apenas desempates de rota observados em builds importadas com a mesma classe, Main Skill, efeito e versão exata do PoB/PoE 1. Frequências de nós e ligações não provam sinergia: o grafo nativo mantém a legalidade e cada finalista passa pelo cálculo exato do PoB.",
		importedRoutesEnabled)
	self.controls.overviewUseImportedRoutes.labelRight = true
	self.controls.overviewUseImportedRoutes.labelWidth = 228
	self.controls.overviewUseImportedRoutes.tooltipText = "Usa padrões estruturais observados em builds compatíveis somente para ordenar rotas empatadas. O PoB valida conectividade, pontos, métricas e hard gates; nenhuma frequência substitui o cálculo."
	local function buildOverviewSkillOptions()
		local options = { }
		for groupIndex, group in ipairs(self.build.skillsTab.socketGroupList or { }) do
			if group.enabled ~= false and group.slotEnabled ~= false then
				local addedActiveSkill = false
				for skillIndex, skill in ipairs(group.displaySkillList or { }) do
					if skill.activeEffect then
						local gemId = SkillCatalog.CurrentMainGemId(self.build, groupIndex, skillIndex)
						if gemId then
							local name = skill.name or skill.activeEffect.grantedEffect and skill.activeEffect.grantedEffect.name or "Active skill"
							options[#options + 1] = { val = tostring(groupIndex) .. ":" .. tostring(skillIndex), label = (group.displayLabel or group.label or ("Group " .. groupIndex)) .. " — " .. name,
								groupIndex = groupIndex, skillIndex = skillIndex, gemId = gemId }
							addedActiveSkill = true
						end
					end
				end
				-- PoB may omit displaySkillList when the loaded Main Skill's socket
				-- color is invalid. Keep the route-first entry point available only
				-- when the raw gem is unambiguous and a native item repair exists.
				if not addedActiveSkill then
					local skillIndex = parsePositiveIndex(group.mainActiveSkill) or 1
					local gemId = SkillCatalog.CurrentMainGemId(self.build, groupIndex, skillIndex)
					local gemData = gemId and self.build.data and self.build.data.gems and self.build.data.gems[gemId]
					local repair = SkillCatalog.PlanSocketRepair(self.build, groupIndex, group)
					if gemId and SkillCatalog.IsActiveSkillGem(gemData) and repair then
						local name = tostring(gemData.name or gemData.grantedEffect and gemData.grantedEffect.name or "Main Skill")
						options[#options + 1] = { val = tostring(groupIndex) .. ":" .. tostring(skillIndex),
							label = (group.displayLabel or group.label or ("Group " .. groupIndex)) .. " — " .. name .. " (socket repair)",
							groupIndex = groupIndex, skillIndex = skillIndex, gemId = gemId, socketRepair = repair }
					end
				end
			end
		end
		if #options == 0 then options[1] = { val = "", label = "No enabled active skill slot" } end
		return options
	end
	local function buildOverviewGemOptions()
		local options = { }
		local catalog = SkillCatalog.ListActive(self.build, "", 1000)
		for _, gem in ipairs(catalog and catalog.gems or { }) do
			local variant = gem.variantId ~= "" and gem.variantId ~= gem.name and (" (" .. gem.variantId .. ")") or ""
			options[#options + 1] = { val = gem.id, label = gem.name .. variant, searchFilter = gem.name .. " " .. gem.variantId }
		end
		if #options == 0 then options[1] = { val = "", label = catalog and "No active gems in loaded PoB data" or "PoB active gem catalog unavailable" } end
		return options
	end
	local overviewSkillOptions = buildOverviewSkillOptions()
	local overviewSkillValue = ""
	for _, option in ipairs(overviewSkillOptions) do
		if option.groupIndex == parsePositiveIndex(self.textValues.targetSkillGroupIndex)
			and option.skillIndex == parsePositiveIndex(self.textValues.targetSkillIndex) then overviewSkillValue = option.val break end
	end
	local hasOverviewSkillOptions = overviewSkillOptions[1] and overviewSkillOptions[1].val ~= ""
	if hasOverviewSkillOptions and overviewSkillValue == "" then
		table.insert(overviewSkillOptions, 1, { val = "", label = "Choose an enabled Main Skill slot" })
	end
	self.controls.overviewSkill = new("DropDownControl"):DropDownControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 143, 260, 22 }, nativeChoiceLabels(overviewSkillOptions), function(_, selected)
		if selected and selected.groupIndex then
			self.textValues.targetSkillGroupIndex = tostring(selected.groupIndex)
			self.textValues.targetSkillIndex = tostring(selected.skillIndex)
			self.textValues.targetSkillGemId = tostring(selected.gemId)
			self.nodeEvidence = nil
			self.controls.overviewGem:SelByValue(selected.gemId, "val")
			self.modFlag = true
			self:RefreshReadiness(true)
		end
	end, "Escolhe um grupo de sockets ativo e um slot de skill nativo do PoB. A seleção orienta a otimização; não troca a skill da build carregada.")
	self.controls.overviewSkill.enableDroppedWidth = true
	self.controls.overviewSkill:SelByValue(overviewSkillValue, "val")
	local overviewGemOptions = buildOverviewGemOptions()
	local hasOverviewGemOptions = overviewGemOptions[1] and overviewGemOptions[1].val ~= ""
	if hasOverviewGemOptions then
		table.insert(overviewGemOptions, 1, { val = "", label = "Choose an active PoE 1 gem" })
	end
	self.controls.overviewGem = new("DropDownControl"):DropDownControl({ "TOPLEFT", self, "TOPLEFT" }, { 284, 143, 260, 22 }, nativeChoiceLabels(overviewGemOptions), function(_, selected)
		if selected and selected.val and selected.val ~= "" then
			self.textValues.targetSkillGemId = selected.val
			self.nodeEvidence = nil
			self.modFlag = true
			self:RefreshReadiness(true)
		end
	end, "Seleciona uma gema ativa dos dados carregados do PoB. Escolher não altera a build; se não houver um slot Main Skill compatível, Configurar build permite criar explicitamente uma variação reversível de skill set.")
	self.controls.overviewGem.enableDroppedWidth = true
	self.controls.overviewGem:SelByValue(tostring(self.textValues.targetSkillGemId or ""), "val")
	self.overviewSkillHasOptions = hasOverviewSkillOptions
	self.overviewGemHasOptions = hasOverviewGemOptions
	self.controls.overviewSkill.enabled = function() return self.overviewSkillHasOptions end
	self.controls.overviewGem.enabled = function() return self.overviewGemHasOptions end
	self.overviewSkillContextKey = nil
	self.RefreshOverviewDirectionControls = function(force)
		local currentOptions = buildOverviewSkillOptions()
		local signature = { tostring(self.build.mainSocketGroup), tostring(self.build.buildFlag) }
		for _, option in ipairs(currentOptions) do
			signature[#signature + 1] = table.concat({ tostring(option.val), tostring(option.gemId or ""), tostring(option.label or "") }, "=")
		end
		signature = table.concat(signature, "|")
		if force or signature ~= self.overviewSkillContextKey then
			local validSkill = false
			local selectedSkill = ""
			for _, option in ipairs(currentOptions) do
				if option.groupIndex == parsePositiveIndex(self.textValues.targetSkillGroupIndex)
					and option.skillIndex == parsePositiveIndex(self.textValues.targetSkillIndex) then
					validSkill = true
					selectedSkill = option.val
					break
				end
			end
			self.overviewSkillHasOptions = currentOptions[1] and currentOptions[1].val ~= "" or false
			if self.overviewSkillHasOptions and not validSkill then
				local previousGroupIndex = tostring(self.textValues.targetSkillGroupIndex or "")
				local previousSkillIndex = tostring(self.textValues.targetSkillIndex or "")
				local previousGemId = tostring(self.textValues.targetSkillGemId or "")
				local mainGroupIndex = parsePositiveIndex(self.build.mainSocketGroup)
				local mainGroup = mainGroupIndex and self.build.skillsTab.socketGroupList[mainGroupIndex]
				local mainSkillIndex = parsePositiveIndex(mainGroup and mainGroup.mainActiveSkill) or 1
				local fallback
				for _, option in ipairs(currentOptions) do
					if option.groupIndex == mainGroupIndex and option.skillIndex == mainSkillIndex then
						fallback = option
						break
					end
				end
				fallback = fallback or currentOptions[1]
				if fallback and fallback.val ~= "" then
					selectedSkill = fallback.val
					self.textValues.targetSkillGroupIndex = tostring(fallback.groupIndex)
					self.textValues.targetSkillIndex = tostring(fallback.skillIndex)
					self.textValues.targetSkillGemId = tostring(fallback.gemId or "")
				else
					self.textValues.targetSkillGroupIndex = ""
					self.textValues.targetSkillIndex = ""
					self.textValues.targetSkillGemId = ""
				end
				if previousGroupIndex ~= tostring(self.textValues.targetSkillGroupIndex or "")
					or previousSkillIndex ~= tostring(self.textValues.targetSkillIndex or "")
					or previousGemId ~= tostring(self.textValues.targetSkillGemId or "") then
					self.nodeEvidence = nil
					self.modFlag = true
				end
			end
			if self.overviewSkillHasOptions and selectedSkill == "" then
				table.insert(currentOptions, 1, { val = "", label = "Choose an enabled Main Skill slot" })
			end
			self.controls.overviewSkill:SetList(nativeChoiceLabels(currentOptions))
			self.controls.overviewSkill:ResetSearch()
			self.controls.overviewSkill:SelByValue(selectedSkill, "val")
			self.overviewSkillContextKey = signature
		end
		if force then
			self.overviewClassGroup:SetValue(self.textValues.baseClassId)
			self.textValues.damageFocus = normalizedOverviewChoice(damageChoices, self.textValues.damageFocus, "Auto")
			self.textValues.defenseProfile = normalizedOverviewChoice(defenseChoices, self.textValues.defenseProfile, "Auto")
			self.overviewDamageGroup:SetValue(self.textValues.damageFocus)
			self.overviewDefenseGroup:SetValue(self.textValues.defenseProfile)
			self.overviewPriorityGroup:SetValue(self.textValues.rankingPriority or "ObjectiveFirst")
			self.controls.overviewUseImportedRoutes.state = tostring(self.textValues.useImportedRouteMemory or "true"):lower() == "true"
			updateOverviewAscendancySummary()
			local gemFound = false
			for _, option in ipairs(overviewGemOptions) do
				if option.val == tostring(self.textValues.targetSkillGemId or "") and option.val ~= "" then gemFound = true break end
			end
			self.overviewGemHasOptions = hasOverviewGemOptions
			if not gemFound then self.textValues.targetSkillGemId = "" end
			self.controls.overviewGem:SelByValue(tostring(self.textValues.targetSkillGemId or ""), "val")
		end
	end
	self.RefreshOverviewDirectionControls(true)
	self.controls.overviewReport = new("TextListControl"):TextListControl({ "TOPLEFT", self, "TOPLEFT" }, { 12, 298, 500, 210 })
	self.controls.overviewReport.width = function() return math.max(120, (self.width or 556) - 24) end
	self.controls.overviewReport.height = function() return math.max(80, (self.height or 520) - 310) end
	local overviewShownOverrides = {
		overviewImport = false,
		overviewAI = false,
		overviewRun = false,
		overviewAdvanced = false,
		overviewRefresh = false,
		overviewDetails = false,
		overviewResult = function() return self.result ~= nil end,
		overviewCancel = function() return self.innerView == "overview" and self.job ~= nil and self.job.status == "running" end,
	}
	for key, control in pairs(self.controls) do
		if key:match("^overview") then
			local shownOverride = overviewShownOverrides[key]
			if shownOverride ~= nil then
				control.shown = shownOverride
			else
				control.shown = function() return self.innerView == "overview" end
			end
		elseif key ~= "pageOverview" and key ~= "pageMatrix" and key ~= "pageNodePotential" and key ~= "nodeAnalyze" and key ~= "nodeCancel" then
			control.shown = function() return self.innerView == "matrix" end
		end
	end
	self.controls.nodeAnalyze.shown = function() return self.innerView == "nodes" end
	self.controls.nodeCancel.shown = function() return self.innerView == "nodes" end
	return self
end

function OptimizerTabClass:Layout(viewPort)
	if self.layoutWidth == viewPort.width then return end
	self.layoutWidth = viewPort.width
	local compact = viewPort.width < 700
	self.compactLayout = compact
	for index, definition in ipairs(Inputs.metricDefinitions) do
		local labelX, y, inputX, inputWidth, labelWidth = metricPosition(index, viewPort.width)
		local label = self.fieldLabels[index]
		label.x = labelX
		label.y = y
		local denseLayout = metricColumnCount(viewPort.width) > 2
		local labelFontSize = (compact or viewPort.width < 900) and 11 or denseLayout and 12 or 14
		label.fontSize = labelFontSize
		local useCompactLabel = compact or viewPort.width < 900
		label.text = metricLabel(definition, labelWidth, useCompactLabel, labelFontSize)
		local control = self.controls["metric_" .. definition.key]
		control.x = inputX
		control.y = y - 1
		control.width = inputWidth
	end
	local contentWidth = math.max(0, viewPort.width - 24)
	local columnGap = compact and 12 or 0
	local columnWidth = compact and (contentWidth - columnGap) / 2 or 0
	local compactFieldIndex = 0
	for _, definition in ipairs(textFieldDefinitions) do
		if not definition.hidden then
		compactFieldIndex = compactFieldIndex + 1
		local label = self.textFieldLabels[definition.key]
		local control = self.controls["text_" .. definition.key]
		local pointCapSlider = definition.key == "maxTotalPoints" and self.controls.pointCapSlider or nil
		if compact then
			local column = (compactFieldIndex - 1) % 2
			local row = math.floor((compactFieldIndex - 1) / 2)
			local x = 12 + column * (columnWidth + columnGap)
			local y = 292 + row * 22
			label.x = x
			label.y = y
			label.text = definition.compactLabel or definition.label
			control.x = x + 116
			control.y = y - 2
			control.width = definition.key == "maxTotalPoints" and 42 or math.max(88, columnWidth - 120)
			if pointCapSlider then
				pointCapSlider.x = control.x + control.width + 4
				pointCapSlider.y = y - 1
				pointCapSlider.width = math.max(30, x + columnWidth - pointCapSlider.x - 4)
			end
		else
			label.x = definition.x
			label.y = definition.y
			label.text = definition.label
			control.x = definition.x + definition.width + 8
			control.y = definition.y - 2
			control.width = definition.key == "maxTotalPoints" and 42 or (fieldChoices[definition.key] and 190 or (definition.placeholder and 190 or 100))
			if pointCapSlider then
				pointCapSlider.x = control.x + control.width + 4
				pointCapSlider.y = control.y + 1
				pointCapSlider.width = 136
			end
		end
		end
	end
	if compact then
		self.controls.run:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, 468)
		self.controls.cancel:SetAnchor("TOPLEFT", self, "TOPLEFT", 130, 468)
		self.controls.apply:SetAnchor("TOPLEFT", self, "TOPLEFT", 228, 468)
		self.controls.activitySchedule:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, 494)
		self.controls.direction:SetAnchor("TOPLEFT", self, "TOPLEFT", 128, 494)
		self.controls.equipment:SetAnchor("TOPLEFT", self, "TOPLEFT", 250, 494)
		self.controls.classResults:SetAnchor("TOPLEFT", self, "TOPLEFT", 334, 520)
		self.controls.marketBudget:SetAnchor("TOPLEFT", self, "TOPLEFT", 420, 494)
		self.controls.aiRequest:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, 520)
		self.controls.mcpRequest:SetAnchor("TOPLEFT", self, "TOPLEFT", 112, 520)
		self.controls.compareRoots:SetAnchor("TOPLEFT", self, "TOPLEFT", 210, 520)
		self.controls.studyRecords:SetAnchor("TOPLEFT", self, "TOPLEFT", math.max(480, math.min(544, viewPort.width - 12 - 72)), 520)
		self.controls.studyRecords.width = 72
		self.controls.resultDetails:SetAnchor("TOPLEFT", self, "TOPLEFT", 334, 520)
		self.controls.resultDetails.width = 92
	else
		self.controls.run:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, 468)
		self.controls.cancel:SetAnchor("TOPLEFT", self, "TOPLEFT", 130, 468)
		self.controls.apply:SetAnchor("TOPLEFT", self, "TOPLEFT", 228, 468)
		self.controls.aiRequest:SetAnchor("TOPLEFT", self, "TOPLEFT", 366, 468)
		self.controls.mcpRequest:SetAnchor("TOPLEFT", self, "TOPLEFT", 466, 468)
		self.controls.compareRoots:SetAnchor("TOPLEFT", self, "TOPLEFT", 564, 468)
		self.controls.direction:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, 494)
		self.controls.activitySchedule:SetAnchor("TOPLEFT", self, "TOPLEFT", 132, 494)
		self.controls.equipment:SetAnchor("TOPLEFT", self, "TOPLEFT", 252, 494)
		self.controls.classResults:SetAnchor("TOPLEFT", self, "TOPLEFT", 410, 494)
		self.controls.marketBudget:SetAnchor("TOPLEFT", self, "TOPLEFT", 570, 494)
		if viewPort.width < 800 then
			self.controls.studyRecords:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, 520)
			self.controls.resultDetails:SetAnchor("TOPLEFT", self, "TOPLEFT", 110, 520)
		elseif viewPort.width < 900 then
			self.controls.studyRecords:SetAnchor("TOPLEFT", self, "TOPLEFT", 704, 494)
			self.controls.resultDetails:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, 520)
		else
			self.controls.studyRecords:SetAnchor("TOPLEFT", self, "TOPLEFT", 704, 494)
			self.controls.resultDetails:SetAnchor("TOPLEFT", self, "TOPLEFT", 800, 494)
		end
	end
	self.statusY = (compact or viewPort.width < 900) and 548 or 522
	if self.controls.overviewDetails and self.controls.overviewResult and self.controls.overviewReport then
		local overviewContentWidth = math.max(1, viewPort.width - 24)
		local classColumns = math.max(4, math.min(7, math.floor(overviewContentWidth / 124)))
		local classRows = math.max(1, math.ceil(#(self.overviewClassGroup and self.overviewClassGroup.options or { }) / classColumns))
		local classCellWidth = overviewContentWidth / classColumns
		for index, option in ipairs(self.overviewClassGroup and self.overviewClassGroup.options or { }) do
			local column = (index - 1) % classColumns
			local row = math.floor((index - 1) / classColumns)
			option.control:SetAnchor("TOPLEFT", self, "TOPLEFT", 12 + column * classCellWidth, 85 + row * 20)
			option.control.labelWidth = math.max(64, classCellWidth - 24)
		end
		local skillLabelY = 88 + classRows * 20
		local skillY = skillLabelY + 18
		local fieldGap = 12
		local fieldWidth = (overviewContentWidth - fieldGap) / 2
		local secondFieldX = 12 + fieldWidth + fieldGap
		local choiceColumns = math.max(1, math.min(4, math.floor((fieldWidth + 4) / 112)))
		local damageRows = math.ceil(#(self.overviewDamageGroup and self.overviewDamageGroup.options or { }) / choiceColumns)
		local defenseRows = math.ceil(#(self.overviewDefenseGroup and self.overviewDefenseGroup.options or { }) / choiceColumns)
		local choiceRows = math.max(damageRows, defenseRows)
		local damageLabelY = skillY + 31
		local damageY = damageLabelY + 17
		local priorityLabelY = damageY + choiceRows * 18 + 4
		local priorityY = priorityLabelY + 16
		local ascendancyY = priorityY + 20
		local actionRowOneY = ascendancyY + 23
		local actionRowTwoY = actionRowOneY + 28
		local reportY = actionRowTwoY + 30
		self.controls.overviewClassLabel:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, 67)
		self.controls.overviewSkillLabel:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, skillLabelY)
		self.controls.overviewGemLabel:SetAnchor("TOPLEFT", self, "TOPLEFT", secondFieldX, skillLabelY)
		self.controls.overviewSkill:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, skillY)
		self.controls.overviewSkill.width = fieldWidth
		self.controls.overviewSkill.maxDroppedWidth = math.max(300, fieldWidth)
		self.controls.overviewSkill:CheckDroppedWidth(true)
		self.controls.overviewGem:SetAnchor("TOPLEFT", self, "TOPLEFT", secondFieldX, skillY)
		self.controls.overviewGem.width = fieldWidth
		self.controls.overviewGem.maxDroppedWidth = math.max(300, fieldWidth)
		self.controls.overviewGem:CheckDroppedWidth(true)
		self.controls.overviewDamageLabel:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, damageLabelY)
		self.controls.overviewDefenseLabel:SetAnchor("TOPLEFT", self, "TOPLEFT", secondFieldX, damageLabelY)
		local function layoutPreferenceGroup(group, left)
			local cellWidth = fieldWidth / choiceColumns
			for index, option in ipairs(group and group.options or { }) do
				local column = (index - 1) % choiceColumns
				local row = math.floor((index - 1) / choiceColumns)
				option.control:SetAnchor("TOPLEFT", self, "TOPLEFT", left + column * cellWidth, damageY + row * 18)
				option.control.labelWidth = math.max(48, cellWidth - 20)
			end
		end
		layoutPreferenceGroup(self.overviewDamageGroup, 12)
		layoutPreferenceGroup(self.overviewDefenseGroup, secondFieldX)
		self.controls.overviewPriorityLabel:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, priorityLabelY)
		for index, option in ipairs(self.overviewPriorityGroup and self.overviewPriorityGroup.options or { }) do
			option.control:SetAnchor("TOPLEFT", self, "TOPLEFT", 12 + (index - 1) * 132, priorityY)
			option.control.labelWidth = 112
		end
		self.controls.overviewUseImportedRoutes:SetAnchor("TOPLEFT", self, "TOPLEFT", 288, priorityY)
		self.controls.overviewUseImportedRoutes.labelWidth = math.max(120, math.min(250, overviewContentWidth - 304))
		self.controls.overviewAscendancy:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, ascendancyY)
		self.controls.overviewDirection:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, actionRowOneY)
		self.controls.overviewRoutes:SetAnchor("TOPLEFT", self, "TOPLEFT", 146, actionRowOneY)
		self.controls.overviewResult:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, actionRowTwoY)
		self.controls.overviewDetails:SetAnchor("TOPLEFT", self, "TOPLEFT", self.result and 132 or 12, actionRowTwoY)
		self.controls.overviewCancel:SetAnchor("TOPLEFT", self, "TOPLEFT", self.result and 236 or 116, actionRowTwoY)
		self.controls.overviewReport:SetAnchor("TOPLEFT", self, "TOPLEFT", 12, reportY)
		self.controls.overviewReport.height = function() return math.max(80, (self.height or 520) - reportY - 12) end
	end
	local pageStart = math.max(300, viewPort.width - 194)
	self.controls.pageMatrix:SetAnchor("TOPLEFT", self, "TOPLEFT", pageStart, 8)
	self.controls.pageNodePotential:SetAnchor("TOPLEFT", self, "TOPLEFT", pageStart + 92, 8)
	if self.controls.pageOverview then self.controls.pageOverview:SetAnchor("TOPLEFT", self, "TOPLEFT", pageStart - 82, 8) end
end

function OptimizerTabClass:RefreshReadiness(force)
	local build = self.build
	local env = build.calcsTab and build.calcsTab.mainEnv
	-- A hidden overview must not keep an obsolete, large calculator environment
	-- alive after another tab recalculates. The report stores scalars only and
	-- its source marker is weak; the native Calcs tab remains the env owner.
	self.readinessSource = self.readinessSource or setmetatable({ }, { __mode = "v" })
	local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
	local importDetail = build.importTab and build.importTab.importCodeDetail
	local spec = build.spec
	local allocatedPointCount = type(spec.CountAllocNodes) == "function" and spec:CountAllocNodes() or nil
	local key = table.concat({ tostring(build.buildFlag), tostring(build.mainSocketGroup), tostring(group and group.mainActiveSkill),
		tostring(group and group.enabled), tostring(group and group.slotEnabled), tostring(group and group.slot),
		tostring(build.characterLevel), tostring(build.characterLevelAutoMode), tostring(spec.curClassId),
		tostring(spec.curAscendClassId), tostring(spec.curSecondaryAscendClassId), tostring(allocatedPointCount),
		tostring(build.buildName), tostring(spec.treeVersion), tostring(importDetail), tostring(build.importTab and build.importTab.importCodeFetching),
		tostring(build.importTab and build.importTab.plannerImportRevision), tostring(build.importTab and build.importTab.plannerOriginRevision),
		tostring(build.importTab and build.importTab.plannerImportAttempt and build.importTab.plannerImportAttempt.status) }, "\31")
	if force or not self.readinessReport or self.readinessSource.env ~= env or self.readinessKey ~= key then
		self.readinessReport = BuildReadiness.Evaluate(build)
		self.readinessSource.env, self.readinessKey = env, key
		self.readinessLayoutWidth = nil
	end
	local values = self.textValues or { }
	local job = self.job
	local progress = job and job.progress or { }
	local result = self.result
	local cachedWorkflow = self.readinessWorkflowCache
	local workflowChanged = not cachedWorkflow
	if cachedWorkflow then
		workflowChanged = cachedWorkflow.readiness ~= self.readinessReport
			or cachedWorkflow.job ~= job
			or cachedWorkflow.jobStatus ~= (job and job.status)
			or cachedWorkflow.processed ~= progress.processed
			or cachedWorkflow.total ~= progress.total
			or cachedWorkflow.phase ~= progress.phase
			or cachedWorkflow.current ~= progress.current
			or cachedWorkflow.generatedProposals ~= progress.generatedProposals
			or cachedWorkflow.uniqueProposals ~= progress.uniqueProposals
			or cachedWorkflow.retainedProposals ~= progress.retainedProposals
			or cachedWorkflow.archiveCompatibleLineages ~= progress.archiveCompatibleLineages
			or cachedWorkflow.archivePatternsAvailable ~= progress.archivePatternsAvailable
			or cachedWorkflow.archiveRoutesGenerated ~= progress.archiveRoutesGenerated
			or cachedWorkflow.archiveCompositionsGenerated ~= progress.archiveCompositionsGenerated
			or cachedWorkflow.archiveRoutesRetained ~= progress.archiveRoutesRetained
			or cachedWorkflow.archiveCompositionsRetained ~= progress.archiveCompositionsRetained
			or cachedWorkflow.archiveDirectExact ~= progress.archiveDirectExact
			or cachedWorkflow.archiveCompositionsExact ~= progress.archiveCompositionsExact
			or cachedWorkflow.archiveGateRepairsGenerated ~= progress.archiveGateRepairsGenerated
			or cachedWorkflow.archiveGateRepairsExact ~= progress.archiveGateRepairsExact
			or cachedWorkflow.archiveGateRepairsFeasible ~= progress.archiveGateRepairsFeasible
			or cachedWorkflow.exactEvaluationPlan ~= progress.exactEvaluationPlan
			or cachedWorkflow.exactEvaluationsByFamily ~= progress.exactEvaluationsByFamily
			or cachedWorkflow.paretoRoutes ~= progress.paretoRoutes
			or cachedWorkflow.exactFeasibleMutations ~= progress.exactFeasibleMutations
			or cachedWorkflow.bestExactRoute ~= progress.bestExactRoute
			or cachedWorkflow.result ~= result
			or cachedWorkflow.selectedRouteResult ~= self.selectedRouteResult
			or cachedWorkflow.selectedRouteCandidate ~= self.selectedRouteCandidate
			or cachedWorkflow.nodeEvidence ~= self.nodeEvidence
			or cachedWorkflow.resultStatus ~= (result and result.status)
		if not workflowChanged then
			for key, value in pairs(values) do
				if cachedWorkflow.values[key] ~= value then workflowChanged = true break end
			end
		end
		if not workflowChanged then
			for key in pairs(cachedWorkflow.values) do
				if values[key] == nil then workflowChanged = true break end
			end
		end
	end
	if self.readinessLayoutWidth ~= self.width or workflowChanged then
		local guidedLines = OptimizerTabClass.FormatGuidedWorkflow(self, self.readinessReport)
		local rows = { }
		for _, line in ipairs(guidedLines) do
			for _, wrapped in ipairs(main:WrapString(line, 14, math.max(100, (self.width or 556) - 54))) do
				rows[#rows + 1] = { "^8" .. DisplayText.Native(wrapped), height = 14 }
			end
		end
		self.controls.overviewReport.list = rows
		self.readinessLayoutWidth = self.width
		local valueSnapshot = { }
		for key, value in pairs(values) do valueSnapshot[key] = value end
		self.readinessWorkflowCache = {
			values = valueSnapshot,
			readiness = self.readinessReport,
			job = job,
			jobStatus = job and job.status,
			processed = progress.processed,
			total = progress.total,
			phase = progress.phase,
			current = progress.current,
			generatedProposals = progress.generatedProposals,
			uniqueProposals = progress.uniqueProposals,
			retainedProposals = progress.retainedProposals,
			archiveCompatibleLineages = progress.archiveCompatibleLineages,
			archivePatternsAvailable = progress.archivePatternsAvailable,
			archiveRoutesGenerated = progress.archiveRoutesGenerated,
			archiveCompositionsGenerated = progress.archiveCompositionsGenerated,
			archiveRoutesRetained = progress.archiveRoutesRetained,
			archiveCompositionsRetained = progress.archiveCompositionsRetained,
			archiveDirectExact = progress.archiveDirectExact,
			archiveCompositionsExact = progress.archiveCompositionsExact,
			archiveGateRepairsGenerated = progress.archiveGateRepairsGenerated,
			archiveGateRepairsExact = progress.archiveGateRepairsExact,
			archiveGateRepairsFeasible = progress.archiveGateRepairsFeasible,
			exactEvaluationPlan = progress.exactEvaluationPlan,
			exactEvaluationsByFamily = progress.exactEvaluationsByFamily,
			paretoRoutes = progress.paretoRoutes,
			exactFeasibleMutations = progress.exactFeasibleMutations,
			bestExactRoute = progress.bestExactRoute,
			result = result,
			selectedRouteResult = self.selectedRouteResult,
			selectedRouteCandidate = self.selectedRouteCandidate,
			nodeEvidence = self.nodeEvidence,
			resultStatus = result and result.status,
		}
	end
	return self.readinessReport
end

function OptimizerTabClass:OpenMarketBudget()
	local controls = { }
	local popupWidth = 720
	local unitChoices = {
		{ val = "Chaos", label = "Chaos Orb equivalent" },
		{ val = "Divine", label = "Divine Orb equivalent" },
	}
	local modeChoices = {
		{ val = "Trade", label = "Trade market estimates" },
		{ val = "SSF", label = "SSF / manual acquisition cost" },
	}
	controls.intro = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 16, 680, 44 },
		"^8A strict total acquisition-cost gate for every selected equipment item and socketed jewel in each candidate. A missing item price blocks certification; the solver never treats an unknown price as zero.")
	setClippedPopupLabel(controls.intro, 680, 13)
	controls.amountLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 28, 78, 126, 20 }, "^7Maximum budget:")
	controls.amount = new("EditControl"):EditControl(popupTopLeftAnchor(), { 160, 76, 112, 20 }, self.textValues.currencyBudgetAmount or "", "Optional", "^%d%.%-,", 12, function(value)
		self.textValues.currencyBudgetAmount = value
		self.modFlag = true
	end, nil, nil, true)
	controls.unitLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 292, 78, 72, 20 }, "^7Currency:")
	controls.unit = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 366, 76, 190, 20 }, unitChoices, function(_, choice)
		self.textValues.currencyBudgetUnit = choice.val
		self.result = nil
		self.modFlag = true
	end)
	controls.unit.optimizerChoices = unitChoices
	controls.unit:SetSel(self.textValues.currencyBudgetUnit == "Divine" and 2 or 1, true)
	controls.modeLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 28, 116, 126, 20 }, "^7Acquisition mode:")
	controls.mode = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 160, 114, 396, 20 }, modeChoices, function(_, choice)
		self.textValues.currencyBudgetMode = choice.val
		self.result = nil
		self.modFlag = true
	end)
	controls.mode.optimizerChoices = modeChoices
	controls.mode:SetSel(self.textValues.currencyBudgetMode == "SSF" and 2 or 1, true)
	controls.leagueLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 28, 154, 126, 20 }, "^7Trade league:")
	controls.league = new("EditControl"):EditControl(popupTopLeftAnchor(), { 160, 152, 396, 20 }, self.textValues.currencyBudgetLeague or "", "Blank = current league", "^%C", 80, function(value)
		self.textValues.currencyBudgetLeague = value
		self.result = nil
		self.modFlag = true
	end, nil, nil, true)
	controls.rateLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 28, 192, 126, 20 }, "^7SSF Divine rate:")
	controls.rate = new("EditControl"):EditControl(popupTopLeftAnchor(), { 160, 190, 112, 20 }, self.textValues.currencyBudgetDivineChaosRate or "", "Optional", "^%d%.%-,", 12, function(value)
		self.textValues.currencyBudgetDivineChaosRate = value
		self.result = nil
		self.modFlag = true
	end, nil, nil, true)
	controls.rateHint = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 282, 192, 400, 20 }, "^8Required only for SSF budgets entered in Divine Orbs; use your own Chaos/Divine conversion.")
	setClippedPopupLabel(controls.rateHint, 400, 12)
	local quoteCount = 0
	local quoteSource, quoteLeague = "none", ""
	local snapshot = json.decode(tostring(self.textValues.marketQuotesJson or "{}"))
	if type(snapshot) == "table" then
		for _ in pairs(snapshot.quotes or { }) do quoteCount = quoteCount + 1 end
		quoteSource = tostring(snapshot.provider or snapshot.source or "none")
		local league = snapshot.league
		quoteLeague = type(league) == "table" and tostring(league.name or league.id or "") or tostring(league or "")
	end
	controls.priceStatus = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 28, 230, 660, 38 },
		"^8Loaded quotes: " .. tostring(quoteCount) .. " item IDs — " .. quoteSource .. (quoteLeague ~= "" and (" — " .. quoteLeague) or ""))
	setClippedPopupLabel(controls.priceStatus, 660, 13)
	controls.guidance = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 28, 274, 660, 54 },
		"^8Companion-MCP optimizer runs fetch supported unique-item estimates through poe.ninja's documented economy API; direct UI runs use only a loaded quote snapshot. Rare items need explicit manual prices. SSF ignores trade prices and requires manual Chaos-equivalent costs. Unknown prices fail the hard gate.")
	setClippedPopupLabel(controls.guidance, 660, 13)
	controls.save = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 28, 340, 128, 22 }, "Save budget", function()
		self.textValues.currencyBudgetAmount = controls.amount.buf or ""
		self.textValues.currencyBudgetUnit = unitChoices[controls.unit.selIndex or 1].val
		self.textValues.currencyBudgetMode = modeChoices[controls.mode.selIndex or 1].val
		self.textValues.currencyBudgetLeague = controls.league.buf or ""
		self.textValues.currencyBudgetDivineChaosRate = controls.rate.buf or ""
		self.result = nil
		self.modFlag = true
		self.statusMessage = self.textValues.currencyBudgetAmount == ""
			and "Currency budget disabled. Point and exact-evaluation budgets remain independent."
			or "Currency budget saved. Run through MCP for fresh trade quotes; unpriced items cannot pass the gate."
		main:ClosePopup()
	end)
	controls.clear = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 170, 340, 128, 22 }, "Clear budget", function()
		self.textValues.currencyBudgetAmount = ""
		self.textValues.currencyBudgetUnit = "Chaos"
		self.textValues.currencyBudgetMode = "Trade"
		self.textValues.currencyBudgetLeague = ""
		self.textValues.currencyBudgetDivineChaosRate = ""
		self.textValues.marketQuotesJson = "{}"
		self.textValues.manualItemPricesJson = "{}"
		self.result = nil
		self.modFlag = true
		self.statusMessage = "Currency budget and price snapshot cleared."
		main:ClosePopup()
	end)
	controls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 592, 340, 90, 22 }, "Close", function() main:ClosePopup() end)
	main:OpenPopup(popupWidth, 390, DisplayText.Native("AI Planner — Currency budget"), controls, "save", "clear", "close")
end

function OptimizerTabClass:OpenEquipmentChoices()
	local slots = Equipment.GetSlots(self.build)
	local overrides, parseError = Equipment.ParseOverrides(self.textValues.requiredItemsJson)
	if not overrides then
		self.statusMessage = "Equipment Matrix is invalid: " .. tostring(parseError)
		return false, parseError
	end
	if #slots == 0 then
		self.statusMessage = "No visible equipment slots are available in the active PoB item set."
		return false, self.statusMessage
	end
	local popupWidth = 760
	local columns = 2
	local rows = math.ceil(#slots / columns)
	local rowHeight = 32
	local rowStart = 158
	local footerY = rowStart + rows * rowHeight + 10
	local controls = { }
	controls.note = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 16, 16, 724, 36 },
		"^8Choose stored items or prepare legal rare proposals. Keep current leaves that slot unchanged. Native slot, socket, requirements and exact-calculation checks gate every result.")
	setClippedPopupLabel(controls.note, 724, 13)
	local searchStoredItems = self.textValues.searchStoredItems == true
		or tostring(self.textValues.searchStoredItems):lower() == "true"
	controls.searchStoredItems = new("CheckBoxControl"):CheckBoxControl(popupTopLeftAnchor(), { 16, 54, 18 },
		"Search stored item alternatives (single items and bounded pairs)", function(state)
			self.textValues.searchStoredItems = state
			self.result = nil
			self.modFlag = true
			self.statusMessage = state
				and "Stored-item search enabled. Alternatives are sampled within the exact PoB evaluation budget."
				or "Stored-item search disabled. Explicit equipment selections remain enforced."
		end,
		"Search only items already in the active PoB Items tab. The solver samples individual replacements and limited two-slot combinations; the exact-evaluation budget remains the hard cap. No items are synthesized or crafted.",
		searchStoredItems)
	controls.searchStoredItems.labelRight = true
	controls.searchStoredItems.labelWidth = 680
	local searchSyntheticGear = self.textValues.searchSyntheticGear == true
		or tostring(self.textValues.searchSyntheticGear):lower() == "true"
	controls.searchSyntheticGear = new("CheckBoxControl"):CheckBoxControl(popupTopLeftAnchor(), { 16, 76, 18 },
		"Generate legal rare items and cross-slot pairs (up to 4 affixes each)", function(state)
			self.textValues.searchSyntheticGear = state
			self.result = nil
			self.modFlag = true
			self.statusMessage = state
				and "Synthetic gear enabled. Native PoB mod weights and exact calculations gate every result."
				or "Synthetic gear disabled. Stored-item and tree searches remain available."
		end,
		"Build bounded single rare items, cross-slot pairs, and small three-item portfolios from PoB's loaded bases and mod data, with at most two prefixes and two suffixes per item. Separate quotas and inspection caps keep package generation bounded; every complete set is checked by PoB's native slot rules and exact calculator. A triple is a whole-set result, not a causal three-factor interaction estimate or crafting-probability/price model.",
		searchSyntheticGear)
	controls.searchSyntheticGear.labelRight = true
	controls.searchSyntheticGear.labelWidth = 680
	controls.syntheticItemLevelLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 16, 103, 176, 18 }, "^7Synthetic item level:")
	controls.syntheticItemLevel = new("EditControl"):EditControl(popupTopLeftAnchor(), { 194, 101, 62, 20 },
		tostring(self.textValues.syntheticItemLevel or ""), "Build level", "^%d", 3, function(value)
			self.textValues.syntheticItemLevel = value
			self.result = nil
			self.modFlag = true
		end, nil, nil, true)
	controls.syntheticItemLevel.tooltipText = "Optional item level from 1 to 100. Blank uses the equipped item's item level, then the current character level."
	controls.syntheticItemCostLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 300, 103, 196, 18 }, "^7Manual cost per rare (Chaos):")
	controls.syntheticItemCost = new("EditControl"):EditControl(popupTopLeftAnchor(), { 500, 101, 86, 20 },
		tostring(self.textValues.syntheticItemCostChaos or ""), "Optional", "^[%d%.]", 12, function(value)
			self.textValues.syntheticItemCostChaos = value
			self.result = nil
			self.modFlag = true
		end, nil, nil, true)
	controls.syntheticItemCost.tooltipText = "Optional manual Chaos-equivalent price per generated rare. A strict currency budget rejects synthetic items without this price."
	controls.catalystCostLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 300, 130, 196, 18 }, "^7Manual catalyst cost (Chaos):")
	controls.catalystCost = new("EditControl"):EditControl(popupTopLeftAnchor(), { 500, 128, 86, 20 },
		tostring(self.textValues.catalystCostChaos or ""), "Optional", "^[%d%.]", 12, function(value)
			self.textValues.catalystCostChaos = value
			self.result = nil
			self.modFlag = true
		end, nil, nil, true)
	controls.catalystCost.tooltipText = "Total manual Chaos-equivalent material cost to bring this existing jewelry item to 20% Catalyst quality. Under a strict budget, this is added to the same source item's loaded or manual price; if either price is missing, the candidate is rejected."
	controls.catalystCostInfo = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 594, 130, 148, 36 },
		"^8Auto repair runs only after exact attribute/resistance deficits.")
	setClippedPopupLabel(controls.catalystCostInfo, 148, 12)
	local activeSet = Equipment.ActiveItemSet(self.build.itemsTab)
	for index, slotName in ipairs(slots) do
		local column = math.floor((index - 1) / rows)
		local row = (index - 1) % rows
		local baseX = 16 + column * 368
		local y = rowStart + row * rowHeight
		local key = "equipment_" .. tostring(index)
		controls[key .. "Label"] = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { baseX, y + 2, 116, 18 }, "^7" .. slotName .. ":")
		local choices = Equipment.GetChoices(self.build, slotName)
		local selectedItemId = overrides[slotName] or 0
		local selectedIndex = 1
		for choiceIndex, choice in ipairs(choices) do
			if choice.itemId == selectedItemId then selectedIndex = choiceIndex break end
		end
		local chosenSlotName = slotName
		local drop = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { baseX + 118, y, 238, 22 }, choices, function(_, choice)
			if choice and choice.itemId and choice.itemId > 0 then
				overrides[chosenSlotName] = choice.itemId
			else
				overrides[chosenSlotName] = nil
			end
			self.textValues.requiredItemsJson = Equipment.EncodeOverrides(overrides)
			self.result = nil
			self.modFlag = true
			self.statusMessage = "Equipment Matrix updated. Run the optimizer to recalculate the selected PoB items."
		end)
		drop.enableDroppedWidth = true
		drop.maxDroppedWidth = 520
		drop:SetSel(selectedIndex, true)
		controls[key] = drop
	end
	controls.clear = new("ButtonControl"):ButtonControl(nil, { 16, footerY, 130, 22 }, "Clear equipment", function()
		for slotName in pairs(overrides) do overrides[slotName] = nil end
		self.textValues.requiredItemsJson = "{}"
		self.result = nil
		self.modFlag = true
		self.statusMessage = "Equipment constraints cleared. The optimizer will use the current PoB item set."
		main:ClosePopup()
	end)
	controls.prepareGear = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 158, footerY, 170, 22 }, "Prepare skill gear", function()
		local groupIndex = parsePositiveIndex(self.textValues.targetSkillGroupIndex)
		local group = groupIndex and self.build.skillsTab.socketGroupList[groupIndex]
		if not group or group.enabled == false or group.slotEnabled == false or group.source then
			self.statusMessage = "Select an enabled manual Main Skill group in Build Direction before preparing socketed gear."
			return
		end
		local skillIndex = parsePositiveIndex(self.textValues.targetSkillIndex)
		local selectedGemId = tostring(self.textValues.targetSkillGemId or "")
		local installedGemId = SkillCatalog.CurrentMainGemId(self.build, groupIndex, skillIndex)
		if selectedGemId ~= "" and installedGemId and selectedGemId ~= installedGemId then
			prepareGenerationPhase(self, "skills")
			self.result = nil
			self.modFlag = true
			self.statusMessage = "First run and apply the selected Main Skill in the Skills phase. Then prepare Equipment so its exact item result matches the installed gem."
			main:ClosePopup()
			return
		end
		prepareGenerationPhase(self, "equipment")
		self.textValues.searchSyntheticGear = true
		controls.searchSyntheticGear.state = true
		self.result = nil
		self.modFlag = true
		self.statusMessage = "Equipment search prepared for the selected Main Skill. Run optimizer to preview native socketed rare proposals; nothing is applied until Apply as variation."
	end)
	controls.prepareGear.tooltipText = "Selects the Equipment phase and enables bounded PoB-native rare/socket proposals for the selected manual skill group. A different gem must first be applied in the Skills checkpoint. Preview is isolated; Apply creates a reversible PoB variation."
	controls.close = new("ButtonControl"):ButtonControl(nil, { popupWidth - 106, footerY, 90, 22 }, "Close", function()
		main:ClosePopup()
	end)
	main:OpenPopup(popupWidth, footerY + 54, DisplayText.Native("Equipment choices — exact PoB items"), controls, "close", "clear")
	return true
end

function OptimizerTabClass:OpenAIRequest()
	if not main.optimizerAI then
		self.statusMessage = "The native ChatGPT client is unavailable on this platform"
		return
	end
	main.optimizerAI:OpenPopup()
end

function OptimizerTabClass:OpenStudyRecords()
	local build = self.build
	local expectedEngine = {
		pobVersion = launch and launch.versionNumber or nil,
		pobBranch = Version.Branch(),
		dataVersion = Version.Data(build),
		treeVersion = build and build.spec and build.spec.treeVersion or nil,
		manifestFingerprint = launch and launch.manifestFingerprint or nil,
	}
	local storePath, pathError = StudyRecords.GetStorePath(main and main.userPath)
	local list, listError
	if storePath then
		list, listError = StudyRecords.List(storePath, 25, expectedEngine.dataVersion, expectedEngine.treeVersion,
			expectedEngine.pobVersion, expectedEngine.pobBranch, expectedEngine.manifestFingerprint)
	end
	local rows = list and list.records or { }
	local popupWidth, popupHeight = 760, 650
	local controls = { }
	local state = { record = nil, assessment = nil, message = nil, attestationControls = { }, rightsBasis = nil }
	controls.intro = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 18, 14, 720, 30 },
		"^8Exact PoB pairs stay local. Rights evidence is recorded locally, never sent to Ask AI or model features.")
	setClippedPopupLabel(controls.intro, 720, 13)
	controls.recordLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 56, 78, 18 }, "^7Record:")
	local options = { }
	for _, row in ipairs(rows) do
		options[#options + 1] = {
			recordId = row.recordId,
			label = tostring(row.recordId) .. " | " .. tostring(row.kind or "study") .. " | "
				.. tostring(row.class or "Unknown") .. " / " .. tostring(row.mainSkill or "No skill")
				.. " | " .. tostring(row.reviewStatus or "pending_review"),
		}
	end
	controls.record = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 102, 52, 630, 22 }, options, function(_, selected)
		if selected and selected.recordId then state.selectRecord(selected.recordId) end
	end)
	controls.record.enableDroppedWidth = true
	controls.record.tooltipText = "Recent locally saved exact baseline/candidate studies. Public build popularity is not used as a training feature."
	if #options == 0 then controls.record:SetList({ "No local study records" }) end

	local function metricValue(value)
		return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
			and string.format("%.4g", value) or "—"
	end
	local function selected()
		return state.record
	end
	local function rowText(makeText)
		return function()
			local record = selected()
			if not record then return makeText(nil) end
			return makeText(record)
		end
	end
	controls.recordLine = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 86, 720, 18 }, rowText(function(record)
		if not record then return "^8" .. tostring(listError or pathError or "No local study records are available.") end
		return "^7" .. tostring(record.recordId) .. " | " .. tostring(record.kind or "study") .. " | " .. tostring(record.engine and record.engine.pobVersion or "unknown")
	end))
	setClippedPopupLabel(controls.recordLine, 720, 13)
	controls.buildLine = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 106, 720, 18 }, rowText(function(record)
		if not record then return "^8Select a study record to inspect its exact pair and admission gates." end
		local buildState = record.buildState or { }
		local class = buildState.class or { }
		return string.format("^7Build: %s / %s | level %s | data/tree %s / %s",
			tostring(class.class or "Unknown"), tostring(class.ascendancy or "No ascendancy"),
			tostring(buildState.characterLevel or "?"), tostring(record.engine and record.engine.dataVersion or "?"),
			tostring(record.engine and record.engine.treeVersion or "?"))
	end))
	setClippedPopupLabel(controls.buildLine, 720, 13)
	controls.deltaLine = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 126, 720, 18 }, rowText(function(record)
		if not record then return "" end
		local delta = record.metricDelta or { }
		return "^7Exact Δ: Combined DPS " .. metricValue(delta.CombinedDPS) .. " | Full DPS " .. metricValue(delta.FullDPS)
			.. " | EHP " .. metricValue(delta.TotalEHP) .. " | Life " .. metricValue(delta.LifeUnreserved)
	end))
	setClippedPopupLabel(controls.deltaLine, 720, 13)
	controls.outputLine = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 146, 720, 18 }, rowText(function(record)
		if not record then return "" end
		local baseline, candidate = record.baseline or { }, record.candidate or { }
		local baselineActivity = baseline.activitySustain and baseline.activitySustain.status or "missing"
		local candidateActivity = candidate.activitySustain and candidate.activitySustain.status or "missing"
		local baselineRequirements = baseline.requirements and baseline.requirements.feasible == true
		local candidateRequirements = candidate.requirements and candidate.requirements.feasible == true
		return "^7PoB requirements: " .. tostring(baselineRequirements) .. " → " .. tostring(candidateRequirements)
			.. " | included activity: " .. tostring(baselineActivity) .. " → " .. tostring(candidateActivity)
	end))
	setClippedPopupLabel(controls.outputLine, 720, 13)
	controls.scenarioLine = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 166, 720, 18 }, rowText(function(record)
		if not record then return "" end
		local config = record.buildState and record.buildState.configuration or { }
		local values = config.values or { }
		local valueCount, customCount = 0, #(config.customModifiers or { })
		for _ in pairs(values) do valueCount = valueCount + 1 end
		return "^7Captured scenario: " .. tostring(config.title or "unnamed PoB config") .. " | "
			.. tostring(valueCount) .. " config values | " .. tostring(customCount) .. " custom-mod blocks; inspect before approval."
	end))
	setClippedPopupLabel(controls.scenarioLine, 720, 13)
	controls.preflightLine = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 186, 720, 18 }, rowText(function(record)
		if not record then return "" end
		local assessment = state.assessment or { }
		if assessment.canApprove then return "^8PoB preflight ready. Human confirmation is still required for each item below." end
		local blockers = assessment.blockers or { }
		return "^1Preflight blocked: " .. (#blockers > 0 and table.concat(blockers, ", ") or "review evidence is incomplete")
	end))
	setClippedPopupLabel(controls.preflightLine, 720, 13)
	controls.sourceLine = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 206, 720, 18 }, rowText(function(record)
		if not record then return "" end
		local source = record.source or { }
		if source.type == "public_build_study" then
			return "^7Data source: imported public build (" .. tostring(source.provider or "unknown provider")
				.. "); source URL is hidden from Ask AI."
		elseif source.type == "native_comparison_build" then
			return "^7Data source: local PoB Compare build."
		end
		return "^7Data source: local active PoB build snapshot."
	end))
	setClippedPopupLabel(controls.sourceLine, 720, 13)

	local function updateApprovalState()
		local record = state.record
		if not record then return false end
		for _, key in ipairs({ "exactPair", "scenario", "activity", "lookupTables", "localTrainingConsent", "sourceRightsVerified" }) do
			local control = state.attestationControls[key]
			if not control or control.state ~= true then return false end
		end
		local rightsEvidence = { basis = state.rightsBasis }
		if state.rightsBasis == "open_license" then
			rightsEvidence.licenseId = controls.licenseId.buf
			rightsEvidence.licenseUrl = controls.licenseUrl.buf
		elseif state.rightsBasis == "creator_permission" then
			rightsEvidence.permissionReference = controls.permissionReference.buf
		end
		if not StudyRecords.NormalizeRightsEvidence(rightsEvidence) then return false end
		return state.assessment and state.assessment.canApprove == true and record.trainingEligible ~= true
	end
	local attestations = {
		{ key = "exactPair", y = 224, label = "I inspected both exact PoB outputs, the delta, and requirement checks." },
		{ key = "scenario", y = 252, label = "I confirmed the captured PoB configuration and scenario match the intended study." },
		{ key = "activity", y = 280, label = "I confirmed the recorded activity-sustain result is relevant and passes." },
		{ key = "lookupTables", y = 308, label = "I reviewed the loaded tree/jewel lookup effects used by this exact calculation." },
		{ key = "localTrainingConsent", y = 336, label = "I explicitly consent to offline local-model training on these exact records." },
		{ key = "sourceRightsVerified", y = 364, label = "I have permission to use this source for local model training." },
	}
	for _, entry in ipairs(attestations) do
		local tooltip = "This is an explicit local human attestation; Ask AI and MCP cannot set it."
		if entry.key == "localTrainingConsent" then
			tooltip = "Opts this exact reviewed record into a sanitized dataset for offline local-model training. It is not sent to a remote trainer."
		elseif entry.key == "sourceRightsVerified" then
			tooltip = "Confirm you have permission to use this source build for local training. PoB cannot infer rights from a public URL."
		end
		local control = new("CheckBoxControl"):CheckBoxControl(popupTopLeftAnchor(), { 34, entry.y, 18 }, entry.label, nil,
			tooltip, false)
		control.labelRight = true
		control.labelWidth = 680
		state.attestationControls[entry.key] = control
		controls["attest_" .. entry.key] = control
	end
	controls.rightsBasisLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 392, 102, 18 }, "^7Rights basis:")
	controls.rightsBasis = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 124, 386, 250, 22 }, {
		{ val = "", label = "Choose verified basis..." },
		{ val = "user_authored", label = "User-authored build" },
		{ val = "creator_permission", label = "Creator permission" },
		{ val = "open_license", label = "Open license" },
	}, function(_, selected)
		state.rightsBasis = selected and selected.val ~= "" and selected.val or nil
	end, "Select the source-use basis you personally verified. A public build URL alone does not grant training rights.")
	controls.rightsBasis:SelByValue("", "val")
	controls.licenseIdLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 420, 102, 18 }, "^7License ID:")
	controls.licenseIdLabel.shown = function() return state.rightsBasis == "open_license" end
	controls.licenseId = new("EditControl"):EditControl(popupTopLeftAnchor(), { 124, 414, 158, 22 }, "", "SPDX or license ID", "%c", 80)
	controls.licenseId.shown = function() return state.rightsBasis == "open_license" end
	controls.licenseId.tooltipText = "Enter the license identifier you verified against the source. PoB does not infer license coverage."
	controls.licenseUrlLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 292, 420, 72, 18 }, "^7License URL:")
	controls.licenseUrlLabel.shown = function() return state.rightsBasis == "open_license" end
	controls.licenseUrl = new("EditControl"):EditControl(popupTopLeftAnchor(), { 366, 414, 366, 22 }, "", "Canonical HTTPS license text", "%c", 256)
	controls.licenseUrl.shown = function() return state.rightsBasis == "open_license" end
	controls.licenseUrl.tooltipText = "The canonical HTTPS license text URL is stored only in the local review journal; it is excluded from model features and exports."
	controls.permissionReferenceLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 420, 102, 18 }, "^7Permission ref:")
	controls.permissionReferenceLabel.shown = function() return state.rightsBasis == "creator_permission" end
	controls.permissionReference = new("EditControl"):EditControl(popupTopLeftAnchor(), { 124, 414, 608, 22 }, "", "Non-personal evidence reference", "%c", 128)
	controls.permissionReference.shown = function() return state.rightsBasis == "creator_permission" end
	controls.permissionReference.tooltipText = "Use a non-personal opaque reference (8–128 letters, digits, . _ : / or -). Never enter a name, email, or private correspondence."
	controls.rightsScope = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 440, 720, 18 },
		"^8Evidence scope is fixed to offline local-model training. Do not enter names, emails, or private correspondence.")
	setClippedPopupLabel(controls.rightsScope, 720, 13)
	controls.reviewStatus = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 462, 720, 18 }, function()
		if state.message then return "^8" .. state.message end
		local record = state.record
		return "^8Review status: " .. tostring(record and record.reviewStatus or "select a record")
	end)
	setClippedPopupLabel(controls.reviewStatus, 720, 13)
	controls.readiness = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 482, 720, 32 }, function()
		local readiness = list and list.trainingReadiness or { }
		return string.format("^7Corpus: %s | rows %s | eligible %s | origin/snapshot groups %s. This does not enable a model.",
			tostring(readiness.status or "unavailable"), tostring(readiness.totalRows or list and list.totalRecords or 0),
			tostring(readiness.eligibleRows or list and list.trainingEligible or 0), tostring(readiness.sourceLineages or 0))
	end)
	setClippedPopupLabel(controls.readiness, 720, 13)
	controls.learningCoverage = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 522, 720, 18 }, function()
		return "^7" .. OptimizerTabClass.FormatLearningCoverage(list and list.learningCoverage)
	end)
	setClippedPopupLabel(controls.learningCoverage, 720, 13)
	controls.learningCoverageContext = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 542, 720, 18 }, function()
		return "^8" .. OptimizerTabClass.FormatLearningCoverageContext(list and list.learningCoverage)
	end)
	setClippedPopupLabel(controls.learningCoverageContext, 720, 13)
	controls.learningCoverageSafety = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 562, 720, 18 }, function()
		return "^8" .. OptimizerTabClass.FormatLearningCoverageSafety(list and list.learningCoverage)
	end)
	setClippedPopupLabel(controls.learningCoverageSafety, 720, 13)
	controls.buildLearning = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 20, 582, 180, 22 },
		"Build archive & learning", function()
		self:OpenBuildLearningDashboard()
	end)
	controls.buildLearning.tooltipText = "Open the persistent local PoB build archive, coverage by normal/transfigured effect, and cross-skill co-occurrence hypotheses."

	state.selectRecord = function(recordId)
		local record, readError = StudyRecords.ReadById(storePath, recordId, expectedEngine.dataVersion,
			expectedEngine.treeVersion, expectedEngine.pobVersion, expectedEngine.pobBranch, expectedEngine.manifestFingerprint)
		state.record = record
		state.assessment = record and record.reviewAssessment or nil
		state.message = readError
		local prior = record and record.certification and record.certification.attestations or { }
		for key, control in pairs(state.attestationControls) do control.state = prior[key] == true end
		state.rightsBasis = nil
		controls.rightsBasis:SelByValue("", "val")
		controls.licenseId:SetText("")
		controls.licenseUrl:SetText("")
		controls.permissionReference:SetText("")
	end
	if #options > 0 then
		controls.record:SetSel(1, true)
		state.selectRecord(options[1].recordId)
	end
	controls.approve = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 344, 602, 160, 22 }, "Approve reviewed record", function()
		if not updateApprovalState() then return end
		local approvals = { }
		for key, control in pairs(state.attestationControls) do approvals[key] = control.state == true end
		approvals.sourceRightsEvidence = { basis = state.rightsBasis }
		if state.rightsBasis == "open_license" then
			approvals.sourceRightsEvidence.licenseId = controls.licenseId.buf
			approvals.sourceRightsEvidence.licenseUrl = controls.licenseUrl.buf
		elseif state.rightsBasis == "creator_permission" then
			approvals.sourceRightsEvidence.permissionReference = controls.permissionReference.buf
		end
		local result, reviewError = StudyRecords.ReviewToPath(storePath, state.record.recordId, "approved", approvals,
			expectedEngine, MakeDir)
		if not result then state.message = reviewError return end
		state.selectRecord(result.recordId)
		state.message = result.duplicate and "This record already has the same approval." or "Human review saved locally; export and model-quality gates still apply."
		local refreshed = StudyRecords.List(storePath, 25, expectedEngine.dataVersion, expectedEngine.treeVersion,
			expectedEngine.pobVersion, expectedEngine.pobBranch, expectedEngine.manifestFingerprint)
		if refreshed then list = refreshed end
	end)
	controls.approve.enabled = updateApprovalState
	controls.reject = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 514, 602, 100, 22 }, "Reject", function()
		if not state.record then return end
		local result, reviewError = StudyRecords.ReviewToPath(storePath, state.record.recordId, "rejected", { }, expectedEngine, MakeDir)
		if not result then state.message = reviewError return end
		state.selectRecord(result.recordId)
		state.message = "Record explicitly rejected and remains quarantined."
		local refreshed = StudyRecords.List(storePath, 25, expectedEngine.dataVersion, expectedEngine.treeVersion,
			expectedEngine.pobVersion, expectedEngine.pobBranch, expectedEngine.manifestFingerprint)
		if refreshed then list = refreshed end
	end)
	controls.reject.enabled = function() return state.record ~= nil and state.record.reviewStatus ~= "rejected" end
	controls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 642, 602, 90, 22 }, "Close", function()
		main:ClosePopup()
	end)
	main:OpenPopup(popupWidth, popupHeight, DisplayText.Native("AI Planner — Study records and review"), controls, "close", "reject", "approve")
end

function OptimizerTabClass:OpenBuildLearningDashboard()
	local build = self.build
	local userPath = main and main.userPath
	local state = { summary = nil, reviewSummary = nil, error = nil, generation = -1,
		reviewGeneration = -1, patch = nil, skillKey = nil, effectId = nil, message = nil,
		ingestionStatus = nil, ingestionLastPoll = 0 }
	local controls = { }
	local function patchRowByVersion(patchVersion)
		for _, row in ipairs(state.summary and state.summary.patchSkillCatalog and state.summary.patchSkillCatalog.patches or { }) do
			if row.patch == patchVersion then return row end
		end
		return nil
	end
	local function selectedPatchRow()
		return patchRowByVersion(state.patch)
	end
	local function selectedSkillRow()
		for _, row in ipairs(selectedPatchRow() and selectedPatchRow().skills or { }) do
			if row.variantKey == state.skillKey then return row end
		end
		return nil
	end
	local function patchOptions()
		local result = { }
		for _, row in ipairs(state.summary and state.summary.patchSkillCatalog and state.summary.patchSkillCatalog.patches or { }) do
			result[#result + 1] = { patch = row.patch, label = string.format("%s — %d/%d skills em 10+",
				row.patch, row.counts.skillsAtTarget, row.counts.targetSkills) }
		end
		return result
	end
	local function skillOptions()
		local result = { }
		for _, skill in ipairs(selectedPatchRow() and selectedPatchRow().skills or { }) do
			result[#result + 1] = { variantKey = skill.variantKey, label = string.format("%s [%s] — %d/%d",
				tostring(skill.name or skill.variantId), tostring(skill.category), skill.uniqueBuilds, skill.sampleTarget) }
		end
		return result
	end
	local function syncSelectors()
		if controls.patch then
			local options = patchOptions()
			controls.patch:SetList(options)
			if state.patch then controls.patch:SelByValue(state.patch, "patch") end
		end
		if controls.skill then
			local options = skillOptions()
			controls.skill:SetList(options)
			if state.skillKey then controls.skill:SelByValue(state.skillKey, "variantKey") end
			if #options == 0 then controls.skill:SetList({ "Catalogo de skills indisponível" }) end
		end
	end
	local function refreshIngestionStatus(force)
		local now = os.clock()
		if not force and now - state.ingestionLastPoll < 1 then return end
		state.ingestionLastPoll = now
		state.ingestionStatus = BuildIngestionStatus.Read(userPath)
	end
	local function reload()
		state.summary, state.error = StudyBuilds.Summary(userPath, build)
		state.reviewSummary = BuildReviewPair.Summary(userPath)
		state.generation = StudyBuilds.Generation()
		state.reviewGeneration = BuildReviewPair.Generation()
		refreshIngestionStatus(true)
		local patches = state.summary and state.summary.patchSkillCatalog and state.summary.patchSkillCatalog.patches or { }
		if #patches > 0 then
			if not patchRowByVersion(state.patch) then state.patch = patches[#patches].patch end
			local patchRow = selectedPatchRow()
			local hasSkill = false
			for _, skill in ipairs(patchRow and patchRow.skills or { }) do
				if skill.variantKey == state.skillKey then hasSkill = true; break end
			end
			if not hasSkill then state.skillKey = patchRow and patchRow.skills[1] and patchRow.skills[1].variantKey or nil end
			local skill = selectedSkillRow()
			state.effectId = skill and skill.effectId or nil
		end
		syncSelectors()
	end
	local function refreshOnArchive()
		refreshIngestionStatus(false)
		if state.generation ~= StudyBuilds.Generation() or state.reviewGeneration ~= BuildReviewPair.Generation() then reload() end
	end
	reload()
	local popupWidth, popupHeight = 760, 700
	controls.title = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 12, 720, 24 }, "^7Build archive — contínuo e local")
	setClippedPopupLabel(controls.title, 720, 16)
	controls.summary = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 40, 720, 20 }, function()
		refreshOnArchive()
		local summary = state.summary
		if not summary then return "^1Archive indisponível: " .. tostring(state.error or "erro desconhecido") end
		local storage = summary.storage
		local coverage = summary.patchSkillCatalog and summary.patchSkillCatalog.patches or { }
		local totalSkills, atTarget = 0, 0
		for _, patch in ipairs(coverage) do
			totalSkills = totalSkills + patch.counts.targetSkills
			atTarget = atTarget + patch.counts.skillsAtTarget
		end
		return string.format("^7XMLs %d | builds/linhagens %d | imports %d | variantes normais/transfiguradas %d | meta 10+ %d/%d",
			storage.objectCount, storage.uniqueBuildLineages, storage.sourceObservations, totalSkills, atTarget, totalSkills)
	end)
	setClippedPopupLabel(controls.summary, 720, 14)
	controls.location = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 60, 720, 18 }, function()
		refreshOnArchive()
		return state.summary and "^8Armazenamento: " .. tostring(state.summary.storage.root)
			or "^8" .. tostring(state.error or "A pasta de dados do PoB não está disponível.")
	end)
	setClippedPopupLabel(controls.location, 720, 13)
	local availablePatchOptions = patchOptions()
	controls.patch = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 20, 86, 145, 22 }, availablePatchOptions, function(_, selected)
		if selected and selected.patch then
			state.patch, state.skillKey = selected.patch, nil
			local patchRow = selectedPatchRow()
			state.skillKey = patchRow and patchRow.skills[1] and patchRow.skills[1].variantKey or nil
			local skill = selectedSkillRow()
			state.effectId = skill and skill.effectId or nil
			syncSelectors()
		end
	end, "Patch é inferido da árvore PoB exata; claim de liga não comprova versão.")
	controls.skill = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 175, 86, 350, 22 }, skillOptions(), function(_, selected)
		if selected and selected.variantKey then
			state.skillKey = selected.variantKey
			local skill = selectedSkillRow()
			state.effectId = skill and skill.effectId or nil
		end
	end, "Identidade da gema = gameId + variantId; cada linhagem única conta uma vez.")
	controls.skill.enableDroppedWidth = true
	controls.effect = controls.skill
	if state.patch then controls.patch:SelByValue(state.patch, "patch") end
	if state.skillKey then controls.skill:SelByValue(state.skillKey, "variantKey") end
	controls.archiveCurrent = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 540, 86, 132, 22 }, "Arquivar build atual", function()
		if not build or type(build.SaveDB) ~= "function" then state.message = "PoB não conseguiu serializar a build atual." return end
		local saveOk, xmlText = pcall(build.SaveDB, build, "AI Planner learning snapshot")
		if not saveOk or type(xmlText) ~= "string" or xmlText == "" then
			state.message = "Falha ao serializar a build atual do PoB."
			return
		end
		local archived, archiveError = StudyBuilds.ArchiveXML(build, xmlText, userPath, {
			type = "local_active_build", label = "AI Planner manual archive",
		}, MakeDir)
		if not archived then state.message = "Falha no arquivo: " .. tostring(archiveError)
		else
			local review = archived.buildReview or { status = "pending" }
			if review.status == "pending" then
				state.message = "Build arquivada; revisão A/B pendente: " .. tostring(review.error or "caderno indisponível")
			else
				state.message = "Build arquivada; revisão A/B: " .. tostring(review.status) .. " (" .. tostring(review.hypothesisCount or 0) .. " hipóteses)."
			end
		end
		reload()
	end)
	controls.archiveCurrent.tooltipText = "Salva o XML PoB local na pasta de aprendizado. Direitos para treino seguem sem verificação e a build não vira rótulo de qualidade."
	controls.refresh = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 680, 86, 60, 22 }, "Atualizar", function()
		reload()
	end)
	controls.patchDetail = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 114, 720, 18 }, function()
		refreshOnArchive()
		local patch = selectedPatchRow()
		if not patch then return "^8Catálogo histórico ausente; execute Export-PatchSkillCatalog.ps1." end
		return string.format("^7%s | alvos %d (%d N/%d T) | Support excl.: %d | Vaal separado: %d | linhagens: %d | ascendências: %d",
			patch.patch, patch.counts.targetSkills, patch.counts.normalSkills, patch.counts.transfiguredSkills,
			patch.counts.supportGrantedEffects or 0, patch.counts.vaalSkills,
			patch.counts.eligibleBuildLineages, patch.standardAscendancies)
	end)
	controls.patchDetail.tooltipText = "Alvos independentes de Main Skill; efeitos ativos concedidos por Support são excluídos e contados à parte. Vaal mantém inventário próprio. Ascendências alternativas/liga permanecem fora da cobertura."
	setClippedPopupLabel(controls.patchDetail, 720, 13)
	controls.effectDetail = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 134, 720, 18 }, function()
		refreshOnArchive()
		local skill = selectedSkillRow()
		if not skill then return "^8Selecione uma skill do inventário da versão." end
		return string.format("^7%s [%s] | %d/%d builds | faltam %d | chave %s",
			tostring(skill.name or skill.variantId), tostring(skill.category), skill.uniqueBuilds,
			skill.sampleTarget, skill.remainingToTarget, tostring(skill.variantKey))
	end)
	setClippedPopupLabel(controls.effectDetail, 720, 13)
	controls.status = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 154, 720, 18 }, function()
		refreshOnArchive()
		if state.message then return "^8" .. state.message end
		if not state.summary then return "^1" .. tostring(state.error or "Archive unavailable") end
		local model = state.summary.model
		return "^8" .. model.status .. " | arquitetura: " .. model.topology .. " | cálculo e gates exatos permanecem no PoB."
	end)
	setClippedPopupLabel(controls.status, 720, 13)
	controls.featurePolicy = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 174, 720, 18 }, function()
		refreshOnArchive()
		return "^8Entradas da rede: " .. tostring(state.summary and state.summary.model.featurePolicy or "indisponível")
	end)
	setClippedPopupLabel(controls.featurePolicy, 720, 13)
	controls.leagueNotice = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 194, 720, 18 }, function()
		refreshOnArchive()
		local audit = state.summary and state.summary.patchSkillCatalog and state.summary.patchSkillCatalog.audit
		local excluded = audit and audit.excludedByReason or { }
		local mismatch = excluded.source_main_skill_mismatch or 0
		local qualityQuarantined = excluded.source_build_quality_quarantined or 0
		local qualityAuditInvalid = excluded.source_build_quality_audit_invalid or 0
		local eventAscendancy = excluded.event_secondary_ascendancy or 0
		local bloodlineNodes = excluded.event_bloodline_node_allocated or 0
		local treeDisagreements = audit and audit.claimTreeDisagreements or 0
		local claims = state.summary and state.summary.leagueClaims
		local rows = claims and claims.rows or { }
		local labels = { }
		for index = 1, math.min(3, #rows) do
			labels[#labels + 1] = tostring(rows[index].claim) .. " (" .. tostring(rows[index].uniqueBuildLineages) .. ")"
		end
		local claimText = #labels > 0 and table.concat(labels, ", ") or "nenhuma"
		controls.leagueNotice.tooltipText = "A versão válida vem de Tree.Spec no XML PoB, limitada às árvores 3.24–3.29. Claims de liga são metadados não verificados, não evidência de versão. "
			.. "A cobertura estrita exige que a skill declarada pela fonte corresponda à Main Skill nativa do PoB; ascendências alternativas/de evento e nós Bloodline ficam fora. "
			.. "Builds com auditoria de qualidade em quarentena permanecem arquivadas, mas não contam cobertura nem coocorrências; auditoria inválida também falha fechado. "
			.. "Claims de liga observadas: " .. claimText .. "."
		return string.format("^8Auditoria: skill≠Main %d | qualidade Q %d/erro %d | asc. evento %d | Bloodline %d | claim/árvore %d",
			mismatch, qualityQuarantined, qualityAuditInvalid, eventAscendancy, bloodlineNodes, treeDisagreements)
	end)
	setClippedPopupLabel(controls.leagueNotice, 720, 13)
	controls.coverageHeader = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 214, 345, 18 }, function()
		return "^7Menor cobertura de " .. tostring(state.patch or "—") .. " — por gema/variante"
	end)
	setClippedPopupLabel(controls.coverageHeader, 345, 13)
	controls.combinationHeader = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 385, 214, 355, 18 }, "^7Skills observadas juntas — hipótese, sem sinergia provada")
	setClippedPopupLabel(controls.combinationHeader, 355, 13)
	for index = 1, 14 do
		local rowIndex = index
		controls["coverage" .. index] = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 234 + (index - 1) * 18, 345, 16 }, function()
			refreshOnArchive()
			local skill = selectedPatchRow() and selectedPatchRow().skills[rowIndex]
			if not skill then return "" end
			return string.format("^8%s [%s] — %d/%d", tostring(skill.name or skill.variantId), skill.category,
				skill.uniqueBuilds, skill.sampleTarget)
		end)
		setClippedPopupLabel(controls["coverage" .. index], 345, 12)
	end
	for index = 1, 14 do
		local rowIndex = index
		controls["pair" .. index] = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 385, 234 + (index - 1) * 18, 355, 16 }, function()
			refreshOnArchive()
			local pair = state.summary and state.summary.observedPairs[rowIndex]
			if not pair then return "" end
			local identityNote = pair.exactVariantIdentity and "" or " (ID legado)"
			return string.format("^8%s: %s + %s — %d build(s); teste factorial pendente%s",
				tostring(pair.patch or "versão desconhecida"), tostring(pair.leftEffectName),
				tostring(pair.rightEffectName), pair.uniqueBuilds, identityNote)
		end)
		setClippedPopupLabel(controls["pair" .. index], 355, 12)
	end
	controls.method = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 500, 720, 34 }, function()
		refreshOnArchive()
		return state.summary and "^8" .. state.summary.combinationEvidence
			or "^8Coocorrência gera apenas uma fila de hipóteses. Treino depende de pares exatos, revisão e holdout por linhagem."
	end)
	setClippedPopupLabel(controls.method, 720, 12)
	controls.featureNote = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 540, 720, 30 },
		"^8XML original e perfil ficam locais em OptimizerStudies/Builds. Importar uma build não libera seus dados para treino; sem os gates, o ranker não ganha permissão para podar candidatos.")
	setClippedPopupLabel(controls.featureNote, 720, 12)
	controls.reviewSummary = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 574, 720, 30 }, function()
		refreshOnArchive()
		local summary = state.reviewSummary
		if not summary then return "^8Revisores A/B: caderno local ainda indisponível." end
		local counts = summary.counts
		return string.format("^7A/B: %d linhagens | %d fatos do snapshot | %d hipóteses | %d contestações/perguntas | %d ideias aguardam teste exato | MLP: 0 labels destas opiniões",
			summary.storage.reviewedLineages, counts.facts, counts.hypotheses, counts.critiquesAndQuestions, counts.pendingExactTests)
	end)
	setClippedPopupLabel(controls.reviewSummary, 720, 12)
	controls.openReview = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 20, 610, 210, 24 }, "Abrir caderno de ideias A/B", function()
		self:OpenBuildReviewDashboard(state.effectId)
	end)
	controls.openReview.tooltipText = "Fatos observados, hipóteses A/B, objeções, respostas e perguntas; ideias não são resultados PoB nem dados de treino."
	controls.openPublicHistory = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 635, 610, 105, 24 }, "Histórico A/B", function()
		self:OpenPublicBuildReviewHistory()
	end)
	controls.openPublicHistory.tooltipText = "Histórico completo e paginado das revisões Scout/Critic da ingestão pública, filtrável por patch, categoria e skill."
	controls.intakeStatus = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 250, 610, 380, 24 }, function()
		refreshOnArchive()
		return BuildIngestionStatus.Format(state.ingestionStatus)
	end)
	setClippedPopupLabel(controls.intakeStatus, 380, 12)
	controls.intakeStatus.tooltipText = "Estado local da extração, pedidos sequenciais, IDs processados e builds arquivadas/recusadas. Atualiza durante o lote; XML e códigos nunca são exibidos aqui."
	controls.latestResults = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 636, 720, 18 }, function()
		refreshOnArchive()
		local details = BuildIngestionStatus.FormatLatestResultsDetails(state.ingestionStatus)
		controls.latestResults.tooltipText = "Resultados nativos mais recentes (sem XML/código):\n" .. details
		return BuildIngestionStatus.FormatLatestResults(state.ingestionStatus)
	end)
	setClippedPopupLabel(controls.latestResults, 720, 12)
	controls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 642, 662, 90, 22 }, "Fechar", function()
		main:ClosePopup()
	end)
	main:OpenPopup(popupWidth, popupHeight, DisplayText.Native("AI Planner — Build archive e aprendizado"), controls, "close")
end

function OptimizerTabClass:OpenPublicBuildReviewHistory()
	local userPath = main and main.userPath
	local historyPath = type(userPath) == "string" and userPath ~= ""
		and (userPath .. "/OptimizerStudies/BuildIngestion/latest-results.jsonl") or ""
	local state = { patch = "", category = "", skill = "", page = 1, pageData = nil,
		filterData = nil, error = nil, signature = nil, lastPoll = 0, detailIndex = nil }
	local controls = { }
	local function patchOptions()
		return {
			{ patch = "", label = "Todos os patches" },
			{ patch = "3.24", label = "3.24" },
			{ patch = "3.25", label = "3.25" },
			{ patch = "3.26", label = "3.26" },
			{ patch = "3.27", label = "3.27" },
			{ patch = "3.28", label = "3.28" },
			{ patch = "3.29", label = "3.29" },
		}
	end
	local function categoryOptions()
		return {
			{ category = "", label = "Todas" },
			{ category = "normal", label = "Normal" },
			{ category = "transfigured", label = "Transfigurada" },
		}
	end
	local function skillOptions()
		local result = { { skill = "", label = "Todas as skills" } }
		local counts = { }
		for _, item in ipairs(state.filterData and state.filterData.skills or { }) do
			if item.skill and item.skill ~= "" then counts[item.skill] = (counts[item.skill] or 0) + item.count end
		end
		local names = { }
		for name in pairs(counts) do names[#names + 1] = name end
		table.sort(names)
		for _, name in ipairs(names) do
			result[#result + 1] = { skill = name, label = string.format("%s — %d revisão(ões)", name, counts[name]) }
		end
		return result
	end
	local function reload(force)
		local filters, filterError = BuildIngestionStatus.ReadPairedReviewFilters(historyPath, state.patch, state.category)
		state.filterData, state.error = filters, filterError
		if filters then
			state.signature = filters.signature
			local skillFound = state.skill == ""
			for _, option in ipairs(skillOptions()) do
				if option.skill == state.skill then skillFound = true; break end
			end
			if not skillFound then state.skill = "" end
			if controls.skill then
				controls.skill:SetList(skillOptions())
				controls.skill:SelByValue(state.skill, "skill")
			end
			local pageData, pageError = BuildIngestionStatus.ReadPairedReviewPage(historyPath,
				state.patch, state.category, state.skill, state.page, 8)
			state.pageData, state.error = pageData, pageError
			if pageData then state.page = pageData.page end
		end
		if controls.patch then controls.patch:SelByValue(state.patch, "patch") end
		if controls.category then controls.category:SelByValue(state.category, "category") end
		if controls.previous then controls.previous.enabled = function() return state.pageData ~= nil and state.pageData.page > 1 end end
		if controls.next then controls.next.enabled = function() return state.pageData ~= nil and state.pageData.page < state.pageData.pageCount end end
		if controls.detailSelect then
			controls.detailSelect.enabled = function() return state.pageData ~= nil and state.pageData.items[state.detailIndex or 0] ~= nil end
		end
	end
	local function refreshIfChanged()
		local now = os.clock()
		if now - state.lastPoll < 1 then return end
		state.lastPoll = now
		local filters = BuildIngestionStatus.ReadPairedReviewFilters(historyPath, state.patch, state.category)
		if filters and filters.signature ~= state.signature then
			state.page = 1
			reload(true)
		elseif not filters and state.error == nil then
			state.error = "history_unavailable"
		end
	end
	local function openDetail(index)
		local item = state.pageData and state.pageData.items[index]
		if not item then return end
		local details = BuildIngestionStatus.FormatPairedReviewDetails(item)
		local popupControls = { }
		popupControls.title = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 12, 780, 30 },
			"^7Revisão Scout/Critic — " .. tostring(item.skill or item.id))
		setClippedPopupLabel(popupControls.title, 780, 15)
		popupControls.details = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 52, 780, 530 }, function()
			return "^8" .. details
		end)
		setClippedPopupLabel(popupControls.details, 780, 13)
		popupControls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 710, 602, 90, 22 }, "Fechar", function()
			main:ClosePopup()
		end)
		main:OpenPopup(820, 636, DisplayText.Native("AI Planner — revisão pública detalhada"), popupControls, "close")
	end
	local function selectPage(page)
		state.page = page
		reload(true)
	end
	reload(true)
	local popupWidth, popupHeight = 840, 700
	controls.title = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 12, 800, 24 }, "^7Histórico público — revisão independente Scout/Critic")
	setClippedPopupLabel(controls.title, 800, 16)
	controls.live = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 40, 800, 26 }, function()
		refreshIfChanged()
		if state.error then
			local labels = {
				history_unavailable = "histórico de revisões não encontrado",
				history_too_large = "histórico excede o limite seguro de 256 MiB",
				history_row_limit = "histórico excede 100.000 revisões; nenhuma página parcial será apresentada",
				invalid_path = "caminho local indisponível",
			}
			return "^1Histórico indisponível: " .. tostring(labels[state.error] or state.error)
		end
		local total = state.filterData and state.filterData.pairedReviewCount or 0
		return string.format("^8%u revisões A/B no arquivo | %u nesta seleção | atualização automática por mudança no histórico | opiniões continuam fora do treino",
			total, state.pageData and state.pageData.total or 0)
	end)
	setClippedPopupLabel(controls.live, 800, 12)
	controls.patch = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 20, 76, 135, 22 }, patchOptions(), function(_, selected)
		if selected and selected.patch ~= nil then state.patch, state.skill, state.page = selected.patch, "", 1; reload(true) end
	end, "Patch vem da árvore nativa registrada na ingestão; claims de liga não substituem essa evidência.")
	controls.category = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 165, 76, 130, 22 }, categoryOptions(), function(_, selected)
		if selected and selected.category ~= nil then state.category, state.skill, state.page = selected.category, "", 1; reload(true) end
	end, "Normal e transfigurada são categorias distintas; Support-granted e Vaal não se tornam alvos Main.")
	controls.skill = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 305, 76, 355, 22 }, skillOptions(), function(_, selected)
		if selected and selected.skill ~= nil then state.skill, state.page = selected.skill, 1; reload(true) end
	end, "Lista skills com revisão pareada no histórico; variantes permanecem distinguíveis pelo nome serializado.")
	controls.skill.enableDroppedWidth = true
	controls.refresh = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 670, 76, 85, 22 }, "Atualizar", function()
		state.page = 1
		reload(true)
	end)
	controls.previous = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 762, 76, 70, 22 }, "Anterior", function()
		if state.pageData and state.pageData.page > 1 then selectPage(state.pageData.page - 1) end
	end)
	controls.next = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 762, 600, 70, 22 }, "Próxima", function()
		if state.pageData and state.pageData.page < state.pageData.pageCount then selectPage(state.pageData.page + 1) end
	end)
	controls.page = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 108, 730, 20 }, function()
		refreshIfChanged()
		local data = state.pageData
		return data and string.format("^7Página %d/%d | %d revisões nesta seleção | entradas mais recentes primeiro", data.page, data.pageCount, data.total)
			or "^8Aguardando histórico pareado."
	end)
	setClippedPopupLabel(controls.page, 730, 13)
	for index = 1, 8 do
		local rowIndex = index
		controls["history" .. index] = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 138 + (index - 1) * 56, 690, 52 }, function()
			refreshIfChanged()
			local row = state.pageData and state.pageData.items[rowIndex]
			return row and BuildIngestionStatus.FormatPairedReviewListRow(row) or ""
		end)
		setClippedPopupLabel(controls["history" .. index], 690, 12)
		controls["detail" .. index] = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 720, 148 + (index - 1) * 56, 90, 24 }, "Detalhes", function()
			openDetail(rowIndex)
		end)
		controls["detail" .. index].enabled = function()
			return state.pageData ~= nil and state.pageData.items[rowIndex] ~= nil
		end
	end
	controls.previousBottom = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 20, 600, 80, 22 }, "Página anterior", function()
		if state.pageData and state.pageData.page > 1 then selectPage(state.pageData.page - 1) end
	end)
	controls.pageBottom = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 112, 600, 250, 22 }, function()
		local data = state.pageData
		return data and string.format("^8Página %d de %d", data.page, data.pageCount) or ""
	end)
	setClippedPopupLabel(controls.pageBottom, 250, 12)
	controls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 730, 662, 100, 22 }, "Fechar", function()
		main:ClosePopup()
	end)
	main:OpenPopup(popupWidth, popupHeight, DisplayText.Native("AI Planner — histórico de revisões públicas"), controls, "close")
end

function OptimizerTabClass:OpenBuildReviewDashboard(initialEffectId)
	local userPath = main and main.userPath
	local state = { section = "ideas", effectId = initialEffectId or "", page = 1, pageData = nil,
		exploreData = nil, exploreCatalog = nil, exploreCursors = { },
		detailIndex = 1,
		summary = nil, archiveSummary = nil, error = nil, sourceStamp = nil, lastPoll = 0 }
	local controls = { }
	local function numberOrZero(value) return tonumber(value) or 0 end
	local function effectOptions()
		local options = { { effectId = "", label = "Todas as skills e variantes" } }
		local seen = { [""] = true }
		for _, effect in ipairs(state.archiveSummary and state.archiveSummary.effects or { }) do
			if type(effect.effectId) == "string" and not seen[effect.effectId] then
				seen[effect.effectId] = true
				options[#options + 1] = { effectId = effect.effectId,
					label = string.format("%s — %d build(s)", tostring(effect.effectName or effect.effectId), effect.uniqueBuilds) }
			end
		end
		for _, effect in ipairs(state.exploreCatalog and state.exploreCatalog.effects or { }) do
			if type(effect.effectId) == "string" and not seen[effect.effectId] then
				seen[effect.effectId] = true
				local suffix = tostring(effect.variantId or "") ~= "" and (" [" .. tostring(effect.variantId) .. "]") or ""
				options[#options + 1] = { effectId = effect.effectId,
					label = tostring(effect.effectName or effect.name or effect.effectId) .. suffix .. " — catálogo PoB atual" }
			end
		end
		return options
	end
	local function detailOptions()
		local options = { }
		for index, item in ipairs(state.pageData and state.pageData.items or { }) do
			options[#options + 1] = { index = index, label = string.format("%d. %s", index, tostring(item.title or item.id or item.category)) }
		end
		if #options == 0 then options[1] = { index = 1, label = "Sem registros nesta página" } end
		return options
	end
	local function selectedDetailItem()
		return state.pageData and state.pageData.items and state.pageData.items[state.detailIndex]
	end
	local function openDetail(item)
		if not item then return end
		local controls, detailLines = { }, { }
		detailLines[#detailLines + 1] = "Papel: " .. tostring(item.role or "não identificado")
		detailLines[#detailLines + 1] = "Estado: " .. tostring(item.status or "não verificado")
		if item.effectA then detailLines[#detailLines + 1] = "Skill A: " .. tostring(item.effectA.name or item.effectA.effectId)
			.. " [" .. tostring(item.effectA.effectId or "") .. "]" end
		if item.effectB then detailLines[#detailLines + 1] = "Skill B: " .. tostring(item.effectB.name or item.effectB.effectId)
			.. " [" .. tostring(item.effectB.effectId or "") .. "]" end
		if item.lineageSha256 then detailLines[#detailLines + 1] = "Linhagem: " .. tostring(item.lineageSha256) end
		if item.archiveObservationId then detailLines[#detailLines + 1] = "Observação: " .. tostring(item.archiveObservationId)
			.. " | XML SHA-256: " .. tostring(item.xmlSha256 or "não informado") end
		if item.requiredTest then
			local test = type(item.requiredTest) == "table" and item.requiredTest.type or item.requiredTest
			detailLines[#detailLines + 1] = "Teste necessário: " .. tostring(test) .. " — ideias não são resultado exacto nem label de treino."
		end
		detailLines[#detailLines + 1] = ""
		detailLines[#detailLines + 1] = tostring(item.detail or "Sem detalhe textual guardado.")
		controls.title = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 12, 780, 34 },
			"^7" .. tostring(item.title or item.category or "Detalhe da hipótese"))
		setClippedPopupLabel(controls.title, 780, 15)
		controls.detail = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 54, 780, 530 }, function()
			return "^8" .. table.concat(detailLines, "\n")
		end)
		setClippedPopupLabel(controls.detail, 780, 13)
		controls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 702, 598, 98, 22 }, "Fechar", function() main:ClosePopup() end)
		main:OpenPopup(820, 636, DisplayText.Native("AI Planner — detalhe A/B"), controls, "close")
	end
	local function sourceStamp()
		local stamp = "no-user-path"
		if type(userPath) == "string" and userPath ~= "" then
			local root = userPath .. "/OptimizerStudies/"
			local function fileSize(path)
				local file = io.open(path, "rb")
				if not file then return "missing" end
				local size = file:seek("end") or 0
				file:close()
				return tostring(size)
			end
			stamp = fileSize(root .. "Builds/builds.jsonl") .. ":" .. fileSize(root .. "BuildReviews/reviews.jsonl")
		end
		if state.section == "explore" then
			local ok, signature = pcall(Candidate.BuildSignature, self.build)
			stamp = stamp .. ":" .. (ok and tostring(signature or "unavailable") or "unavailable")
		end
		return stamp
	end
	local function reload()
		state.archiveSummary = StudyBuilds.Summary(userPath, self.build)
		state.summary = BuildReviewPair.Summary(userPath)
		state.exploreCatalog = SkillCatalog.ListAllActiveEffects(self.build, "")
		if state.section == "explore" then
			local profile, profileError = StudyBuilds.ProfileFromBuild(self.build)
			if not profile then
				state.pageData, state.exploreData, state.error = nil, nil, profileError
			else
				if not state.effectId or state.effectId == "" then
					for _, group in ipairs(profile.skillGroups or { }) do
						for _, skill in ipairs(group.skills or { }) do
							if skill.selectedMainSkill == true then
								for _, effect in ipairs(skill.effects or { }) do
									if effect.selected == true then state.effectId = effect.effectId; break end
								end
							end
							if state.effectId and state.effectId ~= "" then break end
						end
						if state.effectId and state.effectId ~= "" then break end
					end
				end
				local cursorState = state.exploreCursors[state.page] or { }
				state.exploreData, state.error = BuildReviewPair.ExploreSkillPage(profile, state.exploreCatalog,
					state.archiveSummary and state.archiveSummary.observedPairs or { }, state.effectId,
					cursorState, 4)
				if state.exploreData then
					state.exploreCursors[state.page] = cursorState
					if state.exploreData.pages.hasMore then state.exploreCursors[state.page + 1] = state.exploreData.nextCursors end
					local counts = state.exploreData.counts
					local pageCount = math.max(1,
						math.ceil((tonumber(counts.scoutCandidates) or 0) / 4),
						math.ceil((tonumber(counts.criticCandidates) or 0) / 4))
					state.pageData = { items = state.exploreData.items, total = (tonumber(counts.scoutCandidates) or 0)
						+ (tonumber(counts.criticCandidates) or 0), page = state.page, pageCount = pageCount,
						hasMore = state.exploreData.pages.hasMore == true }
				else
					state.pageData = nil
				end
			end
		else
			state.pageData, state.error = BuildReviewPair.ListPage(userPath, state.section, state.effectId, state.page, 8)
			state.exploreData = nil
		end
		if state.pageData then
			state.page = math.min(state.page, state.pageData.pageCount)
			state.detailIndex = math.min(math.max(1, state.detailIndex), math.max(1, #(state.pageData.items or { })))
		else
			state.detailIndex = 1
		end
		state.sourceStamp = sourceStamp()
		if controls.effect then
			controls.effect:SetList(effectOptions())
			controls.effect:SelByValue(state.effectId, "effectId")
		end
		if controls.detailSelect then
			controls.detailSelect:SetList(detailOptions())
			controls.detailSelect:SelByValue(state.detailIndex, "index")
			controls.detailButton.enabled = function() return selectedDetailItem() ~= nil end
		end
	end
	local function refreshIfArchiveChanges()
		local now = os.clock()
		if now - state.lastPoll < 1 then return end
		state.lastPoll = now
		if state.sourceStamp ~= sourceStamp() then
			if state.section == "explore" then state.page, state.exploreCursors = 1, { } end
			reload()
		end
	end
	local function loadSection(section)
		state.section, state.page, state.detailIndex = section, 1, 1
		if section == "explore" then state.exploreCursors = { } end
		reload()
	end
	reload()
	local popupWidth, popupHeight = 820, 700
	controls.title = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 12, 780, 24 }, "^7Caderno de aprendizagem — dois revisores locais")
	setClippedPopupLabel(controls.title, 780, 16)
	controls.runtime = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 40, 780, 34 }, function()
		refreshIfArchiveChanges()
		local summary = state.summary
		if not summary then return "^1Caderno indisponível: " .. tostring(state.error or "erro desconhecido") end
		local archive = state.archiveSummary
		local storage = archive and archive.storage or { }
		local catalog = archive and archive.catalog or { }
		local model = archive and archive.model or { }
		return string.format("^8Arquivo: %d builds | %d skills rastreadas | %d/%d na meta inicial de %d builds.\nA/B: %d revisadas | factorial PoB: %d testados, %d pendentes | MLP: %s, labels A/B: %d; topologia alterada: %s.",
			tonumber(storage.uniqueBuildLineages) or 0, tonumber(catalog.trackedEffectCount) or 0,
			tonumber(catalog.effectsAtTarget) or 0, tonumber(catalog.trackedEffectCount) or 0,
			tonumber(catalog.targetBuildsPerEffect) or 10, tonumber(summary.storage.reviewedLineages) or 0,
			tonumber(summary.counts.exactTests) or 0, tonumber(summary.counts.pendingExactTests) or 0,
			model.enabled and "ativo" or "desativado", tonumber(summary.model.trainingCount) or 0,
			summary.model.topologyChanged and "sim" or "não")
	end)
	setClippedPopupLabel(controls.runtime, 780, 12)
	controls.effect = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 20, 82, 420, 22 }, effectOptions(), function(_, selected)
		if selected and selected.effectId ~= nil then
			state.effectId, state.page, state.exploreCursors, state.detailIndex = selected.effectId, 1, { }, 1
			reload()
		end
	end, "Filtra fatos ou hipóteses que citam esta skill como âncora ou candidata.")
	controls.effect.enableDroppedWidth = true
	controls.effect:SelByValue(state.effectId, "effectId")
	controls.facts = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 450, 82, 74, 22 }, "Fatos", function() loadSection("facts") end)
	controls.ideas = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 530, 82, 110, 22 }, "Arquivo A/B", function() loadSection("ideas") end)
	controls.explore = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 646, 82, 86, 22 }, "Explorar", function() loadSection("explore") end)
	controls.refresh = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 738, 82, 62, 22 }, "Atualizar", reload)
	controls.counts = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 112, 780, 28 }, function()
		refreshIfArchiveChanges()
		local data, summary = state.pageData, state.summary
		if not data then return "^1" .. tostring(state.error or "Caderno indisponível") end
		if state.section == "facts" then
			return string.format("^7Fatos observados do snapshot: %d | página %d/%d | registros inválidos: %d",
				data.total, data.page, data.pageCount, data.brokenReports)
		end
		if state.section == "explore" then
			local counts = state.exploreData and state.exploreData.counts or { }
			return string.format("^7Skill âncora: %s | Scout: %d candidatas (%d nesta página) | Critic: %d candidatas (%d nesta página).\n%d contestações/perguntas | %d respostas | página %d/%d | mais ideias: %s",
				state.exploreData and tostring(state.exploreData.anchor.name or state.exploreData.anchor.effectId) or tostring(state.effectId or "não selecionada"),
				numberOrZero(counts.scoutCandidates), numberOrZero(counts.scoutShown), numberOrZero(counts.criticCandidates), numberOrZero(counts.criticShown),
				numberOrZero(counts.critiques) + numberOrZero(counts.questions), numberOrZero(counts.responses), data.page, data.pageCount,
				data.hasMore and "sim" or "não")
		end
		return string.format("^7A: %d/%d propostas debatidas (%d fora da amostra atual) | B: %d ideias de %d candidatas (%d fora da amostra atual).\n%d contestações/perguntas | %d respostas | página %d/%d | registros com teste exato: %d | hipóteses por testar: %d",
			summary and summary.counts.scoutProposed or 0,
			summary and summary.counts.scoutCandidates or 0,
			summary and summary.counts.scoutUnreviewedCandidates or 0,
			summary and summary.counts.criticIndependentIdeas or 0,
			summary and summary.counts.criticCandidates or 0,
			summary and summary.counts.criticUnreviewedCandidates or 0,
			summary and summary.counts.critiquesAndQuestions or 0,
			summary and summary.counts.responses or 0, data.page, data.pageCount,
			summary and summary.counts.exactTests or 0,
			summary and summary.counts.pendingExactTests or 0)
	end)
	setClippedPopupLabel(controls.counts, 780, 12)
	for index = 1, 9 do
		local rowIndex = index
		controls["review" .. index] = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 146 + (index - 1) * 50, 780, 46 }, function()
			local item = state.pageData and state.pageData.items[rowIndex]
			if not item then return "" end
			local lineage = type(item.lineageSha256) == "string" and item.lineageSha256:sub(1, 12) or "sem linhagem"
			local first = string.format("^7%s ^8[%s | %s | %s | %s]  linhagem %s",
				tostring(item.title or item.category), tostring(item.role), tostring(item.status), tostring(item.category), tostring(item.id), lineage)
			local source = item.archiveObservationId and string.format(" | snapshot %s / XML %s",
				tostring(item.archiveObservationId):sub(1, 12), tostring(item.xmlSha256 or ""):sub(1, 12)) or ""
			local second = "^8" .. tostring(item.detail or "") .. source
			return first .. "\n" .. second
		end)
		setClippedPopupLabel(controls["review" .. index], 780, 12)
	end
	controls.testNotice = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 604, 780, 34 }, function()
		if state.section == "facts" then
			return "^8‘Observado’ significa presente no snapshot PoB arquivado. Não prova desempenho geral nem qualidade causal."
		end
		if state.section == "explore" then
			local data = state.exploreData
			return "^8Pares skill×skill da âncora no catálogo PoB atual e contexto da build aberta. A propõe; B propõe, contesta e pergunta; A responde. Use Detalhe para ler tudo. Tags não provam sinergia. Sem cálculo factorial, treino ou persistência."
				.. (data and (" Catálogo: " .. tostring(data.catalog.dataVersion or "versão desconhecida") .. "; árvore: " .. tostring(data.catalog.treeVersion or "desconhecida") .. ".") or "")
		end
		return "^8O arquivo mostra as revisões e a amostra materializada quando cada build foi importada. Use ‘Explorar’ para percorrer sob demanda toda a fronteira de combinações do catálogo PoB atual. Ideias arquivadas continuam hipóteses; só um teste exacto factorial pode verificar uma interação. Opiniões não alteram a MLP."
	end)
	setClippedPopupLabel(controls.testNotice, 780, 12)
	controls.previous = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 20, 650, 96, 22 }, "Anterior", function()
		if state.page > 1 then state.page = state.page - 1; state.detailIndex = 1; reload() end
	end)
	controls.page = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 124, 650, 200, 22 }, function()
		local data = state.pageData
		return data and string.format("^7Página %d/%d", data.page, data.pageCount) or ""
	end)
	controls.next = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 332, 650, 96, 22 }, "Próxima", function()
		if state.pageData and state.page < state.pageData.pageCount
			and (state.section ~= "explore" or state.pageData.hasMore) then state.page = state.page + 1; state.detailIndex = 1; reload() end
	end)
	controls.detailSelect = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 436, 650, 172, 22 }, detailOptions(), function(_, selected)
		if selected and selected.index then state.detailIndex = selected.index end
	end, "Selecione uma hipótese para ler a discussão completa, identidade e teste necessário.")
	controls.detailSelect.enableDroppedWidth = true
	controls.detailSelect:SelByValue(state.detailIndex, "index")
	controls.detailButton = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 612, 650, 86, 22 }, "Detalhe", function()
		openDetail(selectedDetailItem())
	end)
	controls.detailButton.enabled = function() return selectedDetailItem() ~= nil end
	controls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 702, 650, 98, 22 }, "Fechar", function() main:ClosePopup() end)
	main:OpenPopup(popupWidth, popupHeight, DisplayText.Native("AI Planner — Caderno A/B e hipóteses"), controls, "close")
end

function OptimizerTabClass:UpdateRoutePlannerModelDropdown()
	local control = self.routePlannerModelControl
	if not control then return end
	local catalog = self.routePlannerModelCatalog or { models = { }, status = "unavailable" }
	local selected = tostring(self.textValues.routePlannerModelPackageId or "")
	local choices = { { val = "", label = "PoB nativo (sem GNN)" } }
	local found = selected == ""
	for _, model in ipairs(catalog.models or { }) do
		choices[#choices + 1] = { val = model.packageId, label = "GNN aprovado — " .. model.packageId }
		if model.packageId == selected then found = true end
	end
	if selected ~= "" and not found and catalog.status == "loading" then
		choices[#choices + 1] = { val = selected, label = "Verificando GNN — " .. selected }
	end
	if selected ~= "" and not found and catalog.status ~= "loading" then
		selected = ""
		self.textValues.routePlannerModelPackageId = ""
		self.textValues.routePlannerModelMode = "deterministic_fallback"
	end
	control:SetList(nativeChoiceLabels(choices))
	control:SelByValue(selected, "val")
end

function OptimizerTabClass:RefreshRoutePlannerModelCatalog(force)
	local skill, _, context = RoutePlanner.GetMainSkill(self.build, false, true)
	if not skill and context and context.socketRepair then skill = context.skill end
	local skillIdentity = skill and { effectId = skill.effectId, gemId = skill.gemId } or nil
	local scenarioProfile = tostring(self.textValues.routePlannerScenario or "Current")
	local enemyPreset = scenarioProfile == "Current" and tostring(self.textValues.scenarioEnemyPreset or "Active") or "Pinnacle"
	local scenario = { profile = scenarioProfile, enemyPreset = enemyPreset }
	local engineSnapshot = Version.Snapshot(self.build)
	local engine = { }
	for _, key in ipairs({ "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }) do
		local value = engineSnapshot and engineSnapshot[key]
		if value == nil or tostring(value) == "" then
			self.routePlannerModelCatalog = { status = "incompatible", models = { }, error = "Fingerprint PoB incompleto: " .. key }
			self:UpdateRoutePlannerModelDropdown()
			return false
		end
		engine[key] = tostring(value)
	end
	if not skillIdentity then
		self.routePlannerModelCatalog = { status = "incompatible", models = { }, error = "Main Skill indisponível" }
		self:UpdateRoutePlannerModelDropdown()
		return false
	end
	local keyParts = { }
	for _, name in ipairs({ "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }) do
		keyParts[#keyParts + 1] = engine[name]
	end
	keyParts[#keyParts + 1] = skillIdentity.effectId
	keyParts[#keyParts + 1] = skillIdentity.gemId
	keyParts[#keyParts + 1] = scenario.profile
	keyParts[#keyParts + 1] = scenario.enemyPreset
	local catalogKey = table.concat(keyParts, "\31")
	local previous = self.routePlannerModelCatalog
	if not force and previous and previous.key == catalogKey and previous.status == "ready" then return true end
	if previous and previous.key == catalogKey and previous.status == "loading" then return true end
	for _, oldJob in ipairs(self.routePlannerModelCatalogJobs or { }) do
		if oldJob.key ~= catalogKey then oldJob.cancelled = true end
	end
	local catalog = {
		key = catalogKey,
		status = "loading",
		models = previous and previous.key == catalogKey and previous.models or { },
	}
	self.routePlannerModelCatalog = catalog
	self:UpdateRoutePlannerModelDropdown()
	self.routePlannerModelCatalogJobs = self.routePlannerModelCatalogJobs or { }
	local job = { key = catalogKey, progress = { phase = "Local model catalog", processed = 0, total = 1 } }
	self.routePlannerModelCatalogJob = job
	job.co = coroutine.create(function()
		local client, connectError = GNNIPC.Connect()
		if not client then return { status = "unavailable", error = tostring(connectError or "daemon_not_running"), models = { } } end
		local response, callError = client:Call("build_planner/list_models", {
			engine = engine,
			skill = skillIdentity,
			scenario = scenario,
		}, job, job, 5)
		client:Close()
		if not response then return { status = "unavailable", error = tostring(callError or "model_catalog_query_failed"), models = { } } end
		if type(response.models) ~= "table" then
			return { status = "unavailable", error = "Resposta do catálogo de modelos inválida", models = { } }
		end
		local models = { }
		for _, model in ipairs(response.models) do
			local packageId = type(model) == "table" and model.packageId
			local modelSkill = type(model) == "table" and model.skill or nil
			local modelScenario = type(model) == "table" and model.scenario or nil
			local modelEngine = type(model) == "table" and model.engine or nil
			local compatible = type(packageId) == "string" and #packageId <= 128
				and packageId:match("^[%w_.%-]+$") ~= nil
				and model.modelType == "hetero-gatv2-ensemble-v1"
				and type(modelSkill) == "table" and modelSkill.effectId == skillIdentity.effectId
				and modelSkill.gemId == skillIdentity.gemId
				and type(modelScenario) == "table" and modelScenario.profile == scenario.profile
				and modelScenario.enemyPreset == scenario.enemyPreset
				and type(modelEngine) == "table"
			for _, name in ipairs({ "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }) do
				if type(modelEngine) ~= "table" or tostring(modelEngine[name] or "") ~= engine[name] then compatible = false end
			end
			if compatible and #models < 128 then models[#models + 1] = { packageId = packageId } end
		end
		table.sort(models, function(left, right) return left.packageId < right.packageId end)
		return { status = "ready", models = models }
	end)
	table.insert(self.routePlannerModelCatalogJobs, job)
	return true
end

local function routePlannerSeedCatalogKey(userPath, engine)
	return table.concat({ tostring(userPath or ""), tostring(engine.dataVersion or ""),
		tostring(engine.treeVersion or "") }, "\31")
end

function OptimizerTabClass:RefreshRoutePlannerSeedCatalog(force)
	local snapshot = Version.Snapshot(self.build)
	local engine = {
		dataVersion = snapshot and tostring(snapshot.dataVersion or "") or "",
		treeVersion = snapshot and tostring(snapshot.treeVersion or "") or "",
	}
	if engine.dataVersion == "" or engine.treeVersion == "" then
		self.routePlannerSeedCatalog = { status = "unavailable", seeds = { }, error = "Fingerprint da árvore/patch atual indisponível" }
		return false
	end
	local userPath = main and main.userPath
	local key = routePlannerSeedCatalogKey(userPath, engine)
	local previous = self.routePlannerSeedCatalog
	if not force and previous and previous.key == key and previous.status == "ready" then return true end
	self.routePlannerSeedCatalogJobs = self.routePlannerSeedCatalogJobs or { }
	for _, oldJob in ipairs(self.routePlannerSeedCatalogJobs) do
		if oldJob.key == key and coroutine.status(oldJob.co) ~= "dead" then return true end
		if oldJob.key ~= key then oldJob.cancelled = true end
	end
	self.routePlannerSeedCatalog = { key = key, status = "loading", seeds = { }, error = nil }
	local job = { key = key, progress = { processed = 0 } }
	job.co = coroutine.create(function()
		local seeds, summary = StudyBuilds.ListArchivedSeeds(userPath, {
			dataVersion = engine.dataVersion,
			treeVersion = engine.treeVersion,
			maxResults = 1000,
		}, function(processed)
			coroutine.yield({ processed = processed })
		end)
		if not seeds then return { status = "unavailable", seeds = { }, error = tostring(summary or "Arquivo de builds indisponível") } end
		return { status = "ready", seeds = seeds, summary = summary }
	end)
	self.routePlannerSeedCatalogJob = job
	table.insert(self.routePlannerSeedCatalogJobs, job)
	return true
end

function OptimizerTabClass:OpenArchivedSeedPicker()
	self:RefreshRoutePlannerSeedCatalog(false)
	local popupWidth, popupHeight = 850, 260
	local state = { search = "", selectedHash = tostring(self.textValues.routePlannerSeedXmlSha256 or "") }
	local controls = { }
	local function getFilteredSeeds()
		local catalog = self.routePlannerSeedCatalog or { seeds = { } }
		local search = tostring(state.search or ""):lower()
		local matches = { }
		for _, seed in ipairs(catalog.seeds or { }) do
			local haystack = table.concat({ seed.patch or "", seed.skill and seed.skill.name or "",
				seed.class or "", seed.ascendancy or "", seed.label or "" }, " "):lower()
			if search == "" or haystack:find(search, 1, true) then matches[#matches + 1] = seed end
		end
		return matches
	end
	local function findSelectedSeed()
		for _, seed in ipairs(self.routePlannerSeedCatalog and self.routePlannerSeedCatalog.seeds or { }) do
			if seed.xmlSha256 == state.selectedHash then return seed end
		end
	end
	local function updateSeedList()
		local catalog = self.routePlannerSeedCatalog or { status = "loading", seeds = { } }
		local choices = { }
		if catalog.status == "loading" then
			choices[1] = { val = "", label = "Lendo arquivo de builds do Drive…" }
		elseif catalog.status ~= "ready" then
			choices[1] = { val = "", label = "Arquivo de builds indisponível" }
		else
			local rows = getFilteredSeeds()
			if #rows == 0 then
				choices[1] = { val = "", label = "Nenhuma build compatível com esse filtro" }
			else
				for _, seed in ipairs(rows) do
					local levelText = seed.level and ("Nv. " .. tostring(seed.level)) or "nível não informado"
					local display = string.format("[%s] %s — %s, %s | %s | %s",
						tostring(seed.patch), tostring(seed.skill and seed.skill.name or "Skill desconhecida"),
						tostring(seed.ascendancy), levelText, tostring(seed.label), seed.xmlSha256:sub(1, 8))
					choices[#choices + 1] = { val = seed.xmlSha256, label = sanitizeDetailText(display) }
				end
			end
		end
		if controls.seed then
			controls.seed:SetList(nativeChoiceLabels(choices))
			local found = false
			for _, seed in ipairs(getFilteredSeeds()) do if seed.xmlSha256 == state.selectedHash then found = true break end end
			if not found then state.selectedHash = "" end
			controls.seed:SelByValue(state.selectedHash, "val")
		end
	end
	local function selectedSummary()
		local catalog = self.routePlannerSeedCatalog or { status = "loading" }
		if catalog.status == "loading" then return "Indexando as sementes em segundo plano; a janela permanece utilizável." end
		if catalog.status ~= "ready" then
			return "Arquivo indisponível: " .. tostring(catalog.error or "configure a fonte de builds do Planner")
		end
		local seed = findSelectedSeed()
		if not seed then
			return string.format("%d build(s)-semente da versão %s. Importadas pelo PoB; direitos de uso não verificados; não são rótulos de treino.",
				#(catalog.seeds or { }), tostring(Version.Data(self.build)))
		end
		return string.format("Selecionada: %s | patch %s | %s | %s. Direitos não verificados; uso como semente local, sem treino.",
			tostring(seed.skill and seed.skill.name or "Skill desconhecida"), tostring(seed.patch),
			tostring(seed.ascendancy), tostring(seed.label))
	end
	local function setLabel(key, text, x, y, width, height, size, dynamic)
		controls[key] = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { x, y, width, height }, dynamic or DisplayText.Native(text))
		setClippedPopupLabel(controls[key], width, size or 12)
		return controls[key]
	end
	setLabel("intro", "Builds-semente recolhidas — filtre por skill, patch, classe, ascendência ou origem:", 24, 18, 802, 18, 13)
	controls.search = new("EditControl"):EditControl(popupTopLeftAnchor(), { 24, 44, 270, 22 }, "", "Buscar", "%c", 100, function(buf)
		state.search = tostring(buf or "")
		updateSeedList()
	end, nil, nil, true)
	controls.search:SetPlaceholder("ex.: Cyclone, 3.29, Slayer")
	controls.seed = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 306, 44, 520, 22 },
		nativeChoiceLabels({ { val = "", label = "Carregando catálogo…" } }), function(_, selected)
		state.selectedHash = tostring(type(selected) == "table" and selected.val or "")
		self.textValues.routePlannerSeedXmlSha256 = state.selectedHash
		self.modFlag = true
		updateSeedList()
	end, "São XMLs arquivados para usar como build inicial, não pacotes GNN treinados.")
	controls.seed.enableDroppedWidth = true
	controls.summary = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 78, 802, 44 }, function()
		return DisplayText.Native(selectedSummary())
	end)
	setClippedPopupLabel(controls.summary, 802, 12)
	controls.summary.tooltipText = "Todos os itens da lista são builds-semente arquivadas. A origem/direitos continuam não verificados e nenhuma delas entra no treino automaticamente. O XML selecionado ainda é validado pelo importador e pelo calculador nativo do PoB."
	controls.openSeed = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 24, 138, 224, 24 },
		DisplayText.Native("Abrir como build nova"), function()
		local hash = state.selectedHash
		if hash == "" then return end
		local engine = Version.Snapshot(self.build) or { }
		local seed, seedError = StudyBuilds.ReadArchivedSeed(main and main.userPath, hash, {
			dataVersion = tostring(engine.dataVersion or ""),
			treeVersion = tostring(engine.treeVersion or ""),
		})
		if not seed then
			main:OpenMessagePopup("Build-semente indisponível", tostring(seedError or "O XML não passou pela verificação do arquivo."))
			return
		end
		local name = string.format("[%s] %s — %s", seed.patch, seed.skill.name, seed.ascendancy)
		main:ClosePopup()
		self.routePlannerSeedPickerUpdater = nil
		main:OpenConfirmPopup("Abrir build-semente", DisplayText.Native(
			"Abrir " .. name .. " como build nova? A build atual não será usada como base desta sessão depois da troca. "
			.. "O PoB validará e calculará o XML nativamente. A origem e os direitos da build arquivada não estão verificados; ela será usada apenas como semente local, nunca como rótulo de treino. A busca não começa automaticamente."),
			"Abrir", function()
			local importTab = self.build and self.build.importTab
			local imported, importError = importTab and importTab:ImportArchivedSeed(seed.xmlText, name)
			if not imported then
				main:OpenMessagePopup("Build-semente não aberta", tostring(importError or "O importador nativo do PoB não confirmou a build."))
			end
		end)
	end)
	controls.openSeed.enabled = function() return state.selectedHash ~= "" and (self.routePlannerSeedCatalog or { }).status == "ready" end
	controls.openSeed.tooltipText = "Substitui a build aberta nesta janela apenas depois da confirmação e da validação XML/PoB. O arquivo arquivado não é alterado; nenhuma rota é aplicada e nenhuma busca começa sozinha."
	controls.refresh = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 258, 138, 104, 24 },
		DisplayText.Native("Atualizar lista"), function()
		self:RefreshRoutePlannerSeedCatalog(true)
		updateSeedList()
	end)
	controls.refresh.tooltipText = "Relê o índice somente de leitura no Drive e valida os hashes do XML selecionado antes da importação."
	controls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 722, 138, 104, 24 },
		DisplayText.Native("Fechar"), function()
		self.routePlannerSeedPickerUpdater = nil
		main:ClosePopup()
	end)
	setLabel("rightsNote", "Observação: build-semente ≠ modelo GNN treinado. Direitos pendentes; sem crédito de treino.",
		24, 184, 802, 28, 12)
	controls.rightsNote.tooltipText = "As 623 XMLs canônicas da pasta são sementes locais. A origem pública de cada build ainda está marcada como não verificada; o corpus continua em observação e não há pesos GNN aprovados."
	self.routePlannerSeedPickerUpdater = updateSeedList
	updateSeedList()
	main:OpenPopup(popupWidth, popupHeight, DisplayText.Native("Builds-semente arquivadas"), controls, "close")
end

function OptimizerTabClass:OpenRoutePlanner()
	if self.textValues.useImportedRouteMemory == nil or tostring(self.textValues.useImportedRouteMemory) == "" then
		self.textValues.useImportedRouteMemory = "true"
	end
	if not RoutePlanner.dpsGainModes[tostring(self.textValues.routePlannerDpsGain or "")] then
		self.textValues.routePlannerDpsGain = "NO_LOSS"
	end
	self:RefreshRoutePlannerSeedCatalog(false)
	local skill, skillError, skillContext = RoutePlanner.GetMainSkill(self.build, false, true)
	if not skillContext then skillContext = RoutePlanner.InspectMainSkill(self.build) end
	local socketGroups = self.build.skillsTab and self.build.skillsTab.socketGroupList or { }
	local selectedGroupIndex = tonumber(self.build.mainSocketGroup) or 1
	local selectedGroupExists = selectedGroupIndex >= 1 and selectedGroupIndex <= #socketGroups
	local emptyDefaultSkillGroup = #socketGroups == 0 and selectedGroupIndex == 1
	local socketRepair = skillContext and skillContext.socketRepair
	local socketRepairs = skillContext and skillContext.socketRepairs or { }
	local socketRepairAudit = skillContext and skillContext.socketRepairAudit
	local socketRepairBlockers = socketRepairAudit and socketRepairAudit.blockers or { }
	-- A resolved native Main Skill is enough to start bounded structural search.
	-- Socket/link validity and repair availability are candidate gates, not UI
	-- readiness gates: otherwise one bad imported item can gray out the only
	-- action that could propose an equipment or skill repair. The run still uses
	-- the exact selected effect and every displayed route must pass native proof.
	local searchSkill = skill or (skillContext and skillContext.skill)
	local canOpenRouteConfiguration = skill ~= nil or (skillContext and skillContext.skill ~= nil)
		or selectedGroupExists or emptyDefaultSkillGroup
	-- The optional catalog selector belongs to the advanced view. Do not keep a
	-- reference to a control from a previously closed popup while the native
	-- combination view is open.
	self.routePlannerModelControl = nil
	if searchSkill then self:RefreshRoutePlannerModelCatalog(true) end
	local savedModelId = tostring(self.textValues.routePlannerModelPackageId or "")
	if savedModelId ~= "" then
		local catalog = self.routePlannerModelCatalog
		local modelStillAvailable = false
		for _, model in ipairs(catalog and catalog.models or { }) do
			if model.packageId == savedModelId then modelStillAvailable = true break end
		end
		if not modelStillAvailable then
			-- Unknown, loading, or incompatible saved models are never allowed to
			-- hold the UI closed. Start this run with the deterministic PoB search.
			self.textValues.routePlannerModelPackageId = ""
			self.textValues.routePlannerModelMode = "deterministic_fallback"
			self.modFlag = true
		end
	end
	local controls = { }
	local showAdvanced = self.routePlannerAdvancedExpanded == true
	local blockingReason = not searchSkill
		and tostring(skillError or (skillContext and skillContext.error) or "Main Skill indisponível") or nil
	local socketWarningText
	if #socketRepairBlockers > 0 then
		local warningNames = { }
		for index, warning in ipairs(skillContext.socketWarnings or { }) do
			if index > 3 then break end
			warningNames[#warningNames + 1] = sanitizeDetailText(warning.group or warning.groupIndex or "grupo")
		end
		socketWarningText = "Busca habilitada; " .. groupedNumber(#socketRepairBlockers)
			.. " grupo(s) sem reparo físico nativo" .. (#warningNames > 0 and (": " .. table.concat(warningNames, ", ")) or "")
			.. ". Os cálculos ficam como diagnóstico e não viram rotas aprovadas sem prova de socket/link."
	elseif skillContext and skillContext.socketEvidence and not skillContext.socketEvidence.valid and not socketRepair then
		socketWarningText = "A Main Skill não tem vínculo físico nativo; a busca pode começar, mas só uma candidata que prove o socket/link será aprovada."
	end
	local socketWarningDetails = { }
	for index, warning in ipairs(skillContext and skillContext.socketWarnings or { }) do
		if index > 8 then break end
		socketWarningDetails[#socketWarningDetails + 1] = sanitizeDetailText(warning.group or warning.groupIndex or "grupo")
			.. ": " .. sanitizeDetailText(warning.reason or "socket/link nativo indisponível")
	end
	local layoutOffset = blockingReason and 88 or socketWarningText and 32 or 0
	local popupWidth, popupHeight = 900, (showAdvanced and 752 or 590) + layoutOffset
	local selectedTargetId = tostring(self.textValues.routePlannerTargetNodeId or "")
	local selectedTargetNumber = tonumber(selectedTargetId)
	local selectedTargetNode = selectedTargetNumber and self.build.spec
		and (self.build.spec.nodes[selectedTargetNumber] or self.build.spec.nodes[selectedTargetId]) or nil
	local targetNodeError
	if selectedTargetId ~= "" then
		local savedTreeVersion = tostring(self.textValues.routePlannerTargetTreeVersion or "")
		local savedNodeName = tostring(self.textValues.routePlannerTargetNodeName or "")
		if savedTreeVersion ~= "" and savedTreeVersion ~= tostring(self.build.spec.treeVersion or "") then
			targetNodeError = "O alvo pertence a outra versão da árvore; escolha novamente nesta árvore."
		elseif not selectedTargetNode or tonumber(selectedTargetNode.id) ~= selectedTargetNumber
			or (savedNodeName ~= "" and savedNodeName ~= tostring(selectedTargetNode.dn or selectedTargetNode.name or "")) then
			targetNodeError = "O nó-alvo salvo não existe na árvore atual; escolha outro ou limpe o alvo."
		elseif selectedTargetNode.alloc then
			targetNodeError = "O nó-alvo já está alocado; escolha um nó ainda não alocado."
		elseif selectedTargetNode.ascendancyName or selectedTargetNode.isProxy or selectedTargetNode.isMultipleChoiceOption
			or selectedTargetNode.isTattoo or (selectedTargetNode.type ~= "Normal" and selectedTargetNode.type ~= "Notable"
				and selectedTargetNode.type ~= "Keystone") then
			targetNodeError = "Esse tipo de nó não aceita roteamento direto; escolha um nó passivo normal, notável ou keystone."
		end
	end
	self.routePlannerTrainingConsent = false
	self.routePlannerTrainingAuthorship = false
	self.textValues.routePlannerSearchMode = "SINGLE_SKILL_ONLY"
	self.textValues.routePlannerCrossSkillMode = "SINGLE_SKILL_ONLY"
	local popupAnchor = popupTopLeftAnchor()
	local function addLabel(key, text, x, y, width, height, size)
		controls[key] = new("LabelControl"):LabelControl(popupAnchor, { x, y, width, height }, DisplayText.Native(text))
		setClippedPopupLabel(controls[key], width, size or 13)
		return controls[key]
	end
	local function addChoice(key, label, x, y, choices, fallback, afterChanged)
		addLabel(key .. "Label", label, x, y + 2, 142, 20, 13)
		local control = new("DropDownControl"):DropDownControl(popupAnchor, { x + 148, y, 250, 22 }, nativeChoiceLabels(choices), function(_, selected)
			if selected then
				local value = tostring(type(selected) == "table" and selected.val or selected)
				local previous = tostring(self.textValues[key] or fallback or "")
				self.textValues[key] = value
				self.modFlag = true
				if afterChanged and previous ~= value then afterChanged(value, previous) end
			end
		end)
		control.enableDroppedWidth = true
		control:SelByValue(tostring(self.textValues[key] or fallback), "val")
		controls[key] = control
		return control
	end
	local function metric(value)
		value = tonumber(value)
		if not value or value ~= value or value == math.huge or value == -math.huge then return "indisponível" end
		return groupedNumber(value)
	end
	local baseline = skillContext and skillContext.baseline or { }
	local objectiveMetric = tostring(skillContext and skillContext.objectiveMetric or "CombinedDPS")
	local objectiveLabel = objectiveMetric == "FullDPS" and "DPS total do PoB" or "DPS da Main Skill"
	local dpsTier = tostring(self.textValues.routePlannerDpsTier or "TIER_10M_TO_25M")
	local dpsFloor = RoutePlanner.dpsFloors[dpsTier]
	local baselineDps = tonumber(baseline[objectiveMetric])
	local skillLine
	if #socketRepairs > 0 and searchSkill then
		local repairSlots, seenRepairSlots, disabledSupports = { }, { }, 0
		for _, repairPlan in ipairs(socketRepairs) do
			local slot = tostring(repairPlan.slot or "")
			if slot ~= "" and not seenRepairSlots[slot] then
				seenRepairSlots[slot] = true
				repairSlots[#repairSlots + 1] = slot
			end
			disabledSupports = disabledSupports + #(repairPlan.gemRemovals or { })
		end
		skillLine = "Main Skill pronta | reparo nativo exigido em " .. tostring(#repairSlots)
			.. " item(ns): " .. table.concat(repairSlots, ", ")
		if disabledSupports > 0 then
			skillLine = skillLine .. " | a cópia da rota removerá " .. tostring(disabledSupports)
				.. " suporte(s) desativado(s) para caber nos sockets nativos"
		end
	elseif searchSkill and searchSkill.socketEvidence and searchSkill.socketEvidence.valid then
		local linkLabel = searchSkill.socketEvidence.status == "granted_skill"
			and "skill concedida nativa" or (tostring(searchSkill.socketEvidence.socketCount or "?") .. " sockets vinculados")
		skillLine = "Main Skill pronta: " .. tostring(searchSkill.effectId) .. " | " .. tostring(searchSkill.slot) .. " | " .. linkLabel
	elseif searchSkill and socketRepair then
		skillLine = "Main Skill pronta para reconfigurar sockets: " .. tostring(searchSkill.effectId)
			.. " | " .. tostring(socketRepair.slot)
			.. " | a busca vai incluir um item nativo com cores/links compatíveis"
	elseif searchSkill then
		skillLine = "Main Skill identificada; vínculo físico pendente: " .. tostring(searchSkill.effectId)
			.. " | " .. tostring(searchSkill.slot or "sem slot")
	elseif skillContext and skillContext.skill and skillContext.socketEvidence
		and skillContext.socketEvidence.valid then
		skillLine = "Build bloqueada: " .. tostring(skillError or skillContext.error
			or "uma skill ativa de Full DPS não passou a validação nativa de sockets/links")
	else
		skillLine = "Main Skill bloqueada: " .. tostring(skillError or (skillContext and skillContext.error)
			or "selecione uma skill ativa e válida na aba Skills")
	end
	local baselineLine = "Baseline nativo — " .. objectiveLabel .. ": " .. metric(baseline[objectiveMetric])
		.. " | Vida efetiva (EHP): " .. metric(baseline.TotalEHP)
		.. " | Max hit físico recebido: " .. metric(baseline.PhysicalMaximumHitTaken)
	if objectiveMetric == "FullDPS" then
		baselineLine = baselineLine .. " | DPS da Main Skill: " .. metric(baseline.CombinedDPS)
	end
	local elementalMax = { tonumber(baseline.FireMaximumHitTaken), tonumber(baseline.ColdMaximumHitTaken), tonumber(baseline.LightningMaximumHitTaken) }
	if elementalMax[1] and elementalMax[2] and elementalMax[3] then
		baselineLine = baselineLine .. " | menor max hit elemental recebido " .. metric(math.min(elementalMax[1], elementalMax[2], elementalMax[3]))
	end
	local function currentDpsFloorLine()
		local dpsGainMode = tostring(self.textValues.routePlannerDpsGain or "NO_LOSS")
		local dpsGainPercent = ({ GAIN_5_PERCENT = 0.05, GAIN_10_PERCENT = 0.10,
			GAIN_25_PERCENT = 0.25, NO_LOSS = 0 })[dpsGainMode]
		if dpsGainMode ~= "NONE" and dpsGainPercent ~= nil and baselineDps and baselineDps > 0 and dpsFloor then
			local relativeFloor = baselineDps * (1 + dpsGainPercent)
			local effectiveFloor = math.max(dpsFloor, relativeFloor)
			local targetDescription = dpsGainMode == "NO_LOSS" and "não perder DPS" or ("ganhar pelo menos "
				.. tostring(math.floor(dpsGainPercent * 100)) .. "% de DPS")
			return "Piso de DPS ativo: " .. targetDescription .. " vs. a build carregada ("
				.. objectiveLabel .. " ≥ " .. metric(effectiveFloor) .. "). Comparação usa o baseline atual do PoB, já com os dados do patch carregado."
		elseif dpsGainMode ~= "NONE" then
			return "Ganho relativo indisponível: atualize o cálculo nativo do PoB até obter um baseline positivo para a Main Skill."
		elseif baselineDps and dpsFloor then
			return baselineDps >= dpsFloor and "Baseline já atende ao piso de DPS selecionado."
				or ("Atenção: baseline " .. metric(baselineDps) .. " abaixo do piso " .. metric(dpsFloor)
					.. "; a busca só aprova candidatas que atinjam todos os pisos exatos.")
		end
		return "Piso de DPS selecionado: >= " .. metric(dpsFloor)
			.. ". O PoB ainda não forneceu o baseline exato para esta build; atualize os cálculos antes da busca."
	end
	local floorLine = currentDpsFloorLine()
	local socketBlocker = skillContext and skillContext.socketRepairAudit
		and skillContext.socketRepairAudit.blockers and skillContext.socketRepairAudit.blockers[1]
	local blockingGroup = skillContext and skillContext.fullDpsSocketEvidence
		and skillContext.fullDpsSocketEvidence.violations and skillContext.fullDpsSocketEvidence.violations[1]
	if blockingReason and socketBlocker then
		if tonumber(socketBlocker.groupIndex) == selectedGroupIndex then
			blockingReason = "Corrija a Main Skill e seu vínculo de sockets na aba Skills: "
				.. tostring(socketBlocker.reason or blockingReason)
		else
			blockingReason = "Corrija o grupo " .. tostring(socketBlocker.group or socketBlocker.groupIndex or "de gemas")
				.. " na aba Skills/equipamentos: " .. tostring(socketBlocker.reason or blockingReason)
		end
	elseif blockingReason and blockingGroup then
		blockingReason = "Corrija o grupo " .. tostring(blockingGroup.group or blockingGroup.groupIndex or "Full DPS")
			.. " na aba Skills: " .. tostring(blockingGroup.reason or blockingReason)
	elseif blockingReason then
		blockingReason = "Corrija a Main Skill e seu vínculo de sockets na aba Skills: " .. blockingReason
	end
	if not canOpenRouteConfiguration then
		addLabel("title", "AI Planner — build bloqueada", 24, 22, 840, 28, 17)
		addLabel("skill", skillLine, 28, 54, 840, 24, 12)
		addLabel("baseline", baselineLine, 28, 81, 840, 20, 12)
		controls.blockingReason = addLabel("blockingReason", blockingReason or skillError or "Main Skill indisponível",
			28, 108, 840, 42, 12)
		controls.blockingReason.tooltipText = blockingReason
		controls.fixSkills = new("ButtonControl"):ButtonControl(popupAnchor, { 28, 164, 220, 24 },
			DisplayText.Native("Abrir aba Skills para corrigir"), function()
				main:ClosePopup()
				self.build.viewMode = "SKILLS"
				self.statusMessage = "Corrija os sockets ou desative a inclusão inválida em Full DPS; depois reabra Combinações."
			end)
		controls.fixSkills.tooltipText = "Abre a aba Skills para corrigir a Main Skill, os sockets ou sua inclusão em Full DPS."
		controls.close = new("ButtonControl"):ButtonControl(popupAnchor, { 744, 164, 108, 24 },
			DisplayText.Native("Fechar"), function() main:ClosePopup() end)
		main:OpenPopup(900, 214, DisplayText.Native("AI Planner — build bloqueada"), controls,
			"fixSkills", "close", "close")
		return
	end
	local scenarioChoices = {
		{ val = "Current", label = "Configuração atual" },
		{ val = "PinnacleUnbuffed", label = "Pinnacle sem flasks/kill states" },
		{ val = "PinnacleChassis", label = "Chassis Pinnacle" },
	}
	local dpsChoices = {
		{ val = "TIER_1M_TO_5M", label = ">= 1M DPS" }, { val = "TIER_5M_TO_10M", label = ">= 5M DPS" },
		{ val = "TIER_10M_TO_25M", label = ">= 10M DPS" }, { val = "TIER_25M_TO_50M", label = ">= 25M DPS" },
		{ val = "TIER_50M_PLUS", label = ">= 50M DPS" },
	}
	local ehpChoices = {
		{ val = "TIER_20K_TO_50K", label = ">= 20k EHP" }, { val = "TIER_50K_TO_100K", label = ">= 50k EHP" },
		{ val = "TIER_100K_PLUS", label = ">= 100k EHP" },
	}
	local hitChoices = {
		{ val = "TIER_5K_TO_10K", label = ">= 5k max hit" }, { val = "TIER_10K_TO_20K", label = ">= 10k max hit" },
		{ val = "TIER_15K_TO_25K", label = ">= 15k max hit" }, { val = "TIER_20K_PLUS", label = ">= 20k max hit" },
	}
	local elementalResists = {
		{ val = "CAP_EFFECTIVE", label = "Atingir cap efetivo (>=75%)" },
		{ val = "OVERCAP_30_ALL", label = "30% de overcap nos 3 elementos" },
	}
	local chaosResists = {
		{ val = "POSITIVE_OR_CAP", label = "Caos >= 0%" },
		{ val = "CAP_EFFECTIVE", label = "Caos >= 75%" },
	}
	local damageFocusChoices = {
		{ val = "Auto", label = "Automático — DPS total" },
		{ val = "PhysicalHit", label = "Dano físico de acerto" },
		{ val = "PhysicalImpale", label = "Físico + Impale" },
		{ val = "PhysicalDoT", label = "Físico DoT / Bleed" },
		{ val = "Fire", label = "Fogo" }, { val = "Cold", label = "Frio" },
		{ val = "Lightning", label = "Raio" }, { val = "ChaosPoison", label = "Caos / Veneno" },
		{ val = "Minions", label = "Lacaios" },
	}
	local defenseFocusChoices = {
		{ val = "Auto", label = "Automático — EHP" }, { val = "Life", label = "Vida" },
		{ val = "EnergyShield", label = "Energy Shield" }, { val = "Hybrid", label = "Vida + Energy Shield" },
		{ val = "Ward", label = "Ward" }, { val = "Armour", label = "Armadura" },
		{ val = "Evasion", label = "Evasão" }, { val = "Block", label = "Block de ataques" },
		{ val = "SpellBlock", label = "Spell block" }, { val = "SpellSuppression", label = "Supressão de spells" },
	}
	local rankingPriorityChoices = {
		{ val = "ObjectiveFirst", label = "DPS primeiro; defesa como desempate" },
		{ val = "DefenseFirst", label = "Defesa selecionada primeiro" },
	}
	local proposalLimitChoices = {
		{ val = "10000", label = "Até 10.000 propostas" },
		{ val = "40000", label = "Até 40.000 propostas" },
		{ val = "100000", label = "Até 100.000 propostas" },
	}
	local exactEvaluationBudgetChoices = {
		{ val = "250", label = "250 / até 2 min (teste rápido)" },
		{ val = "500", label = "500 / até 4 min" },
		{ val = "1000", label = "1.000 / até 8 min" },
		{ val = "2500", label = "2.500 / até 15 min" },
		{ val = "5000", label = "5.000 / até 30 min" },
		{ val = "10000", label = "10.000 / até 60 min (busca profunda)" },
	}
	local conversionRouteChoices = {
		{ val = "NONE", label = "Sem conversão obrigatória" },
		{ val = "PHYSICAL_TO_FIRE", label = "Físico → Fogo" },
		{ val = "PHYSICAL_TO_COLD", label = "Físico → Frio" },
		{ val = "PHYSICAL_TO_LIGHTNING", label = "Físico → Raio" },
		{ val = "PHYSICAL_TO_CHAOS", label = "Físico → Caos" },
		{ val = "PHYSICAL_TO_LIGHTNING_TO_COLD", label = "Físico → Raio → Frio" },
		{ val = "LIGHTNING_TO_COLD", label = "Raio → Frio" },
		{ val = "LIGHTNING_TO_FIRE", label = "Raio → Fogo" },
		{ val = "COLD_TO_FIRE", label = "Frio → Fogo" },
	}
	local conversionMinimumChoices = {
		{ val = "50", label = "Mínimo 50% por etapa" },
		{ val = "75", label = "Mínimo 75% por etapa" },
		{ val = "100", label = "Mínimo 100% por etapa" },
	}
	local aggressionChoices = {
		{ val = "CONSERVATIVE_FINE_TUNE", label = "Local — até 12 pontos novos" },
		{ val = "BALANCED_LOCAL_SEARCH", label = "Ampla — até 24 pontos novos" },
		{ val = "AGGRESSIVE_CLUSTER_EXPANSION", label = "Profunda — até 40 pontos novos" },
	}
	local dpsGainChoices = {
		{ val = "NONE", label = "Só o piso de DPS selecionado" },
		{ val = "NO_LOSS", label = "Não perder DPS vs. build atual" },
		{ val = "GAIN_5_PERCENT", label = "Ganhar pelo menos 5% vs. build atual" },
		{ val = "GAIN_10_PERCENT", label = "Ganhar pelo menos 10% vs. build atual" },
		{ val = "GAIN_25_PERCENT", label = "Ganhar pelo menos 25% vs. build atual" },
	}
	local radiusChoices = { { val = "2", label = "K = 2" }, { val = "4", label = "K = 4" }, { val = "6", label = "K = 6" } }
	addLabel("title", "AI Planner — Combinações", 24, 22, 840, 28, 17)
	addLabel("skill", skillLine, 28, 54, 840, 24, 12)
	controls.skill.tooltipText = socketWarningText or blockingReason
	addLabel("baseline", baselineLine, 28, 81, 840, 20, 12)
	addLabel("floorStatus", floorLine, 28, 104, 840, 30, 12)
	if socketWarningText and not blockingReason then
		controls.socketWarning = addLabel("socketWarning", socketWarningText, 28, 130, 840, 30, 11)
		controls.socketWarning.tooltipText = #socketWarningDetails > 0
			and table.concat(socketWarningDetails, "\n")
			or "A rota só aparece como aprovada após o recálculo exato e a prova nativa dos sockets/links."
	end
	if blockingReason then
		controls.blockingReason = addLabel("blockingReason", blockingReason, 28, 130, 840, 40, 12)
		controls.fixSkills = new("ButtonControl"):ButtonControl(popupAnchor, { 28, 174, 164, 22 },
			DisplayText.Native("Abrir aba Skills para corrigir"), function()
				main:ClosePopup()
				self.build.viewMode = "SKILLS"
				self.statusMessage = "Corrija os sockets ou desative a inclusão inválida em Full DPS; depois reabra Combinações."
			end)
		controls.fixSkills.tooltipText = "Abre a aba Skills para selecionar o grupo indicado e corrigir o item/socket ou sua inclusão no Full DPS."
	end
	local targetHeadingY = 140 + layoutOffset
	addLabel("targetHeading", "OBJETIVOS PRINCIPAIS", 28, targetHeadingY, 840, 14, 12)
	addChoice("routePlannerDpsTier", "Piso de DPS", 28, 154 + layoutOffset, dpsChoices, "TIER_10M_TO_25M")
	addChoice("routePlannerEhpTier", "Piso de EHP", 448, 154 + layoutOffset, ehpChoices, "TIER_50K_TO_100K")
	addLabel("focusHeading", "FOCO DA BUILD", 28, 196 + layoutOffset, 840, 14, 12)
	addChoice("damageFocus", "Dano", 28, 212 + layoutOffset, damageFocusChoices, "Auto")
	controls.damageFocus.tooltipText = "Orienta propostas e ranking exato quando o PoB expõe uma métrica compatível. Fogo/Frio/Raio usam o dano médio por acerto daquela fonte; isso não é DPS elemental separado nem força conversão. O piso continua sendo o DPS total exato."
	addChoice("defenseProfile", "Defesa", 448, 212 + layoutOffset, defenseFocusChoices, "Auto")
	addLabel("combinationHeading", "CAPACIDADE DE BUSCA", 28, 254 + layoutOffset, 840, 14, 12)
	addChoice("routePlannerProposalLimit", "Propostas estruturais", 28, 270 + layoutOffset, proposalLimitChoices, "40000")
	addChoice("routePlannerExactEvaluationBudget", "Recálculos exatos", 448, 270 + layoutOffset,
		exactEvaluationBudgetChoices, "5000")
	controls.routePlannerExactEvaluationBudget.tooltipText = "Cada opção define o teto de recálculos exatos e o prazo dessa fase. O prazo começa depois da geração/validação estrutural, ao iniciar os cálculos exatos. A busca termina ao atingir o primeiro limite; uma chamada nativa em andamento pode concluir pouco depois. Você pode cancelar."
	controls.advanced = new("ButtonControl"):ButtonControl(popupAnchor, { 28, 312 + layoutOffset, 156, 24 },
		DisplayText.Native(showAdvanced and "Ocultar opções avançadas" or "Opções avançadas"), function()
			self.routePlannerAdvancedExpanded = not showAdvanced
			main:ClosePopup()
			self:OpenRoutePlanner()
		end)
	controls.advanced.tooltipText = "Abre requisitos de defesa detalhados, conversão, cenário, fontes de padrões, nó-alvo e agressividade."
	controls.configure = new("ButtonControl"):ButtonControl(popupAnchor, { 194, 312 + layoutOffset, 208, 24 },
		DisplayText.Native("Configurar skill e sockets"), function()
			main:ClosePopup()
			self:OpenGuidedSetup()
		end)
	controls.configure.tooltipText = "Abre o setup guiado para escolher uma skill ou corrigir o vínculo nativo com equipamento e sockets."
	if showAdvanced then
		addLabel("routePlannerModelPackageIdLabel", "Modelo ativo", 448, 306 + layoutOffset, 88, 20, 12)
		controls.routePlannerModelPackageId = new("DropDownControl"):DropDownControl(popupAnchor,
			{ 540, 304 + layoutOffset, 276, 22 }, nativeChoiceLabels({
				{ val = "", label = "PoB nativo (sem GNN)" },
			}), function(_, selected)
			if not selected then return end
			local packageId = tostring(type(selected) == "table" and selected.val or selected)
			self.textValues.routePlannerModelPackageId = packageId
			self.textValues.routePlannerModelMode = packageId ~= "" and "approved_gnn" or "deterministic_fallback"
			self.modFlag = true
		end)
		controls.routePlannerModelPackageId.enableDroppedWidth = true
		controls.routePlannerModelPackageId.tooltipText = "Lista apenas pacotes GNN completos, aprovados e compatíveis com a versão do PoB, Main Skill e cenário atuais. Os XMLs arquivados são builds-semente, não modelos treinados."
		self.routePlannerModelControl = controls.routePlannerModelPackageId
		controls.refreshModels = new("ButtonControl"):ButtonControl(popupAnchor,
			{ 822, 304 + layoutOffset, 58, 22 }, DisplayText.Native("Atualizar"), function()
			self:RefreshRoutePlannerModelCatalog(true)
		end)
		controls.refreshModels.tooltipText = "Consulta novamente o catálogo local de modelos GNN aprovados compatíveis."
		controls.modelStatus = new("LabelControl"):LabelControl(popupAnchor,
			{ 448, 330 + layoutOffset, 432, 30 }, function()
			local catalog = self.routePlannerModelCatalog or { status = "loading", models = { } }
			local selected = tostring(self.textValues.routePlannerModelPackageId or "")
			if catalog.status == "loading" then
				local cachedModels = #(catalog.models or { })
				if cachedModels > 0 then
					return DisplayText.Native(tostring(cachedModels)
						.. " modelo(s) GNN aprovado(s) compatível(is); revalidando em segundo plano.")
				end
				return DisplayText.Native("Consultando modelos aprovados compatíveis…")
			end
			if catalog.status == "ready" then
				if selected ~= "" then return DisplayText.Native("GNN aprovado selecionado: " .. selected) end
				if #(catalog.models or { }) > 0 then
					return DisplayText.Native(tostring(#catalog.models) .. " modelo(s) GNN aprovado(s) compatível(is); usando o PoB nativo.")
				end
				return DisplayText.Native("Nenhum modelo GNN aprovado compatível; usando o PoB nativo.")
			end
			return DisplayText.Native("Catálogo GNN indisponível; busca nativa do PoB ativa.")
		end)
		setClippedPopupLabel(controls.modelStatus, 432, 11)
		controls.modelStatus.tooltipText = "Modelos listados vêm de 04_Models_Approved e passam pelos gates de integridade, proveniência, qualidade, skill, cenário e fingerprint. Builds XML arquivadas não são pesos GNN e continuam servindo apenas como sementes/evidência estrutural."
		controls.openArchivedSeeds = new("ButtonControl"):ButtonControl(popupAnchor,
			{ 28, 336 + layoutOffset, 186, 22 }, DisplayText.Native("Builds-semente arquivadas"), function()
			main:ClosePopup()
			self:OpenArchivedSeedPicker()
		end)
		controls.openArchivedSeeds.tooltipText = "Abre a lista pesquisável de XMLs importados pelo PoB. Uma build-semente pode ser carregada como build nova após confirmação; não é um modelo GNN e não entra no treino."
		controls.archivedSeedStatus = new("LabelControl"):LabelControl(popupAnchor,
			{ 220, 339 + layoutOffset, 218, 18 }, function()
			local catalog = self.routePlannerSeedCatalog or { status = "loading" }
			if catalog.status == "loading" then return DisplayText.Native("Lendo sementes do Drive…") end
			if catalog.status == "ready" then
				return DisplayText.Native(string.format("%d sementes | direitos pendentes", #(catalog.seeds or { })))
			end
			return DisplayText.Native("Arquivo-semente indisponível")
		end)
		setClippedPopupLabel(controls.archivedSeedStatus, 218, 11)
		controls.archivedSeedStatus.tooltipText = "Mostra apenas builds-semente da mesma versão de dados e árvore do PoB aberto. As origens/direitos continuam pendentes; nenhuma conta como modelo ou dado de treino."
		local selectedPackageId = tostring(self.textValues.routePlannerModelPackageId or "")
		local initialCatalog = self.routePlannerModelCatalog or { status = "loading", models = { } }
		local initialModelChoices = { { val = "", label = "PoB nativo (sem GNN)" } }
		local initialSelectionValid = selectedPackageId == ""
		for _, model in ipairs(initialCatalog.models or { }) do
			initialModelChoices[#initialModelChoices + 1] = { val = model.packageId, label = "GNN aprovado — " .. model.packageId }
			if model.packageId == selectedPackageId then initialSelectionValid = true end
		end
		if selectedPackageId ~= "" and not initialSelectionValid and initialCatalog.status == "loading" then
			initialModelChoices[#initialModelChoices + 1] = { val = selectedPackageId, label = "Verificando GNN — " .. selectedPackageId }
		end
		controls.routePlannerModelPackageId:SetList(nativeChoiceLabels(initialModelChoices))
		controls.routePlannerModelPackageId:SelByValue(selectedPackageId, "val")
	else
		controls.engineStatus = addLabel("engineStatus",
			"Cálculo exato e validação: motor nativo do PoB. GNN aprovado, se disponível, só prioriza propostas.",
			448, 312 + layoutOffset, 432, 28, 11)
		controls.engineStatus.tooltipText = "O motor do PoB recalcula todas as candidatas aprovadas. Os XMLs arquivados ajudam a propor padrões, mas não são modelos treinados."
	end
	if showAdvanced then
		addLabel("hardFloorHeading", "PISOS DEFENSIVOS ADICIONAIS", 28, 382 + layoutOffset, 840, 14, 12)
		addChoice("routePlannerElementalHitTier", "Pior max hit elemental", 28, 398 + layoutOffset, hitChoices, "TIER_10K_TO_20K")
		addChoice("routePlannerPhysicalHitTier", "Max hit físico", 448, 398 + layoutOffset, hitChoices, "TIER_10K_TO_20K")
		addChoice("routePlannerElementalResists", "Resist. elementais", 28, 440 + layoutOffset, elementalResists, "CAP_EFFECTIVE")
		addChoice("routePlannerChaosResist", "Resist. caos", 448, 440 + layoutOffset, chaosResists, "POSITIVE_OR_CAP")
		addLabel("advancedHeading", "REFINAR A BUSCA", 28, 472 + layoutOffset, 840, 14, 12)
		addChoice("rankingPriority", "Ordem de ranking", 28, 488 + layoutOffset, rankingPriorityChoices, "ObjectiveFirst")
		addChoice("routePlannerScenario", "Cenário", 448, 488 + layoutOffset, scenarioChoices, "Current", function()
			self.textValues.routePlannerModelPackageId = ""
			self.textValues.routePlannerModelMode = "deterministic_fallback"
			self:RefreshRoutePlannerModelCatalog(true)
		end)
		addChoice("routePlannerConversionRoute", "Conversão exigida", 28, 530 + layoutOffset, conversionRouteChoices, "NONE")
		controls.routePlannerConversionRoute.tooltipText = "Exige uma cadeia de conversão específica na Main Skill segundo a tabela exata do PoB. A opção não cria fontes de conversão; se nenhum equipamento, suporte ou efeito fornecer a conversão, a proposta é rejeitada."
		addChoice("routePlannerConversionMinimum", "Mínimo por etapa", 448, 530 + layoutOffset, conversionMinimumChoices, "100")
		controls.routePlannerConversionMinimum.tooltipText = "Cada etapa da cadeia precisa alcançar esse percentual no cálculo exato do PoB."
		addChoice("routePlannerAggressiveness", "Alcance das rotas", 28, 572 + layoutOffset, aggressionChoices, "BALANCED_LOCAL_SEARCH")
		controls.routePlannerAggressiveness.tooltipText = "Limita quantos nós passivos novos cada proposta pode acrescentar. A árvore nativa do PoB valida o limite de pontos do personagem e pode substituir nós periféricos para manter o total legal."
		addChoice("routePlannerGraphRadius", "Raio do GNN", 448, 572 + layoutOffset, radiusChoices, "4")
		controls.routePlannerGraphRadius.enabled = function()
			local selected = tostring(self.textValues.routePlannerModelPackageId or "")
			local catalog = self.routePlannerModelCatalog
			if selected == "" or not catalog or catalog.status ~= "ready" then return false end
			for _, model in ipairs(catalog.models or { }) do
				if model.packageId == selected then return true end
			end
			return false
		end
		controls.routePlannerGraphRadius.tooltipText = "Usado somente pelo GNN aprovado selecionado. A busca nativa do PoB usa a árvore completa e ignora este raio."
		addChoice("routePlannerDpsGain", "Ganho de DPS", 448, 620 + layoutOffset,
			dpsGainChoices, "NO_LOSS", function()
				if controls.floorStatus then controls.floorStatus.label = DisplayText.Native(currentDpsFloorLine()) end
			end)
		controls.routePlannerDpsGain.tooltipText = "Exige que a rota mantenha ou supere o DPS exato da build carregada, já calculado pela versão atual do PoB. Inclui trocas legais de suportes, rotas passivas e combinações entre elas. Para restaurar um valor pré-nerf, carregue e calcule uma referência antiga; o Planner não inventa esse baseline."
		local importedRoutesEnabled = tostring(self.textValues.useImportedRouteMemory or "true"):lower() == "true"
		controls.useImportedRoutes = new("CheckBoxControl"):CheckBoxControl(popupAnchor,
			{ 28, 596 + layoutOffset, 16 }, DisplayText.Native("Padrões de builds compatíveis"), function(checked)
			self.textValues.useImportedRouteMemory = checked and "true" or "false"
			self.nodeEvidence = nil
			self.modFlag = true
		end, "Usa árvores de builds com o mesmo engine, patch/árvore e classe-base; a skill e a ascendência padrão de origem podem diferir. Importa apenas padrões passivos locais — itens e métricas não são transferidos. Toda proposta é recalculada no PoB.",
			importedRoutesEnabled)
		controls.useImportedRoutes.labelRight = true
		controls.useImportedRoutes.labelWidth = 242
		controls.useImportedRoutes.tooltipText = "Padrões passivos de outras builds com o mesmo patch/árvore e classe-base geram propostas locais limitadas, mesmo quando a Main Skill ou ascendência padrão de origem difere. Itens, sockets e métricas de origem não são copiados. Cada rota passa pelo recálculo e pelos gates exatos do PoB."
		local nodePowerEnabled = self.textValues.routePlannerUseNodePower == nil
			or self.textValues.routePlannerUseNodePower == true
			or tostring(self.textValues.routePlannerUseNodePower):lower() == "true"
		controls.useNodePower = new("CheckBoxControl"):CheckBoxControl(popupAnchor,
			{ 448, 596 + layoutOffset, 16 }, DisplayText.Native("Show Node Power"), function(checked)
			self.textValues.routePlannerUseNodePower = checked and "true" or "false"
			self.modFlag = true
		end, nodePowerEnabled)
		controls.useNodePower.labelRight = true
		controls.useNodePower.labelWidth = 186
		controls.useNodePower.tooltipText = "Usa o valor nativo já calculado em Tree > Show Node Power para ordenar alvos, apenas quando o stat selecionado corresponde ao foco de dano/defesa. Não calcula dano por elemento que o PoB não exponha e nunca substitui o recálculo exato."
		local archiveSource, archiveSourceError = StudyBuilds.GetPlannerArchiveSource(main and main.userPath)
		local archiveStatusText
		local archiveSourceLabel = archiveSource and archiveSource.mode == "local_fallback" and "Arquivo local (fallback)"
			or archiveSource and archiveSource.mode == "local_archive" and "Arquivo local" or "Drive"
		local lastEvidence = self.nodeEvidence
		local evidenceMatchesSkill = skill and type(lastEvidence) == "table"
			and lastEvidence.selectedSkillGemId == skill.gemId
			and lastEvidence.archiveSourceMode == (archiveSource and archiveSource.mode)
		if not archiveSource then
			archiveStatusText = "Arquivo de padrões indisponível: " .. tostring(archiveSourceError or "fonte não configurada")
		elseif evidenceMatchesSkill and lastEvidence.status == "ready" then
			archiveStatusText = string.format("%s: %d builds compatíveis do mesmo patch/árvore e classe-base → %d padrões passivos; propostas recalculadas pelo PoB.",
				archiveSourceLabel,
				tonumber(lastEvidence.compatibleBuildCount) or 0, tonumber(lastEvidence.routePatternCount) or 0)
		elseif archiveSource.status == "ready" then
			archiveStatusText = archiveSourceLabel .. " disponível"
				.. (archiveSource.mode == "local_fallback" and "; a pasta externa configurada está indisponível" or "")
				.. "; compatibilidade por patch/árvore, classe, skill e ascendência padrão será verificada ao iniciar a busca."
		else
			archiveStatusText = archiveSourceLabel .. " sem índice pronto; a geração nativa local continua disponível."
			if archiveSource.fallbackStatus then
				archiveStatusText = archiveStatusText .. " Fallback local: " .. tostring(archiveSource.fallbackReason or archiveSource.fallbackStatus) .. "."
			end
		end
		controls.useImportedRoutes.tooltipText = controls.useImportedRoutes.tooltipText .. " " .. archiveStatusText
	end
	local targetY = (showAdvanced and 652 or 394) + layoutOffset
	controls.selectTarget = new("ButtonControl"):ButtonControl(popupAnchor, { 28, targetY, 176, 22 },
		DisplayText.Native("Escolher nó-alvo"), function()
		main:ClosePopup()
		local treeViewer = self.build.treeTab and self.build.treeTab.viewer
		if treeViewer then
			treeViewer.zoneEditMode = false
			treeViewer.zoneEditSpec = nil
		end
		self.routePlannerTargetSelectMode = true
		self.build.viewMode = "TREE"
		self.statusMessage = "Clique em um nó passivo normal, notável ou keystone ainda não alocado. Esc cancela."
	end)
	controls.selectTarget.tooltipText = "Escolhe na árvore um nó final para a rota. O otimizador encontra caminhos legais desde a árvore atual e recalcula as propostas no PoB."
	controls.clearTarget = new("ButtonControl"):ButtonControl(popupAnchor, { 212, targetY, 94, 22 },
		DisplayText.Native("Limpar alvo"), function()
		self.textValues.routePlannerTargetNodeId = ""
		self.textValues.routePlannerTargetNodeName = ""
		self.textValues.routePlannerTargetTreeVersion = ""
		self.textValues.targetNodeIds = ""
		self.modFlag = true
		main:ClosePopup()
		self:OpenRoutePlanner()
	end)
	controls.clearTarget.enabled = function() return selectedTargetId ~= "" end
	local targetLabel
	if targetNodeError then
		targetLabel = "Nó-alvo inválido: " .. targetNodeError
	elseif selectedTargetNode then
		targetLabel = "Nó-alvo: " .. tostring(selectedTargetNode.dn or selectedTargetNode.name or "Passive")
			.. " (#" .. tostring(selectedTargetNumber) .. ")"
	else
		targetLabel = "Nó-alvo: nenhum — busca geral por rotas variadas"
	end
	controls.targetNodeSummary = addLabel("targetNodeSummary", targetLabel, 320, targetY + 3, 546, 18, 12)
	controls.targetNodeSummary.tooltipText = targetNodeError
	if not showAdvanced then
		controls.combinationScope = addLabel("combinationScope",
			"A build aberta é a semente. Compara rotas de passivas, gemas/suportes e itens legais para a base selecionada. Raros teóricos são recalculados pelo PoB; frascos ficam intactos.",
			28, 422 + layoutOffset, 840, 36, 12)
		controls.combinationScope.tooltipText = "Padrões de árvore compatíveis orientam propostas locais; builds completas, itens ou métricas arquivadas não são transplantados. CoC/CwC e outras combinações de gatilho continuam fora até certificação nativa."
	end
	local budgetY = (showAdvanced and 676 or 466) + layoutOffset
	local budgetHeight = showAdvanced and 18 or 20
	controls.budgetNote = new("LabelControl"):LabelControl(popupAnchor, { 28, budgetY, 840, budgetHeight }, function()
		local selectedBudget = ({
			["250"] = { evaluations = 250, minutes = 2 },
			["500"] = { evaluations = 500, minutes = 4 },
			["1000"] = { evaluations = 1000, minutes = 8 },
			["2500"] = { evaluations = 2500, minutes = 15 },
			["5000"] = { evaluations = 5000, minutes = 30 },
			["10000"] = { evaluations = 10000, minutes = 60 },
		})[tostring(self.textValues.routePlannerExactEvaluationBudget or "5000")] or { evaluations = 5000, minutes = 30 }
		return DisplayText.Native("10k/40k/100k propostas | até " .. groupedNumber(selectedBudget.evaluations)
			.. " recálculos exatos / " .. tostring(selectedBudget.minutes) .. " min | vale o limite atingido primeiro | frascos intactos")
	end)
	setClippedPopupLabel(controls.budgetNote, 840, 12)
	local buttonY = popupHeight - 48
	controls.run = new("ButtonControl"):ButtonControl(popupAnchor, { 520, buttonY, 212, 24 }, DisplayText.Native("Gerar rotas e combinações"), function()
		main:ClosePopup()
		self:RunRoutePlanner()
	end)
	controls.run.enabled = function()
		-- Keep this predicate side-effect free. A missing daemon, an unresolved
		-- approved-model lookup, or a stale saved package must never disable the
		-- deterministic native PoB generator.
		local relativeGainNeedsBaseline = tostring(self.textValues.routePlannerDpsGain or "NO_LOSS") ~= "NONE"
		local hasExactRelativeBaseline = isFiniteNumber(baselineDps) and baselineDps > 0
		return searchSkill ~= nil and not targetNodeError
			and (not relativeGainNeedsBaseline or hasExactRelativeBaseline)
			and not (self.job and self.job.status == "running")
	end
	local function activeOptimizerJob()
		local job = self.job
		if type(job) == "table" and job.status == "running" then return job end
		return nil
	end
	controls.activeSearchStatus = new("LabelControl"):LabelControl(popupAnchor,
		{ 28, buttonY - 44, 840, 18 }, function()
		local job = activeOptimizerJob()
		if not job then return DisplayText.Native("") end
		local progress = type(job.progress) == "table" and job.progress or { }
		local function count(value)
			value = tonumber(value)
			if not value or value ~= value or value == math.huge or value == -math.huge then return "—" end
			return groupedNumber(math.max(0, math.floor(value)))
		end
		local processed = tonumber(progress.processed)
		local total = tonumber(progress.total)
		local work = processed and total and total > 0
			and (" " .. groupedNumber(processed) .. "/" .. groupedNumber(total)) or ""
		local phase = ({
			["Preparing native ascendancy routes"] = "Preparando ascendências",
			["Generating native ascendancy routes"] = "Gerando ascendências",
			["Pathfinding"] = "Buscando caminhos na árvore",
			["Mining path patterns"] = "Combinando padrões de builds",
			["Applying contextual path evidence"] = "Combinando evidências locais",
			["Candidate reconstruction"] = "Gerando combinações",
			["Tree validation"] = "Validando rotas",
			["Exact calculations"] = "Recalculando combinações",
		})[tostring(progress.phase or "")] or tostring(progress.phase or "Preparando")
		local exactBudget = progress.exactEvaluationBudget
			or self.textValues.routePlannerExactEvaluationBudget or "5000"
		local headline = job.routePlannerRun == true and "Busca de rotas" or "Outra busca"
		return DisplayText.Native("^8" .. headline .. " — " .. phase .. work
			.. " | exatas " .. count(progress.exactEvaluations) .. "/" .. count(exactBudget)
			.. " | Pareto " .. count(progress.paretoRoutes))
	end)
	controls.activeSearchDetail = new("LabelControl"):LabelControl(popupAnchor,
		{ 28, buttonY - 25, 840, 18 }, function()
		local job = activeOptimizerJob()
		if not job then return DisplayText.Native("") end
		local progress = type(job.progress) == "table" and job.progress or { }
		local current = tostring(progress.current or "")
		local function count(value)
			value = tonumber(value)
			if not value or value ~= value or value == math.huge or value == -math.huge then return "—" end
			return groupedNumber(math.max(0, math.floor(value)))
		end
		return DisplayText.Native("Propostas " .. count(progress.generatedProposals)
			.. " | únicas " .. count(progress.uniqueProposals)
			.. " | na fila " .. count(progress.retainedProposals)
			.. (current ~= "" and " | " .. current or ""))
	end)
	controls.activeSearchStatus.shown = function() return activeOptimizerJob() ~= nil end
	setClippedPopupLabel(controls.activeSearchStatus, 840, 11)
	controls.activeSearchDetail.shown = function() return activeOptimizerJob() ~= nil end
	setClippedPopupLabel(controls.activeSearchDetail, 840, 11)
	controls.cancelActiveSearch = new("ButtonControl"):ButtonControl(popupAnchor,
		{ 394, buttonY, 150, 24 }, DisplayText.Native("Cancelar busca atual"), function()
		local job = activeOptimizerJob()
		if job and type(job.Cancel) == "function" then
			job:Cancel("user_cancelled")
			self.statusMessage = "Cancelamento solicitado; o PoB está encerrando a busca e preservando os cálculos concluídos."
		end
	end)
	controls.cancelActiveSearch.shown = function() return activeOptimizerJob() ~= nil end
	controls.cancelActiveSearch.enabled = function()
		local job = activeOptimizerJob()
		return job ~= nil and type(job.Cancel) == "function"
	end
	controls.cancelActiveSearch.tooltipText = "Cancela a busca ativa com segurança. O PoB preserva somente rotas e cálculos exatos já concluídos."
	controls.run.tooltipText = targetNodeError or (searchSkill and socketWarningText
		and (socketWarningText .. " O PoB ainda calculará as propostas; hard gates nativos continuam obrigatórios.")
		or searchSkill and #socketRepairs > 0
		and "Gera rotas e combina todos os reparos necessários de sockets/links em clones da build; só resultados recalculados pelo PoB podem ser aprovados."
		or searchSkill and "Gera mutações legais da build carregada, recalcula cada candidata no PoB e mostra resultados exatos."
		or (skillError or "Selecione uma Main Skill ligada a equipamento antes de gerar combinações.")
	)
	controls.close = new("ButtonControl"):ButtonControl(popupAnchor, { 744, buttonY, 108, 24 }, DisplayText.Native("Fechar"), function() main:ClosePopup() end)
	-- If another search is running, make this popup a progress/cancel view. Hiding
	-- the setup controls avoids collisions with the live counters, especially in
	-- advanced mode, while preserving the skill/baseline context and Close action.
	local busyViewExempt = {
		title = true, skill = true, baseline = true,
		activeSearchStatus = true, activeSearchDetail = true,
		cancelActiveSearch = true, close = true,
	}
	for key, control in pairs(controls) do
		if not busyViewExempt[key] then
			local previousShown = control.shown
			control.shown = function()
				if activeOptimizerJob() then return false end
				if type(previousShown) == "function" then return previousShown() end
				return previousShown ~= false
			end
		end
	end
	local activeJob = activeOptimizerJob()
	local preferredFocus = activeJob and type(activeJob.Cancel) == "function" and "cancelActiveSearch"
		or searchSkill and "run" or "close"
	main:OpenPopup(popupWidth, popupHeight, DisplayText.Native("AI Planner — Combinações"), controls,
		preferredFocus, "close", "close")
end

function OptimizerTabClass:RunRoutePlanner()
	if not RoutePlanner.dpsGainModes[tostring(self.textValues.routePlannerDpsGain or "")] then
		self.textValues.routePlannerDpsGain = "NO_LOSS"
	end
	local selectedModelPackageId = tostring(self.textValues.routePlannerModelPackageId or "")
	local modelApproved = selectedModelPackageId == ""
	if selectedModelPackageId ~= "" then
		local catalog = self.routePlannerModelCatalog
		if catalog and catalog.status == "ready" then
			for _, model in ipairs(catalog.models or { }) do
				if model.packageId == selectedModelPackageId then modelApproved = true break end
			end
		end
		if not modelApproved then
			-- The trained ranker is optional. A package that is missing,
			-- incompatible, or still being checked falls back to native PoB search.
			self.textValues.routePlannerModelPackageId = ""
			selectedModelPackageId = ""
			self.modFlag = true
			self:UpdateRoutePlannerModelDropdown()
		end
	end
	self.textValues.routePlannerModelMode = selectedModelPackageId ~= "" and "approved_gnn" or "deterministic_fallback"
	self.textValues.routePlannerSearchMode = "SINGLE_SKILL_ONLY"
	self.textValues.routePlannerCrossSkillMode = "SINGLE_SKILL_ONLY"
	-- AI Analyzer searches a complete route space: passive tree, skill/support,
	-- equipment and their bounded combinations. Synthetic rares are restricted
	-- to PoB's exact base/mod registry and remain theoretical until recalculated.
	self.textValues.generationPhase = "combined"
	self.textValues.searchSyntheticGear = "true"
	local selectedTargetNodeId = tostring(self.textValues.routePlannerTargetNodeId or "")
	if selectedTargetNodeId ~= "" then
		local targetId = tonumber(selectedTargetNodeId)
		local targetNode = targetId and self.build.spec
			and (self.build.spec.nodes[targetId] or self.build.spec.nodes[selectedTargetNodeId]) or nil
		local targetName = tostring(self.textValues.routePlannerTargetNodeName or "")
		local targetTreeVersion = tostring(self.textValues.routePlannerTargetTreeVersion or "")
		local currentTreeVersion = tostring(self.build.spec.treeVersion or "")
		local targetError
		if not targetId or targetId < 1 or targetId ~= math.floor(targetId) or not targetNode then
			targetError = "O nó-alvo não existe na árvore carregada; escolha novamente."
		elseif targetTreeVersion == "" or targetTreeVersion ~= currentTreeVersion
			or targetName == "" or targetName ~= tostring(targetNode.dn or targetNode.name or "") then
			targetError = "A versão ou identidade do nó-alvo mudou; escolha novamente na árvore atual."
		elseif targetNode.alloc or targetNode.ascendancyName or targetNode.isProxy or targetNode.isMultipleChoiceOption
			or targetNode.isTattoo or (targetNode.type ~= "Normal" and targetNode.type ~= "Notable"
				and targetNode.type ~= "Keystone") then
			targetError = "O nó-alvo não aceita roteamento direto; escolha um nó principal ainda não alocado."
		end
		if targetError then
			self.statusMessage = targetError
			return false, targetError
		end
	end
	-- The route planner starts from the build currently loaded in PoB. Generic
	-- Matrix selectors are hidden in this flow and can retain a stale class ID
	-- from another build; passing one makes PhantomSim rebuild a bare class root
	-- and silently drops the imported tree/ascendancy from its baseline.
	for _, key in ipairs({ "baseClassId", "ascendancyId", "addNodeIds", "removeNodeIds",
		"requiredNodeIds", "forbiddenNodeIds", "allowedRegions", "requiredRegions", "forbiddenRegions" }) do
		self.textValues[key] = ""
	end
	self.textValues.targetNodeIds = selectedTargetNodeId
	self.textValues.searchAllClasses = "false"
	self.textValues.nodePotentialAnalysis = "false"
	local ok, job = self:StartOptimizer(self.textValues, nil, {
		routePlanner = true,
	})
	if ok then
		self.statusMessage = "Gerando combinações: o PoB recalcula cada candidata selecionada pelo motor nativo."
		return true, job
	end
	return false, job
end

function OptimizerTabClass:OpenGuidedSetup(profile, page)
	local function saveProfile(value)
		self.textValues.guidedProfile = value
		self.modFlag = true
	end
	if profile == nil then
		profile = "beginner"
		page = 1
	end

	if profile ~= "intermediate" and profile ~= "beginner" and profile ~= "advanced" then profile = "beginner" end
	if page == nil or page < 1 then page = 1 end
	saveProfile(profile)
	if profile == "advanced" then return self:OpenBuildDirection() end
	local isIntermediate = profile == "intermediate"
	local reviewPage = isIntermediate and 5 or 4
	local popup
	local controls = { }
	local function writeField(key, value, preserveTreeBudgetMode)
		value = tostring(value or "")
		self.textValues[key] = value
		if key == "maxAddedPoints" and not preserveTreeBudgetMode then
			self.textValues.treeBudgetMode = "custom"
		end
		local matrixControl = self.controls["text_" .. key]
		if matrixControl then
			if key == "maxTotalPoints" then
				matrixControl:SetText(value, false)
				local points = tonumber(value)
				if points and points >= 1 and points <= 130 and self.controls.pointCapSlider then
					self.controls.pointCapSlider.val = (points - 1) / 129
				end
			elseif matrixControl.optimizerChoices then
				setFieldControl(matrixControl, value)
			else
				matrixControl:SetText(value, false)
			end
		end
		self.modFlag = true
	end
	local function advance(nextPage)
		main:ClosePopup(popup)
		return self:OpenGuidedSetup(profile, nextPage)
	end
	local function addLabel(key, text, x, y, width, height, size)
		controls[key] = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { x, y, width, height }, DisplayText.Native(text))
		setClippedPopupLabel(controls[key], width, size or 14)
		return controls[key]
	end
	local function addChoice(key, label, y, choices, selectedValue, callback, tooltip)
		addLabel(key .. "Label", label, 28, y + 2, 180, 20, 14)
		local control = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 218, y, 466, 22 }, nativeChoiceLabels(choices), function(_, selected)
			if selected then callback(selected) end
		end, tooltip)
		control.enableDroppedWidth = true
		if selectedValue ~= nil then control:SelByValue(tostring(selectedValue), "val") end
		controls[key] = control
		return control
	end
	local function addCheckChoices(key, label, choices, selectedValue, layout, callback, tooltip)
		addLabel(key .. "Label", label, layout.labelX or 28, layout.labelY, layout.labelWidth or 650, 18, layout.labelSize or 13)
		local selected = tostring(selectedValue or "")
		local optionControls = { }
		local function sync(value, notify)
			selected = tostring(value or "")
			for _, entry in ipairs(optionControls) do
				entry.control.state = entry.value == selected
			end
			if notify and callback then callback(selected) end
		end
		local function addOption(choice, index)
			local value = tostring(choice.val or "")
			local column = (index - 1) % layout.columns
			local row = math.floor((index - 1) / layout.columns)
			local control
			control = new("CheckBoxControl"):CheckBoxControl(popupTopLeftAnchor(), {
				layout.x + column * layout.cellWidth,
				layout.y + row * layout.rowHeight,
				16,
			}, DisplayText.Native(choice.label), function(checked)
				if checked then
					sync(value, true)
				else
					-- These controls behave as a radio group: an active choice cannot
					-- be cleared by clicking it a second time.
					sync(selected, false)
				end
			end, choice.tooltip or tooltip, selected == value)
			control.labelRight = true
			control.labelWidth = math.max(40, layout.cellWidth - 23)
			control.choiceValue = value
			control.tooltipText = choice.tooltip or tooltip
			local suffix = tostring(choice.key or value):gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
			controls[key .. "_" .. suffix] = control
			optionControls[#optionControls + 1] = { value = value, control = control }
		end
		for index, choice in ipairs(choices) do addOption(choice, index) end
		sync(selected, false)
		return {
			SetValue = function(value, notify) sync(value, notify) end,
			GetValue = function() return selected end,
			SetEnabled = function(enabled)
				for _, entry in ipairs(optionControls) do entry.control.enabled = enabled end
			end,
		}
	end
	local function addEdit(key, label, y, width, pattern, maxLength, tooltip)
		addLabel(key .. "Label", label, 28, y + 2, 180, 20, 14)
		local control = new("EditControl"):EditControl(popupTopLeftAnchor(), { 218, y, width, 20 }, self.textValues[key], "", pattern, maxLength, function(value)
			writeField(key, value)
		end, nil, nil, true)
		control.tooltipText = tooltip
		controls[key] = control
		return control
	end
	local function addCompactFloorEdit(key, label, y, labelX, labelWidth, inputX, inputWidth, tooltip)
		addLabel("floor_" .. key .. "Label", label, labelX, y + 2, labelWidth, 18, 13)
		local control = new("EditControl"):EditControl(popupTopLeftAnchor(), { inputX, y, inputWidth, 20 }, self.textValues[key], "", "^%d%.%-,", 10, function(value)
			writeField(key, value)
		end, nil, nil, true)
		control.tooltipText = tooltip
		controls["floor_" .. key] = control
		return control
	end
	local function button(key, label, x, width, callback, y)
		controls[key] = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { x, y or 354, width, 24 }, label, callback)
		return controls[key]
	end
	local function currentClassName()
		local id = tonumber(self.textValues.baseClassId)
		local class = id and self.build.spec.tree.classes[id]
		return class and class.name or "class not selected"
	end
	local function activeSkillName()
		local groupIndex = parsePositiveIndex(self.textValues.targetSkillGroupIndex)
		local skillIndex = parsePositiveIndex(self.textValues.targetSkillIndex)
		local group = groupIndex and self.build.skillsTab.socketGroupList[groupIndex]
		local skill = group and skillIndex and group.displaySkillList and group.displaySkillList[skillIndex]
		local gem = self.build.data and self.build.data.gems and self.build.data.gems[tostring(self.textValues.targetSkillGemId or "")]
		return tostring(gem and gem.name or skill and (skill.name or skill.activeEffect and skill.activeEffect.grantedEffect and skill.activeEffect.grantedEffect.name) or "No active skill selected")
	end
	if page == 1 and not tostring(self.textValues.baseClassId or ""):match("^%d+$") then
		writeField("baseClassId", self.build.spec.curClassId or "")
		writeField("searchAllClasses", "false")
	end
	local titles = {
		[1] = "Choose class and planning stage",
		[2] = "Choose Main Skill and active gem",
		[3] = "Set damage, defense, and scenario preferences",
		[4] = isIntermediate and "Set conversion and search budget" or "Review before calculation",
		[5] = "Review before calculation",
	}
	local title = titles[page] or titles[reviewPage]
	local totalSteps = isIntermediate and 5 or 4
	addLabel("step", string.format("Step %d of %d — %s", page, totalSteps, title), 24, 32, 548, 26, 16)
	local phaseChoices = {
		{ val = "tree", label = "Tree foundation" },
		{ val = "skills", label = "Skills and supports" },
		{ val = "equipment", label = "Equipment" },
		{ val = "combined", label = "Combined search" },
	}
	local damageChoices = {
		{ val = "Auto", label = "Recommend from exact objective" },
		{ val = "PhysicalHit", label = "Physical hit" },
		{ val = "PhysicalImpale", label = "Physical hit + Impale" },
		{ val = "PhysicalDoT", label = "Physical DoT / Bleed" },
		{ val = "Fire", label = "Fire" }, { val = "Cold", label = "Cold" }, { val = "Lightning", label = "Lightning" },
		{ val = "ChaosPoison", label = "Chaos / Poison" }, { val = "Minions", label = "Minions" },
	}
	local defenseChoices = {
		{ val = "Auto", label = "Auto — PoB EHP when Defense first" }, { val = "Life", label = "Life" },
		{ val = "EnergyShield", label = "Energy Shield / CI" }, { val = "Hybrid", label = "Life + Energy Shield" },
		{ val = "Ward", label = "Ward buffer" }, { val = "Armour", label = "Armour" },
		{ val = "Evasion", label = "Evasion" }, { val = "Block", label = "Attack block" },
		{ val = "SpellBlock", label = "Spell block" }, { val = "SpellSuppression", label = "Spell suppression" },
	}
	local rankChoices = nativeChoiceLabels(rankingPriorityChoices)
	local selectedPhase = tostring(self.textValues.generationPhase or "tree")
	if page == 1 then
		if selectedPhase == "tree" or selectedPhase == "combined" then
			applyGuidedTreeBudget(self, self.textValues.treeBudgetMode or "level")
		end
		local classChoices = { }
		local classIds = { }
		for id in pairs(self.build.spec.tree.classes or { }) do classIds[#classIds + 1] = id end
		table.sort(classIds)
		for _, id in ipairs(classIds) do
			local class = self.build.spec.tree.classes[id]
			classChoices[#classChoices + 1] = { val = tostring(id), label = class.name }
		end
		local classGroup
		addChoice("phase", "Planning stage", 88, phaseChoices, selectedPhase, function(selected)
			prepareGenerationPhase(self, selected.val)
			writeField("generationPhase", selected.val)
			if selected.val ~= "tree" and selected.val ~= "combined" then
				local classId = tostring(self.build.spec.curClassId or "")
				writeField("baseClassId", classId)
				if classGroup then classGroup:SetValue(classId, false) end
				writeField("ascendancyId", "")
			else
				applyGuidedTreeBudget(self, self.textValues.treeBudgetMode or "level")
			end
		end, "Tree searches can choose a class root. Skills and Equipment stages stay on the active PoB class and require the relevant previous checkpoint.")
		classGroup = addCheckChoices("class", "Choose one PoE 1 class start", classChoices,
			self.textValues.baseClassId or self.build.spec.curClassId, {
				x = 32, y = 144, columns = 3, cellWidth = 214, rowHeight = 25,
				labelY = 119, labelWidth = 650,
			}, function(classId)
			writeField("baseClassId", classId)
			writeField("searchAllClasses", "false")
			writeField("ascendancyId", "")
		end, "Select one native PoB class start. The class cannot be typed or duplicated; Ascendancy remains Auto unless selected in Advanced options.")
		for index, classId in ipairs(classIds) do
			local option = controls["class_" .. tostring(classId)]
			if option then
				option.enabled = function()
					local phaseValue = tostring(self.textValues.generationPhase or "tree"):lower()
					return phaseValue == "tree" or phaseValue == "combined"
				end
			end
		end
		local treeBudgetChoices = {
			{ val = "level", label = "Allow the full PoB-legal point range (recommended)" },
			{ val = "local", label = "Focused search — at most 5 new points" },
			{ val = "custom", label = "Keep the custom Matrix limit" },
		}
		local treeBudgetMode = tostring(self.textValues.treeBudgetMode or "level"):lower()
		local knownTreeBudgetMode = false
		for _, option in ipairs(treeBudgetChoices) do if option.val == treeBudgetMode then knownTreeBudgetMode = true break end end
		if not knownTreeBudgetMode then treeBudgetMode = "custom" end
		local treeBudget = addChoice("treeBudget", "Passive tree scope", 218, treeBudgetChoices, treeBudgetMode, function(selected)
			applyGuidedTreeBudget(self, selected.val)
		end, "This is a ceiling, not a target: a candidate may use fewer points. Manual level uses PoB's native level and quest allowance. Auto level allows up to the strict cap and PoB estimates/checks every candidate. The exact point gate rejects illegal trees; the current Matrix total-point cap remains in force.")
		treeBudget.enabled = function()
			local phaseValue = tostring(self.textValues.generationPhase or "tree"):lower()
			return phaseValue == "tree" or phaseValue == "combined"
		end
		addLabel("classHint", "Ascendancy stays on Auto. PoB validates the selected class start, level, quest allowance, requirements and every candidate.", 28, 256, 650, 38, 13)
	elseif page == 2 then
		local skillOptions = { }
		for groupIndex, group in ipairs(self.build.skillsTab.socketGroupList or { }) do
			if group.enabled ~= false and group.slotEnabled ~= false then
				for skillIndex, skill in ipairs(group.displaySkillList or { }) do
					if skill.activeEffect then
						local gemId = SkillCatalog.CurrentMainGemId(self.build, groupIndex, skillIndex)
						if gemId then
							local name = skill.name or skill.activeEffect.grantedEffect and skill.activeEffect.grantedEffect.name or "Active skill"
							skillOptions[#skillOptions + 1] = { val = tostring(groupIndex) .. ":" .. tostring(skillIndex), label = (group.displayLabel or group.label or ("Group " .. groupIndex)) .. " — " .. name,
								groupIndex = groupIndex, skillIndex = skillIndex, gemId = gemId }
						end
					end
				end
			end
		end
		local hasSkillOptions = #skillOptions > 0
		if not hasSkillOptions then skillOptions[1] = { val = "", label = "No enabled active skill group" } end
		local selectedGroup = parsePositiveIndex(self.textValues.targetSkillGroupIndex)
		local selectedIndex = parsePositiveIndex(self.textValues.targetSkillIndex)
		local selectedSkillValue = ""
		for _, option in ipairs(skillOptions) do
			if option.groupIndex == selectedGroup and option.skillIndex == selectedIndex then selectedSkillValue = option.val break end
		end
		if hasSkillOptions and selectedSkillValue == "" then
			table.insert(skillOptions, 1, { val = "", label = "Choose an enabled active skill" })
		end
		local skillControl = addChoice("skill", "Active skill slot", 88, skillOptions, selectedSkillValue, function(selected)
			if selected.groupIndex then
				writeField("targetSkillGroupIndex", selected.groupIndex)
				writeField("targetSkillIndex", selected.skillIndex)
				writeField("targetSkillGemId", selected.gemId)
				controls.gem:SelByValue(selected.gemId, "val")
			end
		end, "Choose an enabled socket group and native active skill slot. The optimizer uses this as the Main Skill direction; the exact PoB calculation still decides legality and metrics.")
		skillControl.enabled = hasSkillOptions
		local catalog = SkillCatalog.ListActive(self.build, "", 1000)
		local gemOptions = { }
		for _, gem in ipairs(catalog and catalog.gems or { }) do
			local variant = gem.variantId ~= "" and gem.variantId ~= gem.name and (" (" .. gem.variantId .. ")") or ""
			gemOptions[#gemOptions + 1] = { val = gem.id, label = gem.name .. variant, searchFilter = gem.name .. " " .. gem.variantId }
		end
		local chosenGem = tostring(self.textValues.targetSkillGemId or "")
		local hasGemOptions = #gemOptions > 0
		if chosenGem ~= "" then
			local found = false
			for _, gem in ipairs(gemOptions) do if gem.val == chosenGem then found = true break end end
			if not found then chosenGem = "" end
		end
		if not hasGemOptions then gemOptions[1] = { val = "", label = catalog and "No active gems in loaded PoB data" or "PoB active gem catalog unavailable" }
		elseif chosenGem == "" then table.insert(gemOptions, 1, { val = "", label = "Choose an active PoE 1 gem" }) end
		local gemControl = addChoice("gem", "Planning gem", 132, gemOptions, chosenGem, function(selected)
			writeField("targetSkillGemId", selected.val)
		end, "This selects a PoE 1 active gem from the loaded PoB data. A different gem is only a calculation proposal until a feasible Skills-stage candidate is explicitly applied.")
		gemControl.enabled = hasGemOptions
		addLabel("skillHint", "Changing the gem does not edit the active build. Use the Skills checkpoint to install it, then prepare compatible gear if needed.", 28, 182, 650, 42, 13)
		controls.createSeed = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 28, 236, 286, 24 }, "Create separate PoB skill-set seed", function()
			local selected = controls.gem:GetSelValue()
			if not selected or not selected.val then return end
			local created, seedError = SkillSeed.Create(self.build, selected.val, tonumber(self.textValues.baseClassId))
			if not created then
				self.statusMessage = seedError or "PoB could not create the skill-set seed."
				return
			end
			self:FinalizeBuildContext()
			self.statusMessage = created.message
			self:RefreshReadiness(true)
			main:ClosePopup(popup)
			self:OpenGuidedSetup(profile, 3)
		end)
		controls.createSeed.tooltipText = "Explicitly creates a separate native PoB skill-set variation and exact-calculates its legal gem level. The previous skill set stays available through PoB's ordinary Undo; nothing is created merely by selecting a gem."
		controls.createSeed.enabled = function()
			local selected = controls.gem:GetSelValue()
			local currentGemId = SkillCatalog.CurrentMainGemId(self.build,
				parsePositiveIndex(self.textValues.targetSkillGroupIndex), parsePositiveIndex(self.textValues.targetSkillIndex))
			return gemControl:IsEnabled() and selected and selected.val and selected.val ~= ""
				and tostring(currentGemId or "") ~= tostring(selected.val)
		end
	elseif page == 3 then
		addChoice("damageFocus", "Damage route", 88, damageChoices, self.textValues.damageFocus or "Auto", function(selected)
			writeField("damageFocus", selected.val)
		end, "A preference for route generation. Physical hit, Impale, DoT, elemental, chaos/poison and minion routes stay distinct; exact PoB output decides results.")
		addChoice("defenseProfile", "Defense focus", 128, defenseChoices, self.textValues.defenseProfile or "Auto", function(selected)
			writeField("defenseProfile", selected.val)
		end, "Ranks by the selected exact PoB defensive output when Defense first is selected. This is a preference; strict minimums belong in the Matrix.")
		addChoice("rankingPriority", "Rank candidates", 168, rankChoices, self.textValues.rankingPriority or "ObjectiveFirst", function(selected)
			writeField("rankingPriority", selected.val)
		end, "Sets lexicographic order only after every exact PoB hard gate passes. It does not replace minimum requirements.")
		addChoice("scenario", "Calculation profile", 208, nativeChoiceLabels(fieldChoices.scenarioProfile), self.textValues.scenarioProfile or "Current", function(selected)
			writeField("scenarioProfile", selected.val)
			local options = enemyPresetChoices(selected.val)
			local currentEnemy = tostring(self.textValues.scenarioEnemyPreset or "Active")
			local allowed = false
			for _, option in ipairs(options) do if option.val == currentEnemy then allowed = true break end end
			if not allowed then currentEnemy = "Active"; writeField("scenarioEnemyPreset", currentEnemy) end
			controls.enemy:SetList(nativeChoiceLabels(options))
			controls.enemy:ResetSearch()
			controls.enemy:SelByValue(currentEnemy, "val")
		end, "Current uses the selected PoB configuration. Pinnacle profiles turn off defined flask/kill/manual states, but do not simulate generated charges or hit-derived uptime.")
		local enemyChoices = enemyPresetChoices(tostring(self.textValues.scenarioProfile or "Current"))
		local enemy = tostring(self.textValues.scenarioEnemyPreset or "Active")
		local validEnemy = false
		for _, option in ipairs(enemyChoices) do if option.val == enemy then validEnemy = true break end end
		if not validEnemy then enemy = "Active"; writeField("scenarioEnemyPreset", enemy) end
		addChoice("enemy", "PoB enemy setting", 248, enemyChoices, enemy, function(selected)
			writeField("scenarioEnemyPreset", selected.val)
		end, "Enemy choice comes from PoB's native ConfigOptions. It is separate from the scenario's flask and condition policy.")
		addLabel("preferenceHint", "Hard floors, conversion locks, and search budgets stay in Advanced Matrix. Blank floors never imply a guarantee.", 28, 280, 650, 38, 13)
		controls.matrix = button("matrix", "Advanced Matrix", 124, 150, function()
			main:ClosePopup(popup)
			self.innerView = "matrix"
		end)
	elseif page == 4 and isIntermediate then
		local conversionChoices = {
			{ val = "", key = "None", label = "No hard conversion route" },
			{ val = "Physical>Lightning", label = "Physical → Lightning" },
			{ val = "Physical>Cold", label = "Physical → Cold" },
			{ val = "Physical>Fire", label = "Physical → Fire" },
			{ val = "Physical>Lightning>Cold", label = "Physical → Lightning → Cold" },
			{ val = "Physical>Cold>Fire", label = "Physical → Cold → Fire" },
			{ val = "Lightning>Cold", label = "Lightning → Cold" },
			{ val = "Lightning>Cold>Fire", label = "Lightning → Cold → Fire" },
			{ val = "Cold>Fire", label = "Cold → Fire" },
		}
		local route = tostring(self.textValues.conversionRoute or "")
		local routeKnown = false
		for _, option in ipairs(conversionChoices) do if option.val == route then routeKnown = true break end end
		if route ~= "" and not routeKnown then conversionChoices[#conversionChoices + 1] = { val = route, label = route .. " (saved; verify in Advanced)" } end
		addCheckChoices("conversion", "Optional exact conversion chain — choose one", conversionChoices, route, {
			x = 32, y = 94, columns = 3, cellWidth = 214, rowHeight = 21,
			labelY = 72, labelWidth = 650,
		}, function(value)
			writeField("conversionRoute", value)
			if value ~= "" and tostring(self.textValues.conversionMin or "") == "" then writeField("conversionMin", "100") end
		end, "Selecting a route creates a strict conversion requirement using PoB's exact conversion output. It does not force PoB to invent a conversion source.")
		addEdit("conversionMin", "Minimum each edge (%)", 180, 130, "^%d%.%-,", 6, "The minimum for every selected conversion edge; Inputs.Parse enforces 0–100%.")
		addEdit("maxTotalPoints", "Passive point cap", 208, 130, "^%d", 3, "Solver search cap, 1–130. PoB also enforces the native character/quest point limit.")
		addEdit("evaluationBudget", "Exact evaluations", 236, 130, "^%d", 5, "Maximum candidates recalculated by the exact PoB engine, 1–10,000. This is search compute, not currency.")
		addLabel("budgetHint", "Currency budget and item prices are configured separately under Market budget. A finite search budget cannot prove global infeasibility.", 28, 266, 650, 36, 13)
	elseif page == reviewPage then
		local parsed, parseError = Inputs.Parse(self.textValues)
		local hardFloors = { }
		for _, definition in ipairs(Inputs.metricDefinitions or { }) do
			local constraint = parsed and parsed.hard and parsed.hard[definition.key]
			if constraint then
				hardFloors[#hardFloors + 1] = string.format("%s %s %s%s", definition.label,
					constraint.operator or ">=", tostring(constraint.value), definition.unit ~= "" and (" " .. definition.unit) or "")
			end
		end
		local hardSummary = #hardFloors > 0 and table.concat(hardFloors, "; ")
			or "No strict metric floors — ranking only; no minimum performance is guaranteed."
		if parsed and parsed.conversion and #(parsed.conversion.route or { }) > 0 then
			hardSummary = hardSummary .. string.format("\nConversion: %s · each edge >= %s%%", table.concat(parsed.conversion.route, " → "), tostring(parsed.conversion.minPercent))
		end
		local currencyBudget = parsed and parsed.search and parsed.search.currencyBudget
		local marketBudgetSummary = "no market currency cap"
		if currencyBudget and currencyBudget.amount ~= nil then
			marketBudgetSummary = "market cap " .. tostring(currencyBudget.amount) .. " " .. tostring(currencyBudget.unit or "Chaos")
		end
		local summary = string.format("Class: %s\nStage: %s · Main Skill gem: %s\nOffense: %s · objective: %s\nDefense: %s · ranking: %s\nScenario: %s · enemy: %s\nSearch: %s exact PoB evaluations · total cap %s · max new %s (ceiling)\nBudget: %s · exact-evaluation budget is compute, not currency\nHard constraints: %s",
			currentClassName(), tostring(self.textValues.generationPhase or "tree"), activeSkillName(), tostring(self.textValues.damageFocus or "Auto"),
			tostring(self.textValues.objectiveMetric or "CombinedDPS"), tostring(self.textValues.defenseProfile or "Auto"), tostring(self.textValues.rankingPriority or "ObjectiveFirst"),
			tostring(self.textValues.scenarioProfile or "Current"), tostring(self.textValues.scenarioEnemyPreset or "Active"),
			tostring(self.textValues.evaluationBudget or "120"), tostring(self.textValues.maxTotalPoints or "120"),
			tostring(self.textValues.maxAddedPoints or "5"), marketBudgetSummary,
			parseError and ("Matrix needs correction: " .. parseError) or hardSummary)
		controls.summary = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 28, 78, 656, 238 }, DisplayText.Native(summary))
		setClippedPopupLabel(controls.summary, 656, 14)
		controls.run = button("run", "Run exact PoB optimizer", 444, 176, function()
			local checked, errorMessage = Inputs.Parse(self.textValues)
			if not checked then
				self.statusMessage = "Invalid Matrix: " .. tostring(errorMessage)
				main:ClosePopup(popup)
				self.innerView = "matrix"
				return
			end
			main:ClosePopup(popup)
			self.innerView = "matrix"
			self:RunOptimizer()
		end)
		controls.run.enabled = parsed ~= nil
		controls.run.tooltipText = "Starts the existing bounded search. Every proposed candidate is evaluated by PoB and checked against strict Matrix floors; no result is applied automatically."
		button("matrix", "Edit hard floors", 24, 150, function() main:ClosePopup(popup); self.innerView = "matrix" end)
		addLabel("reviewHint", "The exact calculator decides legality and metrics. Apply remains a separate, explicit action after candidate review.", 28, 322, 656, 26, 13)
	else
		addLabel("unavailable", "This guided step is unavailable. Close and restart setup, or use Advanced options.", 28, 92, 650, 42, 14)
	end

	local closeX = 594
	controls.back = button("back", "Back", page == reviewPage and 184 or 24, 92, function() advance(math.max(1, page - 1)) end)
	controls.back.enabled = page > 1
	if page < reviewPage then
		button("next", "Next", closeX, 90, function() advance(page + 1) end)
		if page == 2 then
			controls.next.enabled = parsePositiveIndex(self.textValues.targetSkillGroupIndex) ~= nil
			controls.next.tooltipText = "Select an existing active skill slot or create a separate PoB skill-set seed before continuing."
		end
	end
	controls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 594, 10, 90, 22 }, "Close", function() main:ClosePopup(popup) end)
	local heading = isIntermediate and "Intermediate setup" or "Beginner setup"
	popup = main:OpenPopup(720, 400, DisplayText.Native("AI Planner — " .. heading), controls,
		page < reviewPage and "next" or "run", page == 1 and "phase" or nil, "close")
	return popup
end

function OptimizerTabClass:OpenBuildDirection()
	local controls = { }
	local selectedClassId
	local refreshAscendancyOptions
	controls.intro = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 14, 410, 32 }, "^8Choose a phase, class, Main Skill and preferred build profile.")
	setClippedPopupLabel(controls.intro, 410, 13)
	local phaseChoices = {
		{ val = "tree", label = DisplayText.Native("1 · Tree foundation") },
		{ val = "skills", label = DisplayText.Native("2 · Skills and supports") },
		{ val = "equipment", label = DisplayText.Native("3 · Equipment") },
		{ val = "combined", label = DisplayText.Native("Combined search") },
	}
	local phaseChoice = phaseChoices[1]
	for _, choice in ipairs(phaseChoices) do
		if choice.val == tostring(self.textValues.generationPhase or "tree"):lower() then phaseChoice = choice break end
	end
	prepareGenerationPhase(self, phaseChoice.val)
	controls.phaseLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 442, 14, 54, 18 }, "^7Phase:")
	controls.phase = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 502, 10, 194, 20 }, phaseChoices, function(_, selected)
		if not selected then return end
		prepareGenerationPhase(self, selected.val)
		if selected.val ~= "tree" and selected.val ~= "combined" then selectedClassId = self.build.spec.curClassId end
		if refreshAscendancyOptions then refreshAscendancyOptions(selectedClassId, self.textValues.ascendancyId) end
		self.modFlag = true
	end)
	controls.phase:SelByValue(phaseChoice.val, "val")
	controls.phase.enableDroppedWidth = true
	controls.phase.tooltipText = "Tree foundation starts from the selected PoB class root and holds skills/equipment fixed. Skills tests gem variants against the applied tree. After applying Skills, the Planner saves an exact checkpoint and asks before selecting Equipment. Equipment then tests item/anoint changes against the applied tree and gems. Combined retains the mixed search. Every candidate uses the exact PoB calculator."
	local classIds = { }
	for classId in pairs(self.build.spec.tree.classes or { }) do classIds[#classIds + 1] = classId end
	table.sort(classIds)
	self.directionClassControls = { }
	selectedClassId = tonumber(self.textValues.baseClassId) or self.build.spec.curClassId
	local searchAllClasses = self.textValues.searchAllClasses == true or tostring(self.textValues.searchAllClasses):lower() == "true"
	self.directionSelectedClassId = selectedClassId
	for index, classId in ipairs(classIds) do
		local class = self.build.spec.tree.classes[classId]
		local column = (index - 1) % 4
		local row = math.floor((index - 1) / 4)
		local box = new("CheckBoxControl"):CheckBoxControl(popupTopLeftAnchor(), { 30 + column * 164, 58 + row * 28, 18 }, DisplayText.Native(class.name), function()
			selectedClassId = classId
			self.directionSelectedClassId = classId
			searchAllClasses = false
			self.textValues.searchAllClasses = false
			if self.directionAllClassesControl then self.directionAllClassesControl.state = false end
			self.textValues.baseClassId = tostring(classId)
			self.textValues.ascendancyId = ""
			for optionId, option in pairs(self.directionClassControls) do option.state = optionId == classId end
			if refreshAscendancyOptions then refreshAscendancyOptions(classId, "") end
			self.modFlag = true
		end, nil, not searchAllClasses and selectedClassId == classId)
		box.labelRight = true
		box.labelWidth = 136
		box.enabled = function()
			local phase = tostring(self.textValues.generationPhase or "tree"):lower()
			return phase == "tree" or phase == "combined"
		end
		self.directionClassControls[classId] = box
		controls["class_" .. tostring(classId)] = box
	end
	controls.allClasses = new("CheckBoxControl"):CheckBoxControl(popupTopLeftAnchor(), { 30, 112, 18 }, "Search all seven classes (equal exact-evaluation budgets)", function(state)
		searchAllClasses = state
		self.textValues.searchAllClasses = state
		self.textValues.baseClassId = state and "" or tostring(selectedClassId)
		self.textValues.ascendancyId = ""
		for classId, option in pairs(self.directionClassControls) do option.state = not state and classId == selectedClassId end
		if refreshAscendancyOptions then refreshAscendancyOptions(selectedClassId, "") end
		self.modFlag = true
	end, "The total exact-evaluation budget is divided evenly across native class starts. Any selected existing-item overrides, skill set, configuration, and character level remain the same for every class. This is a bounded comparison, not a proof of a global optimum.", searchAllClasses)
	controls.allClasses.labelRight = true
	controls.allClasses.labelWidth = 420
	controls.allClasses.enabled = function()
		local phase = tostring(self.textValues.generationPhase or "tree"):lower()
		return phase == "tree" or phase == "combined"
	end
	self.directionAllClassesControl = controls.allClasses

	local skillOptions = { }
	for groupIndex, group in ipairs(self.build.skillsTab.socketGroupList or { }) do
		if group.enabled ~= false and group.slotEnabled ~= false then
			for skillIndex, skill in ipairs(group.displaySkillList or { }) do
				if skill.activeEffect then
					local sourceGemId = SkillCatalog.CurrentMainGemId(self.build, groupIndex, skillIndex)
					if sourceGemId then
						local groupName = group.displayLabel or group.label or ("Group " .. tostring(groupIndex))
						local skillName = skill.name or (skill.activeEffect.grantedEffect and skill.activeEffect.grantedEffect.name) or "Active skill"
						skillOptions[#skillOptions + 1] = {
							label = DisplayText.Native(tostring(groupName) .. " — " .. tostring(skillName)),
							groupIndex = groupIndex,
							skillIndex = skillIndex,
							sourceGemId = sourceGemId,
						}
					end
				end
			end
		end
	end
	controls.skillLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 137, 105, 18 }, "^7Main skill:")
	controls.skill = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 136, 134, 556, 20 }, skillOptions, function(_, selected)
		if selected then
			self.textValues.targetSkillGroupIndex = tostring(selected.groupIndex)
			self.textValues.targetSkillIndex = tostring(selected.skillIndex)
			self.directionSkillSelection = selected.label
			local currentGemId = SkillCatalog.CurrentMainGemId(self.build, selected.groupIndex, selected.skillIndex)
			if currentGemId then
				self.textValues.targetSkillGemId = currentGemId
				if controls.targetGem then controls.targetGem:SelByValue(currentGemId, "val") end
			end
			self.modFlag = true
		end
	end)
	controls.skill.enableDroppedWidth = true
	controls.skill.tooltipText = "Select the enabled socket group and active effect whose gem slot will be the Main Skill direction. The chosen gem below replaces this slot only inside isolated exact PoB calculations."
	local targetGroup = parsePositiveIndex(self.textValues.targetSkillGroupIndex)
	local targetIndex = parsePositiveIndex(self.textValues.targetSkillIndex)
	local selectedSkillIndex
	for index, option in ipairs(skillOptions) do
		if option.groupIndex == targetGroup and option.skillIndex == targetIndex then selectedSkillIndex = index break end
	end
	if not selectedSkillIndex then selectedSkillIndex = 1 end
	if #skillOptions > 0 then
		controls.skill:SetSel(selectedSkillIndex, true)
		local option = skillOptions[selectedSkillIndex]
		self.textValues.targetSkillGroupIndex = tostring(option.groupIndex)
		self.textValues.targetSkillIndex = tostring(option.skillIndex)
		self.directionSkillSelection = DisplayText.Native(option.label)
	else
		self.textValues.targetSkillGroupIndex = ""
		self.textValues.targetSkillIndex = ""
		controls.skill:SetList({ "No enabled active skill" })
	end
	controls.skill.tooltipText = controls.skill.tooltipText .. " In the Skills phase, only gem level/quality/variant proposals are changed; the passive tree and equipped items stay fixed. In the Equipment phase, the selected skill is only the scoring context."

	local catalog, catalogError = SkillCatalog.ListActive(self.build, "", 1000)
	local gemOptions = { }
	if catalog then
		for _, gem in ipairs(catalog.gems) do
		local variantLabel = gem.variantId ~= "" and gem.variantId ~= gem.name and (" (" .. gem.variantId .. ")") or ""
			gemOptions[#gemOptions + 1] = {
				val = gem.id,
				label = DisplayText.Native(gem.name .. variantLabel),
				searchFilter = gem.name .. " " .. gem.variantId .. " " .. gem.gameId,
			}
		end
	end
	controls.gemLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 165, 105, 18 }, "^7Choose gem:")
	controls.targetGem = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 136, 162, 556, 20 }, gemOptions, function(_, selected)
		if selected then
			self.textValues.targetSkillGemId = selected.val
			self.modFlag = true
		end
	end)
	controls.targetGem.enableDroppedWidth = true
	controls.targetGem.enabled = function() return #gemOptions > 0 end
	controls.targetGem.tooltipText = "Choose an active gem from this PoB version's loaded database. Tree and Skills may calculate it as an unlinked planning context, which is not playable. Apply a feasible Skills checkpoint to install the chosen gem; then use Equipment choices > Prepare skill gear to generate legal native sockets. Equipment and Combined require that gem to already be installed, so an applied result cannot silently keep a different skill. Existing linked items still require the correct PoB socket color."
	local selectedGemId = tostring(self.textValues.targetSkillGemId or "")
	local selectedGemIndex
	for index, option in ipairs(gemOptions) do
		if option.val == selectedGemId then selectedGemIndex = index break end
	end
	if not selectedGemIndex then
		local groupIndex = parsePositiveIndex(self.textValues.targetSkillGroupIndex)
		local skillIndex = parsePositiveIndex(self.textValues.targetSkillIndex)
		selectedGemId = SkillCatalog.CurrentMainGemId(self.build, groupIndex, skillIndex) or ""
		for index, option in ipairs(gemOptions) do
			if option.val == selectedGemId then selectedGemIndex = index break end
		end
	end
	if #gemOptions > 0 then
		controls.targetGem:SetSel(selectedGemIndex or 1, true)
		self.textValues.targetSkillGemId = #skillOptions > 0 and controls.targetGem:GetSelValue().val or ""
	else
		controls.targetGem:SetList({ "No loaded active skill gems" })
		controls.targetGem.enabled = false
		self.textValues.targetSkillGemId = ""
	end
	controls.skill.tooltipText = controls.skill.tooltipText .. " The gem selector uses native loaded data and stable internal IDs; the exact calculation must resolve the selected gem/effect identity or the candidate is rejected."

	local function buildAscendancyOptions(classId)
		local choices = { { val = "", label = DisplayText.Native("Auto — compare legal ascendancies") } }
		local class = self.build.spec.tree.classes[tonumber(classId) or -1]
		local entries = { }
		for id, ascendancy in pairs(class and class.classes or { }) do
			if type(id) == "number" and id > 0 and ascendancy and ascendancy.startNodeId then
			entries[#entries + 1] = { id = id, name = DisplayText.Native(ascendancy.name or ascendancy.id or ("Ascendancy " .. tostring(id))) }
			end
		end
		table.sort(entries, function(a, b) return a.name < b.name end)
		for _, entry in ipairs(entries) do
			choices[#choices + 1] = { val = tostring(entry.id), label = entry.name }
		end
		return choices
	end
	controls.ascendancyLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 193, 105, 18 }, "^7Ascendancy:")
	controls.ascendancy = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 136, 190, 556, 20 },
		nativeChoiceLabels(buildAscendancyOptions(selectedClassId)), function(_, selected)
			if selected then
				self.textValues.ascendancyId = selected.val
				self.modFlag = true
			end
		end)
	controls.ascendancy.enableDroppedWidth = true
	controls.ascendancy.enabled = function()
		local phase = tostring(self.textValues.generationPhase or "tree"):lower()
		return not searchAllClasses and (phase == "tree" or phase == "combined")
	end
	controls.ascendancy.tooltipText = "Auto compares legal main ascendancies. Selecting one locks the Tree search to this PoB-native ascendancy and evaluates combinations of its allocated routes with passive-tree routes."
	refreshAscendancyOptions = function(classId, requestedId)
		local options = nativeChoiceLabels(buildAscendancyOptions(classId))
		controls.ascendancy:SetList(options)
		local wanted = tostring(requestedId or "")
		local found = false
		for index, option in ipairs(options) do
			if option.val == wanted then
				controls.ascendancy:SetSel(index, true)
				found = true
				break
			end
		end
		if not found then
			controls.ascendancy:SetSel(1, true)
			self.textValues.ascendancyId = ""
		end
	end
	refreshAscendancyOptions(selectedClassId, self.textValues.ascendancyId)

	local budgetLevel = tonumber(self.build.characterLevel) or 1
	if self.build.characterLevelAutoMode and self.build.GetEstimatedLevelForPoints then
		local pointsUsed = self.build.spec:CountAllocNodes()
		local extra = self.build.calcsTab.mainOutput and self.build.calcsTab.mainOutput.ExtraPoints or 0
		budgetLevel = self.build:GetEstimatedLevelForPoints(pointsUsed, extra)
	end
	local maximumAscendancyBudget = Inputs.MaxAscendancyPointBudget(budgetLevel)
	local ascendancyBudgetChoices = {
		{ val = "auto", label = DisplayText.Native("Auto — up to " .. tostring(maximumAscendancyBudget) .. " per ascendancy") },
	}
	local ascendancyBudgetIndex = 1
	for budget = 0, maximumAscendancyBudget, 2 do
		ascendancyBudgetChoices[#ascendancyBudgetChoices + 1] = { val = tostring(budget), label = tostring(budget) .. " points per ascendancy" }
	end
	local requestedAscendancyBudget = tostring(self.textValues.ascendancyPointBudget or "auto")
	local budgetChoiceFound = false
	for index, choice in ipairs(ascendancyBudgetChoices) do
		if choice.val == requestedAscendancyBudget then
			ascendancyBudgetIndex = index
			budgetChoiceFound = true
			break
		end
	end
	if not budgetChoiceFound then
		requestedAscendancyBudget = "auto"
		self.textValues.ascendancyPointBudget = requestedAscendancyBudget
		ascendancyBudgetIndex = 1
	end
	controls.ascendancyBudgetLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 398, 126, 18 }, "^7Ascendancy points:")
	controls.ascendancyBudget = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 152, 394, 220, 22 },
		ascendancyBudgetChoices, function(_, selected)
			if selected then
				self.textValues.ascendancyPointBudget = selected.val
				self.modFlag = true
			end
		end)
	controls.ascendancyBudget:SetSel(ascendancyBudgetIndex, true)
	controls.ascendancyBudget.enableDroppedWidth = true
	controls.ascendancyBudget.tooltipText = "Caps primary and secondary ascendancy routes independently. Auto uses a conservative PoE level progression ceiling: 0 before level 33, then 2/4/6/8 points from levels 33/40/50/68. PoB does not store Labyrinth quest completion; lower the cap when a Labyrinth is not complete. The active character level remains the PoB level and is not changed by applying a result."
	controls.ascendancyBudgetHint = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 384, 396, 312, 20 },
		DisplayText.Native("^8PoB " .. (self.build.characterLevelAutoMode and "estimated level " or "level ")
			.. tostring(budgetLevel) .. " · ceiling " .. tostring(maximumAscendancyBudget) .. " points"))
	setClippedPopupLabel(controls.ascendancyBudgetHint, 312, 13)
	controls.useImportedRoutes = new("CheckBoxControl"):CheckBoxControl(popupTopLeftAnchor(), { 24, 414, 16 },
		DisplayText.Native("Use compatible imported route evidence"), function(checked)
		self.textValues.useImportedRouteMemory = checked and "true" or "false"
		self.nodeEvidence = nil
		self.modFlag = true
		self:RefreshReadiness(true)
	end, "Only prioritizes nodes when local observations match the same skill, class and exact PoB data version. It never relaxes a hard gate or replaces exact PoB calculations.",
		tostring(self.textValues.useImportedRouteMemory or "true"):lower() == "true")
	controls.useImportedRoutes.labelRight = true
	controls.useImportedRoutes.labelWidth = 388
	controls.useImportedRoutes.tooltipText = "Imported route observations are optional search guidance. Exact PoB evaluation remains authoritative."

	controls.objectiveLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 356, 62, 18 }, "^7Optimize:")
	controls.objectiveMetric = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 88, 352, 170, 22 }, nativeChoiceLabels(fieldChoices.objectiveMetric), function(_, selected)
		if selected then
			self.textValues.objectiveMetric = selected.val
			local matrixControl = self.controls["text_objectiveMetric"]
			if matrixControl then setFieldControl(matrixControl, selected.val) end
			self.modFlag = true
		end
	end)
	controls.objectiveMetric:SelByValue(tostring(self.textValues.objectiveMetric or "CombinedDPS"), "val")
	controls.objectiveMetric.enableDroppedWidth = true
	controls.objectiveMetric.tooltipText = "This is the ranking objective, not a guarantee. The optimizer still enforces every Matrix hard limit using exact PoB values. Choose TotalEHP to rank by the engine's effective hit pool; it is not a substitute for separate max-hit and resource gates."
	controls.scenarioLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 270, 356, 60, 18 }, "^7Profile:")
	controls.scenarioProfile = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 332, 352, 170, 22 }, nativeChoiceLabels(fieldChoices.scenarioProfile), function(_, selected)
		if selected then
			self.textValues.scenarioProfile = selected.val
			local matrixControl = self.controls["text_scenarioProfile"]
			if matrixControl then setFieldControl(matrixControl, selected.val) end
			local nextChoices = enemyPresetChoices(selected.val)
			local enemyValue = tostring(self.textValues.scenarioEnemyPreset or "Active")
			local isAllowed = false
			for _, choice in ipairs(nextChoices) do if choice.val == enemyValue then isAllowed = true break end end
			if not isAllowed then enemyValue = "Active" end
			self.textValues.scenarioEnemyPreset = enemyValue
			controls.enemyPreset:SetList(nativeChoiceLabels(nextChoices))
			controls.enemyPreset:ResetSearch()
			controls.enemyPreset:SelByValue(enemyValue, "val")
			self.modFlag = true
		end
	end)
	controls.scenarioProfile:SelByValue(tostring(self.textValues.scenarioProfile or "Current"), "val")
	controls.scenarioProfile.enableDroppedWidth = true
	controls.scenarioProfile.tooltipText = "This controls the calculation policy. Current preserves the active configuration and flask state. Pinnacle unbuffed disables regular flasks/tinctures, kill states and manual charge/event stacks. Pinnacle chassis also removes Guard buffs, manual ailment/enemy overrides and custom modifiers. Choose the enemy tier separately in the Enemy selector; all tiers use native PoB ConfigOptions. Generated-charge and hit-derived ailment uptime are not simulated."
	controls.enemyLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 514, 356, 48, 18 }, "^7Enemy:")
	local initialEnemyChoices = enemyPresetChoices(tostring(self.textValues.scenarioProfile or "Current"))
	local initialEnemyValue = tostring(self.textValues.scenarioEnemyPreset or "Active")
	local initialEnemyAllowed = false
	for _, choice in ipairs(initialEnemyChoices) do if choice.val == initialEnemyValue then initialEnemyAllowed = true break end end
	if not initialEnemyAllowed then initialEnemyValue = "Active" end
	self.textValues.scenarioEnemyPreset = initialEnemyValue
	controls.enemyPreset = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 564, 352, 132, 22 }, nativeChoiceLabels(initialEnemyChoices), function(_, selected)
		if selected then
			self.textValues.scenarioEnemyPreset = selected.val
			self.modFlag = true
		end
	end)
	controls.enemyPreset:SelByValue(initialEnemyValue, "val")
	controls.enemyPreset.enableDroppedWidth = true
	controls.enemyPreset.tooltipText = "Native PoB enemyIsBoss choices: active setting, no boss, standard boss, Pinnacle, or Uber Pinnacle. For Current, Active preserves the selected PoB enemy option. For a Pinnacle profile, Active means the profile's standard Pinnacle target. This is independent of flask and condition policy."
	controls.enemyLevelLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 332, 382, 142, 18 }, "^7Enemy level (PoB):")
	controls.enemyLevel = new("EditControl"):EditControl(popupTopLeftAnchor(), { 474, 380, 82, 20 },
		tostring(self.textValues.scenarioEnemyLevel or ""), "", "^%d*$", 3, function(value)
			self.textValues.scenarioEnemyLevel = value
			local matrixControl = self.controls["text_scenarioEnemyLevel"]
			if matrixControl then setFieldControl(matrixControl, value) end
			self.modFlag = true
		end, nil, nil, true)
	controls.enemyLevel.tooltipText = "Optional level written to the isolated native PoB enemyLevel configuration field (1 to "
		.. tostring(data and data.misc and data.misc.MaxEnemyLevel or 85)
		.. "). Leave blank to preserve PoB's selected enemy default. It does not supply area-specific monster stats."

	local damageFocusChoices = {
		{ val = "Auto", label = "Auto — follow exact objective" },
		{ val = "PhysicalHit", label = "Physical hit" },
		{ val = "PhysicalImpale", label = "Physical + Impale" },
		{ val = "PhysicalDoT", label = "Physical DoT / Bleed" },
		{ val = "Fire", label = "Fire" },
		{ val = "Cold", label = "Cold" },
		{ val = "Lightning", label = "Lightning" },
		{ val = "ChaosPoison", label = "Chaos / Poison" },
		{ val = "Minions", label = "Minions" },
	}
	local defenseProfileChoices = {
		{ val = "Auto", label = "Auto — PoB EHP when Defense first" },
		{ val = "Life", label = "Life" },
		{ val = "EnergyShield", label = "Energy Shield / CI" },
		{ val = "Hybrid", label = "Life + Energy Shield" },
		{ val = "Ward", label = "Ward buffer" },
		{ val = "Armour", label = "Armour" },
		{ val = "Evasion", label = "Evasion" },
		{ val = "Block", label = "Attack block" },
		{ val = "SpellBlock", label = "Spell block" },
		{ val = "SpellSuppression", label = "Spell suppression" },
	}
	local rankChoices = nativeChoiceLabels(rankingPriorityChoices)
	controls.damageFocusLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 308, 96, 18 }, "^7Damage focus:")
	controls.damageFocus = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 124, 304, 250, 20 }, nativeChoiceLabels(damageFocusChoices), function(_, selected)
		if selected then
			self.textValues.damageFocus = selected.val
			self.modFlag = true
		end
	end)
	controls.damageFocus:SelByValue(tostring(self.textValues.damageFocus or "Auto"), "val")
	controls.damageFocus.enableDroppedWidth = true
	controls.damageFocus.tooltipText = "Guides proposal generation and exact ranking when PoB exposes a matching native metric. Fire/Cold/Lightning use PoB's exact average hit by damage type (not a separate elemental DPS total); total Combined DPS remains the hard-floor metric. This preference does not force damage conversion. Physical + Impale uses PoB's exact ImpaleDPS output."
	controls.defenseProfileLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 392, 308, 92, 18 }, "^7Defense:")
	controls.defenseProfile = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 484, 304, 212, 20 }, nativeChoiceLabels(defenseProfileChoices), function(_, selected)
		if selected then
			self.textValues.defenseProfile = selected.val
			self.modFlag = true
		end
	end)
	controls.defenseProfile:SelByValue(tostring(self.textValues.defenseProfile or "Auto"), "val")
	controls.defenseProfile.enableDroppedWidth = true
	controls.defenseProfile.tooltipText = "With Defense first, exact PoB ranks by this selected output before the objective. Choices include Life, Energy Shield, EHP, Ward, Armour, Evasion, Attack/Spell Block and Spell Suppression. This is a ranking preference; use Matrix hard floors for required minimums. Ward is an extra buffer, not a replacement for Life or Energy Shield."
	controls.rankingPriorityLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 332, 96, 18 }, "^7Rank first:")
	controls.rankingPriority = new("DropDownControl"):DropDownControl(popupTopLeftAnchor(), { 124, 328, 250, 22 }, rankChoices, function(_, selected)
		if selected then
			self.textValues.rankingPriority = selected.val
			self.modFlag = true
		end
	end)
	controls.rankingPriority:SelByValue(tostring(self.textValues.rankingPriority or "ObjectiveFirst"), "val")
	controls.rankingPriority.enableDroppedWidth = true
	controls.rankingPriority.tooltipText = "Ranks only candidates that passed every exact PoB hard gate. Defense first uses the selected defense pool and then the objective; Offense objective first preserves the legacy order. This is lexicographic, not a synthetic weighted score."
	controls.preferenceHint = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 378, 660, 14 }, "^8Ranking is a priority order, never a replacement for strict hard floors.")
	setClippedPopupLabel(controls.preferenceHint, 660, 12)

	controls.conversionLabel = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 216, 640, 18 }, DisplayText.Native("^7Conversion path — check the source and each destination in PoE order:"))
	setClippedPopupLabel(controls.conversionLabel, 640, 14)
	local selectedTypes = { }
	for typeName in tostring(self.textValues.conversionRoute or ""):gmatch("[^>]+") do selectedTypes[typeName:lower()] = true end
	self.directionConversionControls = { }
	local conversionColors = {
		Physical = colorCodes.NORMAL,
		Lightning = colorCodes.LIGHTNING,
		Cold = colorCodes.COLD,
		Fire = colorCodes.FIRE,
		Chaos = colorCodes.CHAOS,
	}
	local function updateConversionRoute()
		local route = { }
		for _, typeName in ipairs(conversionTypes) do
			local control = self.directionConversionControls[typeName]
			if control and control.state then route[#route + 1] = typeName end
		end
		self.textValues.conversionRoute = #route >= 2 and table.concat(route, ">") or ""
		self.modFlag = true
	end
	for index, typeName in ipairs(conversionTypes) do
		local label = (conversionColors[typeName] or "^7") .. typeName
		local box = new("CheckBoxControl"):CheckBoxControl(popupTopLeftAnchor(), { 36 + (index - 1) * 128, 238, 18 }, label, updateConversionRoute,
			"Select at least two boxes to require a conversion chain in PoE's native order.", selectedTypes[typeName:lower()])
		box.labelRight = true
		box.labelWidth = 102
		self.directionConversionControls[typeName] = box
		controls["conversion_" .. typeName] = box
	end
	controls.conversionPreview = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 262, 650, 18 }, function()
		return DisplayText.Native(self.textValues.conversionRoute ~= "" and ("^8Required route: " .. self.textValues.conversionRoute .. " (edge floor " .. tostring(self.textValues.conversionMin or "100") .. "%)")
			or "^8No hard conversion route selected. Choose at least two damage types to enable this gate.")
	end)
	setClippedPopupLabel(controls.conversionPreview, 650, 13)
	controls.conversionHint = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 24, 280, 660, 26 }, "^8Hard gate: every selected edge must pass PoB's exact conversion calculation.")
	setClippedPopupLabel(controls.conversionHint, 660, 13)
	controls.notes = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 24, 436, 210, 22 }, "Append leveling notes", function()
		local ok, message = self:AppendBuildPlanToNotes()
		self.statusMessage = message
		if ok then main:ClosePopup() end
	end)
	controls.createSeed = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 246, 436, 230, 22 }, "Create skill-set seed", function()
		local selected = controls.targetGem:GetSelValue()
		if not selected or not selected.val then
			self.statusMessage = "Choose an active gem from the loaded PoB catalog first."
			return
		end
		local result, seedError = SkillSeed.Create(self.build, selected.val, selectedClassId)
		if not result then
			self.statusMessage = seedError or "PoB could not create the selected skill-set seed."
			return
		end
		self.directionSkillSelection = DisplayText.Native(result.gemName .. (result.linked
			and (" — linked to " .. tostring(result.socketBinding and result.socketBinding.slot or "equipped item"))
			or " — unlinked seed"))
		self.modFlag = true
		main:ClosePopup()
	end)
	controls.close = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 596, 436, 100, 22 }, "Close", function() main:ClosePopup() end)
	controls.notes.enabled = #skillOptions > 0
	controls.createSeed.enabled = #gemOptions > 0
	controls.createSeed.tooltipText = "Create a reversible native PoB skill set containing the selected active gem. The planner uses an unused socket link on an equipped item only when its next socket starts a distinct native link group and has a compatible color; otherwise it keeps the seed unlinked. PoB checks class-root gem requirements and exact-calculates the result. Supports remain unconfigured and must fit the same native link."
	controls.close.enabled = true
	-- OpenPopup takes (enterControl, defaultControl, escapeControl, scrollbar,
	-- resize). The former call passed the Close control in the scrollbar slot,
	-- which made PopupDialog:Draw call the string and crash every frame. With no
	-- existing active skill, focus the loaded gem selector and make Escape close
	-- the modal; otherwise keep the current-skill selector as the default.
	local defaultControl = #skillOptions > 0 and "skill" or "targetGem"
	main:OpenPopup(720, 480, DisplayText.Native("AI Planner — Build Direction"), controls, "notes", defaultControl, "close")
end

function OptimizerTabClass:OpenActivitySchedule()
	local ROW_TOP, ROW_HEIGHT, ROW_VIEW_HEIGHT = 122, 30, 310
	local modeLabels = { "Continuous", "Scheduled", "Alternative", "Setup" }
	local labelToMode = { Continuous = "continuous", Scheduled = "scheduled", Alternative = "alternative", Setup = "setup" }
	local modeToLabel = { continuous = "Continuous", scheduled = "Scheduled", alternative = "Alternative", setup = "Setup" }
	local state = { version = 1, lastScope = "full_dps", scopes = { } }
	local decodedOk, decoded = pcall(json.decode, tostring(self.textValues.activityScheduleJson or ""))
	if decodedOk and type(decoded) == "table" and decoded.version == 1 and type(decoded.scopes) == "table" then
		state = decoded
	end
	state.optimizerGateEnabled = state.optimizerGateEnabled == true
	if state.lastScope ~= "main_skill" and state.lastScope ~= "full_dps" and state.lastScope ~= "all_enabled_skills" then state.lastScope = "full_dps" end
	if state.optimizerGateScope ~= "full_dps" and state.optimizerGateScope ~= "all_enabled_skills" then state.optimizerGateScope = nil end
	state.scopes = type(state.scopes) == "table" and state.scopes or { }

	local controls, rowsByScope, rowControls = { }, { }, { }
	local currentScope = state.lastScope
	local currentRows = { }
	local resultStatus = "^8Edit average use rates, then evaluate against the current exact PoB activity ledger."
	local resultDetails = "^8PoB damage outputs and linear per-activity projections are available on hover; they are not combined or certified."
	local damageKeyOrder = { "TotalDPS", "TotalDotDPS", "TotalDot", "TotalPoisonDPS", "TotalIgniteDPS", "IgniteDPS", "BleedDPS", "CorruptingBloodDPS", "ImpaleDPS", "DecayDPS", "BurningGroundDPS", "CausticGroundDPS" }
	local damageSourceOrder = { "player", "minion" }
	local function activityDamageTooltip(row)
		if row.resourceOnly then
			local parts = { }
			for _, resource in ipairs({ "Life", "Mana", "ES" }) do
				local rates = row.resourceRates and row.resourceRates[resource]
				if type(rates) == "table" then
					parts[#parts + 1] = string.format("%s cost %.5g/s, regen %.5g/s, leech %.5g/s, on-hit %.5g/s",
						resource, rates.cost or 0, rates.netRegen or 0, rates.leech or 0, rates.onHit or 0)
				end
			end
			local tooltip = #parts > 0 and ("Exact PoB recurring resource rates: " .. table.concat(parts, "; ")) or "PoB recurring resource rates are unavailable."
			if row.unsupportedReason then tooltip = tooltip .. " Schedule blocked: " .. row.unsupportedReason .. "." end
			if row.damageUnsupportedReason then tooltip = tooltip .. " Damage cadence is outside this resource-only estimate." end
			return tooltip .. " User average-use percentages scale resource costs and on-hit recovery only; this does not calculate damage."
		end
		local outputParts, projectionParts = { }, { }
		for _, source in ipairs(damageSourceOrder) do
			local outputs = row.poBDamage and row.poBDamage[source]
			if type(outputs) == "table" then
				for _, key in ipairs(damageKeyOrder) do
					local value = outputs[key]
					if isFiniteNumber(value) then
						outputParts[#outputParts + 1] = source .. "." .. key .. "=" .. string.format("%.5g", value)
						local ratePercent = row.mode == "continuous" and 100 or tonumber((tostring(row.ratePercentText or ""):gsub(",", ".")))
						if isFiniteNumber(ratePercent) and ratePercent >= 0 and ratePercent <= 100 then
							projectionParts[#projectionParts + 1] = source .. "." .. key .. "=" .. string.format("%.5g", value * ratePercent / 100)
						end
					end
				end
			end
		end
		local tooltip = #outputParts > 0 and ("Exact PoB activity outputs: " .. table.concat(outputParts, "; ")) or "PoB per-activity damage outputs are unavailable."
		if row.unsupportedReason then
			tooltip = tooltip .. " Schedule projection unsupported: " .. row.unsupportedReason .. "."
		elseif row.mode == "setup" then
			tooltip = tooltip .. " Setup activities are excluded from damage projection."
		elseif #projectionParts > 0 then
			tooltip = tooltip .. " Linear per-activity projection at " .. (row.mode == "continuous" and "100" or tostring(row.ratePercentText or "?")) .. "%: " .. table.concat(projectionParts, "; ")
		end
		return tooltip .. " This is not recalculated by PoB, not summed across skills, and not a damage or uptime certification."
	end

	local function recordsForScope(scope)
		local output = self.build.calcsTab and self.build.calcsTab.mainOutput
		if type(output) ~= "table" then return nil, nil, false, "PoB has no current calculation output for the active build" end
		if scope == "main_skill" then
			return output.OptimizerMainSkillActivity, { }, false
		elseif scope == "all_enabled_skills" then
			local audit = output.OptimizerSkillCostAudit
			if type(audit) ~= "table" then return nil, nil, false, "PoB did not expose its enabled-skill cost audit" end
			return nil, audit.scheduleActivities, audit.scheduleTruncated == true, audit.scheduleUnsupportedReason, true
		end
		return nil, output.FullDPSActivity, output.FullDPSActivityTruncated, nil, false
	end

	local function loadRows(scope)
		if rowsByScope[scope] then return rowsByScope[scope] end
		local mainRecord, fullRecords, truncated, outputError, resourceOnly = recordsForScope(scope)
		if outputError then return nil, outputError end
		local activities, listError = Activity.ListScheduleActivities(mainRecord, fullRecords, truncated, resourceOnly)
		if not activities then return nil, listError end
		local savedByIdentity = { }
		for _, entry in ipairs(type(state.scopes[scope]) == "table" and state.scopes[scope] or { }) do
			if type(entry) == "table" and type(entry.identity) == "string" then savedByIdentity[entry.identity] = entry end
		end
		local rows = { }
		for _, activityInfo in ipairs(activities) do
			local saved = savedByIdentity[activityInfo.identity]
			local mode = saved and modeToLabel[saved.mode] and saved.mode or nil
			if not mode then mode = "continuous" end
			local rateText = saved and (saved.ratePercentText or tostring(saved.ratePercent or "100")) or "100"
			local packageText = saved and tostring(saved.package or "") or ""
			local requiresIdentity = saved and type(saved.requires) == "string" and saved.requires or ""
			rows[#rows + 1] = {
				identity = activityInfo.identity,
				name = activityInfo.name,
				group = activityInfo.group,
				kind = activityInfo.kind,
				count = activityInfo.count,
				unsupportedReason = activityInfo.unsupportedReason,
				poBDamage = activityInfo.poBDamage,
				resourceOnly = activityInfo.resourceOnly,
				resourceRates = activityInfo.resources,
				damageUnsupportedReason = activityInfo.damageUnsupportedReason,
				mode = mode,
				ratePercentText = tostring(rateText),
				packageText = packageText,
				requiresIdentity = requiresIdentity,
			}
		end
		rowsByScope[scope] = rows
		return rows
	end

	local function persistSchedule()
		state.lastScope = currentScope
		for scope, rows in pairs(rowsByScope) do
			local entries = { }
			for _, row in ipairs(rows) do
				local entry = {
					identity = row.identity,
					mode = row.mode,
					ratePercentText = row.ratePercentText,
					package = row.packageText,
				}
				if row.requiresIdentity ~= "" then entry.requires = row.requiresIdentity end
				entries[#entries + 1] = entry
			end
			state.scopes[scope] = entries
		end
		local ok, encoded = pcall(json.encode, state)
		if ok and type(encoded) == "string" then
			self.textValues.activityScheduleJson = encoded
			self.modFlag = true
		else
			resultStatus = "^1Could not save the activity schedule in this build's Matrix."
		end
	end

	local function clearRowControls()
		for key in pairs(rowControls) do controls[key] = nil end
		rowControls = { }
	end

	local function refreshRows()
		clearRowControls()
		currentRows = { }
		if controls.optimizerGate then controls.optimizerGate.enabled = currentScope ~= "main_skill" end
		local rows, rowsError = loadRows(currentScope)
		if not rows then
			resultStatus = "^1Schedule unavailable: " .. tostring(rowsError):sub(1, 112)
			resultDetails = "^8No resource estimate was run."
			controls.scrollBar:SetContentDimension(0, ROW_VIEW_HEIGHT)
			return
		end
		currentRows = rows
		local scopeLabel = currentScope == "main_skill" and "Main Skill" or currentScope == "all_enabled_skills" and "All enabled skills (resource only)" or "Full DPS included groups"
		local optimizerGateScopeLabel = state.optimizerGateScope == "all_enabled_skills" and "All enabled skills"
			or state.optimizerGateScope == "full_dps" and "Full DPS" or nil
		resultStatus = string.format("^7PoB activities: %d | Scope: %s", #rows, scopeLabel)
		if state.optimizerGateEnabled and optimizerGateScopeLabel then
			resultStatus = resultStatus .. " | Run gate: " .. optimizerGateScopeLabel
		end
		resultDetails = state.optimizerGateEnabled and optimizerGateScopeLabel
			and "^8This saved scope gates every exact optimizer candidate. Average rates are assumptions; damage/uptime are not recalculated or certified."
			or currentScope == "all_enabled_skills"
			and "^8Exact PoB resource rates are scaled by user assumptions; damage and action cadence are not evaluated."
			or "^8PoB damage outputs and linear per-activity projections are available on hover; they are not combined or certified."
		for index, row in ipairs(rows) do
			row.index = index
			local displayName = row.name
			if row.group ~= "" and row.group ~= row.name then displayName = displayName .. " — " .. row.group end
			if row.count > 1 then displayName = displayName .. " x" .. tostring(row.count) end
			if #displayName > 26 then displayName = displayName:sub(1, 23) .. "..." end
			local baseY = ROW_TOP + (index - 1) * ROW_HEIGHT
			local labelKey = "activity_row_label_" .. index
			local modeKey = "activity_row_mode_" .. index
			local rateKey = "activity_row_rate_" .. index
			local packageKey = "activity_row_package_" .. index
			local requiresKey = "activity_row_requires_" .. index
			row.visible = baseY + ROW_HEIGHT <= ROW_TOP + ROW_VIEW_HEIGHT
			local label = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, baseY + 3, 190, 20 }, "^7" .. displayName)
			row.labelControl = label
			label.tooltipText = activityDamageTooltip(row)
			local mode = new("DropDownControl"):DropDownControl({ "TOPLEFT", nil, "TOPLEFT" }, { 216, baseY, 104, 20 }, modeLabels, function(_, selected)
				row.mode = labelToMode[selected] or "continuous"
				row.labelControl.tooltipText = activityDamageTooltip(row)
				persistSchedule()
			end)
			mode:SelByValue(modeToLabel[row.mode])
			local rate = new("EditControl"):EditControl({ "TOPLEFT", nil, "TOPLEFT" }, { 326, baseY, 50, 20 }, row.ratePercentText, "0-100", "^%d%.%-,", 6, function(value)
				row.ratePercentText = value
				row.labelControl.tooltipText = activityDamageTooltip(row)
				persistSchedule()
			end, nil, nil, true)
			rate.enabled = function() return row.mode ~= "continuous" end
			local package = new("EditControl"):EditControl({ "TOPLEFT", nil, "TOPLEFT" }, { 382, baseY, 112, 20 }, row.packageText, "alt package", "^%C", 48, function(value)
				row.packageText = value
				persistSchedule()
			end, nil, nil, true)
			package.enabled = function() return row.mode == "alternative" end
			local requiresOptions = { { identity = "", label = "None" } }
			local requiresFound = row.requiresIdentity == ""
			for targetIndex, target in ipairs(currentRows) do
				if target.identity ~= row.identity then
					local targetLabel = target.name
					if target.group ~= "" and target.group ~= target.name then targetLabel = targetLabel .. " — " .. target.group end
					if #targetLabel > 32 then targetLabel = targetLabel:sub(1, 29) .. "..." end
					requiresOptions[#requiresOptions + 1] = {
						identity = target.identity,
						label = string.format("%02d %s", targetIndex, targetLabel),
					}
					if target.identity == row.requiresIdentity then requiresFound = true end
				end
			end
			if not requiresFound then
				requiresOptions[#requiresOptions + 1] = { identity = row.requiresIdentity, label = "Missing / invalid prerequisite" }
			end
			local requires = new("DropDownControl"):DropDownControl({ "TOPLEFT", nil, "TOPLEFT" }, { 500, baseY, 166, 20 }, requiresOptions, function(_, selected)
				row.requiresIdentity = selected and selected.identity or ""
				persistSchedule()
			end)
			if row.requiresIdentity ~= "" then requires:SelByValue(row.requiresIdentity, "identity") end
			requires.tooltipText = requiresFound
				and "Optional explicit prerequisite activity. This checks graph structure and nonzero use only; PoB does not certify setup duration, event order, or uptime here."
				or "The saved prerequisite is no longer available in this PoB scope. Choose a current activity or None; evaluation will fail closed until this is repaired."
			for _, control in ipairs({ label, mode, rate, package, requires }) do
				control.shown = function() return row.visible == true end
			end
			controls[labelKey], controls[modeKey], controls[rateKey], controls[packageKey], controls[requiresKey] = label, mode, rate, package, requires
			rowControls[labelKey], rowControls[modeKey], rowControls[rateKey], rowControls[packageKey], rowControls[requiresKey] = true, true, true, true, true
			row.controls = { label, mode, rate, package, requires }
		end
		controls.scrollBar:SetContentDimension(#rows * ROW_HEIGHT, ROW_VIEW_HEIGHT)
	end

	controls.intro = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, 14, 690, 22 }, "^8Schedule PoB activities with explicit average-use rates. The third scope estimates resources for every enabled skill; it does not certify damage.")
	controls.scopeLabel = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, 48, 78, 20 }, "^7Activity scope:")
	controls.scope = new("DropDownControl"):DropDownControl({ "TOPLEFT", nil, "TOPLEFT" }, { 110, 44, 220, 20 }, { "Full DPS included groups", "Main Skill", "All enabled skills" }, function(_, selected)
		currentScope = selected == "Main Skill" and "main_skill" or selected == "All enabled skills" and "all_enabled_skills" or "full_dps"
		state.lastScope = currentScope
		resultDetails = currentScope == "all_enabled_skills"
			and "^8This scope estimates recurring resource use only; it does not calculate per-activity or combined damage."
			or "^8PoB per-activity outputs remain exact; schedule projections are diagnostic and do not certify combined DPS or uptime."
		refreshRows()
		persistSchedule()
	end)
	controls.scope:SetSel(currentScope == "main_skill" and 2 or currentScope == "all_enabled_skills" and 3 or 1, true)
	controls.scope.enableDroppedWidth = true
	controls.scope.tooltipText = "Main Skill reads PoB's selected skill. Full DPS reads groups included in PoB FullDPS. All enabled skills reads every enabled skill's exact recurring costs, including utility skills, and reports resource sustain only."
	controls.scopeNote = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 348, 48, 348, 20 }, "^8Rates are not APM; action caps are separate.")
	controls.actionCapLabel = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, 78, 216, 18 }, "^7Damage action cap (0–24):")
	controls.actionCap = new("EditControl"):EditControl({ "TOPLEFT", nil, "TOPLEFT" }, { 240, 76, 48, 20 }, self.textValues.maxManualDamageButtons or "", "Optional", "^%d", 2, function(value)
		self.textValues.maxManualDamageButtons = value
		self.modFlag = true
	end, nil, nil, true)
	controls.actionCap.tooltipText = "Strictly limits distinct enabled manual skills that PoB classifies as damage actions. Triggered skills and persistent reservations are excluded. Blank means no damage-only cap. This does not infer key bindings or actions per minute."
	controls.actionCapNote = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 300, 78, 396, 18 }, "^8Blank disables this damage-only filter; counts distinct PoB skills.")
	controls.columns = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, 100, 660, 18 }, "^7PoB activity              Use mode   Average %   Alt package       Requires")
	controls.scheduleStatus = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, 438, 690, 18 }, function() return resultStatus end)
	controls.scheduleDetails = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, 458, 690, 28 }, function() return resultDetails end)
	controls.scrollBar = new("ScrollBarControl"):ScrollBarControl({ "TOPRIGHT", nil, "TOPRIGHT" }, { -22, ROW_TOP, 18, ROW_VIEW_HEIGHT }, ROW_HEIGHT, "VERTICAL", true)
	local function scrollBarFunc()
		controls.scrollBar:SetContentDimension(#currentRows * ROW_HEIGHT, ROW_VIEW_HEIGHT)
		local offset = controls.scrollBar.offset or 0
		for index, row in ipairs(currentRows) do
			local y = ROW_TOP + (index - 1) * ROW_HEIGHT - offset
			row.visible = y >= ROW_TOP and y + ROW_HEIGHT <= ROW_TOP + ROW_VIEW_HEIGHT
			for _, control in ipairs(row.controls or { }) do control.y = y end
		end
	end

	controls.evaluate = new("ButtonControl"):ButtonControl({ "TOPLEFT", nil, "TOPLEFT" }, { 506, 494, 118, 22 }, "Evaluate sustain", function()
		local currentOutput = self.build.calcsTab and self.build.calcsTab.mainOutput
		local mainRecord, fullRecords, truncated, costRecords, resourceOnly
		if currentScope == "main_skill" then
			mainRecord, fullRecords, truncated = currentOutput and currentOutput.OptimizerMainSkillActivity, { }, false
		elseif currentScope == "all_enabled_skills" then
			local audit = currentOutput and currentOutput.OptimizerSkillCostAudit
			mainRecord, fullRecords = nil, audit and audit.scheduleActivities
			truncated = audit and audit.scheduleTruncated == true
			costRecords, resourceOnly = fullRecords, true
		else
			mainRecord, fullRecords, truncated = nil, currentOutput and currentOutput.FullDPSActivity, currentOutput and currentOutput.FullDPSActivityTruncated
		end
		local schedule = { }
		for _, row in ipairs(currentRows) do
			local entry = { identity = row.identity, mode = row.mode }
			if row.mode ~= "continuous" then
				local rateText = tostring(row.ratePercentText or ""):gsub(",", ".")
				local rate = tonumber(rateText)
				if not isFiniteNumber(rate) or rate < 0 or rate > 100 then
					resultStatus = "^1Invalid average-use rate for " .. row.name:sub(1, 48) .. ": enter 0 to 100%."
					resultDetails = "^8The schedule was not evaluated."
					return
				end
				entry.ratePercent = rate
			end
			if row.mode == "alternative" then
				entry.package = tostring(row.packageText or ""):match("^%s*(.-)%s*$")
				if entry.package == "" then
					resultStatus = "^1Add an alternative package name for " .. row.name:sub(1, 48) .. "."
					resultDetails = "^8The schedule was not evaluated."
					return
				end
			end
			if row.requiresIdentity ~= "" then entry.requires = { row.requiresIdentity } end
			schedule[#schedule + 1] = entry
		end
		persistSchedule()
		local objective = currentScope == "main_skill" and "CombinedDPS" or currentScope == "all_enabled_skills" and "ResourceSustain" or "FullDPS"
		local evaluation, err = Activity.EvaluateSchedule({ objective = objective, hard = { } }, mainRecord, fullRecords, truncated, schedule, costRecords)
		if not evaluation then
			resultStatus = "^1Schedule not evaluated: " .. tostring(err):sub(1, 112)
			resultDetails = "^8The active build was not changed; no optimizer constraint was evaluated."
			self.statusMessage = "Activity schedule could not be evaluated: " .. tostring(err)
			return
		end
		local margins = evaluation.metrics or { }
		local function margin(key)
			return type(margins[key]) == "number" and string.format("%.5g", margins[key]) or "n/a"
		end
		local statusLabel = evaluation.sustainStatus == "pass" and "PASS" or evaluation.sustainStatus == "violated" and "DEFICIT" or "UNSUPPORTED"
		resultStatus = "^7Sustain estimate: " .. statusLabel .. " | Scheduled DPS certification: NO"
		local firstViolation = evaluation.violations and evaluation.violations[1]
		local detail = "Life / mana / ES margin: " .. margin("SustainedLifeMargin") .. " / " .. margin("SustainedManaMargin") .. " / " .. margin("SustainedEnergyShieldMargin") .. " per second"
		if firstViolation and firstViolation.reason then detail = detail .. " | " .. firstViolation.reason end
		local dependencyAudit = evaluation.dependencyAudit or { }
		if dependencyAudit.edgeCount and dependencyAudit.edgeCount > 0 then detail = detail .. " | " .. dependencyAudit.edgeCount .. " prerequisite link(s), timing not certified" end
		local detailSuffix = resourceOnly and " | Resource-only estimate; no damage calculated." or " | Per-activity projections are on row hover; combined scheduled DPS is not certified."
		resultDetails = "^8" .. (detail .. detailSuffix):sub(1, 138)
		self.statusMessage = resourceOnly and ("Enabled-skill resource estimate " .. statusLabel:lower() .. "; damage was not calculated.")
			or ("Activity schedule sustain estimate " .. statusLabel:lower() .. "; damage schedule is not certified.")
	end)
	controls.optimizerGate = new("ButtonControl"):ButtonControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, 494, 164, 22 }, function()
		if state.optimizerGateEnabled and state.optimizerGateScope == currentScope then
			return "Remove Run gate"
		end
		return "Use scope as Run gate"
	end, function()
		if currentScope == "main_skill" then
			resultStatus = "^1Main Skill is diagnostic only; choose Full DPS or All enabled skills for Run optimizer."
			resultDetails = "^8The saved activity schedule was not changed."
			return
		end
		if state.optimizerGateEnabled and state.optimizerGateScope == currentScope then
			state.optimizerGateEnabled = false
			state.optimizerGateScope = nil
		else
			state.optimizerGateEnabled = true
			state.optimizerGateScope = currentScope
		end
		persistSchedule()
		refreshRows()
	end)
	controls.optimizerGate.enabled = currentScope ~= "main_skill"
	controls.optimizerGate.tooltipText = "Apply this exact PoB activity list and the saved average-use rates as a strict resource-sustain gate to every Run optimizer candidate. Main Skill scope is diagnostic only. The gate never certifies damage, event timing, or encounter uptime."
	controls.reset = new("ButtonControl"):ButtonControl({ "TOPLEFT", nil, "TOPLEFT" }, { 374, 494, 116, 22 }, "Reset this scope", function()
		for _, row in ipairs(currentRows) do
			row.mode = "continuous"
			row.ratePercentText = "100"
			row.packageText = ""
			row.requiresIdentity = ""
			local modeControl = controls["activity_row_mode_" .. tostring(row.index)]
			local rateControl = controls["activity_row_rate_" .. tostring(row.index)]
			local packageControl = controls["activity_row_package_" .. tostring(row.index)]
			local requiresControl = controls["activity_row_requires_" .. tostring(row.index)]
			if modeControl then modeControl:SelByValue("Continuous") end
			if rateControl then rateControl:SetText("100", false) end
			if packageControl then packageControl:SetText("", false) end
			if requiresControl then requiresControl:SelByValue("", "identity") end
		end
		resultStatus = "^7Schedule reset to the current PoB continuous rates."
		persistSchedule()
	end)
	controls.close = new("ButtonControl"):ButtonControl({ "TOPLEFT", nil, "TOPLEFT" }, { 646, 494, 74, 22 }, "Close", function() main:ClosePopup() end)
	for index, row in ipairs(currentRows) do row.index = index end
	refreshRows()
	main:OpenPopup(740, 540, DisplayText.Native("AI Planner — Activity Schedule"), controls, "evaluate", "scope", "close", scrollBarFunc)
end

local function buildNativeProgressionStages(build, extraPoints)
	return Progression.BuildNativeActSchedule(build, extraPoints)
end

function OptimizerTabClass:AppendBuildPlanToNotes()
	local build = self.build
	local notes = build.notesTab and build.notesTab.controls and build.notesTab.controls.edit
	if not notes then return false, "PoB Notes editor is unavailable" end
	local groupIndex = parsePositiveIndex(self.textValues.targetSkillGroupIndex) or build.mainSocketGroup
	local group = build.skillsTab.socketGroupList[groupIndex]
	local skillIndex = parsePositiveIndex(self.textValues.targetSkillIndex) or (group and group.mainActiveSkill) or 1
	local skill = group and group.displaySkillList and group.displaySkillList[skillIndex]
	if not skill or not skill.activeEffect then return false, "Choose an enabled Main Skill before generating the leveling notes" end
	local effect = skill.activeEffect.grantedEffect or { }
	-- CalcSetup's live ActiveSkill owns the authoritative PoB skill flags;
	-- grantedEffect data alone generally contains base flags, not computed attack/spell flags.
	local flags = skill.skillFlags or effect.flags or { }
	local tagSet = { }
	for key, value in pairs(effect.tags or { }) do
		if type(value) == "string" then tagSet[value:lower()] = true elseif value then tagSet[tostring(key):lower()] = true end
	end
	local element = tostring(self.textValues.conversionRoute or ""):match("([^>]+)$")
	if element then element = element:lower() end
	if not element then
		for _, candidateElement in ipairs({ "physical", "lightning", "cold", "fire", "chaos" }) do
			if tagSet[candidateElement] then element = candidateElement break end
		end
	end
	local skillName = skill.name or effect.name or "Selected Main Skill"
	local classId = tonumber(self.textValues.baseClassId) or build.spec.curClassId
	local className = build.spec.tree.classes[classId] and build.spec.tree.classes[classId].name or build.spec.curClassName
	local gemColorData = ({
		[1] = { code = "^1", name = "Red / Strength" },
		[2] = { code = "^2", name = "Green / Dexterity" },
		[3] = { code = "^3", name = "Blue / Intelligence" },
		[4] = { code = "^7", name = "Colorless / granted skill" },
	})[tonumber(effect.color)] or { code = "^7", name = "PoB native color" }
	local gemColor = gemColorData.name
	local gemPackage = { }
	for _, configuredGem in ipairs(group.gemList or { }) do
		if configuredGem.enabled and configuredGem.gemData then
			local configuredEffect = configuredGem.grantedEffect or configuredGem.gemData.grantedEffect or { }
			local colorData = ({
				[1] = { code = "^1", name = "R" }, [2] = { code = "^2", name = "G" },
				[3] = { code = "^3", name = "B" }, [4] = { code = "^7", name = "-" },
			})[tonumber(configuredEffect.color or configuredGem.gemData.color)] or { code = "^7", name = "?" }
			local configuredName = configuredGem.gemData.name or configuredGem.nameSpec or configuredEffect.name or "Gem"
			gemPackage[#gemPackage + 1] = colorData.code .. colorData.name .. " " .. tostring(configuredName) .. "^7"
		end
	end
	local offense
	if flags.minion or tagSet.minion then
		offense = { "+ levels of the active minion skill gem (1st when PoB shows level scaling)", "Minion damage with the exact damage type used by the skill (2nd)", "Minion attack/cast speed or DoT multiplier matching the minion's damage package (3rd)", "Critical stats only if the exact minion output uses them (4th)" }
	elseif flags.attack or tagSet.attack then
		local damageName = element and element:sub(1, 1):upper() .. element:sub(2) or (tagSet.physical and "Physical" or "skill-tagged")
		offense = { "% " .. damageName .. " DPS (1st priority)", "Attack Speed (2nd priority)", "Added flat " .. damageName .. " damage (3rd priority)", "Accuracy / critical stats only when PoB's exact skill output benefits (4th)" }
	elseif flags.spell or tagSet.spell then
		local damageName = element and element:sub(1, 1):upper() .. element:sub(2) or "skill-tagged"
		offense = { "+ level of the active skill gem (1st when PoB confirms level scaling)", "% Spell / " .. damageName .. " Damage (2nd priority)", "Cast Speed (3rd priority)", "Critical chance and multiplier only when the selected skill is built to crit (4th)" }
	else
		offense = { "PoB-tested gem levels or base damage scaling (1st priority)", "Skill-tagged damage or DoT multiplier (2nd priority)", "Action speed that the skill actually uses (3rd priority)", "Critical stats only when the exact calculation confirms value (4th)" }
	end
	local output = build.calcsTab and build.calcsTab.mainOutput or { }
	local requirements = string.format("Str %s / Dex %s / Int %s / Level %s", tostring(output.ReqStr or 0), tostring(output.ReqDex or 0), tostring(output.ReqInt or 0), tostring(output.ReqLevel or 0))
	local pointCount = build.spec:CountAllocNodes()
	if classId ~= build.spec.curClassId then pointCount = 0 end
	local extraPoints = output.ExtraPoints or 0
	local planningLevel = build.characterLevel or 1
	local pointLimit
	if type(build.GetPassivePointLimitForLevel) == "function" then
		pointLimit = build:GetPassivePointLimitForLevel(planningLevel, extraPoints)
	end
	local progressionStages, progressionError = buildNativeProgressionStages(build, extraPoints)
	local warningLines = { }
	for _, warning in pairs(build.controls.warnings and build.controls.warnings.lines or { }) do
		if type(warning) == "string" and warning:match("%S") then warningLines[#warningLines + 1] = warning end
	end
	table.sort(warningLines)
	local actNames = {
		[1] = "Act 1", [2] = "Act 2", [3] = "Act 3", [4] = "Act 4", [5] = "Act 5",
		[6] = "Act 6", [7] = "Act 7", [8] = "Act 8", [9] = "Act 9", [10] = "Act 10",
		[11] = "Epilogue / maps",
	}
	local lines = {
		"^xD8B777════════════════════════════════════════════════════",
		"^xD8B777AI PLANNER — BUILD PLAN (PoB native data)",
		"^7Base class: " .. tostring(className) .. " | Main skill: " .. gemColorData.code .. tostring(skillName) .. "^7 | Gem color: " .. gemColor,
		"^7Active skill package (PoB socket colors): " .. (#gemPackage > 0 and table.concat(gemPackage, "  ") or "No enabled gem data in the selected group"),
		"^8Character levels are 1–100 in PoE. Level 0 below means an empty planning state, not a playable character.",
		"^8Act boundaries and legal passive-point ranges below are queried from PoB at note time, including this build's exact ExtraPoints choice.",
		"^8The selected base class is fixed; the planner compares its available main ascendancies with exact PoB calculations. Main-tree points and the separate eight-point ascendancy budget are reported independently.",
		"^7",
		"^xD8B777LEVEL / ACT PROGRESSION",
	}
	if progressionStages then
		for _, stage in ipairs(progressionStages) do
			local name = stage.actLabel or actNames[stage.act] or ("PoB stage " .. tostring(stage.act))
			lines[#lines + 1] = string.format("^7%s | levels %d–%d | PoB legal passive points %d–%d",
				name, stage.firstLevel, stage.lastLevel, stage.firstPointLimit, stage.lastPointLimit)
		end
	else
		lines[#lines + 1] = "^1Native progression point limits unavailable; stage legality is not certified: " .. tostring(progressionError)
	end
	lines[#lines + 1] = "^8Level 0: create the build shell. Level 1: choose the class start and level-usable skill/support gems."
	lines[#lines + 1] = "^8Use PoB's level, socket-color, gem-level, attribute, and passive-point warnings at every stage; do not carry endgame gems/items into an illegal leveling stage."
	if isFiniteNumber(pointLimit) then
		lines[#lines + 1] = string.format("^7Selected planning root: %d allocated passive points; PoB's native act/quest rule allows up to %s passive points at level %d with the loaded quest choice.", pointCount, tostring(pointLimit), planningLevel)
	else
		lines[#lines + 1] = "^1Selected planning root: PoB's native point limit is unavailable; point legality is not certified."
	end
	lines[#lines + 1] = "^8When the selected base class differs from the loaded build, its planning root starts at zero points. Manual candidates cannot exceed PoB's level/quest limit; Auto mode estimates a legal level from the candidate tree."
	lines[#lines + 1] = "^8Requirement values and warning lines below describe the loaded build's current Main Skill and equipment; an alternate selected skill/class must pass the exact optimizer use-requirement gate."
	lines[#lines + 1] = "^7"
	lines[#lines + 1] = "^xD8B777LEVELING ITEM TEMPLATES"
	local itemStages = {
		{ "Acts 1–5 (levels 1–43)", "Replace the weapon as its level requirement allows: " .. offense[1] .. "; then " .. offense[2] .. ". Use a legal socket/link setup for the skill's colored gem package." },
		{ "Acts 6–10 (levels 44–67)", "After the Act 5 resistance penalty, restore elemental resistance toward PoB's cap before optional damage; weapon priorities remain " .. offense[1] .. " then " .. offense[2] .. "." },
		{ "Early maps (levels 68–75)", "Keep the main skill's legal links and gem levels; meet attribute/level requirements, life or ES floor, resistance caps, and the exact resource cost before damage upgrades." },
		{ "Maps (levels 76–89)", "Upgrade the main skill link only when PoB confirms legal sockets; then improve the weakest max-hit type, suppression/block, reservation and payable life/mana/ES. Damage remains " .. offense[1] .. " then " .. offense[2] .. "." },
		{ "Endgame (levels 90–100)", "Consider a unique, cluster, jewel or high-tier rare only after PoB confirms requirements, point legality and every hard defense/resource floor; compare the candidate by exact PoB recalculation." },
	}
	for _, stage in ipairs(itemStages) do
		lines[#lines + 1] = "^7" .. stage[1] .. ": " .. stage[2]
		lines[#lines + 1] = "^8  Body/helmet/gloves: life or ES by selected defense + missing resistances. Belt/rings/amulet: first close attribute/resource/resistance deficits, then the selected skill's exact damage tags. Boots: movement speed after defensive requirements."
	end
	lines[#lines + 1] = "^8Templates are slot priorities, not guaranteed item instances. When enabled, the optimizer can propose legal rare items from PoB's loaded bases/mod data (up to 2 prefixes + 2 suffixes) and 20% Intrinsic/Prismatic Catalyst repairs for exact attribute/resistance deficits. Every proposal is recalculated by PoB; crafting odds and automatic catalyst prices are not modeled. A strict currency budget requires explicit synthetic-rare cost and, for Catalyst, the original item's price plus manual Catalyst investment."
	lines[#lines + 1] = "^7"
	lines[#lines + 1] = "^xD8B777STAT PRIORITIES"
	for index, priority in ipairs(offense) do lines[#lines + 1] = string.format("^7Offense %d: %s", index, priority) end
	lines[#lines + 1] = "^7Defense 1: clear all PoB item/gem level and attribute requirement warnings (current: " .. requirements .. ")."
	lines[#lines + 1] = "^7Defense 2: satisfy the selected EHP and per-damage-type max-hit floors; prioritize the exact weakest hit type."
	lines[#lines + 1] = "^7Defense 3: cap resistances to the active PoB scenario, then compare life/ES, armour/evasion, block, suppression, avoidance, and recovery through exact outputs."
	lines[#lines + 1] = "^7Resource 4: require enough payable unreserved mana/life/ES and inspect PoB's per-skill cost/rate; regen-only margins do not certify leech/on-hit uptime."
	lines[#lines + 1] = "^8Search budget: exact-evaluation count is the maximum PoB candidate calculations; passive-point cap is a separate hard ceiling. Neither is a currency budget. A currency budget needs an explicit league, trade/SSF mode, currency unit, and cap."
	lines[#lines + 1] = "^7"
	lines[#lines + 1] = "^xD8B777CURRENT POB WARNINGS"
	if #warningLines == 0 then
		lines[#lines + 1] = "^8No warning was exposed in the current PoB warning panel at note generation time."
	else
		for _, warning in ipairs(warningLines) do lines[#lines + 1] = "^1• " .. warning end
	end
	lines[#lines + 1] = "^8Recalculate and clear warnings after each stage or equipment change. The exact engine output, not this template, determines legality and performance."
	lines[#lines + 1] = "^xD8B777════════════════════════════════════════════════════"
	lines[#lines + 1] = ""
	local existing = notes.buf or ""
	if existing:match("%S") then notes.caret = #existing + 1 notes.sel = nil notes:Insert("\n\n") end
	notes.caret = #notes.buf + 1
	notes.sel = nil
	-- These notes are generated for the stock PoB Notes editor, which can use
	-- the same native font that escapes unsupported punctuation in the planner.
	-- Adapt only this generated block; existing user notes remain untouched.
	notes:Insert(DisplayText.Native(table.concat(lines, "\n")))
	build.notesTab.modFlag = true
	build.modFlag = true
	return true, "Leveling plan appended to PoB Notes. Review the listed native warnings before applying or gearing a candidate."
end

function OptimizerTabClass:OpenMCPRequest()
	if self.aiRequestData and self.aiRequestData.status == "completed" then
		main:OpenMessagePopup("MCP queued request", self.aiRequestData.message or "The external MCP-connected chat completed the request without a response message.")
		return
	end
	local controls = { }
	controls.description = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, 18, 540, 20 }, "^7Queue this request for an external MCP-connected chat. The chat must be active to retrieve it.")
	controls.request = new("ResizableEditControl"):ResizableEditControl({ "TOPLEFT", nil, "TOPLEFT" }, { 20, 42, 540, 116, 540, 116, 540, 116 }, self.pendingPrompt or "", "Describe the build analysis or change you want", "^%C\t\n", 4096, function(buf)
		self.pendingPrompt = buf
	end, 16)
	controls.queue = new("ButtonControl"):ButtonControl(nil, { -82, 190, 142, 22 }, "Queue request", function()
		local bridge = main.optimizerMCP
		local requestId, err = bridge and bridge:QueueUserRequest(self.build, self.pendingPrompt)
		if not requestId then
		self.statusMessage = "MCP request was not queued: " .. tostring(err or "local MCP bridge unavailable")
			return
		end
		self.aiRequestId = requestId
		self.aiRequestData = { id = requestId, status = "pending" }
		self.pendingPrompt = ""
		main:ClosePopup()
		self.statusMessage = "MCP request queued as " .. requestId .. ". The external chat can retrieve it through MCP."
	end)
	controls.queue.enabled = function() return self.pendingPrompt and self.pendingPrompt:match("%S") and main.optimizerMCP ~= nil end
	controls.cancel = new("ButtonControl"):ButtonControl(nil, { 82, 190, 100, 22 }, "Cancel", function()
		main:ClosePopup()
	end)
	main:OpenPopup(580, 232, "Queue for an external MCP chat", controls, "queue", "request", "cancel")
end

function OptimizerTabClass:StartClassRootComparison()
	if main.optimizerMCP and main.optimizerMCP:IsQARunning() then
		self.statusMessage = "Finish the read-only optimizer QA smoke before starting a class-root comparison."
		return false, self.statusMessage
	end
	if self.job and self.job.status == "running" then
		self.statusMessage = "Finish or cancel the current optimizer search before comparing class roots."
		return false, self.statusMessage
	end
	if self.classRootJob and self.classRootJob.status == "running" then return false, "A class-root comparison is already running" end
	self.classRootResult = nil
	self.classRootJob = ClassRoots.RunComparison(self.build)
	self.statusMessage = "Comparing seven isolated class-start baselines with exact PoB calculations..."
	return true, self.classRootJob
end

function OptimizerTabClass:OpenClassRootsResult()
	local result = self.classRootResult
	if not result or not result.results then return end
	local controls = { }
	controls.note = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 14, 16, 680, 32 }, "^8Exact PoB class-start baseline only. No ascendancy, allocated passives, or tree jewels; this is not a global optimum.")
	controls.header = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 14, 52, 680, 18 }, "^7Base class                         Full DPS                 Selected DPS               EHP             Life       Mana")
	local function fmt(value)
		return type(value) == "number" and string.format("%.4g", value) or "-"
	end
	for index, entry in ipairs(result.results) do
		local metrics = entry.metrics or { }
		local text = string.format("^7%-22s %14s %22s %14s %10s %10s", entry.class or "Unknown", fmt(metrics.FullDPS), fmt(metrics.CombinedDPS), fmt(metrics.TotalEHP), fmt(metrics.Life), fmt(metrics.Mana))
		controls["class" .. index] = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 14, 72 + (index - 1) * 18, 680, 18 }, text)
	end
	controls.close = new("ButtonControl"):ButtonControl(nil, { 0, 218, 90, 22 }, "Close", function() main:ClosePopup() end)
	main:OpenPopup(720, 258, "Seven PoE class starts - exact baseline", controls, "close")
end

function OptimizerTabClass:OpenClassSearchResults()
	local classSearch = self.result and self.result.classSearch
	if not classSearch or type(classSearch.results) ~= "table" or #classSearch.results == 0 then return false end
	local controls = { }
	controls.note = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 14, 14, 900, 20 },
		"^8Per-class best exact candidate within its equal evaluation quota. Coverage counts are sampled, not exhaustive.")
	controls.header = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 14, 42, 900, 18 },
		"^7Class | Gate | Exact / quota | Objective | Tree points | Main ascendancy + Bloodline")
	local function fmt(value)
		return type(value) == "number" and string.format("%.4g", value) or "-"
	end
	local function clipped(value, limit)
		return type(value) == "string" and value:sub(1, limit) or ""
	end
	local objective = self.result.evaluation and self.result.evaluation.objective
		or self.textValues.objectiveMetric or "Objective"
	for index, row in ipairs(classSearch.results) do
		local best = row.bestCandidate or { }
		local mainAscendancy = clipped(best.mainAscendancy, 42)
		local bloodline = clipped(best.bloodline, 36)
		local selectedRoute = mainAscendancy ~= "" and (mainAscendancy .. " " .. fmt(best.mainAscendancyPoints)) or "No feasible route"
		if bloodline ~= "" then
			selectedRoute = selectedRoute .. " + " .. bloodline .. " " .. fmt(best.bloodlinePoints)
		end
		local objectiveValue = type(row.objectiveValue) == "number" and row.objectiveValue or best.objectiveValue
		local firstLine = string.format("^7%s | %s | %d/%d exact | %s %s | tree %s/%s | %s",
			clipped(row.class, 18), clipped(row.status, 24), row.evaluations or 0, row.quota or 0,
			clipped(objective, 18), fmt(objectiveValue), fmt(best.passivePointsUsed), fmt(best.passivePointLimit), selectedRoute)
		controls["class" .. index] = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" },
			{ 14, 64 + (index - 1) * 38, 900, 17 }, firstLine)
		local coverage = row.ascendancyCoverage
		local coverageText
		if not coverage or coverage.status == "budget_exhausted" then
			coverageText = "Ascendancy/Bloodline route generation was not reached within this class's exact-evaluation quota."
		else
			coverageText = string.format("Routes: main %s/%s; Bloodlines %s/%s; combined pairs %s/%s; exact Bloodline %s, combined %s%s",
				fmt(coverage.representedMainAscendancies), fmt(coverage.availableMainAscendancies),
				fmt(coverage.representedBloodlines), fmt(coverage.availableBloodlines),
				fmt(coverage.representedBloodlineCombinations), fmt(coverage.availableBloodlineCombinations),
				fmt(coverage.exactBloodlineEvaluations), fmt(coverage.exactCombinedEvaluations),
				coverage.budgetLimited and "; quota limited" or "")
		end
		if row.bestObservedDeficit then coverageText = coverageText .. "; best normalized deficit " .. fmt(row.bestObservedDeficit) end
		controls["coverage" .. index] = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" },
			{ 28, 81 + (index - 1) * 38, 886, 17 }, "^8" .. clipped(coverageText, 180))
	end
	controls.close = new("ButtonControl"):ButtonControl(nil, { 0, 346, 90, 22 }, "Close", function() main:ClosePopup() end)
	main:OpenPopup(940, 386, DisplayText.Native("AI Planner — per-class exact search results"), controls, "close")
	return true
end

local function collectNodeEvidenceForDirection(tab, values)
	values = values or tab.textValues or { }
	local gemId = tostring(values.targetSkillGemId or "")
	local selectedClassId = tonumber(values.baseClassId)
	local currentClassId = tonumber(tab.build and tab.build.spec and tab.build.spec.curClassId)
	if not selectedClassId then selectedClassId = currentClassId end
	local groupIndex = parsePositiveIndex(values.targetSkillGroupIndex) or (tab.build and tab.build.mainSocketGroup)
	local group = tab.build and tab.build.skillsTab and tab.build.skillsTab.socketGroupList
		and tab.build.skillsTab.socketGroupList[groupIndex]
	local skillIndex = parsePositiveIndex(values.targetSkillIndex) or (group and group.mainActiveSkill) or 1
	local effectOk, effectId, effectError = pcall(SkillCatalog.ResolveTargetEffectId,
		tab.build, groupIndex, skillIndex, gemId)
	if not effectOk or type(effectId) ~= "string" or effectId == "" then
		local evidence = { status = "unavailable",
			reason = "selected_skill_effect_unresolved: " .. tostring(effectOk and effectError or effectId):sub(1, 180),
			compatibleBuildCount = 0, nodes = { }, edges = { }, priorities = { }, causal = false, readOnly = true }
		evidence.archiveGeneration = StudyBuilds.Generation()
		return evidence
	end
	-- An empty effect filter means "any effect" to StudyBuilds.NodeEvidence.
	-- Always pass the same single effect identity ResolveTarget will evaluate,
	-- keeping Vaal and other alternate effects from contaminating route priors.
	local effects = { effectId }
	local sourceOk, archiveSource, sourceError = pcall(StudyBuilds.GetPlannerArchiveSource, main and main.userPath)
	if not sourceOk or type(archiveSource) ~= "table" then
		local reason = sourceOk and sourceError or archiveSource
		local evidence = { status = "unavailable", reason = tostring(reason or "build_archive_source_unavailable"):sub(1, 180),
			compatibleBuildCount = 0, nodes = { }, edges = { }, priorities = { }, causal = false, readOnly = true,
			archiveSourceMode = "unavailable", archiveSourceStatus = "unavailable" }
		evidence.archiveGeneration = StudyBuilds.Generation()
		return evidence
	end
	if archiveSource.status ~= "ready" and archiveSource.status ~= "no_archive" then
		local evidence = { status = "unavailable", reason = tostring(archiveSource.reason or archiveSource.status):sub(1, 180),
			compatibleBuildCount = 0, nodes = { }, edges = { }, priorities = { }, causal = false, readOnly = true,
			archiveSourceMode = archiveSource.mode or "unavailable", archiveSourceStatus = archiveSource.status }
		evidence.archiveGeneration = StudyBuilds.Generation()
		return evidence
	end
	local ok, evidence, err = pcall(StudyBuilds.NodeEvidence, main and main.userPath, tab.build, gemId,
		effects, nil, selectedClassId, archiveSource.root, "class_tree")
	if not ok or type(evidence) ~= "table" then
		evidence = { status = "unavailable", reason = tostring(err or evidence):sub(1, 180),
			compatibleBuildCount = 0, nodes = { }, edges = { }, priorities = { }, causal = false, readOnly = true }
	end
	evidence.archiveSourceMode = archiveSource.mode or "local_archive"
	evidence.archiveSourceStatus = archiveSource.status or "unavailable"
	evidence.archiveGeneration = StudyBuilds.Generation()
	return evidence
end

local function disabledNodeEvidence(reason)
	return { status = "disabled", reason = reason, compatibleBuildCount = 0,
		nodes = { }, edges = { }, nodeCounts = { }, priorities = { }, edgePriorities = { }, causal = false, readOnly = true }
end

function OptimizerTabClass:RunOptimizer()
	local useImportedMemory = tostring(self.textValues.useImportedRouteMemory or "true"):lower() == "true"
	return self:StartOptimizer(self.textValues, nil, { useImportedRouteMemory = useImportedMemory })
end

function OptimizerTabClass:RunNodePotential()
	if self.job and self.job.status == "running" then
		self.statusMessage = "Finish or cancel the current exact search before analyzing node potential."
		return false, self.statusMessage
	end
	local currentContext = currentOptimizerContext(self.build)
	if not contextMatches(self.contextAnchor, currentContext) then
		rebindOptimizerContext(self, currentContext, self.contextAnchor, false)
	end
	local saved = { }
	self.nodePotentialResult = nil
	self.nodePotentialRunActive = true
	for _, key in ipairs({ "generationPhase", "baseClassId", "searchAllClasses", "nodePotentialAnalysis", "targetNodeIds", "addNodeIds", "removeNodeIds", "requiredNodeIds", "forbiddenNodeIds", "requiredItemsJson", "maxAddedPoints", "searchStoredItems", "searchSyntheticGear" }) do
		saved[key] = self.textValues[key]
	end
	local routePointLimit = tonumber(saved.maxAddedPoints) or 0
	if routePointLimit < 1 then routePointLimit = 3 end
	local matrix = {
		generationPhase = "combined",
		baseClassId = tostring(self.build.spec.curClassId or ""),
		searchAllClasses = false,
		nodePotentialAnalysis = true,
		targetNodeIds = "",
		addNodeIds = "",
		removeNodeIds = "",
		requiredNodeIds = "",
		forbiddenNodeIds = "",
		requiredItemsJson = "{}",
		maxAddedPoints = tostring(routePointLimit),
		searchStoredItems = false,
		searchSyntheticGear = false,
	}
	local useImportedMemory = tostring(self.textValues.useImportedRouteMemory or "true"):lower() == "true"
	local ok, result = self:StartOptimizer(matrix, nil, {
		useImportedRouteMemory = useImportedMemory,
	})
	for key, value in pairs(saved) do self.textValues[key] = value == nil and "" or value end
	self.textValues.nodePotentialAnalysis = "false"
	for _, key in ipairs({ "targetNodeIds", "addNodeIds", "removeNodeIds", "requiredNodeIds", "forbiddenNodeIds", "maxAddedPoints" }) do
		local control = self.controls["text_" .. key]
		if control then control:SetText(tostring(self.textValues[key] or ""), false) end
	end
	self.innerView = "nodes"
	self.modFlag = true
	if not ok then
		self.nodePotentialRunActive = false
		return false, result
	end
	return true, result
end

function OptimizerTabClass:CreateIsolatedStudyWorker(sourceBuild)
	if not sourceBuild or not sourceBuild.spec or not sourceBuild.skillsTab then
		return nil, "The isolated study build is incomplete"
	end
	local worker = setmetatable({ }, getmetatable(self))
	worker.build = sourceBuild
	worker.textValues = { }
	for key, value in pairs(self.textValues or { }) do worker.textValues[key] = value end
	worker.controls = { }
	worker.contextAnchor = nil
	worker.contextNotice = nil
	worker.classRootJob = nil
	worker.classRootResult = nil
	worker.job = nil
	worker.result = nil
	worker.modFlag = false
	worker.statusMessage = "Isolated public build study; results are read-only."
	worker.isolatedStudyWorker = true
	rebindOptimizerContext(worker, currentOptimizerContext(sourceBuild), nil, true)
	return worker
end

function OptimizerTabClass:StartOptimizer(matrix, control, options)
	if main.optimizerMCP and main.optimizerMCP:IsQARunning() then
		self.statusMessage = "Finish the read-only optimizer QA smoke before starting another optimizer job."
		return false, self.statusMessage
	end
	if not self.isolatedStudyWorker and main.optimizerMCP
		and type(main.optimizerMCP.IsStudyOptimizerRunning) == "function"
		and main.optimizerMCP:IsStudyOptimizerRunning() then
		self.statusMessage = "An isolated build-study optimization is running; finish or cancel it before starting another optimizer job."
		return false, self.statusMessage
	end
	if self.classRootJob and self.classRootJob.status == "running" then
		return false, "A class-root comparison is running; finish or cancel it before starting optimization"
	end
	if self.job and self.job.status == "running" then
		return false, "An optimizer job is already running"
	end
	local context = currentOptimizerContext(self.build)
	local contextChanged = not contextMatches(self.contextAnchor, context)
	if contextChanged then
		rebindOptimizerContext(self, context, self.contextAnchor, false)
	end
	local resetUnspecifiedMatrixFields = type(options) == "table" and options.resetUnspecifiedMatrixFields == true
	local values = { }
	for _, definition in ipairs(Inputs.metricDefinitions) do
		values[definition.key] = resetUnspecifiedMatrixFields and "" or (self.textValues[definition.key] or "")
	end
	for _, definition in ipairs(textFieldDefinitions) do
		local value = not resetUnspecifiedMatrixFields and self.textValues[definition.key] or nil
		if value == nil then value = definition.default or "" end
		-- The typed MCP API defaults to the mixed search; the native UI keeps
		-- its explicit guided/tree phase selection when it starts a job itself.
		if resetUnspecifiedMatrixFields and definition.key == "generationPhase" then value = "combined" end
		values[definition.key] = value
	end
	if matrix and matrix.equipmentOverrides ~= nil then
		if type(matrix.equipmentOverrides) ~= "table" then
			self.statusMessage = "Invalid Matrix: equipmentOverrides must map PoB slot names to item IDs"
			self.result = nil
			return false, self.statusMessage
		end
		values.requiredItemsJson = Equipment.EncodeOverrides(matrix.equipmentOverrides)
	end
	for _, entry in ipairs({
		{ inputKey = "marketQuotes", textKey = "marketQuotesJson", limit = 32768 },
		{ inputKey = "manualItemPrices", textKey = "manualItemPricesJson", limit = 16384 },
	}) do
		local value = matrix and matrix[entry.inputKey]
		if value ~= nil then
			if type(value) ~= "table" then
				self.statusMessage = "Invalid Matrix: " .. entry.inputKey .. " must be an object"
				self.result = nil
				return false, self.statusMessage
			end
			local encoded, encodeError = json.encode(value)
			if type(encoded) ~= "string" or #encoded > entry.limit then
				self.statusMessage = "Invalid Matrix: " .. entry.inputKey .. " could not be encoded or exceeds " .. tostring(entry.limit) .. " characters"
				self.result = nil
				return false, self.statusMessage
			end
			values[entry.textKey] = encoded
		end
	end
	for key, value in pairs(matrix or { }) do
		if key ~= "equipmentOverrides" and key ~= "marketQuotes" and key ~= "manualItemPrices" and values[key] ~= nil then
			if (key == "searchAllClasses" or key == "searchStoredItems" or key == "searchSyntheticGear" or key == "nodePotentialAnalysis" or key == "useImportedRouteMemory") and type(value) == "boolean" then
				values[key] = value
			elseif type(value) ~= "string" and type(value) ~= "number" then
				self.statusMessage = "Invalid Matrix: " .. key .. " must be text, a number, or its supported boolean value"
				self.result = nil
				return false, self.statusMessage
			else
				local text = tostring(value)
				local maximumLength = key == "requiredItemsJson" and 4096 or key == "activityScheduleJson" and 32768 or 256
				if #text > maximumLength then
					self.statusMessage = "Invalid Matrix: " .. key .. " exceeds the " .. tostring(maximumLength) .. "-character limit"
					self.result = nil
					return false, self.statusMessage
				end
				values[key] = text
			end
		end
	end
	-- MCP callers commonly send only the all-class switch; the selector's saved
	-- default belongs to the visible UI and must not masquerade as an explicit
	-- single-class request in that typed API call.
	if (values.searchAllClasses == true or (type(values.searchAllClasses) == "string" and values.searchAllClasses:lower() == "true"))
		and (not matrix or matrix.baseClassId == nil) then
		values.baseClassId = ""
	end
	local routePlannerRunSpec
	if type(options) == "table" and options.routePlanner == true then
		local spec, floorsOrError = RoutePlanner.Prepare(self.build, values)
		if not spec then
			self.statusMessage = "Route Planner unavailable: " .. tostring(floorsOrError)
			self.result = nil
			return false, floorsOrError
		end
		routePlannerRunSpec = spec
		values.targetSkillGroupIndex = tostring(spec.skill.groupIndex)
		values.targetSkillIndex = tostring(spec.skill.skillIndex)
		values.targetSkillGemId = tostring(spec.skill.gemId)
		values.maxAddedPoints = tostring(spec.maxAddedPoints)
		values.maxTotalPoints = tostring(spec.maxTotalPoints)
		values.objectiveMetric = spec.objectiveMetric or "CombinedDPS"
		values.scenarioProfile = spec.scenario.profile
		values.scenarioEnemyPreset = spec.scenario.enemyPreset
		values.generationPhase = "combined"
		values.evaluationBudget = tostring(spec.budget.maxExactEvaluations)
		values.proposalBudget = tostring(spec.budget.maxProposals)
		values.timeoutSeconds = tostring(spec.budget.timeoutSeconds)
		values.damageFocus = spec.preferences.damageFocus
		values.defenseProfile = spec.preferences.defenseProfile
		values.rankingPriority = spec.preferences.rankingPriority
		values.conversionRoute = spec.conversion.routeText
		values.conversionMin = tostring(spec.conversion.minPercent)
		values.searchAllClasses = "false"
		values.searchStoredItems = "true"
		values.searchSyntheticGear = "true"
		for key, value in pairs(floorsOrError) do values[key] = tostring(value) end
	end
	local parsed, err = Inputs.Parse(values)
	if not parsed then
		self.statusMessage = "Invalid Matrix: " .. err
		self.result = nil
		return false, err
	end
	if routePlannerRunSpec then
		parsed.search.routePlannerRunSpec = routePlannerRunSpec
		parsed.search.allowSocketRepair = routePlannerRunSpec.skill.socketRepair ~= nil
			or #(routePlannerRunSpec.skill.socketRepairs or { }) > 0
		parsed.search.useShowNodePower = routePlannerRunSpec.nodePower.enabled == true
		parsed.search.nodePowerStat = routePlannerRunSpec.nodePower.selectedStat
		parsed.search.nodePowerFocusStat = routePlannerRunSpec.nodePower.requestedStat
		parsed.search.nodePowerFallbackReason = routePlannerRunSpec.nodePower.reason
	end
	if parsed.search.activitySchedule then
		local currentOutput = self.build.calcsTab and self.build.calcsTab.mainOutput
		local scheduleCheck, scheduleError = Activity.EvaluateOptimizerSchedule(parsed.search.activitySchedule, currentOutput, parsed)
		if not scheduleCheck then
			self.statusMessage = "Cannot optimize: saved activity gate is not valid for the current exact PoB build: " .. tostring(scheduleError)
			self.result = nil
			return false, scheduleError
		end
	end
	local buildValid, buildError = Inputs.ValidateBuild(self.build, parsed)
	if not buildValid then
		self.statusMessage = "Cannot optimize: " .. buildError
		self.result = nil
		return false, buildError
	end
	local valid, treeError = Inputs.ValidateAgainstTree(parsed, self.build.spec.tree)
	if not valid then
		self.statusMessage = "Invalid Matrix: " .. treeError
		self.result = nil
		return false, treeError
	end
	local objectiveValid, objectiveError = Inputs.ValidateObjective(self.build, parsed)
	if not objectiveValid then
		self.statusMessage = "Invalid objective: " .. objectiveError
		self.result = nil
		return false, objectiveError
	end
	local importedRouteMemoryEnabled = values.useImportedRouteMemory == true
		or tostring(values.useImportedRouteMemory or "false"):lower() == "true"
	if type(options) == "table" and options.useImportedRouteMemory ~= nil then
		importedRouteMemoryEnabled = options.useImportedRouteMemory == true
	end
	local evidencePriorities = type(options) == "table" and options.nodeEvidencePriorities or nil
	local edgeEvidencePriorities = type(options) == "table" and options.edgeEvidencePriorities or nil
	local importedRoutePatterns = { }
	if importedRouteMemoryEnabled and evidencePriorities == nil then
		local evidence
		if parsed.search.searchAllClasses then
			evidence = disabledNodeEvidence("class_specific_prior_disabled_for_all_class_comparison")
		else
			evidence = collectNodeEvidenceForDirection(self, values)
		end
		self.nodeEvidence = evidence
		evidencePriorities = evidence.priorities
		edgeEvidencePriorities = evidence.edgePriorities
		if routePlannerRunSpec and evidence.status == "ready" and evidence.archiveTruncated ~= true then
			importedRoutePatterns = boundedArchiveRoutePatterns(evidence.routePatterns, evidence.compatibleBuildCount)
		end
	elseif not importedRouteMemoryEnabled then
		self.nodeEvidence = { status = "disabled", compatibleBuildCount = 0, nodes = { }, edges = { }, priorities = { }, edgePriorities = { }, causal = false, readOnly = true }
	end
	parsed.search.importedRouteMemoryEnabled = importedRouteMemoryEnabled
	if routePlannerRunSpec then
		parsed.search.importedRoutePatterns = importedRouteMemoryEnabled and importedRoutePatterns or { }
		parsed.search.importedRoutePatternCount = #parsed.search.importedRoutePatterns
		parsed.search.importedRouteCompatibleBuildCount = importedRouteMemoryEnabled and self.nodeEvidence
			and tonumber(self.nodeEvidence.compatibleBuildCount) or 0
	end
	values.useImportedRouteMemory = importedRouteMemoryEnabled and "true" or "false"
	if parsed.search.nodePotentialAnalysis or importedRouteMemoryEnabled then
		parsed.search.nodeEvidencePriorities = boundedNodeEvidencePriorities(evidencePriorities)
		parsed.search.edgeEvidencePriorities = boundedEdgeEvidencePriorities(edgeEvidencePriorities)
	end
	self.textValues = values
	for key, value in pairs(values) do
		local control = self.controls["metric_" .. key] or self.controls["text_" .. key]
		if control then self.textValues[key] = setFieldControl(control, value) end
	end
	local inputSignature, signatureError = optimizerInputSignature(self.textValues)
	local sourceSignatureOk, sourceSignature = pcall(Candidate.BuildSignature, self.build)
	if not inputSignature or not sourceSignatureOk or type(sourceSignature) ~= "string" or sourceSignature == "" then
		self.statusMessage = "Cannot optimize: result provenance could not be captured"
		self.result = nil
		return false, signatureError or (sourceSignatureOk and "Build signature is unavailable" or tostring(sourceSignature))
	end
	self.activeOptimizerInputSignature = inputSignature
	self.activeOptimizerSourceSignature = sourceSignature
	self.resultInputSignature = nil
	self.resultFreshness = nil
	self.modFlag = true
	self.result = nil
	self.selectedRouteResult = nil
	self.selectedRouteCandidate = nil
	if routePlannerRunSpec and type(options) == "table" and type(options.trainingAuthorization) == "table"
		and options.trainingAuthorization.consent == true and options.trainingAuthorization.rightsBasis == "user_authored" then
		control = control or { cancelled = false }
		control.gnnTrainingAuthorization = { consent = true, rightsBasis = "user_authored" }
	end
	if self.isolatedStudyWorker then
		control = control or { cancelled = false }
		-- An explicitly requested imported-build study contributes only exact,
		-- sanitized PoB outcomes to the local route memory. Keep the source build
		-- read-only; callers may still disable memory writes explicitly.
		if control.recordPathLearning == nil then control.recordPathLearning = true end
		control.isolatedStudy = true
	end
	if parsed.search.searchAllClasses then
		local classJob, classError = ClassSearch.Start(self.build, parsed, control)
		if not classJob then
			self.statusMessage = "Cannot compare all classes: " .. tostring(classError)
			self.result = nil
			return false, classError
		end
		self.job = classJob
	else
		self.job = PhantomSim.RunPhantomSim(self.build, parsed, control)
	end
	if self.job then self.job.routePlannerRun = routePlannerRunSpec ~= nil end
	-- Structural proposal generation and tree validation happen before any native
	-- calculation. Start the selected time budget only when the exact phase begins;
	-- otherwise a quick diagnostic can expire while it is still generating routes.
	self.activeRunDeadline = nil
	self.activeRunTimeoutSeconds = routePlannerRunSpec and tonumber(parsed.search.timeoutSeconds) or nil
	self.routePlannerTimedOut = false
	self.statusMessage = parsed.search.activitySchedule
		and ("Optimizer running with strict " .. (parsed.search.activitySchedule.scope == "all_enabled_skills" and "all-enabled-skill" or "Full DPS") .. " activity-sustain gate...")
		or "Optimizer running..."
	if contextChanged and self.contextNotice then self.statusMessage = self.statusMessage .. " " .. self.contextNotice end
	return true, self.job
end

function OptimizerTabClass:OpenEquipmentPhasePrompt()
	local controls = { }
	controls.message = new("LabelControl"):LabelControl(popupTopLeftAnchor(), { 20, 16, 466, 58 },
		"^8The applied Skills variation and its exact PoB metrics are saved as a checkpoint. Advance to Equipment optimization now?")
	setClippedPopupLabel(controls.message, 466, 14)
	controls.yes = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 282, 104, 110, 24 }, "Yes, continue", function()
		main:ClosePopup()
		prepareGenerationPhase(self, "equipment")
		self.modFlag = true
		self.statusMessage = "Skills checkpoint saved. Equipment is selected; run it when ready."
	end)
	controls.later = new("ButtonControl"):ButtonControl(popupTopLeftAnchor(), { 400, 104, 90, 24 }, "Later", function()
		main:ClosePopup()
		self.statusMessage = "Skills checkpoint saved. Equipment remains available when you are ready."
	end)
	main:OpenPopup(520, 154, DisplayText.Native("AI Planner — Skills checkpoint"), controls, "yes", "later", "later")
end

function OptimizerTabClass:ApplyCandidate(resultCandidate)
	if not resultCandidate or not resultCandidate.feasible then
		self.statusMessage = "No candidate passed every strict gate."
		return false, self.statusMessage
	end
	local resultPhase = tostring(resultCandidate.generationPhase or ""):lower()
	local selectedPhase = tostring(self.textValues.generationPhase or "tree"):lower()
	if resultPhase ~= "" and selectedPhase ~= resultPhase then
		self.statusMessage = "The generation phase changed after this result; run the selected phase again before applying."
		return false, self.statusMessage
	end
	local ok, message = Candidate.Apply(self.build, resultCandidate)
	if ok then
		local phaseNames = { tree = "Tree foundation", skills = "Skills and supports", equipment = "Equipment" }
		local nextPhase = resultPhase == "tree" and "skills" or resultPhase == "skills" and "equipment" or nil
		local checkpointJson, checkpointOrError = Checkpoints.Record(
			self.textValues.phaseCheckpointsJson, resultPhase, self.build, resultCandidate,
			resultCandidate.evaluation, resultCandidate.evaluation and resultCandidate.evaluation.objective or self.textValues.objectiveMetric,
			{ damageFocus = self.textValues.damageFocus, defenseProfile = self.textValues.defenseProfile,
				rankingPriority = self.textValues.rankingPriority })
		if checkpointJson then
			self.textValues.phaseCheckpointsJson = checkpointJson
			self.modFlag = true
		end
		if nextPhase then
			if resultPhase == "tree" then
				prepareGenerationPhase(self, nextPhase)
				self.modFlag = true
				self.statusMessage = (message or (phaseNames[resultPhase] .. " applied as a new PoB variation."))
					.. " Tree-only passive and branch constraints were cleared. Next phase: " .. phaseNames[nextPhase] .. "; run it against the applied build."
			else
				self.statusMessage = (message or "Skills and supports applied as a new PoB variation.")
					.. " Exact Skills checkpoint saved. Choose whether to advance to Equipment."
				if not checkpointJson then self.statusMessage = self.statusMessage .. " Checkpoint warning: " .. tostring(checkpointOrError) end
			end
		elseif resultPhase == "equipment" then
			self.statusMessage = (message or "Equipment applied as a new PoB variation.")
				.. " Tree, Skills and Equipment phases are complete; review final PoB diagnostics and warnings."
		else
			self.statusMessage = message or "Applied as a new passive-tree and/or skill-set variation."
		end
		if resultCandidate.unlinkedMainSkillPlan then
			self.statusMessage = self.statusMessage
				.. " The selected Main Skill remains an unlinked planner group; continue to Equipment and apply a real compatible socketed item before treating this as playable."
		end
		self.build.viewMode = "TREE"
		self.result = nil
		if resultPhase == "skills" then self:OpenEquipmentPhasePrompt() end
		local resultEvaluation = resultCandidate.evaluation or { }
		local usedPoints = tonumber(resultEvaluation.passivePointsUsed)
		local strictPointCap = tonumber(resultEvaluation.strictPointCap) or 120
		local nativePointLimit = tonumber(resultEvaluation.passivePointLimit)
		local usablePointCeiling = nativePointLimit and math.min(strictPointCap, nativePointLimit) or strictPointCap
		if resultPhase == "tree" and usedPoints and usedPoints < usablePointCeiling then
			self.statusMessage = self.statusMessage .. string.format(
				" Partial tree checkpoint: %d of %d level/Matrix-allowed points used. Review the remaining passives before calling it a finished build.",
				math.floor(usedPoints), math.floor(usablePointCeiling))
		end
	else
		self.statusMessage = "Could not apply result: " .. tostring(message)
	end
	return ok, message
end

function OptimizerTabClass:ApplyResult()
	if not self.result or self.result.status ~= "feasible" or not self.result.candidate then
		self.statusMessage = "No candidate passed every strict gate."
		return false, self.statusMessage
	end
	local freshness, freshnessError = OptimizerTabClass.RefreshResultFreshness(self, true)
	if freshness ~= "current" then
		self.statusMessage = freshness == "stale"
			and ("Cannot apply stale optimizer result: " .. tostring(freshnessError or "the build or Matrix changed"))
			or ("Cannot apply optimizer result not verified for the current build: " .. tostring(freshnessError or "missing provenance"))
		return false, self.statusMessage
	end
	return self:ApplyCandidate(self.result.candidate)
end

function OptimizerTabClass:Tick()
	local catalogJobs = self.routePlannerModelCatalogJobs
	if catalogJobs then
		for index = #catalogJobs, 1, -1 do
			local catalogJob = catalogJobs[index]
			if coroutine.status(catalogJob.co) ~= "dead" then
				local resumed, result = coroutine.resume(catalogJob.co)
				if not resumed then result = { status = "unavailable", error = tostring(result), models = { } } end
				if coroutine.status(catalogJob.co) == "dead" and self.routePlannerModelCatalogJob == catalogJob then
					if type(result) ~= "table" then result = { status = "unavailable", error = "Resposta do catálogo de modelos inválida", models = { } } end
					result.key = catalogJob.key
					self.routePlannerModelCatalog = result
					self:UpdateRoutePlannerModelDropdown()
				end
			end
			if coroutine.status(catalogJob.co) == "dead" then table.remove(catalogJobs, index) end
		end
	end
	local seedCatalogJobs = self.routePlannerSeedCatalogJobs
	if seedCatalogJobs then
		for index = #seedCatalogJobs, 1, -1 do
			local seedJob = seedCatalogJobs[index]
			if coroutine.status(seedJob.co) ~= "dead" then
				local resumed, result = coroutine.resume(seedJob.co)
				if not resumed then result = { status = "unavailable", seeds = { }, error = tostring(result) } end
				if coroutine.status(seedJob.co) == "dead" and self.routePlannerSeedCatalogJob == seedJob then
					if type(result) ~= "table" then
						result = { status = "unavailable", seeds = { }, error = "Resposta inválida do catálogo de builds-semente" }
					end
					result.key = seedJob.key
					self.routePlannerSeedCatalog = result
					if self.routePlannerSeedPickerUpdater then self.routePlannerSeedPickerUpdater() end
				elseif coroutine.status(seedJob.co) ~= "dead" and self.routePlannerSeedCatalogJob == seedJob then
					seedJob.progress = type(result) == "table" and result or seedJob.progress
				end
			end
			if coroutine.status(seedJob.co) == "dead" then table.remove(seedCatalogJobs, index) end
		end
	end
	if self.job and self.job.status == "running" then
		local activeJob = self.job
		local activeProgress = type(activeJob.progress) == "table" and activeJob.progress or { }
		if activeJob.routePlannerRun == true and self.activeRunTimeoutSeconds
			and not self.activeRunDeadline and not self.routePlannerTimedOut
			and tostring(activeProgress.phase or "") == "Exact calculations" then
			self.activeRunDeadline = os.clock() + self.activeRunTimeoutSeconds
		end
		if self.activeRunDeadline and os.clock() >= self.activeRunDeadline then
			activeJob:Cancel("timeout")
			self.routePlannerTimedOut = true
			self.activeRunDeadline = nil
			self.statusMessage = "AI Analyzer atingiu o prazo selecionado de "
				.. groupedNumber(self.activeRunTimeoutSeconds or 0)
				.. " segundos de recálculo exato; resultados concluídos serão preservados."
		end
		local status, result = activeJob:Step()
		if status == "running" then
			local progress = activeJob.progress or { }
			local current = progress.current or progress.currentClass
			local classLabel = progress.classCount and string.format("; class %d/%d", progress.classIndex or 0, progress.classCount) or ""
			if activeJob.routePlannerRun == true then
				local routePhases = {
					["Preparing native ascendancy routes"] = "Preparando rotas de ascendência",
					["Generating native ascendancy routes"] = "Gerando rotas de ascendência",
					["Pathfinding"] = "Buscando caminhos na árvore",
					["Mining path patterns"] = "Avaliando padrões de rota",
					["Applying contextual path evidence"] = "Combinando evidências locais",
					["Candidate reconstruction"] = "Gerando combinações",
					["Tree validation"] = "Validando rotas",
					["Exact calculations"] = "Recalculando combinações no PoB",
				}
				local processed = math.max(0, tonumber(progress.processed) or 0)
				local total = math.max(0, tonumber(progress.total) or 0)
				local completion = total > 0 and string.format(" (%d%%)", math.min(100, math.floor(processed * 100 / total))) or ""
				local attempt = tonumber(progress.candidatesExamined)
				local attemptTotal = tonumber(progress.candidateAttemptTotal)
				local attemptStatus = attempt and attemptTotal and (" | propostas verificadas "
					.. groupedNumber(attempt) .. "/" .. groupedNumber(attemptTotal)) or ""
				self.statusMessage = "AI Analyzer — " .. tostring(routePhases[tostring(progress.phase)] or progress.phase or "Preparando busca")
					.. ": " .. groupedNumber(processed) .. " / " .. groupedNumber(total) .. completion
					.. attemptStatus
					.. (current and (" | " .. sanitizeDetailText(current)) or "") .. classLabel
			else
				self.statusMessage = string.format("%s: %d / %d%s%s", progress.phase or "Running", progress.processed or 0, progress.total or 0,
					current and (" - " .. current) or "", classLabel)
			end
		else
			self.activeRunDeadline = nil
			self.activeRunTimeoutSeconds = nil
			self.result = result
			self.job = nil
			if type(result) == "table" then
				if activeJob.routePlannerRun == true then result.routePlanner = true end
				result.sourceSignature = result.sourceSignature or activeJob.sourceSignature or self.activeOptimizerSourceSignature
				result.inputSignature = result.inputSignature or activeJob.inputSignature or self.activeOptimizerInputSignature
				self.resultInputSignature = result.inputSignature
				self.resultFreshness = nil
				if self.routePlannerTimedOut then
					result.searchInterrupted = true
					result.searchTimedOut = true
				end
			end
			if self.routePlannerTimedOut then
				self.statusMessage = "Route search timed out; completed exact results are preserved."
				self.routePlannerTimedOut = false
			end
			if result and result.status == "node_potential_complete" then
				self.nodePotentialResult = result
				self.nodePotentialRunActive = false
				self.textValues.nodePotentialAnalysis = "false"
				self.statusMessage = string.format("Node analysis complete: %d exact PoB calculations, %d passive routes, no allocation applied.",
					result.evaluations or 0, #(result.results or { }))
			elseif result and result.status == "no_feasible_candidate" and self.nodePotentialRunActive then
				self.nodePotentialResult = result
				self.nodePotentialRunActive = false
				self.statusMessage = "Node analysis found no feasible route within the current branch, point and hard-gate limits."
			elseif result and result.status == "feasible" then
				local evaluation = result.evaluation or { }
				local phaseName = ({ tree = "Tree foundation", skills = "Skills", equipment = "Equipment", combined = "Combined search" })[result.generationPhase or self.textValues.generationPhase] or "Optimizer"
				local objective = evaluation.objective or "Objective"
				local objectiveValue = evaluation.metrics and evaluation.metrics[objective]
				local pointLabel = string.format("%d/%d points", evaluation.passivePointsUsed or 0, evaluation.strictPointCap or 120)
				local actionAudit = evaluation.manualActionAudit
				local actionLabel = ""
				if actionAudit and (actionAudit.limit ~= nil or actionAudit.damageLimit ~= nil) then
					actionLabel = string.format("; manual %d (damage %d, utility %d)",
						actionAudit.manualButtonCount or 0,
						actionAudit.manualDamageButtonCount or 0,
						actionAudit.manualUtilityButtonCount or 0)
					if actionAudit.limit ~= nil then actionLabel = actionLabel .. "; total cap " .. tostring(actionAudit.limit) end
					if actionAudit.damageLimit ~= nil then
						actionLabel = actionLabel .. "; damage cap " .. tostring(actionAudit.damageLimit)
					end
				end
				local classSearchLabel = result.classSearch and string.format("; compared %d class starts with equal budget", result.classSearch.classCount or 0) or ""
				if result.routePlanner == true then
					local baseline = routePlannerComparisonBaseline(result) or { }
					local visibleRouteCount, counted, metricVectors, distinctMetricCount = 0, { }, { }, 0
					local statusRoute
					local routeMetricKeys = { "CombinedDPS", "FullDPS", "FullDotDPS", "TotalEHP", "Life", "EnergyShield",
						"PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken",
						"FireResist", "ColdResist", "LightningResist", "ChaosResist", "SpellSuppressionChance",
						"BlockChance", "Armour", "Evasion" }
					local focusMetric = Ranking.DamageFocusMetricKey(tostring(self.textValues.damageFocus or "Auto"))
					if focusMetric then routeMetricKeys[#routeMetricKeys + 1] = focusMetric end
					local function countRoute(route)
						if type(route) ~= "table" or counted[route] or route.feasible ~= true
							or route.sourceSignature ~= result.sourceSignature
							or type(route.evaluation) ~= "table" or route.evaluation.feasible ~= true
							or type(route.evaluation.metrics) ~= "table" or not Candidate.HasMutation(route)
							or routePlannerProposalUsesFlask(self.build, route) then return end
						local vectorParts = { }
						for _, key in ipairs(routeMetricKeys) do
							local value = route.evaluation.metrics[key]
							vectorParts[#vectorParts + 1] = key .. "=" .. (isFiniteNumber(value) and string.format("%.17g", value) or "-")
						end
						local vector = table.concat(vectorParts, "|")
						counted[route] = true
						visibleRouteCount = visibleRouteCount + 1
						if not metricVectors[vector] then
							metricVectors[vector] = true
							distinctMetricCount = distinctMetricCount + 1
						end
						statusRoute = statusRoute or route
					end
					countRoute(result.candidate)
					for _, route in ipairs(result.paretoFront or { }) do countRoute(route) end
					local statusEvaluation = statusRoute and statusRoute.evaluation or evaluation
					local statusMetrics = statusEvaluation.metrics or { }
					local statusObjective = statusEvaluation.objective or objective
					local statusObjectiveValue = statusMetrics[statusObjective]
					local summaryParts = { }
					if type(statusObjectiveValue) == "number" then
						local objectiveLabel = statusObjective == "CombinedDPS" and "DPS da skill"
							or statusObjective == "FullDPS" and "DPS total" or metricDisplayName(statusObjective)
						local line = objectiveLabel .. ": " .. metricDisplayValue(statusObjective, statusObjectiveValue)
						if type(baseline[statusObjective]) == "number" then
							line = line .. " (Δ " .. metricDisplayDelta(statusObjective, statusObjectiveValue, baseline[statusObjective]) .. ")"
						end
						summaryParts[#summaryParts + 1] = line
					end
					local ehpValue = statusMetrics.TotalEHP
					if statusObjective ~= "TotalEHP" and type(ehpValue) == "number" then
						local ehpLine = "EHP: " .. metricDisplayValue("TotalEHP", ehpValue)
						if type(baseline.TotalEHP) == "number" then
							ehpLine = ehpLine .. " (Δ " .. metricDisplayDelta("TotalEHP", ehpValue, baseline.TotalEHP) .. ")"
						end
						summaryParts[#summaryParts + 1] = ehpLine
					end
					local statusRouteLabel = statusRoute
						and sanitizeDetailText(statusRoute.label or statusRoute.evaluation.candidateLabel or "") or ""
					if statusRouteLabel ~= "" then summaryParts[#summaryParts + 1] = "Rota: " .. statusRouteLabel end
					local targetNodeId = tostring(self.textValues.routePlannerTargetNodeId or "")
					local targetNodeName = sanitizeDetailText(self.textValues.routePlannerTargetNodeName or "")
					local targetSummary = targetNodeId ~= "" and (" | Alvo: " .. (targetNodeName ~= "" and targetNodeName or ("nó #" .. targetNodeId))) or ""
					if visibleRouteCount > 0 then
						local metricProfileNoun = distinctMetricCount == 1 and "perfil métrico" or "perfis métricos"
						local metricProfileSummary = distinctMetricCount < visibleRouteCount
							and (" (" .. groupedNumber(distinctMetricCount) .. " " .. metricProfileNoun .. ")") or ""
						self.statusMessage = "AI Analyzer concluído: " .. groupedNumber(visibleRouteCount)
							.. " rotas exatas aprovadas" .. metricProfileSummary .. " | " .. table.concat(summaryParts, " | ")
							.. " | " .. groupedNumber(result.evaluations or 0) .. " recálculos nativos do PoB"
							.. targetSummary .. " | clique em Ver rotas para comparar e carregar uma variação."
					elseif not Candidate.HasMutation(result.candidate) then
						self.statusMessage = "AI Analyzer concluído: a build base já passa os hard gates; nenhuma rota alterada foi aprovada"
							.. " | " .. groupedNumber(result.evaluations or 0) .. " recálculos nativos do PoB" .. targetSummary .. "."
					else
						self.statusMessage = "AI Analyzer concluiu " .. groupedNumber(result.evaluations or 0)
							.. " recálculos exatos; a melhor rota encontrada passou os hard gates" .. targetSummary .. "."
					end
			else
				if not Candidate.HasMutation(result.candidate) then
					self.statusMessage = string.format("%s: %s meets every hard gate - %s %s; %s%s.", phaseName, evaluation.scenarioProfile or "Current scenario", objective,
						objectiveValue and string.format("%.4g", objectiveValue) or "exact output unavailable", pointLabel, actionLabel .. classSearchLabel)
				else
					self.statusMessage = string.format("%s: %s feasible - %s %s; %s%s; %d exact evaluations.", phaseName, evaluation.scenarioProfile or "Current scenario", objective,
						objectiveValue and string.format("%.4g", objectiveValue) or "exact output unavailable",
						pointLabel, actionLabel .. classSearchLabel, result.evaluations or 0)
				end
			end
				local resultPhase = tostring(result.generationPhase or self.textValues.generationPhase or ""):lower()
				local usedPoints = tonumber(evaluation.passivePointsUsed)
				local strictPointCap = tonumber(evaluation.strictPointCap) or 120
				local nativePointLimit = tonumber(evaluation.passivePointLimit)
			local usablePointCeiling = nativePointLimit and math.min(strictPointCap, nativePointLimit) or strictPointCap
				if resultPhase == "tree" and usedPoints and usedPoints < usablePointCeiling then
					self.statusMessage = self.statusMessage .. string.format(
						" Partial tree checkpoint: %d of %d level/Matrix-allowed points used; this is not a completed character build.",
						math.floor(usedPoints), math.floor(usablePointCeiling))
				end
				if result.candidate and result.candidate.unlinkedSupportPlan then
					self.statusMessage = self.statusMessage .. " Support gems are an exact PoB planning simulation; this group has no item socket/link and is not playable until assigned to a compatible linked item."
				end
				if result.candidate and result.candidate.unlinkedMainSkillPlan then
					self.statusMessage = self.statusMessage .. " Main Skill is a calculation-only planner checkpoint; apply a compatible socketed item in Equipment before treating it as playable."
				end
				if result.routePlanner ~= true then
				local zoneSummary = OptimizerTabClass.FormatZoneOutcomeSummary(result.searchCoverage and result.searchCoverage.zones, true)
				if zoneSummary then self.statusMessage = self.statusMessage .. " | " .. zoneSummary end
				local repairSummary = OptimizerTabClass.FormatRequirementRepairSummary(result.searchCoverage and result.searchCoverage.requirementRepair)
				if repairSummary then self.statusMessage = self.statusMessage .. " | " .. repairSummary end
				local catalystSummary = OptimizerTabClass.FormatCatalystSearchSummary(result.searchCoverage and result.searchCoverage.catalysts)
				if catalystSummary then self.statusMessage = self.statusMessage .. " | " .. catalystSummary end
				local syntheticSummary = OptimizerTabClass.FormatSyntheticGearSummary(result.searchCoverage and result.searchCoverage.syntheticGear)
				if syntheticSummary then self.statusMessage = self.statusMessage .. " | " .. syntheticSummary end
				local flaskSummary = OptimizerTabClass.FormatFlaskExceptionSummary(evaluation.scenario and evaluation.scenario.flaskAudit)
				if flaskSummary then self.statusMessage = self.statusMessage .. " | " .. flaskSummary end
				local assumptionSummary = OptimizerTabClass.FormatScenarioAssumptionSummary(evaluation.scenario)
				if assumptionSummary then self.statusMessage = self.statusMessage .. " | " .. assumptionSummary end
				local rankerSummary = OptimizerTabClass.FormatLearningRankerSummary(result.searchCoverage and result.searchCoverage.learningRanker)
				if rankerSummary then self.statusMessage = self.statusMessage .. " | " .. rankerSummary end
				local pathSummary = OptimizerTabClass.FormatPathExperienceSummary(result.searchCoverage and result.searchCoverage.pathLearning)
				if pathSummary then self.statusMessage = self.statusMessage .. " | " .. pathSummary end
				local supportCoverage = result.searchCoverage and result.searchCoverage.phase
				if supportCoverage and ((supportCoverage.exactSupportAddEvaluations or 0) > 0
					or (supportCoverage.exactSupportSwapEvaluations or 0) > 0) then
					local supportSummary = OptimizerTabClass.FormatSupportPackageSummary(supportCoverage)
					if supportSummary then self.statusMessage = self.statusMessage .. " | " .. supportSummary end
				end
				end
			elseif result and result.status == "no_feasible_candidate" then
				local phaseName = ({ tree = "Tree foundation", skills = "Skills", equipment = "Equipment", combined = "Combined search" })[result.generationPhase or self.textValues.generationPhase] or "Optimizer"
				if result.routePlanner == true then
					local nearMissCount = type(result.nearMisses) == "table" and #result.nearMisses or 0
					if result.searchTimedOut == true then
						self.statusMessage = "AI Analyzer atingiu o prazo de recálculo após "
							.. groupedNumber(tonumber(result.evaluations) or 0) .. " cálculos exatos; nenhuma rota passou todos os hard gates."
					elseif nearMissCount > 0 then
						self.statusMessage = "AI Analyzer concluído: 0 rotas passaram todos os hard gates; "
							.. groupedNumber(nearMissCount) .. " candidatas exatas falharam em pelo menos um piso."
					else
						self.statusMessage = "AI Analyzer concluído: 0 rotas aprovadas dentro do orçamento; nenhuma candidata exata ficou disponível."
					end
				else
					self.statusMessage = result.classSearch and (phaseName .. ": no feasible candidate across the class-start budgets; open Class results for per-class coverage and deficits.")
						or (phaseName .. ": no feasible candidate within budget; best observed deficit is shown below.")
				end
				if result.routePlanner ~= true then
				if result.routePlanner ~= true then
				local zoneSummary = OptimizerTabClass.FormatZoneOutcomeSummary(result.searchCoverage and result.searchCoverage.zones, false)
				if zoneSummary then self.statusMessage = self.statusMessage .. " | " .. zoneSummary end
				local repairSummary = OptimizerTabClass.FormatRequirementRepairSummary(result.searchCoverage and result.searchCoverage.requirementRepair)
				if repairSummary then self.statusMessage = self.statusMessage .. " | " .. repairSummary end
				local catalystSummary = OptimizerTabClass.FormatCatalystSearchSummary(result.searchCoverage and result.searchCoverage.catalysts)
				if catalystSummary then self.statusMessage = self.statusMessage .. " | " .. catalystSummary end
				local syntheticSummary = OptimizerTabClass.FormatSyntheticGearSummary(result.searchCoverage and result.searchCoverage.syntheticGear)
				if syntheticSummary then self.statusMessage = self.statusMessage .. " | " .. syntheticSummary end
				local scenarioDetails = result.scenario or (result.evaluation and result.evaluation.scenario)
				local flaskSummary = OptimizerTabClass.FormatFlaskExceptionSummary(scenarioDetails and scenarioDetails.flaskAudit)
				if flaskSummary then self.statusMessage = self.statusMessage .. " | " .. flaskSummary end
				local assumptionSummary = OptimizerTabClass.FormatScenarioAssumptionSummary(scenarioDetails)
				if assumptionSummary then self.statusMessage = self.statusMessage .. " | " .. assumptionSummary end
				local rankerSummary = OptimizerTabClass.FormatLearningRankerSummary(result.searchCoverage and result.searchCoverage.learningRanker)
				if rankerSummary then self.statusMessage = self.statusMessage .. " | " .. rankerSummary end
				local pathSummary = OptimizerTabClass.FormatPathExperienceSummary(result.searchCoverage and result.searchCoverage.pathLearning)
				if pathSummary then self.statusMessage = self.statusMessage .. " | " .. pathSummary end
				local supportCoverage = result.searchCoverage and result.searchCoverage.phase
				if supportCoverage and ((supportCoverage.exactSupportAddEvaluations or 0) > 0
					or (supportCoverage.exactSupportSwapEvaluations or 0) > 0) then
					local supportSummary = OptimizerTabClass.FormatSupportPackageSummary(supportCoverage)
					if supportSummary then self.statusMessage = self.statusMessage .. " | " .. supportSummary end
				end
				end
				end
			elseif result and result.status == "invalid_inputs" then
				self.statusMessage = "Invalid Matrix: " .. tostring(result.message)
			elseif result and result.status == "stale_build" then
				self.statusMessage = result.message or "The build changed during optimization; run the search again."
			elseif result and (result.status == "timed_out" or result.searchTimedOut == true) then
				self.statusMessage = "AI Analyzer atingiu o prazo antes de concluir recálculos exatos; nenhuma rota não calculada foi mostrada."
			elseif result and result.status == "cancelled" then
				self.statusMessage = "Search cancelled after " .. tostring(result.evaluations or 0) .. " exact evaluations."
			else
				self.statusMessage = "Optimizer error: " .. tostring((result and result.message) or activeJob.error or "unknown failure")
			end
			local exportStatus = activeJob.gnnTrainingExportStatus
			if exportStatus then
				if exportStatus.status == "exported" then
					self.statusMessage = self.statusMessage .. string.format(" Local training export: %d exact rows saved to 01_Inbox (%s).",
						exportStatus.rows or 0, tostring(exportStatus.fileName or "shard"))
				elseif exportStatus.status == "empty" then
					self.statusMessage = self.statusMessage .. " No exact candidate passed the local training export filters."
				else
					self.statusMessage = self.statusMessage .. " Local training export failed: " .. tostring(exportStatus.message or "daemon unavailable")
				end
			end
			if result and result.searchInterrupted == true then
				local interruptionText = result.searchTimedOut == true
					and "Prazo de recálculo atingido após " or "Busca interrompida após "
				self.statusMessage = self.statusMessage .. string.format(
					" %s%d recálculos exatos concluídos; só candidatas já recalculadas pelo PoB e aprovadas nos gates aparecem como rotas.",
					interruptionText, tonumber(result.evaluations) or 0)
			end
		end
	end
	if self.classRootJob and self.classRootJob.status == "running" then
		local activeJob = self.classRootJob
		local status, result = activeJob:Step()
		if status == "running" then
			local progress = activeJob.progress or { }
			self.statusMessage = string.format("Class starts: %d / %d%s", progress.processed or 0, progress.total or 0, progress.current and (" - " .. progress.current) or "")
		else
			self.classRootResult = result
			self.classRootJob = nil
			if result and result.status == "complete" then
				self.statusMessage = "Seven class-start baselines calculated with the exact PoB engine. Click Compare roots to view them."
			else
				self.statusMessage = "Class-root comparison " .. tostring(result and result.status or "failed") .. "."
			end
		end
	end
	if self.aiRequestId and main.optimizerMCP then
		local request = main.optimizerMCP:GetUserRequestStatus(self.aiRequestId, self.build)
		if request then
			local oldStatus = self.aiRequestData and self.aiRequestData.status
			self.aiRequestData = request
			if request.status ~= oldStatus then
				if request.status == "processing" then
					self.statusMessage = "The connected AI chat is processing request " .. request.id .. "."
				elseif request.status == "completed" then
					self.statusMessage = "AI request " .. request.id .. " completed. Click Ask AI to read the response."
				elseif request.status == "failed" or request.status == "stale" then
					self.statusMessage = "AI request " .. request.id .. " " .. request.status .. "."
				end
			end
		end
	end
end

function OptimizerTabClass:Load(xml, dbFileName)
	for _, child in ipairs(xml) do
		if type(child) == "table" and child.elem == "Context" then
			self.loadedOptimizerContext = contextFromXML(child.attrib)
		elseif type(child) == "table" and child.elem == "Input" and child.attrib and child.attrib.name then
			self.hasPersistedOptimizerInputs = true
			local name = child.attrib.name
			if self.textValues[name] ~= nil then
				self.textValues[name] = child.attrib.value or ""
				local control = self.controls["metric_" .. name] or self.controls["text_" .. name]
				if control then self.textValues[name] = setFieldControl(control, self.textValues[name]) end
			end
		end
	end
	local generationPhase = tostring(self.textValues.generationPhase or "tree"):lower()
	if not Inputs.generationPhases[generationPhase] then generationPhase = "tree" end
	prepareGenerationPhase(self, generationPhase)
	local pointCap = tonumber(self.textValues.maxTotalPoints)
	if not pointCap or pointCap ~= math.floor(pointCap) then
		pointCap = 120
	elseif pointCap > 130 then
		pointCap = 130
	elseif pointCap < 1 then
		pointCap = 1
	end
	self.textValues.maxTotalPoints = tostring(pointCap)
	local pointCapControl = self.controls.text_maxTotalPoints
	if pointCapControl then pointCapControl:SetText(self.textValues.maxTotalPoints, false) end
	if self.controls.pointCapSlider then self.controls.pointCapSlider.val = (pointCap - 1) / 129 end
	if self.RefreshOverviewDirectionControls then self.RefreshOverviewDirectionControls(true) end
	self.modFlag = false
end

function OptimizerTabClass:FinalizeBuildContext()
	local context = currentOptimizerContext(self.build)
	local previous = self.loadedOptimizerContext or self.contextAnchor
	local legacy = self.hasPersistedOptimizerInputs and self.loadedOptimizerContext == nil
	local changed = legacy or not contextMatches(previous, context)
	if changed then rebindOptimizerContext(self, context, previous, legacy) end
	self.contextAnchor = context
	self.loadedOptimizerContext = context
	self.hasPersistedOptimizerInputs = false
	if self.RefreshOverviewDirectionControls then self.RefreshOverviewDirectionControls(true) end
end

local archivedSeedContextFields = {
	baseClassId = true, ascendancyId = true, searchAllClasses = true,
	targetSkillGroupIndex = true, targetSkillIndex = true, targetSkillGemId = true,
	targetNodeIds = true, addNodeIds = true, removeNodeIds = true, requiredNodeIds = true, forbiddenNodeIds = true,
	allowedRegions = true, requiredRegions = true, forbiddenRegions = true,
	routePlannerModelMode = true, routePlannerModelPackageId = true,
	routePlannerTargetNodeId = true, routePlannerTargetNodeName = true, routePlannerTargetTreeVersion = true,
	routePlannerSeedXmlSha256 = true, phaseCheckpointsJson = true, requiredItemsJson = true,
	marketQuotesJson = true, manualItemPricesJson = true,
}

function OptimizerTabClass:CaptureArchivedSeedPreferences()
	local preferences = { }
	for key, value in pairs(self.textValues or { }) do
		if not archivedSeedContextFields[key] and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
			preferences[key] = tostring(value)
		end
	end
	return preferences
end

function OptimizerTabClass:ApplyArchivedSeedPreferences(preferences)
	if type(preferences) ~= "table" then return false end
	for key, value in pairs(preferences) do
		if self.textValues[key] ~= nil and not archivedSeedContextFields[key]
			and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
			self.textValues[key] = tostring(value)
		end
	end
	local context = currentOptimizerContext(self.build)
	self.textValues.baseClassId = context.classId ~= nil and tostring(context.classId) or ""
	self.textValues.ascendancyId = ""
	self.textValues.searchAllClasses = "false"
	self.textValues.targetSkillGroupIndex = context.groupIndex and tostring(context.groupIndex) or ""
	self.textValues.targetSkillIndex = context.skillIndex and tostring(context.skillIndex) or ""
	self.textValues.targetSkillGemId = tostring(context.gemId or "")
	for _, key in ipairs({ "targetNodeIds", "addNodeIds", "removeNodeIds", "requiredNodeIds", "forbiddenNodeIds",
		"allowedRegions", "requiredRegions", "forbiddenRegions", "routePlannerTargetNodeId",
		"routePlannerTargetNodeName", "routePlannerTargetTreeVersion" }) do
		self.textValues[key] = ""
	end
	self.textValues.routePlannerModelMode = "deterministic_fallback"
	self.textValues.routePlannerModelPackageId = ""
	self.textValues.routePlannerSeedXmlSha256 = ""
	self.textValues.phaseCheckpointsJson = "{}"
	self.textValues.requiredItemsJson = "{}"
	self.textValues.marketQuotesJson = "{}"
	self.textValues.manualItemPricesJson = "{}"
	self.textValues.nodePotentialAnalysis = "false"
	self.nodeEvidence = nil
	self.result = nil
	self.nodePotentialResult = nil
	self.activeRunDeadline = nil
	self.activeRunTimeoutSeconds = nil
	self.routePlannerTimedOut = nil
	self.contextAnchor = context
	self.loadedOptimizerContext = context
	self.hasPersistedOptimizerInputs = false
	for key, value in pairs(self.textValues) do
		local control = self.controls["metric_" .. key] or self.controls["text_" .. key]
		if control then self.textValues[key] = setFieldControl(control, value) end
	end
	if self.RefreshOverviewDirectionControls then self.RefreshOverviewDirectionControls(true) end
	self.statusMessage = "Build-semente carregada; metas do Planner preservadas e classe/skill vinculadas à build nova."
	self.modFlag = true
	return true
end

function OptimizerTabClass:Save(xml)
	for name, value in pairs(self.textValues) do
		t_insert(xml, { elem = "Input", attrib = { name = name, value = tostring(value) } })
	end
	local context = currentOptimizerContext(self.build)
	t_insert(xml, { elem = "Context", attrib = {
		version = "1",
		classId = context.classId ~= nil and tostring(context.classId) or "",
		ascendancyId = tostring(context.ascendancyId or 0),
		treeVersion = tostring(context.treeVersion or ""),
		groupIndex = context.groupIndex and tostring(context.groupIndex) or "",
		skillIndex = context.skillIndex and tostring(context.skillIndex) or "",
		gemId = tostring(context.gemId or ""),
	} })
	self.contextAnchor = context
	self.loadedOptimizerContext = context
	self.modFlag = false
end

local function optimizerMetricText(value)
	return type(value) == "number" and string.format("%.4g", value) or "n/a"
end

local function optimizerDeltaText(value)
	return isFiniteNumber(value) and string.format("%+.4g", value) or "n/a"
end

function OptimizerTabClass:DrawNodePotentialPage(viewPort)
	local x, width = viewPort.x + 12, math.max(0, viewPort.width - 24)
	drawPlannerString(x, viewPort.y + 56, "LEFT", 15, "VAR", "^7Potencial dos nós — comparação exata de rotas")
	drawPlannerString(x, viewPort.y + 104, "LEFT", 12, "VAR", "^8Usa a skill selecionada, os itens atuais e o cálculo exato do PoB. Respeita filtros de ramo, limite de pontos e requisitos rígidos da Matrix.")
	local result = self.nodePotentialResult
	if not result then
		drawPlannerString(x, viewPort.y + 134, "LEFT", 13, "VAR", "^8Selecione Analisar skill para calcular a base e comparar rotas limitadas da árvore.")
		local checkpoints = Checkpoints.GetSummary(self.textValues.phaseCheckpointsJson, self.build)
		local checkpointLabels = { }
		for _, entry in ipairs(checkpoints.phases) do
			local phaseName = ({ tree = "Árvore", skills = "Skills", equipment = "Equipamento", combined = "Combinada" })[entry.phase] or entry.phase
			checkpointLabels[#checkpointLabels + 1] = phaseName .. " " .. (entry.status == "current" and "atual" or entry.status == "stale" and "desatualizada" or "guardada")
		end
		drawPlannerString(x, viewPort.y + 162, "LEFT", 12, "VAR", "^8Etapas aplicadas: " .. (#checkpointLabels > 0 and table.concat(checkpointLabels, " → ") or "nenhuma"))
		return
	end
	local preferences = result.preferences or { }
	local damageFocus = preferences.damageFocus or "Auto"
	local defenseProfile = preferences.defenseProfile or "Auto"
	local damageMetric, defenseMetric
	for _, focus in ipairs(result.focusMetrics or { }) do
		if focus.role == "damage" or focus.role == "objective" then damageMetric = damageMetric or focus end
		if focus.role == "defense" then defenseMetric = focus end
	end
	local baseline = result.baselineMetrics or { }
	local selectedSkill = tostring(result.skillName or self.directionSkillSelection or self.textValues.targetSkillGemId or "Main Skill")
	local damageDescription = damageMetric and (damageMetric.label .. " " .. optimizerMetricText(baseline[damageMetric.key])) or "métrica de dano indisponível"
	local defenseDescription = defenseMetric and (defenseMetric.label .. " " .. optimizerMetricText(baseline[defenseMetric.key])) or "sem perfil defensivo"
	local line = string.format("^8Skill: %s | %s → %s | %s → %s | PoB %s / árvore %s",
		clipStatusText(selectedSkill, math.min(210, width * 0.30), 12), damageFocus, damageDescription, defenseProfile, defenseDescription,
		tostring(result.version and result.version.dataVersion or "unknown"),
		tostring(result.version and result.version.treeVersion or "unknown"))
	drawPlannerString(x, viewPort.y + 126, "LEFT", 12, "VAR", line)
	drawPlannerString(x, viewPort.y + 142, "LEFT", 11, "VAR", "^8Tags da gema: " .. clipStatusText(result.skillTags or "indisponíveis", width, 11))
	local focusNote = #(result.focusNotes or { }) > 0 and table.concat(result.focusNotes, "; ") or nil
	if focusNote then
		drawPlannerString(x, viewPort.y + 158, "LEFT", 11, "VAR", "^8" .. clipStatusText(focusNote, width, 11))
	end
	local evidence = self.nodeEvidence
	local evidenceText
	if not evidence then
		evidenceText = "Grafo importado indisponível; continuam a valer as ligações nativas da árvore e os resultados exatos do PoB."
	elseif evidence.archiveGeneration ~= StudyBuilds.Generation() then
		evidenceText = "O arquivo mudou após esta análise; execute novamente para atualizar os padrões importados."
	elseif evidence.status == "ready" then
		evidenceText = string.format("Grafo importado: %d builds da mesma versão | %d nós | %d ligações observadas; frequência só desempata propostas.",
			evidence.compatibleBuildCount or 0, #(evidence.nodes or { }), #(evidence.edges or { }))
	else
		local reason = evidence.status == "single_build_only" and "uma build compatível; linhagens insuficientes para criar prioridade"
			or evidence.status == "scan_limit_reached" and "limite de leitura atingido; prioridade importada desativada"
			or evidence.status == "no_archive" and "ainda não há builds importadas para esta skill"
			or evidence.status == "no_compatible_builds" and "ainda não há build compatível com esta classe e skill"
			or evidence.reason or evidence.status or "indisponível"
		evidenceText = "Grafo importado: " .. tostring(reason) .. "; a busca exata do PoB continua sem essa prioridade."
	end
	drawPlannerString(x, viewPort.y + 176, "LEFT", 11, "VAR", "^8" .. clipStatusText(evidenceText, width, 11))
	local rowStartY = focusNote and 214 or 196
	local candidates = { }
	for _, entry in ipairs(result.results or { }) do candidates[#candidates + 1] = entry end
	t_sort(candidates, function(a, b)
		if a.feasible ~= b.feasible then return a.feasible == true end
		local rankA = isFiniteNumber(a.paretoRank) and a.paretoRank or math.huge
		local rankB = isFiniteNumber(b.paretoRank) and b.paretoRank or math.huge
		if rankA ~= rankB then return rankA < rankB end
		local efficiencyA = isFiniteNumber(a.objectiveDelta) and a.objectiveDelta / math.max(tonumber(a.pointsAdded) or 1, 1) or -math.huge
		local efficiencyB = isFiniteNumber(b.objectiveDelta) and b.objectiveDelta / math.max(tonumber(b.pointsAdded) or 1, 1) or -math.huge
		if efficiencyA ~= efficiencyB then return efficiencyA > efficiencyB end
		return (a.targetId or 0) < (b.targetId or 0)
	end)
	local rows = math.max(0, math.floor((viewPort.height - rowStartY - 50) / 28))
	if #candidates == 0 then
		drawPlannerString(x, viewPort.y + rowStartY, "LEFT", 12, "VAR", "^8Nenhuma rota conectada respeitou os filtros de ramo e o limite de pontos atuais.")
	end
	for index = 1, math.min(#candidates, rows) do
		local entry = candidates[index]
		local status
		if entry.exactCalculated ~= true then
			status = "^1não avaliada: " .. tostring(entry.reason or "restrição da árvore")
		else
			status = entry.feasible and "^2requisitos rígidos aprovados" or "^1requisitos rígidos não atingidos"
		end
		local metricParts = { }
		if damageMetric then
			metricParts[#metricParts + 1] = "Δ " .. damageMetric.label .. " " .. optimizerDeltaText(entry.metricDelta and entry.metricDelta[damageMetric.key])
		end
		if defenseMetric then
			metricParts[#metricParts + 1] = "Δ " .. defenseMetric.label .. " " .. optimizerDeltaText(entry.metricDelta and entry.metricDelta[defenseMetric.key])
		end
		if #metricParts == 0 then
			metricParts[#metricParts + 1] = "Δ objetivo " .. optimizerDeltaText(entry.objectiveDelta)
		end
		local importedUsage = evidence and evidence.nodeCounts and evidence.nodeCounts[tonumber(entry.targetId)]
		if importedUsage then
			metricParts[#metricParts + 1] = string.format("arquivo %d/%d", importedUsage.supportCount or 0, importedUsage.sampleCount or 0)
		end
		local objectiveDelta = entry.objectiveDelta
		local routeIds = entry.nodeIds or { }
		local name = tostring(entry.label or "Rota da árvore")
		if #name > 48 then name = name:sub(1, 45) .. "..." end
		if damageMetric and defenseMetric and damageMetric.key ~= defenseMetric.key then
			metricParts[#metricParts + 1] = "Δ objetivo " .. optimizerDeltaText(objectiveDelta)
		end
		local rankLabel = entry.paretoRank and ("Pareto " .. tostring(entry.paretoRank)) or ""
		local row = string.format("^7%d. %s | %d pts | %s | %s | %s | %s",
			index, name, entry.pointsAdded or #routeIds, table.concat(metricParts, " | "), rankLabel,
			tostring(entry.targetId or "route"), status)
		drawPlannerString(x, viewPort.y + rowStartY + (index - 1) * 28, "LEFT", 12, "VAR", clipStatusText(row, width, 12))
		if index == 1 then
			self.nodePotentialHighlightedNodeIds = routeIds
		end
	end
	local checkpoints = Checkpoints.GetSummary(self.textValues.phaseCheckpointsJson, self.build)
	local checkpointLabels = { }
	for _, entry in ipairs(checkpoints.phases) do
		local phaseName = ({ tree = "Tree", skills = "Skills", equipment = "Equipment", combined = "Combined" })[entry.phase] or entry.phase
		checkpointLabels[#checkpointLabels + 1] = phaseName .. " " .. (entry.status == "current" and "current" or entry.status == "stale" and "stale" or "saved")
	end
	local footerY = math.max(viewPort.height - 22, rowStartY - 22 + math.min(#candidates, rows) * 28)
	drawPlannerString(x, viewPort.y + footerY, "LEFT", 11, "VAR", "^8Etapas: " .. (#checkpointLabels > 0 and table.concat(checkpointLabels, " → ") or "nenhuma")
		.. " | A frequência importada só desempata propostas; variações Pareto e requisitos rígidos usam cálculos exatos do PoB. A análise é somente de leitura.")
end

function OptimizerTabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height
	self:Layout(viewPort)
	self:ProcessControlsInput(inputEvents, viewPort)

	main:DrawBackground(viewPort)
	drawPlannerString(viewPort.x + 12, viewPort.y + 8, "LEFT", 18, "VAR", "^7AI Planner")
	-- The first status and result lines start below the final button row. Draw
	-- them when those lines fit; longer result details naturally clip at the
	-- viewport edge, while short windows receive the live summary above.
	local statusPanelVisible = self.statusY + 38 <= viewPort.height
	local statusLine, statusIsError
	if statusPanelVisible and self.innerView ~= "overview" then
		statusLine, statusIsError = formatMCPStatus(main.optimizerMCP), false
	else
		statusLine, statusIsError = OptimizerTabClass.FormatVisibleStatus(self, main.optimizerMCP, viewPort.width)
	end
	drawPlannerString(viewPort.x + 12, viewPort.y + 30, "LEFT", 14, "VAR", statusIsError and colorCodes.NEGATIVE .. statusLine or "^8" .. statusLine)
	if self.innerView == "overview" then
		if self.RefreshOverviewDirectionControls then self.RefreshOverviewDirectionControls() end
		self:RefreshReadiness()
	end
	self:DrawControls(viewPort)
	if self.innerView == "overview" then return end
	if self.innerView == "nodes" then
		self:DrawNodePotentialPage(viewPort)
		return
	end
	for _, label in ipairs(self.fieldLabels) do
		local fontSize = label.fontSize or (label.y < 292 and (self.compactLayout and 13 or 14) or (self.compactLayout and 14 or 15))
		drawPlannerString(viewPort.x + label.x, viewPort.y + label.y, "LEFT", fontSize, "VAR", "^7" .. label.text)
	end
	if not statusPanelVisible then return end
	local statusY = viewPort.y + self.statusY
	local statusWidth = math.max(120, viewPort.width - 24)
	local statusLines = main:WrapString(self.statusMessage, 14, statusWidth)
	local keepDetailsBelow = self.job and self.job.status == "running"
		or self.result and (self.result.status == "feasible" or self.result.status == "no_feasible_candidate")
	local maxStatusLines = keepDetailsBelow and 1
		or math.max(1, math.floor((viewPort.height - self.statusY - 10) / 16))
	for index = 1, math.min(#statusLines, maxStatusLines) do
		drawPlannerString(viewPort.x + 12, statusY + (index - 1) * 16, "LEFT", 14, "VAR",
			(self.result and self.result.status == "no_feasible_candidate" and colorCodes.NEGATIVE or "^7") .. statusLines[index])
	end
	if self.job and self.job.status == "running" then
		local progress = self.job.progress or { }
		local fraction = progress.total and progress.total > 0 and (progress.processed or 0) / progress.total or 0
		SetDrawColor(0.15, 0.15, 0.15)
		DrawImage(nil, viewPort.x + 12, statusY + 23, math.max(0, viewPort.width - 24), 10)
		SetDrawColor(0.25, 0.68, 0.36)
		DrawImage(nil, viewPort.x + 12, statusY + 23, math.max(0, (viewPort.width - 24) * fraction), 10)
		SetDrawColor(1, 1, 1)
	end
	if self.result and self.result.status == "feasible" and self.result.evaluation then
		local metrics = self.result.evaluation.metrics
		local function fmt(value) return type(value) == "number" and groupedNumber(value) or "-" end
		local selectedClass = self.result.evaluation.selectedBaseClassName or self.build.spec.curClassName or "Unknown class"
		local selectedAscendancy = self.result.evaluation.selectedAscendancyName or "No ascendancy"
		local mainPoints = self.result.evaluation.passivePointsUsed or 0
		local ascendancyPoints = self.result.evaluation.ascendancyPointsUsed or 0
		local extraPoints = self.result.evaluation.extraPassivePoints
		local extraPointsText = type(extraPoints) == "number" and ((extraPoints >= 0 and "+" or "") .. fmt(extraPoints)) or "unknown"
		drawPlannerString(viewPort.x + 12, statusY + 21, "LEFT", 14, "VAR", "^7" .. (self.result.candidate.label or "Feasible candidate")
			.. " | " .. tostring(selectedClass) .. " / " .. tostring(selectedAscendancy))
		drawPlannerString(viewPort.x + 12, statusY + 38, "LEFT", 14, "VAR", "^7Passives " .. fmt(mainPoints) .. "/" .. fmt(self.result.evaluation.strictPointCap)
			.. " | PoB legal " .. fmt(self.result.evaluation.passivePointLimit) .. " (Extra " .. extraPointsText .. ")"
			.. " | Asc " .. fmt(ascendancyPoints) .. "/8 | EHP " .. fmt(metrics.TotalEHP) .. " | Life " .. fmt(metrics.Life) .. " | Mana " .. fmt(metrics.Mana))
		drawPlannerString(viewPort.x + 12, statusY + 55, "LEFT", 14, "VAR", "^7Max hit P/F/C/L/Ch "
			.. fmt(metrics.PhysicalMaximumHitTaken) .. " / " .. fmt(metrics.FireMaximumHitTaken) .. " / "
			.. fmt(metrics.ColdMaximumHitTaken) .. " / " .. fmt(metrics.LightningMaximumHitTaken) .. " / "
			.. fmt(metrics.ChaosMaximumHitTaken) .. " | Suppression " .. fmt(metrics.SpellSuppressionChance) .. "%")
		local sustain = self.result.evaluation.activitySustain or { }
		local sustainText
		if sustain.status == "pass" then
			local scopeName = sustain.optimizerScheduleApplied
				and ("Scheduled " .. tostring(sustain.scope) .. " activities") or "Included damage activities"
			sustainText = string.format("%s: L/M/ES margin %s / %s / %s per second",
				scopeName,
				groupedNumber(sustain.metrics.SustainedLifeMargin or 0),
				groupedNumber(sustain.metrics.SustainedManaMargin or 0),
				groupedNumber(sustain.metrics.SustainedEnergyShieldMargin or 0))
		elseif sustain.status == "not_required" then
			sustainText = "No DPS activity-sustain check for the configured objective"
		else
			local first = sustain.violations and sustain.violations[1]
			sustainText = "Included activity not certified: " .. tostring(first and first.reason or sustain.status or "not certified")
		end
		drawPlannerString(viewPort.x + 12, statusY + 72, "LEFT", 14, "VAR", "^7" .. sustainText)
		local budget = self.result.evaluation.marketBudget
		if budget and budget.enabled then
			local budgetText
			if budget.status == "pass" then
				budgetText = string.format("Item budget %s / %s %s (%d priced item(s), %s)",
					groupedNumber(budget.total or 0), groupedNumber(budget.limit or 0), budget.unit or "Chaos", budget.pricedItemCount or 0, budget.mode or "Trade")
			else
				local violation = budget.violations and budget.violations[1]
				budgetText = "Item budget not certified: " .. tostring(violation and violation.reason or budget.status)
			end
			drawPlannerString(viewPort.x + 12, statusY + 89, "LEFT", 14, "VAR", budget.status == "pass" and "^7" .. budgetText or colorCodes.NEGATIVE .. budgetText)
		end
	elseif self.result and self.result.status == "no_feasible_candidate" then
		local violations = self.result.bestObservedViolations or { }
		t_sort(violations, function(a, b) return tostring(a.label or a.key) < tostring(b.label or b.key) end)
		local text = #violations > 0 and OptimizerTabClass.FormatViolation(violations[1]) or "No structured deficit was returned"
		if #violations > 1 then text = text .. " (and " .. tostring(#violations - 1) .. " more; open Details)" end
		drawPlannerString(viewPort.x + 12, statusY + 21, "LEFT", 14, "VAR",
			colorCodes.NEGATIVE .. clipStatusText(text, math.max(120, viewPort.width - 24), 14))
	end
end

return OptimizerTabClass
