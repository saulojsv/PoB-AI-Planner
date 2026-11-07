-- Path of Building
--
-- Module: Persistent, local archive of exact PoB build snapshots used by the
-- AI Planner study workflow. Raw XML is content-addressed; metadata keeps the
-- source, engine identity, configured skill effects and a structural profile.
-- Node-usage counts are aggregated from compatible profiles at query time,
-- never stored as popularity labels. An archived public build is an
-- observation, never a training label or evidence of source-use rights.

local json = require("dkjson")
local sha = require("sha2")
local Candidate = require("Modules.Optimizer.Candidate")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local SurrogateFeatures = require("Modules.Optimizer.SurrogateFeatures")
local Version = require("Modules.Optimizer.Version")
local Surrogate = require("Modules.Optimizer.Surrogate")
local PatchSkillCatalogFingerprint = require("Modules.Optimizer.PatchSkillCatalogFingerprint")
local xml = require("xml")

local builds = { }

local STORE_FOLDER = "OptimizerStudies"
local ARCHIVE_FOLDER = "Builds"
local OBJECT_FOLDER = "objects"
local INDEX_FILE = "builds.jsonl"
local CATALOG_FOLDER = "catalog"
local PATCH_SKILL_CATALOG_FILE = "skill-catalog.json"
local ARCHIVE_SOURCE_CONFIG_FILE = "BuildArchiveSource.json"
local ARCHIVE_SOURCE_CONFIG_SCHEMA = "pob-ai-planner-archive-source"
local MAX_ARCHIVE_SOURCE_CONFIG_BYTES = 8192
local MAX_BUILD_BYTES = 16 * 1024 * 1024
local MAX_INDEX_LINE_BYTES = 262144
local MAX_PATCH_CATALOG_BYTES = 16 * 1024 * 1024
local MAX_SKILL_GROUPS = 48
local MAX_GEMS_PER_GROUP = 32
local MAX_EFFECTS_PER_BUILD = 512
local TARGET_BUILDS_PER_EFFECT = 10
-- The current read-only archive index is ~59 MB. Keep the scan bounded, but
-- leave enough room to finish it and modest corpus growth so route priors are
-- not silently disabled halfway through a normal Planner run.
local MAX_NODE_EVIDENCE_BYTES = 128 * 1024 * 1024
local MAX_NODE_EVIDENCE_ROWS = 20000
local MAX_NODE_EVIDENCE_OUTPUT_NODES = 512
local MAX_NODE_EVIDENCE_OUTPUT_EDGES = 1024
local MAX_NODE_EVIDENCE_OUTPUT_PATTERNS = 24
local MAX_ARCHIVE_LINEAGE_SCAN_ROWS = 100000
local STANDARD_ASCENDANCY_CLASS_IDS = {
	Ascendant = 0,
	Berserker = 1, Chieftain = 1, Juggernaut = 1,
	Deadeye = 2, Pathfinder = 2, Raider = 2,
	Elementalist = 3, Necromancer = 3, Occultist = 3,
	Champion = 4, Gladiator = 4, Slayer = 4,
	Guardian = 5, Hierophant = 5, Inquisitor = 5,
	Assassin = 6, Saboteur = 6, Trickster = 6,
}
local STANDARD_ASCENDANCY_CLASS_INDICES = {
	Ascendant = 1,
	Berserker = 2, Chieftain = 3, Juggernaut = 1,
	Deadeye = 2, Pathfinder = 3, Raider = 1,
	Elementalist = 2, Necromancer = 3, Occultist = 1,
	Champion = 3, Gladiator = 2, Slayer = 1,
	Guardian = 3, Hierophant = 2, Inquisitor = 1,
	Assassin = 1, Saboteur = 3, Trickster = 2,
}
local STANDARD_ASCENDANCY_CLASS_NAMES = { [0] = "Scion", "Marauder", "Ranger", "Witch", "Duelist", "Templar", "Shadow" }
local STANDARD_ASCENDANCY_DISPLAY_NAMES = {
	Raider = { Raider = true, Warden = true, ["Warden of the Maji"] = true },
}
local sequence = 0
local archiveGeneration = 0
local isFingerprint

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function cleanText(value, maximum)
	if type(value) ~= "string" or value == "" or #value > (maximum or 200) or value:find("[%c]") then return nil end
	return value
end

local function joinPath(left, right, separator)
	local base = tostring(left or "")
	while base:sub(-1) == "/" or base:sub(-1) == "\\" do base = base:sub(1, -2) end
	return base .. separator .. right
end

local function separator()
	return package.config and package.config:sub(1, 1) or "\\"
end

local function makeDirectory(path, createDirectory)
	if type(createDirectory) ~= "function" then return nil, "PoB's native directory creator is unavailable" end
	local ok, created, createError = pcall(createDirectory, path .. separator())
	if not ok then return nil, "Could not create the local build archive directory: " .. tostring(created):sub(1, 200) end
	-- PoB's MakeDir convention is (nil, "No error") when the directory exists.
	if not created and createError ~= "No error" then
		return nil, "Could not create the local build archive directory: " .. tostring(createError or "unknown"):sub(1, 200)
	end
	return true
end

function builds.GetPaths(userPath)
	if type(userPath) ~= "string" or userPath == "" or userPath:find("[%c]") then
		return nil, "PoB's configured user-data directory is unavailable"
	end
	local sep = separator()
	local studiesDirectory = joinPath(userPath, STORE_FOLDER, sep)
	local root = joinPath(studiesDirectory, ARCHIVE_FOLDER, sep)
	local catalogDirectory = joinPath(root, CATALOG_FOLDER, sep)
	return {
		studies = studiesDirectory,
		root = root,
		objects = joinPath(root, OBJECT_FOLDER, sep),
		index = joinPath(root, INDEX_FILE, sep),
		catalogDirectory = catalogDirectory,
		patchSkillCatalog = joinPath(catalogDirectory, PATCH_SKILL_CATALOG_FILE, sep),
		relativeRoot = STORE_FOLDER .. "/" .. ARCHIVE_FOLDER,
	}
end

builds.ItemFingerprint = SurrogateFeatures.ItemFingerprint

