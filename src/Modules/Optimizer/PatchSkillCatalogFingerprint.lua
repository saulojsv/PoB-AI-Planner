-- Shared canonical fingerprint for the exact patch skill/ascendancy catalog
-- consumed by both the exporter and the local build archive.

local sha = require("sha2")

local fingerprint = { }

local function appendValue(parts, value)
	local kind = type(value)
	local text = value == nil and "" or tostring(value)
	parts[#parts + 1] = kind:sub(1, 1) .. tostring(#text) .. ":" .. text
end

local function appendArray(parts, values)
	if type(values) ~= "table" then
		appendValue(parts, values)
		return
	end
	appendValue(parts, "array")
	appendValue(parts, #values)
	for index = 1, #values do appendValue(parts, values[index]) end
end

function fingerprint.Compute(patch)
	if type(patch) ~= "table" or type(patch.sourceHashes) ~= "table"
		or type(patch.skills) ~= "table" or type(patch.standardAscendancies) ~= "table"
		or type(patch.excludedAlternateAscendancies) ~= "table"
		or type(patch.excludedLeagueSpecificAscendancies) ~= "table"
		or type(patch.bloodlineNodeIds) ~= "table" or type(patch.counts) ~= "table" then
		return nil
	end
	local parts = { }
	for _, value in ipairs({
		patch.patch, patch.pobTag, patch.sourceRef, patch.sourceLabel, patch.commit,
		patch.sourceHashes.gems, patch.sourceHashes.tree, patch.sourceHashes.skills, patch.sourceHashes.data,
	}) do appendValue(parts, value) end
	for _, key in ipairs({ "totalActiveGemRecords", "normal", "transfigured", "vaal", "vaalAlternateVariants",
		"supportGrantedEffects", "support_granted_effect", "other", "standardAscendancies",
		"excludedAlternateAscendancies", "excludedLeagueSpecificAscendancies" }) do
		appendValue(parts, key)
		appendValue(parts, patch.counts[key])
	end

	appendValue(parts, "skills")
	appendValue(parts, #patch.skills)
	for _, skill in ipairs(patch.skills) do
		appendValue(parts, "skill")
		for _, key in ipairs({ "gemId", "gameId", "variantId", "variantKey", "name", "baseName",
			"grantedEffectId", "secondaryGrantedEffectId", "category", "origin" }) do
			appendValue(parts, key)
			appendValue(parts, skill[key])
		end
		appendArray(parts, skill.tags)
	end

	appendValue(parts, "standardAscendancies")
	appendValue(parts, #patch.standardAscendancies)
	for _, ascendancy in ipairs(patch.standardAscendancies) do
		appendValue(parts, "standardAscendancy")
		for _, key in ipairs({ "id", "name", "classId", "className", "ascendClassId" }) do
			appendValue(parts, key)
			appendValue(parts, ascendancy[key])
		end
	end

	appendValue(parts, "excludedAlternateAscendancies")
	appendArray(parts, patch.excludedAlternateAscendancies)
	appendValue(parts, "excludedLeagueSpecificAscendancies")
	appendValue(parts, #patch.excludedLeagueSpecificAscendancies)
	for _, ascendancy in ipairs(patch.excludedLeagueSpecificAscendancies) do
		for _, key in ipairs({ "id", "classId", "className", "reason" }) do
			appendValue(parts, key)
			appendValue(parts, ascendancy[key])
		end
	end

	appendValue(parts, "bloodlineNodeIds")
	appendArray(parts, patch.bloodlineNodeIds)
	return sha.sha256(table.concat(parts))
end

return fingerprint
