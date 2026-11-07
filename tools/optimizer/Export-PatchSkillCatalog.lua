-- Export a compact, patch-specific PoE 1 skill/standard-ascendancy inventory
-- from official Path of Building Community source tags. This is catalog data,
-- not build data, training labels, or a claim that a game build is legal.

local json = require("dkjson")
local sha = require("sha2")
local PatchSkillCatalogFingerprint = require("Modules.Optimizer.PatchSkillCatalogFingerprint")

local inputPath = assert(os.getenv("POB_PATCH_SKILL_INPUT"), "input manifest is required")
local outputPath = assert(os.getenv("POB_PATCH_SKILL_OUTPUT"), "output path is required")

local function readJson(path)
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	local value, _, err = json.decode(text)
	assert(type(value) == "table", err or "invalid JSON")
	return value
end

local function readLuaTable(path)
	local chunk, loadError = loadfile(path)
	assert(chunk, loadError)
	local value = chunk()
	assert(type(value) == "table", "expected a returned Lua table: " .. path)
	return value
end

local function readText(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end

-- Forward declarations ensure the parsers below capture these locals instead
-- of accidentally resolving globals before their definitions appear.
local cleanString, sortedKeys

local function readSkillIdentifiers(paths, hashes)
	assert(type(paths) == "table" and type(hashes) == "table", "native skill source files and hashes are required")
	local identifiers, baseNames, hashParts = { }, { }, { }
	for _, group in ipairs(sortedKeys(paths)) do
		local sourceHash = tostring(hashes[group] or "")
		assert(#sourceHash == 64 and sourceHash:match("^%x+$") ~= nil,
			"invalid native skill source hash: " .. tostring(group))
		hashParts[#hashParts + 1] = group .. "=" .. sourceHash:lower() .. "\n"
		local text = readText(paths[group])
		local currentSkill
		for line in (text .. "\n"):gmatch("(.-)\n") do
			local id = line:match('^%s*skills%["([^"]+)"%]%s*=')
			if id then
				currentSkill = id
				identifiers[id] = true
			end
			if currentSkill then
				local baseName = line:match('^%s*baseTypeName%s*=%s*"([^"]+)"')
				if baseName then
					baseNames[currentSkill] = cleanString(baseName, 120)
					currentSkill = nil
				end
			end
		end
	end
	assert(#hashParts > 0, "no native skill source files were hashed")
	return identifiers, baseNames, sha.sha256(table.concat(hashParts))
end

cleanString = function(value, maxLength)
	if type(value) ~= "string" then return "" end
	value = value:gsub("[%z\1-\31\127]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return value:sub(1, maxLength or 200)
end

sortedKeys = function(value)
	local result = { }
	for key, enabled in pairs(value or { }) do if enabled then result[#result + 1] = tostring(key) end end
	table.sort(result)
	return result
end

local function skillCategory(gem, variantId, gameId)
	if gem.tags and gem.tags.support == true then return "support_granted_effect" end
	if gem.vaalGem == true or variantId:match("^Vaal") or gameId:find("SkillGemVaal", 1, true) then return "vaal" end
	if variantId:match("Alt[XYZ]$") or variantId:find("Transfigured", 1, true) then return "transfigured" end
	if variantId ~= "" and gameId ~= "" then return "normal" end
	return "other"
end

local leagueSpecificAscendancies = {
	Reliquarian = "Its notable pool rotates with challenge leagues; excluded by the user's standard-ascendancy rule.",
	Luminary = "Introduced as the Curse of the Allflame league ascendancy; excluded by the user's standard-ascendancy rule.",
}
local standardAscendancyClassIds = {
	Ascendant = 0,
	Berserker = 1, Chieftain = 1, Juggernaut = 1,
	Deadeye = 2, Pathfinder = 2, Raider = 2,
	Elementalist = 3, Necromancer = 3, Occultist = 3,
	Champion = 4, Gladiator = 4, Slayer = 4,
	Guardian = 5, Hierophant = 5, Inquisitor = 5,
	Assassin = 6, Saboteur = 6, Trickster = 6,
}
local standardAscendancyClassIndices = {
	Ascendant = 1,
	Berserker = 2, Chieftain = 3, Juggernaut = 1,
	Deadeye = 2, Pathfinder = 3, Raider = 1,
	Elementalist = 2, Necromancer = 3, Occultist = 1,
	Champion = 3, Gladiator = 2, Slayer = 1,
	Guardian = 3, Hierophant = 2, Inquisitor = 1,
	Assassin = 1, Saboteur = 3, Trickster = 2,
}
local standardAscendancyDisplayNames = {
	Raider = { Raider = true, Warden = true, ["Warden of the Maji"] = true },
}

local input = readJson(inputPath)
assert(input.schema == "pob-ai-planner-patch-skill-source-input" and input.schemaVersion == 2,
	"unsupported input manifest")
local output = {
	schema = "pob-ai-planner-patch-skill-catalog",
	schemaVersion = 5,
	featureSchemaVersion = 1,
	generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	source = {
		repository = "https://github.com/PathOfBuildingCommunity/PathOfBuilding",
		method = "official_release_tag_or_pinned_upstream_commit",
		ascendancyRule = "Only the active standard ascendancy is eligible; any secondary alternate ascendancy or allocated isBloodline node is excluded.",
		coverageRule = "Each active gem is keyed by gameId + variantId; support-granted effects are classified separately and excluded as independent Main Skill targets; Vaal variants, including the native Data.lua AltX/AltY derivations, are inventoried separately from normal/transfigured targets.",
	},
	patches = { },
}

for _, source in ipairs(input.patches or { }) do
	local gems = readLuaTable(source.gemsPath)
	local tree = readLuaTable(source.treePath)
	local skillIdentifiers, skillBaseNames, skillSourceHash = readSkillIdentifiers(source.skillPaths, source.skillHashes)
	local dataSource = readText(source.dataPath)
	assert(dataSource:find('data.skills[gem.secondaryGrantedEffectId..alt]', 1, true)
		and dataSource:find('"AltX", "AltY"', 1, true),
		"the pinned PoB Data.lua does not match the native Vaal AltX/AltY derivation contract")
	local patch = {
		patch = cleanString(source.patch, 16),
		pobTag = cleanString(source.pobTag, 32),
		sourceRef = cleanString(source.sourceRef, 80),
		sourceLabel = cleanString(source.sourceLabel, 120),
		commit = cleanString(source.commit, 64),
		treeVersion = cleanString(source.treeVersion, 24),
		sourceHashes = { gems = cleanString(source.gemsSha256, 64), tree = cleanString(source.treeSha256, 64),
			skills = skillSourceHash, data = cleanString(source.dataSha256, 64) },
		classes = { },
		bloodlineNodeIds = { },
		standardAscendancies = { },
		excludedAlternateAscendancies = { },
		excludedLeagueSpecificAscendancies = { },
		skills = { },
		counts = { normal = 0, transfigured = 0, vaal = 0, support_granted_effect = 0,
			vaalAlternateVariants = 0, other = 0, totalActiveGemRecords = 0 },
	}
	for classIndex, class in ipairs(tree.classes or { }) do
		local classRow = { classId = classIndex - 1, name = cleanString(class.name, 64), ascendancies = { } }
		for ascendClassId, ascendancy in ipairs(class.ascendancies or { }) do
			local id = cleanString(ascendancy.id, 80)
			if id ~= "" then
				local row = { id = id, name = cleanString(ascendancy.name or id, 80), classId = classIndex - 1,
					className = classRow.name, ascendClassId = ascendClassId }
				if leagueSpecificAscendancies[id] then
					patch.excludedLeagueSpecificAscendancies[#patch.excludedLeagueSpecificAscendancies + 1] = {
						id = id, classId = classIndex - 1, className = classRow.name,
						reason = leagueSpecificAscendancies[id],
					}
				else
					classRow.ascendancies[#classRow.ascendancies + 1] = row
					patch.standardAscendancies[#patch.standardAscendancies + 1] = row
				end
			end
		end
		patch.classes[#patch.classes + 1] = classRow
	end
	for _, ascendancy in ipairs(tree.alternate_ascendancies or { }) do
		local id = cleanString(ascendancy.id, 80)
		if id ~= "" then patch.excludedAlternateAscendancies[#patch.excludedAlternateAscendancies + 1] = id end
	end
	for nodeId, node in pairs(tree.nodes or { }) do
		if type(node) == "table" and node.isBloodline == true then
			local id = tonumber(node.id or nodeId)
			assert(id and id > 0 and id == math.floor(id), "invalid bloodline node id in " .. tostring(source.treeVersion))
			patch.bloodlineNodeIds[#patch.bloodlineNodeIds + 1] = id
		end
	end
	table.sort(patch.bloodlineNodeIds)
	table.sort(patch.excludedAlternateAscendancies)
	table.sort(patch.excludedLeagueSpecificAscendancies, function(left, right) return left.id < right.id end)
	for gemId, gem in pairs(gems) do
		if type(gem) == "table" and type(gem.tags) == "table" and gem.tags.grants_active_skill == true then
			local gameId = cleanString(gem.gameId, 200)
			local variantId = cleanString(gem.variantId, 200)
			local category = skillCategory(gem, variantId, gameId)
			local row = {
				gemId = cleanString(gemId, 200),
				gameId = gameId,
				variantId = variantId,
				variantKey = gameId .. "|" .. variantId,
				name = cleanString(gem.name or gem.baseTypeName or variantId, 120),
				baseName = cleanString(gem.baseTypeName or gem.name or "", 120),
				grantedEffectId = cleanString(gem.grantedEffectId, 200),
				secondaryGrantedEffectId = cleanString(gem.secondaryGrantedEffectId, 200),
				category = category,
				tags = sortedKeys(gem.tags),
			}
			patch.skills[#patch.skills + 1] = row
			patch.counts[category] = (patch.counts[category] or 0) + 1
			if category == "support_granted_effect" then
				patch.counts.supportGrantedEffects = (patch.counts.supportGrantedEffects or 0) + 1
			end
			patch.counts.totalActiveGemRecords = patch.counts.totalActiveGemRecords + 1
		end
	end
	-- Match Modules/Data.lua: a Vaal hybrid receives AltX/AltY gem variants
	-- only when the secondary granted-effect id has that exact native skill.
	-- These generated gems are real runtime choices, but remain in the separate
	-- Vaal inventory rather than inflating normal/transfigured target coverage.
	local emittedGemIds = { }
	for _, row in ipairs(patch.skills) do emittedGemIds[row.gemId] = true end
	for gemId, gem in pairs(gems) do
		if type(gem) == "table" and gem.vaalGem == true and type(gem.secondaryGrantedEffectId) == "string" then
			for _, alt in ipairs({ "AltX", "AltY" }) do
				local effectId = gem.secondaryGrantedEffectId .. alt
				local derivedGemId = gemId .. alt
				if skillIdentifiers[effectId] and not emittedGemIds[derivedGemId] then
					local variantId = cleanString(gem.variantId, 200) .. alt
					local gameId = cleanString(gem.gameId, 200)
					local name = "Vaal " .. tostring(skillBaseNames[effectId] or "")
					assert(name ~= "Vaal ", "native Vaal alternate effect lacks a base name: " .. effectId)
					local row = {
						gemId = cleanString(derivedGemId, 200), gameId = gameId, variantId = variantId,
						variantKey = gameId .. "|" .. variantId, name = cleanString(name, 120),
						baseName = cleanString(skillBaseNames[effectId], 120),
						grantedEffectId = cleanString(gem.grantedEffectId, 200),
						secondaryGrantedEffectId = cleanString(effectId, 200),
						category = "vaal", tags = sortedKeys(gem.tags), origin = "native_vaal_alt_derivation",
					}
					patch.skills[#patch.skills + 1] = row
					emittedGemIds[derivedGemId] = true
					patch.counts.vaal = patch.counts.vaal + 1
					patch.counts.vaalAlternateVariants = patch.counts.vaalAlternateVariants + 1
					patch.counts.totalActiveGemRecords = patch.counts.totalActiveGemRecords + 1
				end
			end
		end
	end
	table.sort(patch.skills, function(left, right)
		if left.category ~= right.category then return left.category < right.category end
		if left.name ~= right.name then return left.name:lower() < right.name:lower() end
		if left.gameId ~= right.gameId then return left.gameId < right.gameId end
		return left.variantId < right.variantId
	end)
	table.sort(patch.standardAscendancies, function(left, right)
		if left.classId ~= right.classId then return left.classId < right.classId end
		return left.id < right.id
	end)
	local standardSeen = { }
	for _, ascendancy in ipairs(patch.standardAscendancies) do
		assert(standardAscendancyClassIds[ascendancy.id] == ascendancy.classId,
			"unexpected standard ascendancy identity in " .. patch.treeVersion .. ": " .. ascendancy.id)
		local allowedNames = standardAscendancyDisplayNames[ascendancy.id]
		assert((allowedNames and allowedNames[ascendancy.name]) or (not allowedNames and ascendancy.name == ascendancy.id),
			"unexpected standard ascendancy display name in " .. patch.treeVersion .. ": " .. ascendancy.id .. " / " .. ascendancy.name)
		assert(ascendancy.ascendClassId == standardAscendancyClassIndices[ascendancy.id],
			"invalid numeric ascendancy identity in " .. patch.treeVersion .. ": " .. ascendancy.id)
		assert(not standardSeen[ascendancy.id], "duplicate standard ascendancy in " .. patch.treeVersion)
		standardSeen[ascendancy.id] = true
	end
	assert(#patch.standardAscendancies == 19, "the standard ascendancy set changed in " .. patch.treeVersion)
	for id in pairs(standardAscendancyClassIds) do
		assert(standardSeen[id], "missing standard ascendancy in " .. patch.treeVersion .. ": " .. id)
	end
	assert(patch.patch:match("^3%.2[4-9]$"), "unexpected patch in source manifest")
	assert(patch.pobTag:match("^v%d+%.%d+%.%d+$"), "invalid official PoB tag")
	assert(#patch.standardAscendancies > 0, "patch has no standard ascendancy catalog")
	patch.counts.standardAscendancies = #patch.standardAscendancies
	patch.counts.excludedAlternateAscendancies = #patch.excludedAlternateAscendancies
	patch.counts.excludedLeagueSpecificAscendancies = #patch.excludedLeagueSpecificAscendancies
	patch.catalogFingerprint = assert(PatchSkillCatalogFingerprint.Compute(patch), "could not fingerprint patch catalog")
	output.patches[#output.patches + 1] = patch
end

table.sort(output.patches, function(left, right) return left.patch < right.patch end)
local expectedPatchRanges = {
	[4] = { "3.26", "3.27", "3.28", "3.29" },
	[6] = { "3.24", "3.25", "3.26", "3.27", "3.28", "3.29" },
}
local expectedPatchList = expectedPatchRanges[#output.patches]
assert(expectedPatchList, "catalog must contain either 3.26 through 3.29 or 3.24 through 3.29")
for index, expectedPatch in ipairs(expectedPatchList) do
	assert(output.patches[index].patch == expectedPatch, "catalog has an unexpected patch range/order")
end
local encoded = assert(json.encode(output, { indent = true, keyorder = { "schema", "schemaVersion", "featureSchemaVersion", "generatedAt", "source", "patches" } }))
local file = assert(io.open(outputPath, "wb"))
assert(file:write(encoded))
assert(file:close())
io.write("PATCH_SKILL_CATALOG " .. json.encode({ output = outputPath, patches = #output.patches,
	counts = (function() local rows = { }; for _, patch in ipairs(output.patches) do rows[#rows + 1] = {
		patch = patch.patch, pobTag = patch.pobTag, total = patch.counts.totalActiveGemRecords,
		normal = patch.counts.normal, transfigured = patch.counts.transfigured, vaal = patch.counts.vaal,
		standardAscendancies = patch.counts.standardAscendancies, sourceLabel = patch.sourceLabel,
	} end; return rows end)() }) .. "\n")