local function sortedPositiveIds(values)
	local result, seen = { }, { }
	for value, allocated in pairs(values or { }) do
		local id = tonumber(value)
		if allocated and isFinite(id) and id > 0 and id == math.floor(id) and id <= 2147483647 and not seen[id] then
			seen[id] = true
			result[#result + 1] = id
		end
	end
	table.sort(result)
	return result
end

local function masteryRows(values)
	local result = { }
	for nodeId, effect in pairs(values or { }) do
		local id = tonumber(nodeId)
		local effectId = type(effect) == "table" and tonumber(effect.effectId or effect.effect) or tonumber(effect)
		if isFinite(id) and id > 0 and id == math.floor(id) and isFinite(effectId)
			and effectId > 0 and effectId == math.floor(effectId) then
			result[#result + 1] = { nodeId = id, effectId = effectId }
		end
	end
	table.sort(result, function(left, right)
		if left.nodeId ~= right.nodeId then return left.nodeId < right.nodeId end
		return left.effectId < right.effectId
	end)
	return result
end

local function resolveSourceGem(group, activeEffect)
	local source = activeEffect and activeEffect.srcInstance
	if source then
		for _, gem in ipairs(group.gemList or { }) do if gem == source then return gem end end
	end
	local effect = activeEffect and activeEffect.grantedEffect
	local effectId = effect and tostring(effect.id or "") or ""
	for _, gem in ipairs(group.gemList or { }) do
		local data = gem.gemData
		if data and (tostring(gem.skillId or "") == effectId or tostring(data.grantedEffectId or "") == effectId
			or tostring(data.grantedEffect and data.grantedEffect.id or "") == effectId) then return gem end
		for _, granted in ipairs(data and data.grantedEffectList or { }) do
			if tostring(granted.id or "") == effectId then return gem end
		end
	end
	return nil
end

local function mainSkillCategory(gemData, gameId, variantId)
	variantId = tostring(variantId or "")
	gameId = tostring(gameId or "")
	local tags = gemData and gemData.tags
	if type(tags) == "table" and (tags.support == true or tags.support_granted_effect == true) then
		return "support_granted_effect"
	end
	if gemData and gemData.vaalGem == true or variantId:match("^Vaal") or gameId:find("SkillGemVaal", 1, true) then return "vaal" end
	if variantId:match("Alt[XYZ]$") or variantId:find("Transfigured", 1, true) then return "transfigured" end
	if gameId ~= "" and variantId ~= "" then return "normal" end
	return "unknown"
end

local function hasTag(tags, wanted)
	if type(tags) ~= "table" then return false end
	if tags[wanted] == true then return true end
	for _, tag in ipairs(tags) do if tag == wanted then return true end end
	return false
end

-- Catalog schema 1 predates separate support-granted effects, so derive their
-- role from tags. Also recognize Vaal identity before the shared AltX/AltY
-- transfigured naming convention when reading historical schema-1 catalogs.
local function catalogSkillCategory(skill)
	if type(skill) ~= "table" then return "other" end
	if hasTag(skill.tags, "support") or hasTag(skill.tags, "support_granted_effect")
		or skill.category == "support_granted_effect" then return "support_granted_effect" end
	local gemId, gameId, variantId = tostring(skill.gemId or ""), tostring(skill.gameId or ""), tostring(skill.variantId or "")
	if skill.vaalGem == true or variantId:match("^Vaal")
		or gemId:find("SkillGemVaal", 1, true) or gameId:find("SkillGemVaal", 1, true) then return "vaal" end
	if skill.category == "normal" or skill.category == "transfigured" or skill.category == "vaal" then
		return skill.category
	end
	if variantId:match("Alt[XYZ]$") or variantId:find("Transfigured", 1, true) then return "transfigured" end
	return "other"
end

local function catalogSkillMatchesMainSkillEffect(skill, mainSkill, sourcePatchSkillId)
	if type(skill) ~= "table" or type(mainSkill) ~= "table"
		or tostring(skill.gemId or "") ~= tostring(mainSkill.gemId or "")
		or tostring(skill.gameId or "") ~= tostring(mainSkill.gameId or "")
		or tostring(skill.variantId or "") ~= tostring(mainSkill.variantId or "") then
		return false
	end
	local effectId = tostring(mainSkill.effectId or "")
	local socketedGemSkillId = tostring(mainSkill.skillId or "")
	sourcePatchSkillId = tostring(sourcePatchSkillId or "")
	local grantedEffectId = tostring(skill.grantedEffectId or "")
	local secondaryGrantedEffectId = tostring(skill.secondaryGrantedEffectId or "")
	-- Historical transfigured gems can retain the source patch's socketed
	-- gem skillId while the active effect resolved by a newer PoB differs.
	-- Both IDs are accepted only after the exact gemId/gameId/variantId match
	-- above, and each is compared against the same patch-native catalog row.
	return effectId ~= "" and (effectId == grantedEffectId or effectId == secondaryGrantedEffectId
		or socketedGemSkillId ~= "" and (socketedGemSkillId == grantedEffectId
			or socketedGemSkillId == secondaryGrantedEffectId)
		or sourcePatchSkillId ~= "" and (sourcePatchSkillId == grantedEffectId
			or sourcePatchSkillId == secondaryGrantedEffectId))
end

local function sourceMainSkillClaimError(source, mainSkill)
	local claim = type(source) == "table" and source.claimedMainSkill or nil
	if claim == nil then return nil end
	if type(claim) ~= "table" then return "claimed_main_skill_claim_invalid" end
	for _, field in ipairs({ "gemId", "gameId", "variantId", "effectId" }) do
		if type(claim[field]) ~= "string" or claim[field] == "" then
			return "claimed_main_skill_claim_invalid"
		end
	end
	for _, field in ipairs({ "gemId", "gameId", "variantId", "effectId" }) do
		if tostring(claim[field]) ~= tostring(mainSkill[field] or "") then
			local audit = source.buildQualityAudit
			local resolution = type(audit) == "table" and audit.nativeMainSkillResolution or nil
			if resolution == nil then return "source_main_skill_mismatch" end
			if type(resolution) ~= "table" or resolution.schemaVersion ~= 1
				or resolution.status ~= "reviewed_native_main_group"
				or resolution.evidence ~= "native_active_spec_main_skill_group"
				or type(audit) ~= "table" or audit.status ~= "reviewed_valid"
				or type(audit.reportPath) ~= "string" or audit.reportPath == ""
				or audit.reviewMethod ~= "independent_native_xml_audits_with_cross_challenge"
				or audit.crossChallenge ~= "both_reviewers_confirmed_native_Main_identity_and_resolved_cross_challenge"
				or audit.trainingEligible ~= false then
				return "source_main_skill_resolution_invalid"
			end
			local hasScout, hasCritic = false, false
			for _, role in ipairs(audit.reviewerRoles or { }) do
				if role == "Scout" then hasScout = true end
				if role == "Critic" then hasCritic = true end
			end
			if not hasScout or not hasCritic then return "source_main_skill_resolution_invalid" end
			local resolved = resolution.mainSkill
			if type(resolved) ~= "table" then return "source_main_skill_resolution_invalid" end
			for _, identityField in ipairs({ "gemId", "gameId", "variantId", "effectId" }) do
				if type(resolved[identityField]) ~= "string" or resolved[identityField] == ""
					or resolved[identityField] ~= tostring(mainSkill[identityField] or "") then
					return "source_main_skill_resolution_invalid"
				end
			end
		end
	end
	return nil
end

local function sourceBuildQualityAuditError(source)
	local audit = type(source) == "table" and source.buildQualityAudit or nil
	if audit == nil then return nil end
	if type(audit) ~= "table" or audit.schemaVersion ~= 1
		or type(audit.status) ~= "string" then
		return "source_build_quality_audit_invalid"
	end
	if audit.status == "quarantined" then
		if type(audit.reasonCode) ~= "string" or audit.reasonCode == ""
			or type(audit.reportPath) ~= "string" or audit.reportPath == "" then
			return "source_build_quality_audit_invalid"
		end
		return "source_build_quality_quarantined"
	end
	if audit.status == "reviewed_valid" and type(audit.reportPath) == "string" and audit.reportPath ~= "" then
		return nil
	end
	return "source_build_quality_audit_invalid"
end

local MAX_SUPPORTS_PER_SKILL = 64

local function supportProfileForSkill(build, group, socketEvidence, activeSkill, activeEffect,
		groupIndex, skillIndex, itemFingerprintsBySlot, itemGrantedSeen)
	local activeSupportSet, rows = { }, { }
	for _, effectInstance in ipairs(activeSkill.effectList or { }) do
		if effectInstance.grantedEffect and effectInstance.grantedEffect.support then activeSupportSet[effectInstance] = true end
	end
	for supportIndex, support in ipairs(activeSkill.supportList or { }) do
		if supportIndex > MAX_SUPPORTS_PER_SKILL then break end
		local grantedEffect = support.grantedEffect
		if grantedEffect and grantedEffect.support then
			local sourceGem = support.srcInstance
			local gemData = support.gemData or sourceGem and sourceGem.gemData
			local evidence = SkillCatalog.SupportEvidence(build, groupIndex, group, support,
				activeSupportSet, itemFingerprintsBySlot, socketEvidence)
			local origin = evidence.origin
			local effectId = cleanText(grantedEffect.id or "", 180)
			local sourceSlot = cleanText(evidence.sourceSlot or "", 64)
			local sourceFingerprint = evidence.sourceItemFingerprint
			local row = {
				gemId = cleanText(sourceGem and (sourceGem.gemId or gemData and gemData.id) or gemData and gemData.id or "", 160),
				gameId = cleanText(gemData and gemData.gameId or "", 200),
				variantId = cleanText(gemData and gemData.variantId or "", 200),
				skillId = cleanText(gemData and gemData.grantedEffectId or effectId, 180),
				effectId = effectId,
				name = cleanText(grantedEffect.name or gemData and gemData.name or "", 120),
				level = tonumber(support.level) or 1,
				quality = tonumber(support.quality) or 0,
				origin = origin,
				sourceSlot = sourceSlot,
				sourceItemFingerprint = sourceFingerprint,
				targetGroupIndex = groupIndex,
				targetSkillIndex = skillIndex,
				targetEffectId = cleanText(activeEffect and activeEffect.grantedEffect and activeEffect.grantedEffect.id or "", 180),
				configured = evidence.configured,
				calculatorApplied = evidence.calculatorApplied,
				active = evidence.active,
				socketMatched = evidence.socketMatched,
				socketState = evidence.socketState,
				linkState = evidence.linkState,
				groupState = evidence.groupState,
				playableActive = evidence.playableActive,
				supportProfileVersion = 2,
			}
			rows[#rows + 1] = row
			if origin == "item_granted" and row.playableActive and effectId ~= "" then itemGrantedSeen[effectId] = true end
		end
	end
	table.sort(rows, function(left, right)
			if left.effectId ~= right.effectId then return left.effectId < right.effectId end
			if left.origin ~= right.origin then return left.origin < right.origin end
			if tostring(left.sourceSlot or "") ~= tostring(right.sourceSlot or "") then return tostring(left.sourceSlot or "") < tostring(right.sourceSlot or "") end
			return tostring(left.gemId or "") < tostring(right.gemId or "")
		end)
	return rows
end

local function profileSkillGroups(build, itemFingerprintsBySlot)
	local result, selectedEffects, availableEffects, supports, mainSkill = { }, { }, { }, { }, nil
	local selectedSeen, availableSeen, supportSeen, itemGrantedSeen = { }, { }, { }, { }
	for groupIndex, group in ipairs(build.skillsTab and build.skillsTab.socketGroupList or { }) do
		if groupIndex > MAX_SKILL_GROUPS then break end
		local groupRow = {
			groupIndex = groupIndex,
			label = cleanText(group.displayLabel or group.label or "", 120),
			slot = cleanText(group.slot or "", 64),
			enabled = group.enabled ~= false,
			slotEnabled = group.slotEnabled ~= false,
			includeInFullDPS = group.includeInFullDPS == true,
			selectedMainGroup = build.mainSocketGroup == groupIndex,
			supportProfileVersion = 2,
			socketValidation = SkillCatalog.SocketGroupEvidence(build, groupIndex, group),
			gems = { },
			skills = { },
		}
		for gemIndex, gem in ipairs(group.gemList or { }) do
			if gemIndex > MAX_GEMS_PER_GROUP then break end
			local data = gem.gemData
			local granted = gem.grantedEffect or (data and data.grantedEffect)
			local isSupport = granted and granted.support == true or false
			local gemId = tostring(gem.gemId or data and data.id or "")
			local gemRow = {
				gemIndex = gemIndex,
				gemId = cleanText(gemId, 160),
				gameId = cleanText(data and data.gameId or "", 200),
				variantId = cleanText(data and data.variantId or "", 200),
				skillId = cleanText(gem.skillId or data and data.grantedEffectId or "", 180),
				name = cleanText(data and data.name or granted and granted.name or gem.nameSpec or "", 120),
				level = tonumber(gem.level) or 1,
				quality = tonumber(gem.quality) or 0,
				enabled = gem.enabled ~= false,
				isSupport = not not isSupport,
				socketMatched = groupRow.socketValidation.valid == true,
			}
			groupRow.gems[#groupRow.gems + 1] = gemRow
			if isSupport and gemRow.enabled and gemId ~= "" then supportSeen[gemId] = true end
		end
		for skillIndex, activeSkill in ipairs(group.displaySkillList or { }) do
			if skillIndex > MAX_GEMS_PER_GROUP then break end
			local activeEffect = activeSkill.activeEffect
			if not activeEffect and activeSkill.effectList and #activeSkill.effectList == 1 then
				activeEffect = activeSkill.effectList[1]
			end
			local sourceGem = resolveSourceGem(group, activeEffect)
			local gemData = sourceGem and sourceGem.gemData
			local effectRows = { }
			for _, effectInstance in ipairs(activeSkill.effectList or { }) do
				local effect = effectInstance.grantedEffect
				if effect and effect.id then
					local effectId = tostring(effect.id)
					local effectSourceGem = effectInstance.srcInstance
					local effectGemData = effectInstance.gemData or effectSourceGem and effectSourceGem.gemData
					local variant = {
						effectId = effectId,
						name = cleanText(effect.name or "", 120),
						gemId = cleanText(effectSourceGem and (effectSourceGem.gemId or effectGemData and effectGemData.id)
							or effectGemData and effectGemData.id or sourceGem and (sourceGem.gemId or gemData and gemData.id) or "", 160),
						gameId = cleanText(effectGemData and effectGemData.gameId or gemData and gemData.gameId or "", 200),
						variantId = cleanText(effectGemData and effectGemData.variantId or gemData and gemData.variantId or "", 200),
						category = mainSkillCategory(effectGemData or gemData,
							effectGemData and effectGemData.gameId or gemData and gemData.gameId,
							effectGemData and effectGemData.variantId or gemData and gemData.variantId),
						selected = effectInstance == activeEffect,
					}
					effectRows[#effectRows + 1] = variant
					if variant.gemId and variant.gemId ~= "" then availableSeen[effectId] = variant end
					if variant.selected and group.enabled ~= false and group.slotEnabled ~= false
						and (not sourceGem or sourceGem.enabled ~= false) then
						selectedSeen[effectId] = variant
					end
				end
			end
			groupRow.skills[#groupRow.skills + 1] = {
				skillIndex = skillIndex,
				name = cleanText(activeSkill.name or activeEffect and activeEffect.grantedEffect and activeEffect.grantedEffect.name or "", 120),
				selectedMainSkill = build.mainSocketGroup == groupIndex
					and (group.mainActiveSkill or 1) == skillIndex,
				effects = effectRows,
				supportProfileVersion = 2,
				supports = supportProfileForSkill(build, group, groupRow.socketValidation,
					activeSkill, activeEffect, groupIndex, skillIndex, itemFingerprintsBySlot or { }, itemGrantedSeen),
			}
			if groupRow.selectedMainGroup and (group.mainActiveSkill or 1) == skillIndex and sourceGem then
				local mainEffect = activeEffect and activeEffect.grantedEffect
				mainSkill = {
					gemId = cleanText(sourceGem.gemId or gemData and gemData.id or "", 160),
					gameId = cleanText(gemData and gemData.gameId or "", 200),
					variantId = cleanText(gemData and gemData.variantId or "", 200),
					skillId = cleanText(sourceGem.skillId or gemData and gemData.grantedEffectId or "", 180),
					effectId = cleanText(mainEffect and mainEffect.id or "", 180),
					name = cleanText(gemData and gemData.name or activeSkill.name or mainEffect and mainEffect.name or "", 120),
				}
				mainSkill.category = mainSkillCategory(gemData, mainSkill.gameId, mainSkill.variantId)
			end
		end
		result[#result + 1] = groupRow
	end
	local function rowsFromMap(map)
		local rows = { }
		for _, value in pairs(map) do rows[#rows + 1] = value end
		table.sort(rows, function(left, right) return tostring(left.effectId or left) < tostring(right.effectId or right) end)
		return rows
	end
	for gemId in pairs(supportSeen) do supports[#supports + 1] = gemId end
	table.sort(supports)
	local itemGrantedSupportEffectIds = { }
	for effectId in pairs(itemGrantedSeen) do itemGrantedSupportEffectIds[#itemGrantedSupportEffectIds + 1] = effectId end
	table.sort(itemGrantedSupportEffectIds)
	return result, rowsFromMap(selectedSeen), rowsFromMap(availableSeen), supports, mainSkill, itemGrantedSupportEffectIds
end

local function profileMainSkillCandidates(skillGroups, mainSkill)
	local candidates = { }
	for groupIndex, group in ipairs(skillGroups or { }) do
		for skillIndex, skill in ipairs(group.skills or { }) do
			for _, effect in ipairs(skill.effects or { }) do
				if effect.selected == true and tostring(effect.gemId or "") ~= ""
					and tostring(effect.gameId or "") ~= "" and tostring(effect.variantId or "") ~= ""
					and tostring(effect.effectId or "") ~= "" then
					candidates[#candidates + 1] = {
						gemId = effect.gemId,
						gameId = effect.gameId,
						variantId = effect.variantId,
						effectId = effect.effectId,
						name = effect.name or skill.name,
						category = effect.category or mainSkillCategory(nil, effect.gameId, effect.variantId),
						groupIndex = groupIndex,
						skillIndex = skillIndex,
						groupLabel = group.label,
						selectedMainGroup = group.selectedMainGroup == true,
						selectedMainSkill = skill.selectedMainSkill == true,
						socketValidationStatus = group.socketValidation and group.socketValidation.status or "not_assessed",
					}
				end
			end
		end
	end
	table.sort(candidates, function(left, right)
		local leftKey = table.concat({ tostring(left.groupIndex), tostring(left.skillIndex), left.gameId, left.variantId, left.effectId }, "|")
		local rightKey = table.concat({ tostring(right.groupIndex), tostring(right.skillIndex), right.gameId, right.variantId, right.effectId }, "|")
		return leftKey < rightKey
	end)
	if type(mainSkill) == "table" then
		for _, candidate in ipairs(candidates) do
			candidate.selectedMainSkill = candidate.selectedMainSkill
				or candidate.gameId == tostring(mainSkill.gameId or "")
					and candidate.variantId == tostring(mainSkill.variantId or "")
					and candidate.effectId == tostring(mainSkill.effectId or "")
					and candidate.gemId == tostring(mainSkill.gemId or "")
		end
	end
	return candidates
end

local function itemSlotProfile(build)
	local result = { }
	local itemsTab = build.itemsTab
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId])
	local seen = { }
	local function appendItem(slotName, itemId, item, sourceKind, socketNodeId)
		if not item or seen[tostring(slotName)] then return end
		seen[tostring(slotName)] = true
		result[#result + 1] = {
			slot = tostring(slotName),
			itemType = cleanText(item.type or "", 80),
			name = cleanText(item.name or "", 120),
			base = cleanText(item.baseName or item.type or "", 120),
			rarity = cleanText(item.rarity or "", 40),
			itemFingerprint = SurrogateFeatures.ItemFingerprint(item),
			sourceKind = sourceKind,
			itemId = tonumber(itemId),
			socketNodeId = tonumber(socketNodeId),
		}
	end
	if itemSet then
		for slotName, slot in pairs(itemSet) do
			local itemId = type(slot) == "table" and tonumber(slot.selItemId)
			local item = itemId and itemId > 0 and itemsTab.items and itemsTab.items[itemId]
			if item then appendItem(slotName, itemId, item, "equipment_slot") end
		end
	end
	-- Passive tree jewels live on the active Spec rather than the equipment
	-- item-set row. Preserve them even if headless loading cannot rebuild UI slots
	-- (for example, when a historical Timeless Jewel LUT is unavailable).
	for nodeId, itemId in pairs(build.spec and build.spec.jewels or { }) do
		local numericItemId, numericNodeId = tonumber(itemId), tonumber(nodeId)
		local item = numericItemId and numericItemId > 0 and itemsTab and itemsTab.items
			and itemsTab.items[numericItemId]
		if item then appendItem("Tree Socket " .. tostring(numericNodeId), numericItemId, item,
			"passive_tree_socket", numericNodeId) end
	end
	table.sort(result, function(left, right) return left.slot < right.slot end)
	return result
end

function builds.ProfileFromBuild(build)
	if type(build) ~= "table" or type(build.spec) ~= "table" then return nil, "A loaded PoB build is required" end
	local snapshot = Version.Snapshot(build)
	local itemSlots = itemSlotProfile(build)
	local itemFingerprintsBySlot = { }
	for _, item in ipairs(itemSlots) do itemFingerprintsBySlot[item.slot] = item.itemFingerprint end
	local skills, selectedEffects, availableEffects, supports, mainSkill, itemGrantedSupportEffectIds =
		profileSkillGroups(build, itemFingerprintsBySlot)
	local mainSkillCandidates = profileMainSkillCandidates(skills, mainSkill)
	if #selectedEffects > MAX_EFFECTS_PER_BUILD or #availableEffects > MAX_EFFECTS_PER_BUILD then
		return nil, "The build exceeds the archive's per-build skill-effect safety limit"
	end
	local mainSkillStatus = "unidentified"
	if type(mainSkill) == "table" then
		if tostring(mainSkill.gameId or "") ~= "" and tostring(mainSkill.variantId or "") ~= ""
			and tostring(mainSkill.effectId or "") ~= "" then
			mainSkillStatus = "identified"
		else
			mainSkillStatus = "partial"
		end
	end
	local classId, ascendancyId = tonumber(build.spec.curClassId), tonumber(build.spec.curAscendClassId)
	local class = build.spec.curClass or build.spec.tree and build.spec.tree.classes and build.spec.tree.classes[classId]
	local secondaryAscendancyId = tonumber(build.spec.curSecondaryAscendClassId) or 0
	local bloodlineNodeIds = { }
	for nodeId, node in pairs(build.spec.allocNodes or { }) do
		if type(node) == "table" and node.isBloodline == true then
			local id = tonumber(nodeId)
			if isFinite(id) and id > 0 and id == math.floor(id) then bloodlineNodeIds[#bloodlineNodeIds + 1] = id end
		end
	end
	table.sort(bloodlineNodeIds)
	return {
		schema = "pob-ai-planner-build-profile",
		schemaVersion = 1,
		capturedAt = os.time(),
		engine = snapshot,
		character = {
			classId = classId,
			class = cleanText(class and class.name or "", 64),
			ascendancyId = ascendancyId,
			ascendancy = cleanText(build.spec.curAscendClass and build.spec.curAscendClass.name or "", 80),
			secondaryAscendancyId = secondaryAscendancyId,
			secondaryAscendancy = cleanText(build.spec.curSecondaryAscendClassName or "None", 80),
			level = tonumber(build.characterLevel),
		},
		activeSpec = {
			index = tonumber(build.treeTab and build.treeTab.activeSpec),
			treeVersion = cleanText(build.spec.treeVersion or "", 24),
			classId = classId,
			ascendancyId = ascendancyId,
			secondaryAscendancyId = secondaryAscendancyId,
			allocatedNodeIds = sortedPositiveIds(build.spec.allocNodes),
			allocatedBloodlineNodeIds = bloodlineNodeIds,
		},
		league = { status = "unknown", value = nil },
		allocatedNodeIds = sortedPositiveIds(build.spec.allocNodes),
		masterySelections = masteryRows(build.spec.masterySelections),
		mainSocketGroup = tonumber(build.mainSocketGroup),
		mainSkill = mainSkill,
		mainSkillStatus = mainSkillStatus,
		mainSkillCandidates = mainSkillCandidates,
		mainSkillResolutionStatus = type(mainSkill) == "table" and "selected_main_skill_identified"
			or (#mainSkillCandidates > 0 and "configured_skill_effects_preserved_without_single_selection"
				or "no_catalog_resolvable_configured_skill_effect"),
		archiveReadinessStatus = ((build.sourceInactiveSpecRecoveryGap or 0) > 0
			or #(build.sourceUnparsedTreeSocketItemIds or { }) > 0)
			and "native_active_profile_complete_source_xml_preserved" or "native_profile_complete",
		sourceTreeRecoveryStatus = cleanText(build.sourceTreeRecoveryStatus or "native_source_tree_loaded", 80),
		sourceInactiveSpecRecoveryGap = tonumber(build.sourceInactiveSpecRecoveryGap) or 0,
		sourceUnparsedTreeSocketItemIds = build.sourceUnparsedTreeSocketItemIds or { },
		skillGroups = skills,
		configuredSkillEffects = selectedEffects,
		availableSkillEffects = availableEffects,
		supportGemIds = supports,
		supportFeatureSchemaVersion = 2,
		itemGrantedSupportEffectIds = itemGrantedSupportEffectIds,
		itemSlotFeatureSchemaVersion = 2,
		itemSlots = itemSlots,
		trainingStatus = "observation_only_pending_rights_and_exact_labels",
	}
end

local function atomicObjectWrite(path, payload, digest)
	local existing = io.open(path, "rb")
	if existing then
		local size = existing:seek("end") or 0
		existing:seek("set", 0)
		local current = size <= MAX_BUILD_BYTES and existing:read("*a") or nil
		existing:close()
		if type(current) == "string" and sha.sha256(current) == digest then return true, "duplicate" end
		return nil, "An existing content-addressed build object failed its SHA-256 check"
	end
	sequence = sequence + 1
	local tempPath = path .. ".tmp-" .. tostring(os.time()) .. "-" .. tostring(sequence)
	local file, openError = io.open(tempPath, "wb")
	if not file then return nil, "Could not create the archived build object: " .. tostring(openError):sub(1, 200) end
	local wrote, writeError = file:write(payload)
	local flushed, flushError = wrote and file:flush()
	local closed, closeError = file:close()
	if not wrote or not flushed or not closed then
		os.remove(tempPath)
		return nil, "Could not write the archived build object: " .. tostring(writeError or flushError or closeError or "write failed"):sub(1, 200)
	end
	local renamed, renameError = os.rename(tempPath, path)
	if renamed then return true, "stored" end
	os.remove(tempPath)
	-- A second importer may have won the content-addressed write. Verify it.
	local verify = io.open(path, "rb")
	if verify then
		local current = verify:read("*a")
		verify:close()
		if type(current) == "string" and sha.sha256(current) == digest then return true, "duplicate" end
	end
	return nil, "Could not finalize the archived build object: " .. tostring(renameError or "rename failed"):sub(1, 200)
end

local function normalizeSource(source)
	if type(source) ~= "table" then source = { type = "local_active_build" } end
	local sourceType = cleanText(source.type or "local_active_build", 40)
	local provider = cleanText(source.provider or "", 80)
	local reference = cleanText(source.reference or "", 1024)
	local label = cleanText(source.label or "", 120)
	local codeSha256 = cleanText(source.codeSha256 or "", 64)
	local codePath = cleanText(source.codePath or "", 256)
	local sourceXmlSha256 = cleanText(source.sourceXmlSha256 or "", 64)
	local sourceXmlPath = cleanText(source.sourceXmlPath or "", 256)
	local targetScopeStatus = source.targetScopeStatus
	if targetScopeStatus ~= "in_scope" and targetScopeStatus ~= "out_of_target_scope"
		and targetScopeStatus ~= "unclassified" then targetScopeStatus = "not_assessed" end
	local nativeImportStatus = source.nativeImportStatus == "native_imported" and "native_imported" or "not_assessed"
	local nativeSerializationStatus = source.nativeSerializationStatus
	if nativeSerializationStatus ~= "native_reserialized"
		and nativeSerializationStatus ~= "source_xml_preserved_after_native_save_error"
		and nativeSerializationStatus ~= "source_xml_preserved_historical_tree_data" then
		nativeSerializationStatus = "not_assessed"
	end
	local nativeSerializationReason = cleanText(source.nativeSerializationReason or "", 240)
	if codeSha256 and (#codeSha256 ~= 64 or not codeSha256:match("^%x+$")) then
		codeSha256 = nil
	end
	if sourceXmlSha256 and (#sourceXmlSha256 ~= 64 or not sourceXmlSha256:match("^%x+$")) then
		sourceXmlSha256 = nil
	end
	if codePath and (not codePath:match("^source%-codes/") or codePath:find("\\", 1, true)
		or codePath:find(":", 1, true)) then codePath = nil end
	if codePath then
		for segment in codePath:gmatch("[^/]+") do
			if segment == ".." then codePath = nil; break end
		end
	end
	if sourceXmlPath and (not sourceXmlPath:match("^source%-xml/[A-Za-z0-9_-]+/[A-Za-z0-9_.%-]+%.xml$")
		or sourceXmlPath:find("\\", 1, true) or sourceXmlPath:find(":", 1, true)) then sourceXmlPath = nil end
	if sourceXmlPath then
		for segment in sourceXmlPath:gmatch("[^/]+") do
			if segment == ".." then sourceXmlPath = nil; break end
		end
	end
	local claimedMainSkill
	if source.claimedMainSkill ~= nil then
		if type(source.claimedMainSkill) == "table" then
			claimedMainSkill = {
				gemId = cleanText(source.claimedMainSkill.gemId or "", 180),
				gameId = cleanText(source.claimedMainSkill.gameId or "", 180),
				variantId = cleanText(source.claimedMainSkill.variantId or "", 120),
				effectId = cleanText(source.claimedMainSkill.effectId or "", 120),
				name = cleanText(source.claimedMainSkill.name or "", 120),
				evidenceUrl = cleanText(source.claimedMainSkill.evidenceUrl or "", 1024),
				basis = cleanText(source.claimedMainSkill.basis or "", 80),
			}
		else
			claimedMainSkill = source.claimedMainSkill
		end
	end
	local result = {
		type = sourceType or "unspecified",
		provider = provider,
		reference = reference,
		sourceUrl = cleanText(source.sourceUrl or "", 1024),
		label = label,
		locale = cleanText(source.locale or "", 32),
		claimedLeague = cleanText(source.claimedLeague or "", 80),
		claimedPatch = cleanText(source.claimedPatch or "", 32),
		claimedMainSkill = claimedMainSkill,
		rightsStatus = cleanText(source.rightsStatus or "unverified", 64) or "unverified",
		rightsEvidenceUrl = cleanText(source.rightsEvidenceUrl or "", 1024),
		acquisitionMethod = cleanText(source.acquisitionMethod or "", 64),
		targetScopeStatus = targetScopeStatus,
		targetScopeReason = cleanText(source.targetScopeReason or "", 96),
		nativeImportStatus = nativeImportStatus,
		nativeSerializationStatus = nativeSerializationStatus,
		nativeSerializationReason = nativeSerializationReason,
		codeSha256 = codeSha256 and codeSha256:lower() or nil,
		codePath = codePath,
		sourceXmlSha256 = sourceXmlSha256 and sourceXmlSha256:lower() or nil,
		sourceXmlPath = sourceXmlPath,
		acquiredAt = cleanText(source.acquiredAt or "", 40),
	}
	if result.claimedLeague and result.claimedLeague ~= "" then result.leagueEvidence = "source_claim_unverified" end
	return result
end

local function sourceXmlPathIsSafe(sourceXmlPath)
	if type(sourceXmlPath) ~= "string" or not sourceXmlPath:match("^source%-xml/[A-Za-z0-9_-]+/[A-Za-z0-9_.%-]+%.xml$")
		or sourceXmlPath:find("\\", 1, true) or sourceXmlPath:find(":", 1, true) or sourceXmlPath:find("[%c]") then
		return false
	end
	for segment in sourceXmlPath:gmatch("[^/]+") do if segment == ".." then return false end end
	return true
end

local sourcePatchSkillIdFromXml

local function archivedSourcePatchSkillId(paths, row, mainSkill)
	local source = type(row) == "table" and row.source or nil
	if type(source) ~= "table" or not sourceXmlPathIsSafe(source.sourceXmlPath)
		or not isFingerprint(source.sourceXmlSha256) then return nil end
	local relativePath = source.sourceXmlPath:gsub("/", function() return separator() end)
	local path = joinPath(paths.root, relativePath, separator())
	local file = io.open(path, "rb")
	if not file then return nil end
	local size = file:seek("end") or 0
	if size <= 0 or size > MAX_BUILD_BYTES then file:close(); return nil end
	file:seek("set", 0)
	local payload = file:read("*a")
	file:close()
	if type(payload) ~= "string" or sha.sha256(payload) ~= source.sourceXmlSha256:lower() then return nil end
	return sourcePatchSkillIdFromXml(payload, row.profile, mainSkill)
end

function builds.ArchiveXML(build, xmlText, userPath, source, createDirectory, sourceXmlText)
	if type(xmlText) ~= "string" or #xmlText == 0 or #xmlText > MAX_BUILD_BYTES then
		return nil, "The PoB XML must be between 1 byte and 16 MiB"
	end
	local paths, pathError = builds.GetPaths(userPath)
	if not paths then return nil, pathError end
	local profile, profileError = builds.ProfileFromBuild(build)
	if not profile then return nil, profileError end
	local signatureOk, signature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or type(signature) ~= "string" then return nil, "Could not fingerprint the exact loaded PoB build state" end
	local xmlHash = sha.sha256(xmlText)
	local lineageHash = sha.sha256(signature)
	if type(source) == "table" and source.skipDuplicateLineage == true then
		local archivedLineages, lineageError = builds.ArchivedLineages(userPath)
		if not archivedLineages then return nil, "Could not verify build lineage uniqueness: " .. tostring(lineageError):sub(1, 180) end
		if archivedLineages[lineageHash:lower()] then
			return {
				duplicateLineage = true,
				storageStatus = "duplicate_lineage",
				lineageSha256 = lineageHash,
			}, nil
		end
	end
	local sourcePatchSkillId
	if type(sourceXmlText) == "string" and #sourceXmlText > 0 and #sourceXmlText <= MAX_BUILD_BYTES then
		local sourceHash = sha.sha256(sourceXmlText)
		local declaredSourceHash = type(source) == "table" and tostring(source.sourceXmlSha256 or ""):lower() or ""
		if declaredSourceHash == "" or declaredSourceHash == sourceHash then
			sourcePatchSkillId = sourcePatchSkillIdFromXml(sourceXmlText, profile, profile.mainSkill)
		end
	end
	if sourcePatchSkillId and type(profile.mainSkill) == "table" then
		profile.mainSkill.sourcePatchSkillId = sourcePatchSkillId
		profile.mainSkill.sourcePatchSkillIdSourceXmlSha256 = sha.sha256(sourceXmlText)
	end
	local shard = xmlHash:sub(1, 2)
	local objectDirectory = joinPath(paths.objects, shard, separator())
	for _, directory in ipairs({ paths.studies, paths.root, paths.objects, objectDirectory }) do
		local created, createError = makeDirectory(directory, createDirectory)
		if not created then return nil, createError end
	end
	local objectPath = joinPath(objectDirectory, xmlHash .. ".xml", separator())
	local stored, storageStatus = atomicObjectWrite(objectPath, xmlText, xmlHash)
	if not stored then return nil, storageStatus end
	local normalizedSource = normalizeSource(source)
	profile.league = normalizedSource.claimedLeague and {
		status = "source_claim_unverified",
		value = normalizedSource.claimedLeague,
	} or { status = "unknown", value = nil }
	sequence = sequence + 1
	local observationId = sha.sha256(table.concat({ xmlHash, lineageHash, tostring(os.time()), tostring(sequence),
		normalizedSource.type or "", normalizedSource.provider or "", normalizedSource.reference or "" }, "\0"))
	local row = {
		recordType = "build_archive_observation",
		schemaVersion = 1,
		observationId = observationId,
		observedAt = os.time(),
		xmlSha256 = xmlHash,
		lineageSha256 = lineageHash,
		object = OBJECT_FOLDER .. "/" .. shard .. "/" .. xmlHash .. ".xml",
		source = normalizedSource,
		profile = profile,
	}
	local encoded, encodeError = json.encode(row)
	if type(encoded) ~= "string" or #encoded > MAX_INDEX_LINE_BYTES then
		return nil, "The build metadata could not be encoded within the 256 KiB row limit: " .. tostring(encodeError or "row too large")
	end
	local file, openError = io.open(paths.index, "ab")
	if not file then return nil, "Could not append to the build archive index: " .. tostring(openError):sub(1, 200) end
	local wrote, writeError = file:write(encoded, "\n")
	local flushed, flushError = wrote and file:flush()
	local closed, closeError = file:close()
	if not wrote or not flushed or not closed then
		return nil, "Could not persist the build archive index: " .. tostring(writeError or flushError or closeError or "write failed"):sub(1, 200)
	end
	archiveGeneration = archiveGeneration + 1
	local reviewStatus
	local catalogOk, catalog = pcall(SkillCatalog.ListAllActiveEffects, build, "")
	if catalogOk and type(catalog) == "table" and catalog.truncated == false then
		local reviewModuleOk, BuildReviewPair = pcall(require, "Modules.Optimizer.BuildReviewPair")
		if reviewModuleOk and type(BuildReviewPair.Process) == "function" then
			local reviewOk, reviewResult, reviewError = pcall(BuildReviewPair.Process,
				profile, catalog, { }, userPath, lineageHash, createDirectory, row)
			if reviewOk and reviewResult then
				reviewStatus = reviewResult
			else
				reviewStatus = { status = "pending", error = tostring(reviewError or reviewResult or "review could not be persisted") }
			end
		else
			reviewStatus = { status = "pending", error = "Local paired reviewer runtime is unavailable: " .. tostring(BuildReviewPair):sub(1, 160) }
		end
	else
		reviewStatus = { status = "pending", error = "PoB's complete loaded skill-effect catalog is unavailable: " .. tostring(catalog or catalog) }
	end
	return {
		observationId = observationId,
		xmlSha256 = xmlHash,
		lineageSha256 = lineageHash,
		objectPath = objectPath,
		indexPath = paths.index,
		relativeRoot = paths.relativeRoot,
		storageStatus = storageStatus,
		configuredEffectCount = #profile.configuredSkillEffects,
		availableEffectCount = #profile.availableSkillEffects,
		catalogEffectCount = catalogOk and type(catalog) == "table" and tonumber(catalog.count) or nil,
		skillPairCount = math.max(0, #profile.configuredSkillEffects * (#profile.configuredSkillEffects - 1) / 2),
		trainingStatus = row.profile.trainingStatus,
		buildReview = reviewStatus,
	}
end

function builds.Generation()
	return archiveGeneration
end

local function missingFile(message)
	message = tostring(message or ""):lower()
	return message:find("no such file", 1, true) or message:find("cannot find", 1, true)
		or message:find("does not exist", 1, true) or message:find("system cannot find", 1, true)
end

local function absoluteArchiveRoot(value)
	local root = cleanText(value, 2048)
	if not root then return nil end
	local isWindowsRoot = root:match("^%a:[/\\]") ~= nil or root:match("^\\\\[^\\]") ~= nil
	local isUnixRoot = root:sub(1, 1) == "/"
	if not isWindowsRoot and not isUnixRoot then return nil end
	root = root:gsub("[/\\]+$", "")
	return root ~= "" and root or nil
end

-- Resolve the read-only source used by the route planner. External archives
-- are selected through a small local config or the process environment; all
-- archive writes continue to use the normal PoB user-data path.
function builds.GetPlannerArchiveSource(userPath)
	local root, mode
	local environmentRoot = type(os.getenv) == "function" and os.getenv("POB_AI_BUILD_ARCHIVE_ROOT") or nil
	if type(environmentRoot) == "string" and environmentRoot ~= "" then
		root, mode = absoluteArchiveRoot(environmentRoot), "environment_archive"
		if not root then return nil, "POB_AI_BUILD_ARCHIVE_ROOT must be an absolute path" end
	else
		local userPaths, userPathError = builds.GetPaths(userPath)
		if not userPaths then return nil, userPathError end
		local configPath = joinPath(userPaths.studies, ARCHIVE_SOURCE_CONFIG_FILE, separator())
		local configFile, configError = io.open(configPath, "rb")
		if not configFile then
			if not missingFile(configError) then
				return nil, "Could not read the build archive source config: " .. tostring(configError):sub(1, 180)
			end
			root, mode = absoluteArchiveRoot(userPath) or cleanText(userPath, 2048), "local_archive"
		else
			local size = configFile:seek("end") or 0
			if size <= 0 or size > MAX_ARCHIVE_SOURCE_CONFIG_BYTES then
				configFile:close()
				return nil, "Build archive source config is empty or exceeds its 8 KiB safety limit"
			end
			configFile:seek("set", 0)
			local payload = configFile:read("*a")
			configFile:close()
			local decodedOk, config = pcall(json.decode, payload)
			if not decodedOk or type(config) ~= "table"
				or config.schema ~= ARCHIVE_SOURCE_CONFIG_SCHEMA or config.schemaVersion ~= 1
				or config.readOnly ~= true then
				return nil, "Build archive source config has an unsupported schema or is not marked read-only"
			end
			root = absoluteArchiveRoot(config.root)
			if not root then return nil, "Build archive source config must contain an absolute root path" end
			mode = "project_archive"
		end
	end
	if not root then return nil, "PoB's archive source root is unavailable" end
	local function inspectArchive(candidateRoot, candidateMode)
		local paths, pathError = builds.GetPaths(candidateRoot)
		if not paths then return nil, pathError end
		local indexFile, indexError = io.open(paths.index, "rb")
		if not indexFile then
			return { root = candidateRoot, mode = candidateMode,
				status = missingFile(indexError) and "no_archive" or "unavailable",
				reason = missingFile(indexError) and "no_imported_build_archive" or "archive_index_unreadable", readOnly = true }
		end
		indexFile:close()
		local catalogFile, catalogError = io.open(paths.patchSkillCatalog, "rb")
		if not catalogFile then
			return { root = candidateRoot, mode = candidateMode,
				status = missingFile(catalogError) and "catalog_missing" or "unavailable",
				reason = missingFile(catalogError) and "patch_skill_catalog_missing" or "patch_skill_catalog_unreadable", readOnly = true }
		end
		catalogFile:close()
		return { root = candidateRoot, mode = candidateMode, status = "ready", paths = paths, readOnly = true }
	end
	local configuredSource, sourceError = inspectArchive(root, mode)
	if not configuredSource then return nil, sourceError end
	if configuredSource.status == "ready" or mode ~= "project_archive" then return configuredSource end

	-- A configured Drive archive can be temporarily unavailable while PoB's
	-- local copy remains usable. Keep project configuration authoritative when
	-- reachable; otherwise fall back only to the active PoB user's own archive.
	local localRoot = absoluteArchiveRoot(userPath)
	local function normalizedRoot(value)
		value = tostring(value or ""):gsub("/", "\\"):gsub("\\+$", "")
		return package.config:sub(1, 1) == "\\" and value:lower() or value
	end
	if localRoot and normalizedRoot(localRoot) ~= normalizedRoot(root) then
		local localSource = inspectArchive(localRoot, "local_fallback")
		if localSource and localSource.status == "ready" then
			localSource.configuredRoot = root
			localSource.configuredStatus = configuredSource.status
			localSource.configuredReason = configuredSource.reason
			localSource.fallbackReason = configuredSource.reason or configuredSource.status
			return localSource
		end
		configuredSource.fallbackStatus = localSource and localSource.status or "unavailable"
		configuredSource.fallbackReason = localSource and localSource.reason or "local_archive_unavailable"
	end
	return configuredSource
end

local function effectIdentity(effect)
	if type(effect) ~= "table" then return nil end
	local id = cleanText(tostring(effect.effectId or ""), 180)
	if not id or id == "" then return nil end
	return id
end

local function configuredSkillIdentity(effect)
	if type(effect) ~= "table" then return nil end
	local gameId = cleanText(tostring(effect.gameId or ""), 200)
	local variantId = cleanText(tostring(effect.variantId or ""), 200)
	local effectId = effectIdentity(effect)
	if gameId and variantId then
		return { key = gameId .. "|" .. variantId, gameId = gameId, variantId = variantId,
			effectId = effectId, name = cleanText(tostring(effect.name or variantId), 120), exact = true }
	end
	if effectId then
		return { key = "effect|" .. effectId, gameId = nil, variantId = nil,
			effectId = effectId, name = cleanText(tostring(effect.name or effectId), 120), exact = false }
	end
	return nil
end

local function patchFromTreeVersion(treeVersion)
	if type(treeVersion) ~= "string" then return nil end
	local minor = treeVersion:match("^3_(2[4-9])$") or treeVersion:match("^3%.(2[4-9])$")
	if not minor then return nil end
	return "3." .. minor
end

local function profileMainSkill(profile)
	if type(profile) ~= "table" or type(profile.skillGroups) ~= "table" then return nil end
	local selectedGroups = { }
	for _, group in ipairs(profile.skillGroups) do
		if type(group) == "table" and group.selectedMainGroup == true then selectedGroups[#selectedGroups + 1] = group end
	end
	if #selectedGroups ~= 1 then return nil end
	local group = selectedGroups[1]
	if type(group.enabled) ~= "boolean" or type(group.slotEnabled) ~= "boolean"
		or not group.enabled or not group.slotEnabled or type(group.skills) ~= "table" then return nil end
	local selectedSkills = { }
	for _, skill in ipairs(group.skills) do
		if type(skill) == "table" and skill.selectedMainSkill == true then selectedSkills[#selectedSkills + 1] = skill end
	end
	if #selectedSkills ~= 1 then return nil end
	local skill = selectedSkills[1]
	if skill.enabled == false or type(skill.effects) ~= "table" then return nil end
	local selectedEffect, selectedEffectCount = nil, 0
	for _, effect in ipairs(skill.effects) do
		if type(effect) == "table" and effect.selected == true then
			selectedEffect = effect
			selectedEffectCount = selectedEffectCount + 1
		end
	end
	if selectedEffectCount ~= 1 then return nil end
	local selectedGemId = cleanText(tostring(selectedEffect.gemId or ""), 160)
	if not selectedGemId or type(group.gems) ~= "table" then return nil end
	local matchingGems, sourceGem = 0, nil
	for _, gem in ipairs(group.gems) do
		if type(gem) == "table" and tostring(gem.gemId or "") == selectedGemId then
			matchingGems = matchingGems + 1
			sourceGem = gem
		end
	end
	if matchingGems ~= 1 or type(sourceGem.enabled) ~= "boolean" or not sourceGem.enabled
		or type(sourceGem.isSupport) ~= "boolean" or sourceGem.isSupport
		or tostring(sourceGem.gameId or "") ~= tostring(selectedEffect.gameId or "")
		or tostring(sourceGem.variantId or "") ~= tostring(selectedEffect.variantId or "") then return nil end
	local gameId = cleanText(tostring(selectedEffect.gameId or ""), 200)
	local variantId = cleanText(tostring(selectedEffect.variantId or ""), 200)
	local effectId = cleanText(tostring(selectedEffect.effectId or ""), 180)
	local skillId = cleanText(tostring(sourceGem.skillId or ""), 180)
	if not gameId or not variantId or not effectId then return nil end
	local selected = {
		gemId = cleanText(tostring(selectedEffect.gemId or ""), 160),
		gameId = gameId, variantId = variantId, skillId = skillId, effectId = effectId,
		name = cleanText(tostring(selectedEffect.name or skill.name or ""), 120),
		category = mainSkillCategory(nil, gameId, variantId),
	}
	local direct = profile.mainSkill
	if direct ~= nil then
		if type(direct) ~= "table" or tostring(direct.gameId or "") ~= gameId
			or tostring(direct.variantId or "") ~= variantId
			or direct.skillId ~= nil and skillId ~= nil and tostring(direct.skillId) ~= skillId
			or direct.effectId ~= nil and tostring(direct.effectId) ~= effectId then
			return nil
		end
	end
	return selected
end

local function validArchivedObservation(row)
	return type(row) == "table" and row.recordType == "build_archive_observation"
		and row.schemaVersion == 1 and isFingerprint(row.lineageSha256) and isFingerprint(row.xmlSha256)
		and type(row.profile) == "table" and row.profile.schema == "pob-ai-planner-build-profile"
		and row.profile.schemaVersion == 1 and type(row.source) == "table"
end

local function archivedObjectRelativePath(xmlSha256)
	return OBJECT_FOLDER .. "/" .. xmlSha256:sub(1, 2):lower() .. "/" .. xmlSha256:lower() .. ".xml"
end

local function archivedSeedFromObservation(row)
	if not validArchivedObservation(row) then return nil end
	local profile = row.profile
	local engine = type(profile.engine) == "table" and profile.engine or { }
	local patch = cleanText(tostring(engine.dataVersion or ""), 32)
	local treeVersion = cleanText(tostring(engine.treeVersion or ""), 32)
	if not patch or not treeVersion or patchFromTreeVersion(treeVersion) ~= patch then return nil end
	local skill = profileMainSkill(profile)
	local character = type(profile.character) == "table" and profile.character or { }
	local className = cleanText(tostring(character.class or ""), 40)
	local ascendancy = cleanText(tostring(character.ascendancy or ""), 60)
	if not skill or not className or not ascendancy or not STANDARD_ASCENDANCY_CLASS_IDS[ascendancy] then return nil end
	local sourceLabel = cleanText(tostring(row.source.label or ""), 160)
	if not sourceLabel then sourceLabel = "Build arquivada " .. row.xmlSha256:sub(1, 8) end
	local level = tonumber(character.level)
	if not isFinite(level) or level < 1 or level > 100 then level = nil end
	return {
		xmlSha256 = row.xmlSha256:lower(),
		label = sourceLabel,
		buildName = string.format("[%s] %s — %s", patch, skill.name or skill.variantId, ascendancy),
		patch = patch,
		treeVersion = treeVersion,
		skill = skill,
		class = className,
		ascendancy = ascendancy,
		level = level,
		rightsStatus = cleanText(tostring(row.source.rightsStatus or "unverified"), 80) or "unverified",
		trainingStatus = cleanText(tostring(profile.trainingStatus or "observation_only_pending_rights_and_exact_labels"), 100)
			or "observation_only_pending_rights_and_exact_labels",
		observedAt = isFinite(tonumber(row.observedAt)) and tonumber(row.observedAt) or 0,
		object = archivedObjectRelativePath(row.xmlSha256),
	}
end

-- List immutable, previously imported build seeds from the configured archive.
-- These are starting builds only; their public origin/rights do not grant
-- training eligibility. The optional progress callback may yield to keep the
-- Planner responsive while a Drive-backed JSONL index is being scanned.
function builds.ListArchivedSeeds(userPath, filters, onProgress)
	filters = type(filters) == "table" and filters or { }
	local source, sourceError = builds.GetPlannerArchiveSource(userPath)
	if not source then return nil, sourceError end
	if source.status ~= "ready" or type(source.paths) ~= "table" then
		return nil, source.reason or "The configured build archive is not ready"
	end
	local file, openError = io.open(source.paths.index, "rb")
	if not file then return nil, "Could not read the build archive index: " .. tostring(openError):sub(1, 180) end
	local latestByHash, observationCount, lineNumber = { }, 0, 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if lineNumber > MAX_ARCHIVE_LINEAGE_SCAN_ROWS then
			file:close()
			return nil, "Build archive seed catalog exceeds its row safety limit"
		end
		if #line > MAX_INDEX_LINE_BYTES then
			file:close()
			return nil, "Build archive index row exceeds the 256 KiB safety limit at line " .. lineNumber
		end
		if line ~= "" then
			local decoded, row = pcall(json.decode, line)
			if not decoded or not validArchivedObservation(row) then
				file:close()
				return nil, "Build archive index contains an invalid record at line " .. lineNumber
			end
			observationCount = observationCount + 1
			local seed = archivedSeedFromObservation(row)
			if seed and (not filters.dataVersion or seed.patch == tostring(filters.dataVersion))
				and (not filters.treeVersion or seed.treeVersion == tostring(filters.treeVersion)) then
				local current = latestByHash[seed.xmlSha256]
				if not current or seed.observedAt >= current.observedAt then latestByHash[seed.xmlSha256] = seed end
			end
		end
		if onProgress and lineNumber % 32 == 0 then onProgress(lineNumber) end
	end
	file:close()
	local seeds = { }
	for _, seed in pairs(latestByHash) do seeds[#seeds + 1] = seed end
	table.sort(seeds, function(left, right)
		if left.patch ~= right.patch then return left.patch > right.patch end
		local leftSkill, rightSkill = tostring(left.skill.name or ""):lower(), tostring(right.skill.name or ""):lower()
		if leftSkill ~= rightSkill then return leftSkill < rightSkill end
		if left.ascendancy ~= right.ascendancy then return left.ascendancy < right.ascendancy end
		if (left.level or 0) ~= (right.level or 0) then return (left.level or 0) > (right.level or 0) end
		return left.xmlSha256 < right.xmlSha256
	end)
	local maxResults = tonumber(filters.maxResults) or 1000
	maxResults = math.max(1, math.min(1000, math.floor(maxResults)))
	while #seeds > maxResults do table.remove(seeds) end
	return seeds, {
		archiveMode = source.mode,
		observationCount = observationCount,
		uniqueBuildCount = #latestByHash,
		listedBuildCount = #seeds,
		filteredByVersion = filters.dataVersion ~= nil or filters.treeVersion ~= nil,
	}
end

-- Read exactly one selected content-addressed build and verify both its archive
-- path and SHA-256 before handing XML to PoB's existing native import flow.
function builds.ReadArchivedSeed(userPath, xmlSha256, filters)
	filters = type(filters) == "table" and filters or { }
	if not isFingerprint(xmlSha256) then return nil, "Selected build seed ID is invalid" end
	local source, sourceError = builds.GetPlannerArchiveSource(userPath)
	if not source then return nil, sourceError end
	if source.status ~= "ready" or type(source.paths) ~= "table" then
		return nil, source.reason or "The configured build archive is not ready"
	end
	local file, openError = io.open(source.paths.index, "rb")
	if not file then return nil, "Could not read the build archive index: " .. tostring(openError):sub(1, 180) end
	local selected, lineNumber = nil, 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if lineNumber > MAX_ARCHIVE_LINEAGE_SCAN_ROWS or #line > MAX_INDEX_LINE_BYTES then
			file:close()
			return nil, "Build archive seed lookup exceeded its safety limit"
		end
		if line ~= "" then
			local decoded, row = pcall(json.decode, line)
			if not decoded or not validArchivedObservation(row) then
				file:close()
				return nil, "Build archive index contains an invalid record at line " .. lineNumber
			end
			if row.xmlSha256:lower() == xmlSha256:lower() then
				local seed = archivedSeedFromObservation(row)
				if seed and (not filters.dataVersion or seed.patch == tostring(filters.dataVersion))
					and (not filters.treeVersion or seed.treeVersion == tostring(filters.treeVersion))
				and (not selected or seed.observedAt >= selected.observedAt) then
					selected = seed
				end
			end
		end
	end
	file:close()
	if not selected then return nil, "Selected build seed is not compatible with the current PoB data/tree version" end
	local expectedObject = archivedObjectRelativePath(selected.xmlSha256)
	if selected.object ~= expectedObject then return nil, "Archived build seed object path does not match its content hash" end
	local objectPath = joinPath(source.paths.root, expectedObject:gsub("/", function() return separator() end), separator())
	local object, objectError = io.open(objectPath, "rb")
	if not object then return nil, "Archived build seed XML is unavailable: " .. tostring(objectError):sub(1, 160) end
	local size = object:seek("end") or 0
	object:seek("set", 0)
	local payload = size > 0 and size <= MAX_BUILD_BYTES and object:read("*a") or nil
	object:close()
	if type(payload) ~= "string" or sha.sha256(payload) ~= selected.xmlSha256 then
		return nil, "Archived build seed failed its SHA-256 check"
	end
	local parsed, document, parseError = pcall(xml.ParseXML, payload)
	if not parsed or parseError or type(document) ~= "table" or type(document[1]) ~= "table"
		or document[1].elem ~= "PathOfBuilding" then
		return nil, "Archived build seed is not a valid native PoB XML"
	end
	selected.xmlText = payload
	selected.archiveMode = source.mode
	return selected
end

-- Resolve a historical socketed-gem skillId from the immutable source XML.
-- Runtime gem/effect IDs can change when an older build is loaded by newer PoB
-- data; the selected group, selected active skill, gameId, and variantId must
-- all agree before the historical skillId is considered evidence.
sourcePatchSkillIdFromXml = function(sourceXmlText, profile, mainSkill)
	if type(sourceXmlText) ~= "string" or #sourceXmlText == 0 or #sourceXmlText > MAX_BUILD_BYTES
		or type(profile) ~= "table" or type(mainSkill) ~= "table" then return nil end
	local ok, document = pcall(xml.ParseXML, sourceXmlText)
	if not ok or type(document) ~= "table" or type(document[1]) ~= "table"
		or document[1].elem ~= "PathOfBuilding" then return nil end
	local buildNode, skillsNode
	for _, node in ipairs(document[1]) do
		if type(node) == "table" and node.elem == "Build" then
			if buildNode then return nil end
			buildNode = node
		elseif type(node) == "table" and node.elem == "Skills" then
			if skillsNode then return nil end
			skillsNode = node
		end
	end
	if type(buildNode) ~= "table" or type(skillsNode) ~= "table" then return nil end
	local buildAttrib = type(buildNode.attrib) == "table" and buildNode.attrib or { }
	local groupIndex = tonumber(buildAttrib.mainSkillIndex) or tonumber(buildAttrib.mainSocketGroup) or 1
	if not isFinite(groupIndex) or groupIndex < 1 or groupIndex ~= math.floor(groupIndex) then return nil end
	local selectedProfileGroup, selectedProfileSkill
	for _, group in ipairs(profile.skillGroups or { }) do
		if type(group) == "table" and group.selectedMainGroup == true then
			if selectedProfileGroup then return nil end
			selectedProfileGroup = group
		end
	end
	if not selectedProfileGroup or tonumber(selectedProfileGroup.groupIndex) ~= groupIndex
		or selectedProfileGroup.enabled ~= true or selectedProfileGroup.slotEnabled ~= true then return nil end
	for _, skill in ipairs(selectedProfileGroup.skills or { }) do
		if type(skill) == "table" and skill.selectedMainSkill == true then
			if selectedProfileSkill then return nil end
			selectedProfileSkill = skill
		end
	end
	if not selectedProfileSkill then return nil end
	local activeSkillIndex = tonumber(selectedProfileSkill.skillIndex)
	if not isFinite(activeSkillIndex) or activeSkillIndex < 1 or activeSkillIndex ~= math.floor(activeSkillIndex) then return nil end
	local skillsAttrib = type(skillsNode.attrib) == "table" and skillsNode.attrib or { }
	local activeSetId = tonumber(skillsAttrib.activeSkillSet) or 1
	if not isFinite(activeSetId) or activeSetId < 1 or activeSetId ~= math.floor(activeSetId) then return nil end
	local selectedSet, matchingSets = nil, 0
	for _, node in ipairs(skillsNode) do
		if type(node) == "table" and node.elem == "SkillSet"
			and tonumber(node.attrib and node.attrib.id) == activeSetId then
			matchingSets, selectedSet = matchingSets + 1, node
		end
	end
	local groupRows
	if matchingSets == 1 then
		groupRows = selectedSet
	elseif matchingSets == 0 then
		-- Pre-SkillSet legacy XML stores socket groups directly under Skills.
		local hasSkillSet = false
		for _, node in ipairs(skillsNode) do if type(node) == "table" and node.elem == "SkillSet" then hasSkillSet = true end end
		if hasSkillSet then return nil end
		groupRows = skillsNode
	else
		return nil
	end
	local selectedXmlGroup, currentIndex = nil, 0
	for _, node in ipairs(groupRows) do
		if type(node) == "table" and node.elem == "Skill" then
			currentIndex = currentIndex + 1
			if currentIndex == groupIndex then selectedXmlGroup = node; break end
		end
	end
	if not selectedXmlGroup then return nil end
	local groupAttrib = type(selectedXmlGroup.attrib) == "table" and selectedXmlGroup.attrib or { }
	local xmlMainSkillIndex = tonumber(groupAttrib.mainActiveSkill) or 1
	if not isFinite(xmlMainSkillIndex) or xmlMainSkillIndex ~= activeSkillIndex then return nil end
	if groupAttrib.enabled == "false" or groupAttrib.active == "false" then return nil end
	local expectedGameId = tostring(mainSkill.gameId or "")
	local expectedVariantId = tostring(mainSkill.variantId or "")
	if expectedGameId == "" or expectedVariantId == "" then return nil end
	local matchedSkillId, matchingGems = nil, 0
	for _, node in ipairs(selectedXmlGroup) do
		if type(node) == "table" and node.elem == "Gem" then
			local attrib = type(node.attrib) == "table" and node.attrib or { }
			if tostring(attrib.gemId or "") == expectedGameId
				and tostring(attrib.variantId or "") == expectedVariantId
				and attrib.enabled ~= "false" then
				local sourceSkillId = cleanText(tostring(attrib.skillId or ""), 180)
				if not sourceSkillId then return nil end
				matchingGems, matchedSkillId = matchingGems + 1, sourceSkillId
			end
		end
	end
	if matchingGems ~= 1 then return nil end
	return matchedSkillId
end

local function loadPatchSkillCatalog(path)
	local file, openError = io.open(path, "rb")
	if not file then
		local message = tostring(openError or ""):lower()
		if message:find("no such file", 1, true) or message:find("cannot find", 1, true)
			or message:find("does not exist", 1, true) or message:find("system cannot find", 1, true) then
			return nil, "catalog_missing"
		end
		return nil, "catalog_unreadable"
	end
	local size = file:seek("end") or 0
	if size <= 0 or size > MAX_PATCH_CATALOG_BYTES then file:close(); return nil, "catalog_size_invalid" end
	file:seek("set", 0)
	local payload = file:read("*a")
	file:close()
	local ok, catalog = pcall(json.decode, payload)
	if not ok or type(catalog) ~= "table" or catalog.schema ~= "pob-ai-planner-patch-skill-catalog"
		or (catalog.schemaVersion ~= 1 and catalog.schemaVersion ~= 2 and catalog.schemaVersion ~= 3
			and catalog.schemaVersion ~= 4 and catalog.schemaVersion ~= 5)
		or type(catalog.patches) ~= "table" or (#catalog.patches ~= 4 and #catalog.patches ~= 6) then
		return nil, "catalog_schema_invalid"
	end
	local expectedPatches = #catalog.patches == 6
		and { ["3.24"] = "3_24", ["3.25"] = "3_25", ["3.26"] = "3_26", ["3.27"] = "3_27", ["3.28"] = "3_28", ["3.29"] = "3_29" }
		or { ["3.26"] = "3_26", ["3.27"] = "3_27", ["3.28"] = "3_28", ["3.29"] = "3_29" }
	local byPatch = { }
	for _, patch in ipairs(catalog.patches) do
		if type(patch) ~= "table" or not expectedPatches[patch.patch]
			or byPatch[patch.patch] or patch.treeVersion ~= expectedPatches[patch.patch]
			or type(patch.pobTag) ~= "string" or not patch.pobTag:match("^v%d+%.%d+%.%d+$")
			or type(patch.sourceRef) ~= "string" or type(patch.sourceLabel) ~= "string"
			or type(patch.commit) ~= "string" or #patch.commit ~= 40 or not patch.commit:match("^%x+$")
			or type(patch.catalogFingerprint) ~= "string" or #patch.catalogFingerprint ~= 64 or not patch.catalogFingerprint:match("^%x+$")
			or type(patch.sourceHashes) ~= "table" or type(patch.sourceHashes.gems) ~= "string" or #patch.sourceHashes.gems ~= 64
			or not patch.sourceHashes.gems:match("^%x+$")
			or type(patch.sourceHashes.tree) ~= "string" or #patch.sourceHashes.tree ~= 64 or not patch.sourceHashes.tree:match("^%x+$")
			or catalog.schemaVersion >= 3 and (type(patch.sourceHashes.skills) ~= "string" or #patch.sourceHashes.skills ~= 64
				or not patch.sourceHashes.skills:match("^%x+$") or type(patch.sourceHashes.data) ~= "string"
				or #patch.sourceHashes.data ~= 64 or not patch.sourceHashes.data:match("^%x+$"))
			or catalog.schemaVersion >= 4 and type(patch.bloodlineNodeIds) ~= "table"
			or type(patch.skills) ~= "table" or type(patch.standardAscendancies) ~= "table"
			or type(patch.excludedAlternateAscendancies) ~= "table"
			or type(patch.excludedLeagueSpecificAscendancies) ~= "table" then
			return nil, "catalog_patch_invalid"
		end
		local skillByKey, categoryCounts = { }, { normal = 0, transfigured = 0, vaal = 0, other = 0, support_granted_effect = 0 }
		for _, skill in ipairs(patch.skills) do
			if type(skill) ~= "table" or type(skill.gameId) ~= "string" or type(skill.variantId) ~= "string"
				or type(skill.category) ~= "string" or categoryCounts[skill.category] == nil then return nil, "catalog_skill_invalid" end
			if catalog.schemaVersion == 5 then
				if type(skill.gemId) ~= "string" or type(skill.name) ~= "string" or type(skill.baseName) ~= "string"
					or type(skill.grantedEffectId) ~= "string" or type(skill.secondaryGrantedEffectId) ~= "string"
					or type(skill.tags) ~= "table" or skill.origin ~= nil and type(skill.origin) ~= "string" then
					return nil, "catalog_skill_invalid"
				end
				local tagCount, tagMaxIndex, tagSet = 0, 0, { }
				for tagIndex, tag in pairs(skill.tags) do
					if type(tagIndex) ~= "number" or tagIndex < 1 or tagIndex ~= math.floor(tagIndex)
						or type(tag) ~= "string" or tagSet[tag] then return nil, "catalog_skill_invalid" end
					tagSet[tag] = true
					tagCount = tagCount + 1
					if tagIndex > tagMaxIndex then tagMaxIndex = tagIndex end
				end
				if tagCount ~= tagMaxIndex then return nil, "catalog_skill_invalid" end
			end
			local key = tostring(skill.variantKey or (skill.gameId .. "|" .. skill.variantId))
			if key ~= skill.gameId .. "|" .. skill.variantId or skillByKey[key] then return nil, "catalog_skill_identity_invalid" end
			skillByKey[key] = skill
			categoryCounts[skill.category] = categoryCounts[skill.category] + 1
		end
		local counts = patch.counts or { }
		local derivedVaalCount = 0
		for _, skill in ipairs(patch.skills) do
			if skill.origin == "native_vaal_alt_derivation" and skill.category == "vaal" then
				derivedVaalCount = derivedVaalCount + 1
			end
		end
		if counts.totalActiveGemRecords ~= #patch.skills or counts.normal ~= categoryCounts.normal
			or counts.transfigured ~= categoryCounts.transfigured or counts.vaal ~= categoryCounts.vaal
			or counts.other ~= categoryCounts.other or counts.standardAscendancies ~= #patch.standardAscendancies
			or catalog.schemaVersion >= 2 and counts.supportGrantedEffects ~= categoryCounts.support_granted_effect
			or catalog.schemaVersion >= 3 and (counts.vaalAlternateVariants ~= derivedVaalCount
				or derivedVaalCount > categoryCounts.vaal)
			or catalog.schemaVersion == 5 and (counts.support_granted_effect ~= categoryCounts.support_granted_effect
				or counts.excludedAlternateAscendancies ~= #patch.excludedAlternateAscendancies
				or counts.excludedLeagueSpecificAscendancies ~= #patch.excludedLeagueSpecificAscendancies) then
			return nil, "catalog_counts_invalid"
		end
		local bloodlineNodeIdSet = { }
		if catalog.schemaVersion >= 4 then
			local bloodlineArrayCount, bloodlineMaxIndex = 0, 0
			for key in pairs(patch.bloodlineNodeIds) do
				if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "catalog_bloodline_nodes_invalid" end
				bloodlineArrayCount = bloodlineArrayCount + 1
				if key > bloodlineMaxIndex then bloodlineMaxIndex = key end
			end
			if bloodlineArrayCount ~= bloodlineMaxIndex then return nil, "catalog_bloodline_nodes_invalid" end
			local previousId = 0
			for index = 1, bloodlineArrayCount do
				local rawId = patch.bloodlineNodeIds[index]
				local id = tonumber(rawId)
				if not isFinite(id) or id <= previousId or id ~= math.floor(id) or id > 2147483647 then
					return nil, "catalog_bloodline_nodes_invalid"
				end
				bloodlineNodeIdSet[id] = true
				previousId = id
			end
			if catalog.schemaVersion == 4 then
				local fingerprint = sha.sha256(table.concat({ patch.patch, patch.pobTag, patch.sourceRef,
					patch.sourceLabel, patch.commit, patch.sourceHashes.gems, patch.sourceHashes.tree,
					tostring(#patch.skills), tostring(#patch.standardAscendancies),
					tostring(#patch.excludedAlternateAscendancies), tostring(#patch.excludedLeagueSpecificAscendancies),
					table.concat(patch.bloodlineNodeIds, ",") }, "\0"))
				if fingerprint ~= patch.catalogFingerprint:lower() then return nil, "catalog_fingerprint_mismatch" end
			end
		end
		local seenStandardAscendancies, standardAscendancyByNumericId = { }, { }
		for _, ascendancy in ipairs(patch.standardAscendancies) do
			local expectedClassId = type(ascendancy) == "table" and STANDARD_ASCENDANCY_CLASS_IDS[ascendancy.id]
			if not expectedClassId or tonumber(ascendancy.classId) ~= expectedClassId or not ascendancy.className
				or seenStandardAscendancies[ascendancy.id] then return nil, "catalog_standard_ascendancy_invalid" end
			if catalog.schemaVersion == 5 then
				local allowedNames = STANDARD_ASCENDANCY_DISPLAY_NAMES[ascendancy.id]
				local displayNameValid = allowedNames and allowedNames[ascendancy.name]
					or not allowedNames and ascendancy.name == ascendancy.id
				local numericId = tonumber(ascendancy.ascendClassId)
				if not displayNameValid or tostring(ascendancy.className) ~= STANDARD_ASCENDANCY_CLASS_NAMES[expectedClassId]
					or not isFinite(numericId) or numericId ~= STANDARD_ASCENDANCY_CLASS_INDICES[ascendancy.id] then
					return nil, "catalog_standard_ascendancy_invalid"
				end
				local numericKey = tostring(expectedClassId) .. ":" .. tostring(numericId)
				if standardAscendancyByNumericId[numericKey] then return nil, "catalog_standard_ascendancy_invalid" end
				standardAscendancyByNumericId[numericKey] = ascendancy
			end
			seenStandardAscendancies[ascendancy.id] = true
		end
		local standardAscendancyCount = 0
		for id in pairs(STANDARD_ASCENDANCY_CLASS_IDS) do
			standardAscendancyCount = standardAscendancyCount + 1
			if not seenStandardAscendancies[id] then return nil, "catalog_standard_ascendancy_invalid" end
		end
		if standardAscendancyCount ~= 19 or #patch.standardAscendancies ~= standardAscendancyCount then
			return nil, "catalog_standard_ascendancy_invalid"
		end
		if catalog.schemaVersion == 5 then
			local fingerprint = PatchSkillCatalogFingerprint.Compute(patch)
			if fingerprint ~= patch.catalogFingerprint:lower() then return nil, "catalog_fingerprint_mismatch" end
		end
		byPatch[patch.patch] = { metadata = patch, skills = skillByKey, bloodlineNodeIdSet = bloodlineNodeIdSet,
			standardAscendancyByNumericId = standardAscendancyByNumericId,
			hasBloodlineNodeCatalog = catalog.schemaVersion == 5 }
	end
	for patch in pairs(expectedPatches) do if not byPatch[patch] then return nil, "catalog_patch_missing" end end
	return { raw = catalog, byPatch = byPatch }
end

local function standardAscendancyClassMatch(patchCatalog, character, expectedClassId)
	if type(patchCatalog) ~= "table" or type(character) ~= "table"
		or type(patchCatalog.standardAscendancyByNumericId) ~= "table" then return false end
	local classId, ascendancyClassId = tonumber(character.classId), tonumber(character.ascendancyId)
	if not classId or not ascendancyClassId or expectedClassId and classId ~= tonumber(expectedClassId) then return false end
	local row = patchCatalog.standardAscendancyByNumericId[tostring(classId) .. ":" .. tostring(ascendancyClassId)]
	if not row then return false end
	local ascendancyName = tostring(character.ascendancy or ""):lower()
	if ascendancyName == "" or ascendancyName == "none" or ascendancyName == "unascended" then return false end
	return ascendancyName == tostring(row.id or ""):lower() or ascendancyName == tostring(row.name or ""):lower()
end

local function standardAscendancyMatch(patchCatalog, character, activeSpec)
	if type(activeSpec) ~= "table" then return false end
	local classId, ascendancyClassId = tonumber(character and character.classId), tonumber(character and character.ascendancyId)
	if not classId or not ascendancyClassId or tonumber(activeSpec.classId) ~= classId
		or tonumber(activeSpec.ascendancyId) ~= ascendancyClassId then return false end
	return standardAscendancyClassMatch(patchCatalog, character, classId)
end

local function validNodeIdList(values)
	if type(values) ~= "table" then return nil end
	local result, seen = { }, { }
	for _, rawId in ipairs(values) do
		local id = tonumber(rawId)
		if not isFinite(id) or id <= 0 or id ~= math.floor(id) or id > 2147483647 or seen[id] then return nil end
		seen[id] = true
		result[#result + 1] = id
	end
	table.sort(result)
	return result
end

local function nodeIdListsEqual(left, right)
	if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
	for index = 1, #left do if left[index] ~= right[index] then return false end end
	return true
end

local function parseActiveSpecFromXml(payload)
	if type(payload) ~= "string" or #payload == 0 or #payload > MAX_BUILD_BYTES then return nil, "active_spec_xml_size_invalid" end
	local ok, document, parseError = pcall(xml.ParseXML, payload)
	if not ok or type(document) ~= "table" or type(document[1]) ~= "table"
		or document[1].elem ~= "PathOfBuilding" then return nil, "active_spec_xml_invalid" end
	local latestTreeSection
	for _, node in ipairs(document[1]) do
		-- PoB defers Tree and legacy Spec sections, then loads them in their
		-- original order. Every TreeTab:Load replaces the previous spec list.
		if type(node) == "table" and (node.elem == "Tree" or node.elem == "Spec") then
			latestTreeSection = node
		end
	end
	local specs, activeIndex = { }, 1
	if latestTreeSection and latestTreeSection.elem == "Tree" then
		local rawIndex = latestTreeSection.attrib and latestTreeSection.attrib.activeSpec
		if rawIndex ~= nil then
			activeIndex = tonumber(rawIndex)
			if not isFinite(activeIndex) or activeIndex < 1 or activeIndex ~= math.floor(activeIndex) then
				return nil, "active_spec_index_invalid"
			end
		end
		for _, node in ipairs(latestTreeSection) do
			if type(node) == "table" and node.elem == "Spec" then specs[#specs + 1] = node end
		end
	elseif latestTreeSection and latestTreeSection.elem == "Spec" then
		specs = { latestTreeSection }
	end
	if activeIndex < 1 or activeIndex ~= math.floor(activeIndex) or activeIndex > #specs then return nil, "active_spec_missing" end
	local attributes = type(specs[activeIndex].attrib) == "table" and specs[activeIndex].attrib or { }
	local secondaryAscendancyId = 0
	local rawSecondaryAscendancyId = attributes.secondaryAscendClassId
	if rawSecondaryAscendancyId ~= nil and rawSecondaryAscendancyId ~= "" and tostring(rawSecondaryAscendancyId):lower() ~= "nil" then
		secondaryAscendancyId = tonumber(rawSecondaryAscendancyId)
		if not isFinite(secondaryAscendancyId) or secondaryAscendancyId < 0
			or secondaryAscendancyId ~= math.floor(secondaryAscendancyId) then
			return nil, "active_spec_secondary_ascendancy_invalid"
		end
	end
	local nodeIds, seen = { }, { }
	for rawId in tostring(attributes.nodes or ""):gmatch("[^,]+") do
		local id = tonumber(rawId)
		if not isFinite(id) or id <= 0 or id ~= math.floor(id) or id > 2147483647 or seen[id] then
			return nil, "active_spec_node_list_invalid"
		end
		seen[id] = true
		nodeIds[#nodeIds + 1] = id
	end
	table.sort(nodeIds)
	return {
		index = activeIndex,
		treeVersion = cleanText(attributes.treeVersion or "", 24),
		classId = tonumber(attributes.classId),
		ascendancyId = tonumber(attributes.ascendClassId),
		secondaryAscendancyId = secondaryAscendancyId,
		allocatedNodeIds = nodeIds,
	}
end

local function archivedActiveSpec(paths, row)
	if type(row) ~= "table" or not isFingerprint(row.xmlSha256) then return nil, "active_spec_xml_hash_invalid" end
	local object = type(row.object) == "string" and row.object or ""
	if object == "" then return nil, "active_spec_object_missing" end
	local xmlSha256 = row.xmlSha256:lower()
	local expectedObject = "objects/" .. xmlSha256:sub(1, 2) .. "/" .. xmlSha256 .. ".xml"
	if object ~= expectedObject then return nil, "active_spec_object_path_invalid" end
	local relativePath = object:gsub("/", function() return separator() end)
	local objectPath = joinPath(paths.root, relativePath, separator())
	local file = io.open(objectPath, "rb")
	if not file then return nil, "active_spec_object_missing" end
	local size = file:seek("end") or 0
	if size <= 0 or size > MAX_BUILD_BYTES then file:close(); return nil, "active_spec_object_size_invalid" end
	file:seek("set", 0)
	local payload = file:read("*a")
	file:close()
	if type(payload) ~= "string" or sha.sha256(payload) ~= xmlSha256 then return nil, "active_spec_object_hash_mismatch" end
	return parseActiveSpecFromXml(payload)
end

local function profileActiveSpec(profile, patchCatalog, xmlEvidence)
	local profileSpec = type(profile.activeSpec) == "table" and profile.activeSpec or nil
	local spec = xmlEvidence or profileSpec
	if not spec then return nil, "active_spec_not_verified" end
	local engine = type(profile.engine) == "table" and profile.engine or { }
	local character = type(profile.character) == "table" and profile.character or { }
	local secondaryId = tonumber(spec.secondaryAscendancyId)
	local rawCharacterSecondaryId = character.secondaryAscendancyId
	local characterSecondaryId = tonumber(rawCharacterSecondaryId)
	if secondaryId == nil then return nil, "secondary_ascendancy_unverified" end
	if rawCharacterSecondaryId ~= nil and (not isFinite(characterSecondaryId) or characterSecondaryId < 0
		or characterSecondaryId ~= math.floor(characterSecondaryId)) then
		return nil, "secondary_ascendancy_invalid"
	end
	-- Historical archive profiles predate the secondary-ascendancy field. When
	-- the exact content-addressed PoB XML is available, its selected Spec is the
	-- authority for this value; an optional profile value remains a consistency
	-- check. Profile-only observations still need the field explicitly.
	if characterSecondaryId == nil and not xmlEvidence then return nil, "secondary_ascendancy_unverified" end
	if tostring(spec.treeVersion or "") == "" or tostring(spec.treeVersion) ~= tostring(engine.treeVersion or "")
		or tonumber(spec.classId) == nil or tonumber(spec.ascendancyId) == nil
		or tonumber(spec.classId) ~= tonumber(character.classId)
		or tonumber(spec.ascendancyId) ~= tonumber(character.ascendancyId)
		or characterSecondaryId ~= nil and characterSecondaryId ~= secondaryId then
		return nil, "active_spec_profile_mismatch"
	end
	local profileNodes = validNodeIdList(profile.allocatedNodeIds)
	local specNodes = validNodeIdList(spec.allocatedNodeIds)
	if not profileNodes or not specNodes or not nodeIdListsEqual(profileNodes, specNodes) then
		return nil, "active_spec_profile_mismatch"
	end
	if profileSpec and xmlEvidence then
		local cachedNodes = validNodeIdList(profileSpec.allocatedNodeIds or profile.allocatedNodeIds)
		if tonumber(profileSpec.classId) ~= tonumber(xmlEvidence.classId)
			or tonumber(profileSpec.ascendancyId) ~= tonumber(xmlEvidence.ascendancyId)
			or tonumber(profileSpec.secondaryAscendancyId or 0) ~= tonumber(xmlEvidence.secondaryAscendancyId or 0)
			or profileSpec.index ~= nil and tonumber(profileSpec.index) ~= tonumber(xmlEvidence.index)
			or tostring(profileSpec.treeVersion or "") ~= tostring(xmlEvidence.treeVersion or "")
			or not cachedNodes or not nodeIdListsEqual(cachedNodes, xmlEvidence.allocatedNodeIds) then
			return nil, "active_spec_profile_mismatch"
		end
	end
	if secondaryId ~= 0 then return nil, "event_secondary_ascendancy" end
	if not patchCatalog or patchCatalog.hasBloodlineNodeCatalog ~= true then return nil, "bloodline_catalog_unavailable" end
	local bloodlineNodeIds = { }
	for _, nodeId in ipairs(specNodes) do
		if patchCatalog.bloodlineNodeIdSet[nodeId] then bloodlineNodeIds[#bloodlineNodeIds + 1] = nodeId end
	end
	if #bloodlineNodeIds > 0 then return nil, "event_bloodline_node_allocated" end
	return { spec = spec, allocatedBloodlineNodeIds = bloodlineNodeIds }
end

function builds.ValidateTargetBuild(userPath, profile, sourceXmlText)
	if type(profile) ~= "table" then return nil, "profile_invalid" end
	local engine = type(profile.engine) == "table" and profile.engine or { }
	local patch = patchFromTreeVersion(tostring(engine.treeVersion or ""))
	if not patch then return nil, "tree_not_in_3_24_to_3_29" end
	local paths, pathError = builds.GetPaths(userPath)
	if not paths then return nil, pathError end
	local catalog, catalogError = loadPatchSkillCatalog(paths.patchSkillCatalog)
	if not catalog then return nil, catalogError end
	local patchCatalog = catalog.byPatch[patch]
	if not patchCatalog then return nil, "patch_catalog_missing" end
	local activeSpec, activeSpecError = profileActiveSpec(profile, patchCatalog, nil)
	if not activeSpec then return nil, activeSpecError end
	if not standardAscendancyMatch(patchCatalog, profile.character or { }, activeSpec.spec) then
		return nil, "nonstandard_or_missing_ascendancy"
	end
	local mainSkill = profileMainSkill(profile)
	if not mainSkill then return nil, "main_skill_not_identifiable" end
	local skillKey = tostring(mainSkill.gameId or "") .. "|" .. tostring(mainSkill.variantId or "")
	local skill = patchCatalog.skills[skillKey]
	if not skill then return nil, "skill_not_in_patch_catalog" end
	local category = catalogSkillCategory(skill)
	if category == "support_granted_effect" then return nil, "support_granted_effect_not_independent_target" end
	if category ~= "normal" and category ~= "transfigured" then
		return nil, "skill_category_out_of_scope"
	end
	local sourceSkillId = sourcePatchSkillIdFromXml(sourceXmlText, profile, mainSkill)
	if sourceXmlText ~= nil and not sourceSkillId then return nil, "source_skill_identity_unverified" end
	if not catalogSkillMatchesMainSkillEffect(skill, mainSkill, sourceSkillId) then return nil, "skill_effect_catalog_mismatch" end
	local character = profile.character or { }
	return {
		patch = patch,
		treeVersion = tostring(engine.treeVersion or ""),
		mainSkillKey = skillKey,
		mainSkillName = skill.name,
		sourcePatchSkillId = sourceSkillId,
		category = category,
		classId = tonumber(character.classId),
		className = character.class,
		ascendancyId = character.ascendancyId,
		ascendancy = character.ascendancy,
	}
end

local OUT_OF_TARGET_SCOPE_REASONS = {
	tree_not_in_3_24_to_3_29 = true,
	event_secondary_ascendancy = true,
	event_bloodline_node_allocated = true,
	skill_category_out_of_scope = true,
	support_granted_effect_not_independent_target = true,
}

-- Target scope is an optimizer filter, not an import/archive validity gate.
-- Unknown skill/catalog evidence remains unclassified so new PoE 1 skills can
-- still be archived and counted without claiming that the planner supports them.
function builds.ClassifyTargetScope(userPath, profile, sourceXmlText)
	local eligibility, reason = builds.ValidateTargetBuild(userPath, profile, sourceXmlText)
	if eligibility then return { status = "in_scope", eligibility = eligibility } end
	reason = cleanText(tostring(reason or "target_scope_unclassified"), 96) or "target_scope_unclassified"
	return {
		status = OUT_OF_TARGET_SCOPE_REASONS[reason] and "out_of_target_scope" or "unclassified",
		reason = reason,
	}
end

local function emptyPatchCoverage(catalog)
	local result = { }
	for _, patchRow in ipairs(catalog and catalog.patches or { }) do
		local row = {
			patch = patchRow.patch, pobTag = patchRow.pobTag, sourceRef = patchRow.sourceRef,
			sourceLabel = patchRow.sourceLabel, commit = patchRow.commit,
			treeVersion = patchRow.treeVersion, catalogFingerprint = patchRow.catalogFingerprint,
			standardAscendancies = patchRow.counts and patchRow.counts.standardAscendancies or #patchRow.standardAscendancies,
			excludedAlternateAscendancies = patchRow.excludedAlternateAscendancies or { },
			excludedLeagueSpecificAscendancies = patchRow.excludedLeagueSpecificAscendancies or { },
			counts = { targetSkills = 0, targetBuildLineages = 0, skillsWithBuilds = 0, skillsAtTarget = 0,
				normalSkills = 0, transfiguredSkills = 0, vaalSkills = 0, vaalBuildLineages = 0,
				supportGrantedEffects = 0, eligibleBuildLineages = 0 },
			skills = { },
		}
		for _, skill in ipairs(patchRow.skills or { }) do
			local category = catalogSkillCategory(skill)
			if category == "support_granted_effect" then
				row.counts.supportGrantedEffects = (row.counts.supportGrantedEffects or 0) + 1
			elseif category == "normal" or category == "transfigured" then
				row.counts.targetSkills = row.counts.targetSkills + 1
				row.counts[category == "normal" and "normalSkills" or "transfiguredSkills"]
					= row.counts[category == "normal" and "normalSkills" or "transfiguredSkills"] + 1
				row.skills[#row.skills + 1] = {
					variantKey = skill.variantKey or (skill.gameId .. "|" .. skill.variantId),
					gemId = skill.gemId, gameId = skill.gameId, variantId = skill.variantId,
					name = skill.name, category = category, effectId = skill.grantedEffectId,
					tags = skill.tags or { }, uniqueBuilds = 0, sampleTarget = TARGET_BUILDS_PER_EFFECT,
					remainingToTarget = TARGET_BUILDS_PER_EFFECT, targetReached = false,
				}
			elseif category == "vaal" then
				row.counts.vaalSkills = row.counts.vaalSkills + 1
			end
		end
		table.sort(row.skills, function(left, right)
			if left.uniqueBuilds ~= right.uniqueBuilds then return left.uniqueBuilds < right.uniqueBuilds end
			if left.category ~= right.category then return left.category < right.category end
			if tostring(left.name or ""):lower() ~= tostring(right.name or ""):lower() then
				return tostring(left.name or ""):lower() < tostring(right.name or ""):lower()
			end
			return left.variantKey < right.variantKey
		end)
		result[#result + 1] = row
	end
	table.sort(result, function(left, right) return left.patch < right.patch end)
	return result
end

local function emptyNodeEvidence(status, reason, gemId, snapshot)
	return {
		schema = "pob-ai-planner-imported-node-evidence",
		schemaVersion = 1,
		status = status,
		reason = reason,
		selectedSkillGemId = gemId,
		engine = snapshot,
		compatibleBuildCount = 0,
		distinctBuildLineages = 0,
		nodes = { },
		edges = { },
		nodeCounts = { },
		priorities = { },
		edgePriorities = { },
		routePatterns = { },
		routePatternCount = 0,
		causal = false,
		readOnly = true,
	}
end

local function sameEvidenceEngine(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	-- Imported archives contribute passive-node IDs only, never calculated
	-- metrics. Require the exact PoE data and tree patch; a different PoB binary,
	-- branch, or source manifest does not invalidate a structural tree pattern.
	for _, key in ipairs({ "dataVersion", "treeVersion" }) do
		if type(right[key]) ~= "string" or right[key] == "" or tostring(left[key] or "") ~= right[key] then return false end
	end
	local currentPatch = patchFromTreeVersion(tostring(right.treeVersion or ""))
	return currentPatch ~= nil and patchFromTreeVersion(tostring(left.treeVersion or "")) == currentPatch
end

isFingerprint = function(value)
	return type(value) == "string" and #value == 64 and value:match("^%x+$") ~= nil
end

-- Return the exact build lineages that have a durable archived observation.
-- Review journals use this to avoid counting a recalculated, non-canonical
-- import as a second build when PoB serialization normalizes the build state.
function builds.ArchivedLineages(userPath)
	local paths, pathError = builds.GetPaths(userPath)
	if not paths then return nil, pathError end
	local file, openError = io.open(paths.index, "rb")
	if not file then
		if missingFile(openError) then return { } end
		return nil, "Could not read the build archive index: " .. tostring(openError):sub(1, 200)
	end
	local lineages, lineNumber = { }, 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if lineNumber > MAX_ARCHIVE_LINEAGE_SCAN_ROWS then
			file:close()
			return nil, "Build archive lineage scan exceeds its row safety limit"
		end
		if #line > MAX_INDEX_LINE_BYTES then
			file:close()
			return nil, "Build archive index row exceeds the 256 KiB safety limit at line " .. lineNumber
		end
		if line ~= "" then
			local ok, row = pcall(json.decode, line)
			if not ok or type(row) ~= "table" or row.recordType ~= "build_archive_observation"
				or row.schemaVersion ~= 1 or not isFingerprint(row.lineageSha256)
				or not isFingerprint(row.xmlSha256) or type(row.profile) ~= "table"
				or row.profile.schema ~= "pob-ai-planner-build-profile" or row.profile.schemaVersion ~= 1 then
				file:close()
				return nil, "Build archive index contains an invalid record at line " .. lineNumber
			end
			lineages[row.lineageSha256:lower()] = true
		end
	end
	file:close()
	return lineages
end

-- Resolve a reviewed snapshot to the exact immutable archive observation that
-- supplied it. A source reference may identify more than one revision, so the
-- resolver refuses ambiguous references instead of attaching a review to the
-- wrong saved build. The content-addressed XML is verified before its profile
-- can be used by the paired reviewers.
function builds.FindArchivedObservationByReference(userPath, reference)
	if type(reference) ~= "string" or reference == "" or #reference > 1024 or reference:find("[%c]") then
		return nil, "A valid archived build source reference is required"
	end
	local paths, pathError = builds.GetPaths(userPath)
	if not paths then return nil, pathError end
	local file, openError = io.open(paths.index, "rb")
	if not file then
		if missingFile(openError) then return nil, "No archived build matches this source reference", "source_reference_not_archived" end
		return nil, "Could not read the build archive index: " .. tostring(openError):sub(1, 200)
	end
	local matches, lineNumber = { }, 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if lineNumber > MAX_ARCHIVE_LINEAGE_SCAN_ROWS then
			file:close()
			return nil, "Build archive lookup exceeds its row safety limit"
		end
		if #line > MAX_INDEX_LINE_BYTES then
			file:close()
			return nil, "Build archive index row exceeds the 256 KiB safety limit at line " .. lineNumber
		end
		if line ~= "" then
			local ok, row = pcall(json.decode, line)
			if not ok or type(row) ~= "table" or row.recordType ~= "build_archive_observation"
				or row.schemaVersion ~= 1 or not isFingerprint(row.lineageSha256)
				or not isFingerprint(row.xmlSha256) or not isFingerprint(row.observationId)
				or type(row.profile) ~= "table" or row.profile.schema ~= "pob-ai-planner-build-profile"
				or row.profile.schemaVersion ~= 1 or type(row.source) ~= "table" then
				file:close()
				return nil, "Build archive index contains an invalid record at line " .. lineNumber
			end
			if row.source.reference == reference then matches[#matches + 1] = row end
		end
	end
	file:close()
	if #matches == 0 then return nil, "No archived build matches this source reference", "source_reference_not_archived" end
	local row, contentIdentity
	for _, candidate in ipairs(matches) do
		local identity = candidate.xmlSha256 .. "\0" .. candidate.lineageSha256
		if contentIdentity and identity ~= contentIdentity then
			return nil, "Source reference resolves to multiple archived snapshots; exact snapshot selection is required"
		end
		contentIdentity = identity
		if not row or (tonumber(candidate.observedAt) or 0) > (tonumber(row.observedAt) or 0) then row = candidate end
	end
	local shard = row.xmlSha256:sub(1, 2)
	local objectPath = joinPath(joinPath(paths.objects, shard, separator()), row.xmlSha256 .. ".xml", separator())
	local object, objectError = io.open(objectPath, "rb")
	if not object then return nil, "Archived PoB XML is missing: " .. tostring(objectError):sub(1, 160) end
	local size = object:seek("end") or 0
	object:seek("set", 0)
	local payload = size > 0 and size <= MAX_BUILD_BYTES and object:read("*a") or nil
	object:close()
	if type(payload) ~= "string" or sha.sha256(payload) ~= row.xmlSha256 then
		return nil, "Archived PoB XML failed its content hash check"
	end
	return row
end

-- Resolve an already archived source revision by its public reference and
-- verified raw PoB-code hash. Source references can be edited over time, so
-- the hash is required before an import can be treated as idempotent.
function builds.FindArchivedObservationBySourceCode(userPath, reference, codeSha256)
	if type(reference) ~= "string" or reference == "" or #reference > 1024 or reference:find("[%c]")
		or not isFingerprint(codeSha256) then
		return nil, "A valid source reference and PoB-code SHA-256 are required"
	end
	local paths, pathError = builds.GetPaths(userPath)
	if not paths then return nil, pathError end
	local file, openError = io.open(paths.index, "rb")
	if not file then
		if missingFile(openError) then return nil, "source_code_not_archived" end
		return nil, "Could not read the build archive index: " .. tostring(openError):sub(1, 200)
	end
	local lineNumber = 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if lineNumber > MAX_ARCHIVE_LINEAGE_SCAN_ROWS then
			file:close()
			return nil, "Build archive source-code lookup exceeds its row safety limit"
		end
		if #line > MAX_INDEX_LINE_BYTES then
			file:close()
			return nil, "Build archive index row exceeds the 256 KiB safety limit at line " .. lineNumber
		end
		if line ~= "" then
			local ok, row = pcall(json.decode, line)
			if not ok or type(row) ~= "table" or row.recordType ~= "build_archive_observation"
				or row.schemaVersion ~= 1 or not isFingerprint(row.lineageSha256)
				or not isFingerprint(row.xmlSha256) or type(row.source) ~= "table" or type(row.profile) ~= "table" then
				file:close()
				return nil, "Build archive index contains an invalid record at line " .. lineNumber
			end
			local source = row.source
			if source.reference == reference and type(source.codeSha256) == "string"
				and source.codeSha256:lower() == codeSha256:lower() then
				local codePath = source.codePath
				if type(codePath) ~= "string" or not codePath:match("^source%-codes/")
					or codePath:find("\\", 1, true) or codePath:find(":", 1, true) or codePath:find("[%c]") then
					file:close()
					return nil, "Archived source-code path is invalid"
				end
				for segment in codePath:gmatch("[^/]+") do
					if segment == ".." or segment == "." then
						file:close()
						return nil, "Archived source-code path is invalid"
					end
				end
				local relativePath = codePath:gsub("/", function() return separator() end)
				local codeFile, codeError = io.open(joinPath(paths.root, relativePath, separator()), "rb")
				if not codeFile then
					file:close()
					return nil, "Archived PoB source code is missing: " .. tostring(codeError):sub(1, 160)
				end
				local codeText = codeFile:read(MAX_BUILD_BYTES + 1)
				codeFile:close()
				if type(codeText) ~= "string" or #codeText > MAX_BUILD_BYTES or sha.sha256(codeText) ~= codeSha256:lower() then
					file:close()
					return nil, "Archived PoB source code failed its SHA-256 check"
				end
				file:close()
				return row
			end
		end
	end
	file:close()
	return nil, "source_code_not_archived"
end

local function mainPassiveNode(node)
	return type(node) == "table" and not node.ascendancyName and node.type ~= "AscendClassStart"
		and not node.isMultipleChoiceOption
end

-- Imported builds provide exact-compatible passive-tree patterns and a
-- structural prior for Node Potential. Counts are descriptive usage patterns,
-- never mechanical labels or proof of synergy. The caller may turn a bounded
-- pattern into a local proposal, but PoB must still validate and calculate it.
function builds.NodeEvidence(userPath, build, gemId, effectIds, maxOutputNodes, requestedClassId, archiveRoot, skillScope)
	local cleanGemId = cleanText(gemId, 160)
	skillScope = skillScope == "class_tree" and "class_tree" or "selected_skill"
	local snapshot = Version.Snapshot(build)
	if not cleanGemId then return emptyNodeEvidence("unavailable", "selected_skill_gem_missing", nil, snapshot) end
	local paths, pathError = builds.GetPaths(archiveRoot or userPath)
	if not paths then return emptyNodeEvidence("unavailable", pathError, cleanGemId, snapshot) end
	local tree = build and build.spec and build.spec.tree
	local classId = tonumber(requestedClassId) or tonumber(build and build.spec and build.spec.curClassId)
	local nativeNodes = tree and tree.nodes
	local nativeClass = tree and tree.classes and (tree.classes[classId] or tree.classes[tostring(classId)])
	if not classId or not nativeClass or type(nativeNodes) ~= "table" then
		return emptyNodeEvidence("unavailable", "current_class_or_native_tree_missing", cleanGemId, snapshot)
	end
	if type(snapshot.dataVersion) ~= "string" or snapshot.dataVersion == ""
		or type(snapshot.treeVersion) ~= "string" or snapshot.treeVersion == ""
		or type(snapshot.pobVersion) ~= "string" or snapshot.pobVersion == ""
		or type(snapshot.manifestFingerprint) ~= "string" or snapshot.manifestFingerprint == "" then
		return emptyNodeEvidence("unavailable", "current_engine_fingerprint_unverified", cleanGemId, snapshot)
	end
	local requestedEffects = { }
	if type(effectIds) == "table" then
		for index = 1, math.min(#effectIds, 64) do
			local effectId = cleanText(effectIds[index], 180)
			if effectId then requestedEffects[effectId] = true end
		end
	end
	if next(requestedEffects) == nil then
		return emptyNodeEvidence("unavailable", "selected_skill_effect_missing", cleanGemId, snapshot)
	end
	local file, openError = io.open(paths.index, "rb")
	if not file then
		if missingFile(openError) then return emptyNodeEvidence("no_archive", "no_imported_build_archive", cleanGemId, snapshot) end
		return emptyNodeEvidence("unavailable", "archive_index_unreadable", cleanGemId, snapshot)
	end
	local patchSkillCatalog, patchCatalogError = loadPatchSkillCatalog(paths.patchSkillCatalog)
	local treePatch = patchFromTreeVersion(tostring(snapshot.treeVersion or ""))
	local currentPatch = patchSkillCatalog and treePatch and patchSkillCatalog.byPatch[treePatch]
	if not currentPatch then
		file:close()
		return emptyNodeEvidence("unavailable", patchCatalogError or "patch_bloodline_catalog_unavailable", cleanGemId, snapshot)
	end
	local lineageSeen, nodeCounts, edgeCounts, routePatternsByKey = { }, { }, { }, { }
	local activePassiveSet, activePassiveCount = { }, 0
	for rawId, node in pairs(build and build.spec and build.spec.allocNodes or { }) do
		local nodeId = tonumber(rawId)
		if nodeId and mainPassiveNode(node) and node.type ~= "ClassStart" and node.type ~= "Mastery" and node.type ~= "Socket" then
			activePassiveSet[nodeId] = true
			activePassiveCount = activePassiveCount + 1
		end
	end
	local activeSpecEvidenceByObject = { }
	local compatibleBuildCount, scannedRows, scannedBytes, malformedRows = 0, 0, 0, 0
	local truncated = false
	for line in file:lines() do
		scannedRows = scannedRows + 1
		scannedBytes = scannedBytes + #line + 1
		if scannedRows > MAX_NODE_EVIDENCE_ROWS or scannedBytes > MAX_NODE_EVIDENCE_BYTES then
			truncated = true
			break
		end
		if #line > MAX_INDEX_LINE_BYTES then
			malformedRows = malformedRows + 1
		else
			local decoded, row = pcall(json.decode, line)
			if decoded and type(row) == "table" and row.recordType == "build_archive_observation"
				and row.schemaVersion == 1 and isFingerprint(row.lineageSha256) and isFingerprint(row.xmlSha256)
				and type(row.profile) == "table" and row.profile.schema == "pob-ai-planner-build-profile"
				and row.profile.schemaVersion == 1 then
				local profile = row.profile
				local character, engine = profile.character or { }, profile.engine or { }
				local matchingBuild = false
				if tonumber(character.classId) == classId and sameEvidenceEngine(engine, snapshot) then
					local mainSkill = profileMainSkill(profile)
					local mainSkillKey = mainSkill and (tostring(mainSkill.gameId or "") .. "|" .. tostring(mainSkill.variantId or ""))
					local catalogSkill = mainSkillKey and currentPatch.skills[mainSkillKey]
					local catalogIdentityMatches = catalogSkillMatchesMainSkillEffect(catalogSkill, mainSkill)
					if not catalogIdentityMatches and mainSkill then
						local sourceSkillId = archivedSourcePatchSkillId(paths, row, mainSkill)
						catalogIdentityMatches = catalogSkillMatchesMainSkillEffect(catalogSkill, mainSkill, sourceSkillId)
					end
					local configuredMainSkill = false
					for _, effect in ipairs(type(profile.configuredSkillEffects) == "table" and profile.configuredSkillEffects or { }) do
						local configuredGemMatches = skillScope == "class_tree"
							or type(effect) == "table" and tostring(effect.gemId or "") == cleanGemId
						if type(effect) == "table" and configuredGemMatches
							and tostring(effect.effectId or "") == tostring(mainSkill and mainSkill.effectId or "")
							and tostring(effect.gameId or "") == tostring(mainSkill and mainSkill.gameId or "")
							and tostring(effect.variantId or "") == tostring(mainSkill and mainSkill.variantId or "") then
							configuredMainSkill = true
							break
						end
					end
					local category = catalogSkillCategory(catalogSkill)
					local nativeMainSkill = mainSkill and configuredMainSkill and catalogIdentityMatches
						and (category == "normal" or category == "transfigured" or category == "vaal")
					if skillScope == "class_tree" then
						-- A same-class, same-data/tree passive allocation can seed a local
						-- route even when its archived Main Skill or standard ascendancy
						-- differs. It contributes structure only; the current build's
						-- skill and exact PoB calculator remain authoritative.
						matchingBuild = nativeMainSkill == true
					elseif mainSkill and tostring(mainSkill.gemId or "") == cleanGemId
						and requestedEffects[tostring(mainSkill.effectId or "")] == true and nativeMainSkill then
						matchingBuild = true
					end
				end
				if matchingBuild then
					local activeSpecEvidence = activeSpecEvidenceByObject[row.xmlSha256]
					if activeSpecEvidence == nil then
						local verifiedEvidence = archivedActiveSpec(paths, row)
						if verifiedEvidence then
							activeSpecEvidence = verifiedEvidence
							activeSpecEvidenceByObject[row.xmlSha256] = verifiedEvidence
						else
							malformedRows = malformedRows + 1
						end
					end
					local strictIdentity = activeSpecEvidence and profileActiveSpec(profile, currentPatch, activeSpecEvidence)
					local ascendancyCompatible = skillScope == "class_tree"
						and standardAscendancyClassMatch(currentPatch, character, classId)
						or skillScope ~= "class_tree" and strictIdentity
							and standardAscendancyMatch(currentPatch, character, strictIdentity.spec)
					if not strictIdentity or not ascendancyCompatible then matchingBuild = false end
				end
				local lineage = row.lineageSha256:lower()
				if matchingBuild and not lineageSeen[lineage] then
					local allocated = profile.allocatedNodeIds
					if type(allocated) == "table" and #allocated <= 4096 then
						lineageSeen[lineage] = true
						compatibleBuildCount = compatibleBuildCount + 1
						local allocatedSet = { }
						for _, value in ipairs(allocated) do
							local nodeId = tonumber(value)
							local node = nodeId and nodeId > 0 and nodeId == math.floor(nodeId)
								and (nativeNodes[nodeId] or nativeNodes[tostring(nodeId)])
							if nodeId and mainPassiveNode(node) then
								allocatedSet[nodeId] = true
								if node.type ~= "ClassStart" then nodeCounts[nodeId] = (nodeCounts[nodeId] or 0) + 1 end
							end
						end
						local patternNodeIds = { }
						for nodeId in pairs(allocatedSet) do
							local node = nativeNodes[nodeId] or nativeNodes[tostring(nodeId)]
							if node and node.type ~= "ClassStart" and node.type ~= "Mastery" and node.type ~= "Socket" then
								patternNodeIds[#patternNodeIds + 1] = nodeId
							end
						end
					table.sort(patternNodeIds)
						if #patternNodeIds > 0 then
							local patternKeyParts = { }
							for _, nodeId in ipairs(patternNodeIds) do patternKeyParts[#patternKeyParts + 1] = tostring(nodeId) end
							local patternKey = table.concat(patternKeyParts, ",")
							local pattern = routePatternsByKey[patternKey]
							if not pattern then
								pattern = { nodeIds = patternNodeIds, supportCount = 0, key = patternKey }
								routePatternsByKey[patternKey] = pattern
							end
							pattern.supportCount = pattern.supportCount + 1
						end
						for nodeId in pairs(allocatedSet) do
							local node = nativeNodes[nodeId] or nativeNodes[tostring(nodeId)]
						for key, value in pairs(node.out or node.connections or { }) do
							local otherId = tonumber(value) or tonumber(key)
							if otherId and otherId > nodeId and allocatedSet[otherId] then
								local edgeKey = tostring(nodeId) .. ":" .. tostring(otherId)
								edgeCounts[edgeKey] = (edgeCounts[edgeKey] or 0) + 1
							end
						end
					end
					else
						malformedRows = malformedRows + 1
					end
				end
			elseif line ~= "" then
				malformedRows = malformedRows + 1
			end
		end
	end
	file:close()
	local nodeRows = { }
	for nodeId, supportCount in pairs(nodeCounts) do
		local node = nativeNodes[nodeId] or nativeNodes[tostring(nodeId)]
		nodeRows[#nodeRows + 1] = { nodeId = nodeId, name = cleanText(node.dn or node.name or "", 180) or "Passive node",
			supportCount = supportCount, sampleCount = compatibleBuildCount,
			supportRate = compatibleBuildCount > 0 and supportCount / compatibleBuildCount or 0 }
	end
	table.sort(nodeRows, function(left, right)
		if left.supportCount ~= right.supportCount then return left.supportCount > right.supportCount end
		return left.nodeId < right.nodeId
	end)
	local edgeRows = { }
	for key, supportCount in pairs(edgeCounts) do
		local left, right = key:match("^(%d+):(%d+)$")
		local leftId, rightId = tonumber(left), tonumber(right)
		if leftId and rightId then edgeRows[#edgeRows + 1] = { nodeA = leftId, nodeB = rightId,
			supportCount = supportCount, sampleCount = compatibleBuildCount,
			supportRate = compatibleBuildCount > 0 and supportCount / compatibleBuildCount or 0 } end
	end
	table.sort(edgeRows, function(left, right)
		if left.supportCount ~= right.supportCount then return left.supportCount > right.supportCount end
		if left.nodeA ~= right.nodeA then return left.nodeA < right.nodeA end
		return left.nodeB < right.nodeB
	end)
	local outputLimit = tonumber(maxOutputNodes) or MAX_NODE_EVIDENCE_OUTPUT_NODES
	if outputLimit ~= math.floor(outputLimit) or outputLimit < 1 or outputLimit > MAX_NODE_EVIDENCE_OUTPUT_NODES then
		outputLimit = MAX_NODE_EVIDENCE_OUTPUT_NODES
	end
	local nodeCountsById, priorities = { }, { }
	for index = 1, math.min(#nodeRows, outputLimit) do
		local row = nodeRows[index]
		nodeCountsById[row.nodeId] = { supportCount = row.supportCount, sampleCount = row.sampleCount, supportRate = row.supportRate }
		-- Require at least two distinct imported lineages before historical usage
		-- can nudge proposal order. Truncated scans never influence the solver.
		if compatibleBuildCount >= 2 and not truncated then priorities[row.nodeId] = row.supportRate end
	end
	while #nodeRows > outputLimit do table.remove(nodeRows) end
	while #edgeRows > MAX_NODE_EVIDENCE_OUTPUT_EDGES do table.remove(edgeRows) end
	local edgePriorities = { }
	-- Only complete scans with at least two distinct, exact-compatible build
	-- lineages can guide route tie breaks. An observed edge is a structural
	-- prior; missing edges are unknown, not negative evidence.
	if compatibleBuildCount >= 2 and not truncated then
		for _, row in ipairs(edgeRows) do
			if row.supportRate > 0 then edgePriorities[tostring(row.nodeA) .. ":" .. tostring(row.nodeB)] = row.supportRate end
		end
	end
	local routePatterns = { }
	-- Keep only complete scans backed by at least two independent exact-compatible
	-- lineages. Prefer trees near the active allocation so the solver can derive
	-- bounded local swaps instead of proposing wholesale imported builds.
	if compatibleBuildCount >= 2 and not truncated then
		for _, pattern in pairs(routePatternsByKey) do
			local overlap, novel = 0, 0
			for _, nodeId in ipairs(pattern.nodeIds) do
				if activePassiveSet[nodeId] then overlap = overlap + 1 else novel = novel + 1 end
			end
			if novel > 0 then
				local union = activePassiveCount + #pattern.nodeIds - overlap
				pattern.similarity = union > 0 and overlap / union or 0
				pattern.novelNodeCount = novel
				pattern.sampleCount = compatibleBuildCount
				pattern.supportRate = pattern.supportCount / compatibleBuildCount
				routePatterns[#routePatterns + 1] = pattern
			end
		end
		table.sort(routePatterns, function(left, right)
			if left.similarity ~= right.similarity then return left.similarity > right.similarity end
			if left.supportCount ~= right.supportCount then return left.supportCount > right.supportCount end
			if left.novelNodeCount ~= right.novelNodeCount then return left.novelNodeCount < right.novelNodeCount end
			return left.key < right.key
		end)
		while #routePatterns > MAX_NODE_EVIDENCE_OUTPUT_PATTERNS do table.remove(routePatterns) end
	end
	local status = truncated and "scan_limit_reached" or compatibleBuildCount >= 2 and "ready" or compatibleBuildCount == 1 and "single_build_only" or "no_compatible_builds"
	return {
		schema = "pob-ai-planner-imported-node-evidence",
		schemaVersion = 1,
		status = status,
		reason = truncated and "archive_scan_limit_reached_prior_disabled" or nil,
		selectedSkillGemId = cleanGemId,
		skillScope = skillScope,
		engine = snapshot,
		compatibleBuildCount = compatibleBuildCount,
		distinctBuildLineages = compatibleBuildCount,
		scannedRows = scannedRows,
		scannedBytes = scannedBytes,
		malformedRows = malformedRows,
		archiveTruncated = truncated,
		nodes = nodeRows,
		edges = edgeRows,
		nodeCounts = nodeCountsById,
		priorities = priorities,
		edgePriorities = edgePriorities,
		routePatterns = routePatterns,
		routePatternCount = #routePatterns,
		causal = false,
		readOnly = true,
		proposalOrderingOnly = true,
		proposalGenerationAvailable = #routePatterns > 0,
	}
end

function builds.Summary(userPath, build)
	local paths, pathError = builds.GetPaths(userPath)
	if not paths then return nil, pathError end
	local file, openError = io.open(paths.index, "rb")
	local active = SkillCatalog.ListAllActiveEffects(build, "")
	if not active then return nil, "PoB's loaded active-skill effect catalog is unavailable" end
	local patchSkillCatalog, patchCatalogError = loadPatchSkillCatalog(paths.patchSkillCatalog)
	local patchCoverage = emptyPatchCoverage(patchSkillCatalog and patchSkillCatalog.raw)
	local patchCoverageByVersion, patchLineagesBySkill, patchEligibleLineages, patchVaalLineages = { }, { }, { }, { }
	for _, patchRow in ipairs(patchCoverage) do
		local skillRows = { }
		for _, skill in ipairs(patchRow.skills) do skillRows[skill.variantKey] = skill end
		patchCoverageByVersion[patchRow.patch] = { row = patchRow, skills = skillRows }
		patchLineagesBySkill[patchRow.patch] = { }
		for skillKey in pairs(skillRows) do patchLineagesBySkill[patchRow.patch][skillKey] = { } end
		patchEligibleLineages[patchRow.patch] = { }
		patchVaalLineages[patchRow.patch] = { }
	end
	local effects, currentEffectIds, lineagesByEffect, pairLineages = { }, { }, { }, { }
	for _, effect in ipairs(active.effects or { }) do
		local id = effectIdentity(effect)
		if id then currentEffectIds[id] = true; effects[id] = {
			effectId = id,
			effectName = effect.effectName,
			gemId = effect.gemId,
			gemName = effect.name,
			variantId = effect.variantId,
			activeInCurrentCatalog = true,
			uniqueBuilds = 0,
			patches = { },
		} end end
	local totalObservations, uniqueBuilds, uniqueObjects, sourceProviders, leagueLineages, claimedLineages = 0, { }, { }, { }, { }, { }
	local verifiedSourceCodeFiles = { }
	local activeSpecEvidenceByObject = { }
	-- Reimported PoB XML may normalize a build signature. Collapse those rows by
	-- source only after the archived code file independently confirms its hash.
	local function sampleLineageKey(row)
		local source = type(row.source) == "table" and row.source or { }
		local codeSha256, codePath = source.codeSha256, source.codePath
		if isFingerprint(codeSha256) and type(codePath) == "string" and codePath:match("^source%-codes/")
			and not codePath:find("\\", 1, true) and not codePath:find(":", 1, true) and not codePath:find("[%c]") then
			local safePath = true
			for segment in codePath:gmatch("[^/]+") do
				if segment == ".." or segment == "." then safePath = false; break end
			end
			local cacheKey = codePath .. "\0" .. codeSha256:lower()
			local verified = safePath and verifiedSourceCodeFiles[cacheKey]
			if verified == nil and safePath then
				local relativePath = codePath:gsub("/", function() return separator() end)
				local codeFile = io.open(joinPath(paths.root, relativePath, separator()), "rb")
				if codeFile then
					local codeText = codeFile:read(MAX_BUILD_BYTES + 1)
					codeFile:close()
					verified = type(codeText) == "string" and #codeText <= MAX_BUILD_BYTES
						and sha.sha256(codeText) == codeSha256:lower()
				else
					verified = false
				end
				verifiedSourceCodeFiles[cacheKey] = verified
			end
			if verified then return "source-code:" .. codeSha256:lower() end
		end
		return "pob-signature:" .. row.lineageSha256:lower()
	end
	local patchAudit = { observations = 0, claimTreeDisagreements = 0, excludedByReason = { }, claimMismatchLineages = { } }
	local historicalEffects = { }
	if not file then
		if not missingFile(openError) then return nil, "Could not read the build archive index: " .. tostring(openError):sub(1, 200) end
	else
		local lineNumber = 0
		for line in file:lines() do
			lineNumber = lineNumber + 1
			if #line > MAX_INDEX_LINE_BYTES then file:close(); return nil, "Build archive index row exceeds the 256 KiB safety limit at line " .. lineNumber end
			if line ~= "" then
				local ok, row = pcall(json.decode, line)
				if not ok or type(row) ~= "table" or row.recordType ~= "build_archive_observation"
					or row.schemaVersion ~= 1 or type(row.profile) ~= "table"
					or not isFingerprint(row.lineageSha256) or not isFingerprint(row.xmlSha256) then
					file:close(); return nil, "Build archive index contains an invalid record at line " .. lineNumber
				end
				totalObservations = totalObservations + 1
				local sampleLineage = sampleLineageKey(row)
				uniqueBuilds[sampleLineage] = true
				uniqueObjects[row.xmlSha256] = true
				local provider = row.source and cleanText(row.source.provider or row.source.type or "unknown", 80)
				if provider then sourceProviders[provider] = true end
				local claimedLeague = row.source and cleanText(row.source.claimedLeague or "", 80)
				if claimedLeague then
					leagueLineages[claimedLeague] = leagueLineages[claimedLeague] or { }
					leagueLineages[claimedLeague][sampleLineage] = true
					claimedLineages[sampleLineage] = true
				end
				local engine = row.profile.engine or { }
				local version = tostring(engine.dataVersion or engine.treeVersion or "unknown")
				patchAudit.observations = patchAudit.observations + 1
				local treePatch = patchFromTreeVersion(tostring(engine.treeVersion or ""))
				local sourceClaims = row.source and tostring(row.source.claimedPatch or "") or ""
				if sourceClaims == "" then sourceClaims = tostring(row.source and row.source.claimedLeague or "") end
				local claimedPatch = sourceClaims:match("(3%.2[4-9])")
				if claimedPatch and treePatch and claimedPatch ~= treePatch
					and not patchAudit.claimMismatchLineages[sampleLineage] then
					patchAudit.claimMismatchLineages[sampleLineage] = true
					patchAudit.claimTreeDisagreements = patchAudit.claimTreeDisagreements + 1
				end
				local coveragePatch = treePatch and patchCoverageByVersion[treePatch]
				local strictMainSkillIdentityVerified = false
				local strictConfiguredEffects = { }
				local qualityAuditError = sourceBuildQualityAuditError(row.source)
				if not patchSkillCatalog then
					patchAudit.excludedByReason[patchCatalogError or "catalog_unavailable"]
						= (patchAudit.excludedByReason[patchCatalogError or "catalog_unavailable"] or 0) + 1
				elseif not coveragePatch then
					patchAudit.excludedByReason[treePatch and "patch_catalog_missing" or "tree_not_in_3_24_to_3_29"]
						= (patchAudit.excludedByReason[treePatch and "patch_catalog_missing" or "tree_not_in_3_24_to_3_29"] or 0) + 1
				elseif qualityAuditError then
					patchAudit.excludedByReason[qualityAuditError] = (patchAudit.excludedByReason[qualityAuditError] or 0) + 1
				else
					local patchMetadata = patchSkillCatalog.byPatch[treePatch]
					local activeSpec, activeSpecError
					local cachedEvidence = activeSpecEvidenceByObject[row.xmlSha256]
					if cachedEvidence == nil then
						local verifiedEvidence, evidenceError = archivedActiveSpec(paths, row)
						if verifiedEvidence then
							cachedEvidence = verifiedEvidence
							activeSpecEvidenceByObject[row.xmlSha256] = verifiedEvidence
						else
							activeSpecError = evidenceError
						end
					end
					if cachedEvidence then activeSpec, activeSpecError = profileActiveSpec(row.profile, patchMetadata, cachedEvidence) end
					if not activeSpec then
						activeSpecError = activeSpecError or "active_spec_not_verified"
						patchAudit.excludedByReason[activeSpecError] = (patchAudit.excludedByReason[activeSpecError] or 0) + 1
					elseif not standardAscendancyMatch(patchMetadata, row.profile.character or { }, activeSpec.spec) then
						patchAudit.excludedByReason.nonstandard_or_missing_ascendancy
							= (patchAudit.excludedByReason.nonstandard_or_missing_ascendancy or 0) + 1
					else
						local mainSkill = profileMainSkill(row.profile)
						if not mainSkill then
							patchAudit.excludedByReason.main_skill_not_identifiable
								= (patchAudit.excludedByReason.main_skill_not_identifiable or 0) + 1
						else
							local skillKey = tostring(mainSkill.gameId or "") .. "|" .. tostring(mainSkill.variantId or "")
							local patchSkill = patchMetadata.skills[skillKey]
							local sourcePatchSkillId
							local mainSkillIdentityMatches = catalogSkillMatchesMainSkillEffect(patchSkill, mainSkill)
							if not mainSkillIdentityMatches then
								sourcePatchSkillId = archivedSourcePatchSkillId(paths, row, mainSkill)
								mainSkillIdentityMatches = catalogSkillMatchesMainSkillEffect(patchSkill, mainSkill, sourcePatchSkillId)
							end
							local sourceClaimError = sourceMainSkillClaimError(row.source, mainSkill)
							if not patchSkill then
								patchAudit.excludedByReason.skill_not_in_patch_catalog
									= (patchAudit.excludedByReason.skill_not_in_patch_catalog or 0) + 1
							elseif not mainSkillIdentityMatches then
								patchAudit.excludedByReason.skill_effect_catalog_mismatch
									= (patchAudit.excludedByReason.skill_effect_catalog_mismatch or 0) + 1
							elseif sourceClaimError then
								patchAudit.excludedByReason[sourceClaimError]
									= (patchAudit.excludedByReason[sourceClaimError] or 0) + 1
							else
								-- Combination/effect aggregates use a build only after its selected Main Skill
								-- has an exact gem/variant/effect match in this patch's authoritative catalog.
								strictMainSkillIdentityVerified = true
								for _, effect in ipairs(row.profile.configuredSkillEffects or { }) do
									local effectKey = type(effect) == "table"
										and (tostring(effect.gameId or "") .. "|" .. tostring(effect.variantId or "")) or ""
									local configuredPatchSkill = patchMetadata.skills[effectKey]
									local configuredIdentityMatches = catalogSkillMatchesMainSkillEffect(configuredPatchSkill, effect)
									if not configuredIdentityMatches and effect.gameId == mainSkill.gameId
										and effect.variantId == mainSkill.variantId and effect.gemId == mainSkill.gemId
										and effect.effectId == mainSkill.effectId then
										local configuredSourceSkillId = sourcePatchSkillId or archivedSourcePatchSkillId(paths, row, mainSkill)
										configuredIdentityMatches = catalogSkillMatchesMainSkillEffect(configuredPatchSkill, effect, configuredSourceSkillId)
									end
									if configuredIdentityMatches then
										strictConfiguredEffects[#strictConfiguredEffects + 1] = effect
									else
										local reason = "configured_effect_catalog_mismatch"
										patchAudit.excludedByReason[reason] = (patchAudit.excludedByReason[reason] or 0) + 1
									end
								end
								local patchCategory = catalogSkillCategory(patchSkill)
								if patchCategory == "vaal" then
									local vaalSet = patchVaalLineages[treePatch]
									if not vaalSet[sampleLineage] then
										vaalSet[sampleLineage] = true
										coveragePatch.row.counts.vaalBuildLineages = coveragePatch.row.counts.vaalBuildLineages + 1
									end
								elseif patchCategory == "support_granted_effect" then
									patchAudit.excludedByReason.support_granted_effect_not_independent_target
										= (patchAudit.excludedByReason.support_granted_effect_not_independent_target or 0) + 1
								elseif (patchCategory == "normal" or patchCategory == "transfigured")
									and coveragePatch.skills[skillKey] then
									local lineages = patchLineagesBySkill[treePatch][skillKey]
									if not lineages[sampleLineage] then
										lineages[sampleLineage] = true
										local skillRow = coveragePatch.skills[skillKey]
										skillRow.uniqueBuilds = skillRow.uniqueBuilds + 1
										coveragePatch.row.counts.targetBuildLineages = coveragePatch.row.counts.targetBuildLineages + 1
									end
									if not patchEligibleLineages[treePatch][sampleLineage] then
										patchEligibleLineages[treePatch][sampleLineage] = true
										coveragePatch.row.counts.eligibleBuildLineages = coveragePatch.row.counts.eligibleBuildLineages + 1
									end
								else
									patchAudit.excludedByReason.out_of_scope_gem_variant = (patchAudit.excludedByReason.out_of_scope_gem_variant or 0) + 1
								end
							end
						end
					end
				end
				if strictMainSkillIdentityVerified then
					for _, effect in ipairs(strictConfiguredEffects) do
						local id = effectIdentity(effect)
						if id then
							if not effects[id] then
								effects[id] = {
									effectId = id, effectName = effect.name or id, gemId = effect.gemId,
									gemName = effect.gameId or "Historical PoB effect", variantId = effect.variantId,
									activeInCurrentCatalog = false, uniqueBuilds = 0, patches = { },
								}
							end
							local rowEffect = effects[id]
							lineagesByEffect[id] = lineagesByEffect[id] or { }
							if not lineagesByEffect[id][sampleLineage] then
								lineagesByEffect[id][sampleLineage] = true
								rowEffect.uniqueBuilds = rowEffect.uniqueBuilds + 1
							end
							rowEffect.patches[version] = true
						end
					end
					local pairEffects = { }
					for _, effect in ipairs(strictConfiguredEffects) do
						local skill = configuredSkillIdentity(effect)
						if skill then pairEffects[skill.key] = skill end
					end
					local pairIds = { }
					for key in pairs(pairEffects) do pairIds[#pairIds + 1] = key end
					table.sort(pairIds)
					for index = 1, #pairIds do
						for other = index + 1, #pairIds do
							local leftSkill, rightSkill = pairEffects[pairIds[index]], pairEffects[pairIds[other]]
							local patch = treePatch or "unknown"
							local key = patch .. "\31" .. pairIds[index] .. "\31" .. pairIds[other]
							pairLineages[key] = pairLineages[key] or {
								patch = patch, leftSkillKey = leftSkill.key, rightSkillKey = rightSkill.key,
								leftEffectId = leftSkill.effectId, rightEffectId = rightSkill.effectId,
								leftEffectName = leftSkill.name, rightEffectName = rightSkill.name,
								exactVariantIdentity = leftSkill.exact and rightSkill.exact,
								lineages = { },
							}
							pairLineages[key].lineages[sampleLineage] = true
						end
					end
					for _, effect in ipairs(strictConfiguredEffects) do
						local id = effectIdentity(effect)
						if id and not currentEffectIds[id] then historicalEffects[id] = true end
					end
				end
			end
		end
		file:close()
	end
	for _, patchRow in ipairs(patchCoverage) do
		for _, skill in ipairs(patchRow.skills) do
			skill.remainingToTarget = math.max(0, TARGET_BUILDS_PER_EFFECT - skill.uniqueBuilds)
			skill.targetReached = skill.uniqueBuilds >= TARGET_BUILDS_PER_EFFECT
			if skill.uniqueBuilds > 0 then patchRow.counts.skillsWithBuilds = patchRow.counts.skillsWithBuilds + 1 end
			if skill.targetReached then patchRow.counts.skillsAtTarget = patchRow.counts.skillsAtTarget + 1 end
		end
		table.sort(patchRow.skills, function(left, right)
			if left.uniqueBuilds ~= right.uniqueBuilds then return left.uniqueBuilds < right.uniqueBuilds end
			if left.category ~= right.category then return left.category < right.category end
			if tostring(left.name or ""):lower() ~= tostring(right.name or ""):lower() then
				return tostring(left.name or ""):lower() < tostring(right.name or ""):lower()
			end
			return left.variantKey < right.variantKey
		end)
	end
	local claimMismatchCount = patchAudit.claimTreeDisagreements
	patchAudit.claimMismatchLineages = nil
	local effectRows = { }
	for _, effect in pairs(effects) do
		local patchRows = { }
		for patch in pairs(effect.patches) do patchRows[#patchRows + 1] = patch end
		table.sort(patchRows)
		effect.sampleTarget = TARGET_BUILDS_PER_EFFECT
		effect.remainingToTarget = math.max(0, TARGET_BUILDS_PER_EFFECT - effect.uniqueBuilds)
		effect.targetReached = effect.uniqueBuilds >= TARGET_BUILDS_PER_EFFECT
		effect.coverageRatio = math.min(1, effect.uniqueBuilds / TARGET_BUILDS_PER_EFFECT)
		effect.patches = patchRows
		effectRows[#effectRows + 1] = effect
	end
	table.sort(effectRows, function(left, right)
		if left.uniqueBuilds ~= right.uniqueBuilds then return left.uniqueBuilds < right.uniqueBuilds end
		local leftName, rightName = tostring(left.effectName or ""):lower(), tostring(right.effectName or ""):lower()
		if leftName ~= rightName then return leftName < rightName end
		return left.effectId < right.effectId
	end)
	local pairRows, pairSeenCount = { }, 0
	for _, pair in pairs(pairLineages) do
		local count = 0
		for _ in pairs(pair.lineages) do count = count + 1 end
		pairRows[#pairRows + 1] = { patch = pair.patch, leftSkillKey = pair.leftSkillKey, rightSkillKey = pair.rightSkillKey,
			leftEffectId = pair.leftEffectId, rightEffectId = pair.rightEffectId,
			leftEffectName = pair.leftEffectName, rightEffectName = pair.rightEffectName,
			exactVariantIdentity = pair.exactVariantIdentity,
			uniqueBuilds = count, evidence = "co_observed_only_synergy_untested" }
		pairSeenCount = pairSeenCount + count
	end
	table.sort(pairRows, function(left, right)
		if left.uniqueBuilds ~= right.uniqueBuilds then return left.uniqueBuilds > right.uniqueBuilds end
		if left.patch ~= right.patch then return left.patch < right.patch end
		if left.leftSkillKey ~= right.leftSkillKey then return left.leftSkillKey < right.leftSkillKey end
		return left.rightSkillKey < right.rightSkillKey
	end)
	local uniqueBuildCount, uniqueObjectCount, providerCount = 0, 0, 0
	for _ in pairs(uniqueBuilds) do uniqueBuildCount = uniqueBuildCount + 1 end
	for _ in pairs(uniqueObjects) do uniqueObjectCount = uniqueObjectCount + 1 end
	for _ in pairs(sourceProviders) do providerCount = providerCount + 1 end
	local topPairs = { }
	for index = 1, math.min(30, #pairRows) do topPairs[index] = pairRows[index] end
	local leagueRows = { }
	for league, lineages in pairs(leagueLineages) do
		local count = 0
		for _ in pairs(lineages) do count = count + 1 end
		leagueRows[#leagueRows + 1] = { claim = league, uniqueBuildLineages = count, evidence = "source_claim_unverified" }
	end
	table.sort(leagueRows, function(left, right)
		if left.uniqueBuildLineages ~= right.uniqueBuildLineages then return left.uniqueBuildLineages > right.uniqueBuildLineages end
		return left.claim < right.claim
	end)
	return {
		schema = "pob-ai-planner-build-learning-summary",
		schemaVersion = 1,
		storage = { root = paths.root, index = paths.index, objectCount = uniqueObjectCount,
			uniqueBuildLineages = uniqueBuildCount, sourceObservations = totalObservations, providerCount = providerCount },
		patchSkillCatalog = {
			status = patchSkillCatalog and "ready" or (patchCatalogError or "catalog_unavailable"),
			path = paths.patchSkillCatalog,
			schemaVersion = patchSkillCatalog and patchSkillCatalog.raw.schemaVersion or nil,
			featureSchemaVersion = patchSkillCatalog and patchSkillCatalog.raw.featureSchemaVersion or nil,
			source = patchSkillCatalog and patchSkillCatalog.raw.source or nil,
			patches = patchCoverage,
			audit = { treeVersionIsPatchEvidence = true, leagueClaimsAreNotPatchEvidence = true,
				observations = patchAudit.observations, claimTreeDisagreements = claimMismatchCount,
				excludedByReason = patchAudit.excludedByReason },
		},
			catalog = { activeEffectCount = active.count, trackedEffectCount = #effectRows,
			archivedHistoricalEffectCount = (function() local count = 0; for _ in pairs(historicalEffects) do count = count + 1 end; return count end)(), targetBuildsPerEffect = TARGET_BUILDS_PER_EFFECT,
				coveredEffects = (function() local count = 0; for _, row in ipairs(effectRows) do if row.uniqueBuilds > 0 then count = count + 1 end end; return count end)(),
				effectsAtTarget = (function() local count = 0; for _, row in ipairs(effectRows) do if row.targetReached then count = count + 1 end end; return count end)() },
		effects = effectRows,
		observedPairs = topPairs,
		leagueClaims = { status = "unverified_source_claims", rows = leagueRows,
			unknownLineages = math.max(0, uniqueBuildCount - (function() local count = 0; for _ in pairs(claimedLineages) do count = count + 1 end; return count end)()) },
		combinationEvidence = "Build co-occurrence is discovery evidence only; exact four-cell PoB factorial experiments are required before claiming synergy or training an interaction target.",
		model = { topology = "existing single-hidden-layer scalar MLP", enabled = Surrogate.enabled == true,
			modelType = Surrogate.model and Surrogate.model.modelType or "passive-one-node-build-context-mlp-v2",
			featurePolicy = SurrogateFeatures.FEATURE_POLICY,
			artifactPath = joinPath(joinPath(userPath, "OptimizerModels", separator()), "active.json", separator()),
			status = Surrogate.enabled == true and "runtime ranker enabled; build archive observations are not its training labels"
				or "ranker disabled; build archive observations do not train or enable the MLP",
			candidatePruning = false, exactPoBAuthority = true },
	}
end

return builds
