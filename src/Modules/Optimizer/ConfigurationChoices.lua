-- Path of Building
--
-- Module: Bounded search over native Bandit and Pantheon choices.
-- These options are sourced from ConfigOptions.lua so the optimizer follows
-- the active PoB version instead of maintaining a second game-data list.
--
local configOptions = require("Modules.ConfigOptions")
local choices = { }

local fields = {
	{ key = "bandit", label = "Bandit" },
	{ key = "pantheonMajorGod", label = "Major Pantheon" },
	{ key = "pantheonMinorGod", label = "Minor Pantheon" },
}
local optionsByField = { }
local labelsByField = { }

for _, field in ipairs(fields) do
	optionsByField[field.key] = { }
	labelsByField[field.key] = { }
end
for _, definition in ipairs(configOptions) do
	if optionsByField[definition.var] and definition.list then
		for _, option in ipairs(definition.list) do
			optionsByField[definition.var][#optionsByField[definition.var] + 1] = option.val
			labelsByField[definition.var][option.val] = option.label or option.val
		end
	end
end

local function copyVariant(source)
	return {
		bandit = source.bandit,
		pantheonMajorGod = source.pantheonMajorGod,
		pantheonMinorGod = source.pantheonMinorGod,
	}
end

local function countDifferences(a, b)
	local count = 0
	for _, field in ipairs(fields) do
		if a[field.key] ~= b[field.key] then count = count + 1 end
	end
	return count
end

local function variantKey(variant)
	return table.concat({ variant.bandit, variant.pantheonMajorGod, variant.pantheonMinorGod }, "\31")
end

local function variantLabel(variant)
	return string.format("Bandit: %s; Major: %s; Minor: %s",
		labelsByField.bandit[variant.bandit] or variant.bandit,
		labelsByField.pantheonMajorGod[variant.pantheonMajorGod] or variant.pantheonMajorGod,
		labelsByField.pantheonMinorGod[variant.pantheonMinorGod] or variant.pantheonMinorGod)
end

function choices.ReadCurrent(build)
	local configTab = build and build.configTab
	local input = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	input = input and input.input or configTab and configTab.input
	if type(input) ~= "table" then return nil, "The active PoB configuration choices are unavailable" end
	local result = { }
	for _, field in ipairs(fields) do
		local value = input[field.key]
		if value == nil then value = optionsByField[field.key][1] end
		local valid = false
		for _, option in ipairs(optionsByField[field.key]) do
			if value == option then valid = true break end
		end
		if not valid then
			return nil, "Unsupported active PoB " .. field.label .. " option: " .. tostring(value)
		end
		result[field.key] = value
	end
	return result
end

function choices.Validate(variant)
	if type(variant) ~= "table" then return false, "A complete Bandit/Pantheon choice table is required" end
	for key in pairs(variant) do
		if not optionsByField[key] then return false, "Unsupported PoB configuration choice field: " .. tostring(key) end
	end
	for _, field in ipairs(fields) do
		local value, valid = variant[field.key], false
		for _, option in ipairs(optionsByField[field.key]) do
			if value == option then valid = true break end
		end
		if not valid then return false, "Unsupported PoB " .. field.label .. " option: " .. tostring(value) end
	end
	return true
end

function choices.BuildCandidates(build, limit, seed)
	local current, currentError = choices.ReadCurrent(build)
	if not current then return nil, nil, currentError end
	limit = math.max(0, math.floor(tonumber(limit) or 0))
	local totalCombinations = #optionsByField.bandit * #optionsByField.pantheonMajorGod * #optionsByField.pantheonMinorGod
	local candidates, seen = { }, { [variantKey(current)] = true }
	local singleChoiceCoverage = { bandit = 0, pantheonMajorGod = 0, pantheonMinorGod = 0 }

	local function append(variant, differenceCount)
		local key = variantKey(variant)
		if seen[key] or #candidates >= limit then return false end
		seen[key] = true
		candidates[#candidates + 1] = {
			nodeIds = { },
			removeNodeIds = { },
			configurationVariant = copyVariant(variant),
			label = "Native PoB options: " .. variantLabel(variant),
			island = ((#candidates + (tonumber(seed) or 0)) % 4) + 1,
			configurationAxesChanged = differenceCount,
		}
		return true
	end

	-- First sweep every individual option with the other two choices held at
	-- their current PoB values. This ensures a bounded search can still compare
	-- each choice family instead of spending its entire quota on combinations.
	local maxOptions = 0
	for _, field in ipairs(fields) do maxOptions = math.max(maxOptions, #optionsByField[field.key]) end
	-- Round-robin axes so even a tiny budget tries at least one Bandit, major
	-- Pantheon, and minor Pantheon change before spending on deeper sweeps.
	for optionIndex = 1, maxOptions do
		for _, field in ipairs(fields) do
			local value = optionsByField[field.key][optionIndex]
			if value and value ~= current[field.key] then
				local variant = copyVariant(current)
				variant[field.key] = value
				if append(variant, 1) then singleChoiceCoverage[field.key] = singleChoiceCoverage[field.key] + 1 end
			end
		end
	end

	local multiChoiceVariants = { }
	for _, bandit in ipairs(optionsByField.bandit) do
		for _, major in ipairs(optionsByField.pantheonMajorGod) do
			for _, minor in ipairs(optionsByField.pantheonMinorGod) do
				local variant = { bandit = bandit, pantheonMajorGod = major, pantheonMinorGod = minor }
				local differences = countDifferences(variant, current)
				if differences > 1 and not seen[variantKey(variant)] then
					multiChoiceVariants[#multiChoiceVariants + 1] = { value = variant, differences = differences }
				end
			end
		end
	end

	local combinationSlots = math.max(0, limit - #candidates)
	local selectedCombinations = math.min(combinationSlots, #multiChoiceVariants)
	if selectedCombinations == #multiChoiceVariants then
		for _, item in ipairs(multiChoiceVariants) do append(item.value, item.differences) end
	elseif selectedCombinations > 0 then
		local offset = math.abs(math.floor(tonumber(seed) or 0)) % #multiChoiceVariants
		for slot = 1, selectedCombinations do
			local evenlySpaced = math.floor((slot - 0.5) * #multiChoiceVariants / selectedCombinations) + 1
			local index = ((evenlySpaced + offset - 1) % #multiChoiceVariants) + 1
			local item = multiChoiceVariants[index]
			append(item.value, item.differences)
		end
	end

	return candidates, {
		totalCombinations = totalCombinations,
		generatedCandidates = #candidates,
		individualChoiceCandidates = singleChoiceCoverage,
		generatedMultiChoiceCandidates = math.max(0, #candidates - singleChoiceCoverage.bandit - singleChoiceCoverage.pantheonMajorGod - singleChoiceCoverage.pantheonMinorGod),
		current = current,
	}, nil
end

function choices.Label(variant)
	if not choices.Validate(variant) then return "" end
	return variantLabel(variant)
end

function choices.VariationTitle(variant)
	if not choices.Validate(variant) then return "Optimizer result" end
	local major = (labelsByField.pantheonMajorGod[variant.pantheonMajorGod] or variant.pantheonMajorGod):gsub("^Soul of ", "")
	local minor = (labelsByField.pantheonMinorGod[variant.pantheonMinorGod] or variant.pantheonMinorGod):gsub("^Soul of ", "")
	return table.concat({ "Optimizer", labelsByField.bandit[variant.bandit] or variant.bandit, major, minor }, " - ")
end

return choices
