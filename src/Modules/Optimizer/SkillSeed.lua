-- Path of Building
--
-- Module: Native starting skill-set seed for the AI Planner.
-- A selected PoB active gem is added as a single-gem group in a new skill-set
-- variation. When an unused native socket-link starts on an equipped item, the
-- seed is assigned to that slot; otherwise it remains explicitly unlinked.

local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local Candidate = require("Modules.Optimizer.Candidate")
local Equipment = require("Modules.Optimizer.Equipment")

local seed = { }

local function nextSkillSetId(skillSets)
	local id = 1
	while skillSets[id] do id = id + 1 end
	return id
end

local function seedLevel(gemData, characterLevel, output)
	local effect = gemData.grantedEffect
	local levels = effect and effect.levels or { }
	local maximum = math.min(tonumber(gemData.naturalMaxLevel) or #levels, #levels)
	local levelAllowed = false
	for level = maximum, 1, -1 do
		local levelData = levels[level]
		local requiredLevel = levelData and (tonumber(levelData.levelRequirement) or 1)
		if requiredLevel and requiredLevel <= characterLevel then
			levelAllowed = true
			local strength = calcLib.getGemStatRequirement(requiredLevel, effect.support, gemData.reqStr)
			local dexterity = calcLib.getGemStatRequirement(requiredLevel, effect.support, gemData.reqDex)
			local intelligence = calcLib.getGemStatRequirement(requiredLevel, effect.support, gemData.reqInt)
			if strength <= (tonumber(output.Str) or -1) and dexterity <= (tonumber(output.Dex) or -1)
				and intelligence <= (tonumber(output.Int) or -1) then
				return level, { level = requiredLevel, strength = strength, dexterity = dexterity, intelligence = intelligence }
			end
		end
	end
	return nil, levelAllowed and "PoB's exact Strength, Dexterity, or Intelligence is below the selected gem's level-1 requirement"
		or "The selected gem has no level allowed by the current character level"
end

local function shallowCopy(source)
	local copy = { }
	for key, value in pairs(source or { }) do copy[key] = value end
	return copy
end

local function copySkillSet(sourceSet)
	-- Skill groups contain derived display/runtime objects with back-references.
	-- PoB's own CreateUndoState deliberately copies these records shallowly; a
	-- recursive copyTable(sourceSet) can recurse forever on those cycles.
	local copiedSet = shallowCopy(sourceSet)
	copiedSet.socketGroupList = { }
	for groupIndex, sourceGroup in pairs(sourceSet.socketGroupList or { }) do
		local copiedGroup = shallowCopy(sourceGroup)
		copiedGroup.gemList = { }
		for gemIndex, sourceGem in pairs(sourceGroup.gemList or { }) do
			copiedGroup.gemList[gemIndex] = shallowCopy(sourceGem)
		end
		copiedSet.socketGroupList[groupIndex] = copiedGroup
	end
	return copiedSet
end

local function findCompatibleSocketBinding(build, sourceGroups, gemData)
	local itemsTab = build and build.itemsTab
	local itemSet = Equipment.ActiveItemSet(itemsTab)
	if not itemsTab or not itemSet or type(itemsTab.IsItemValidForSlot) ~= "function" then return nil end
	local effect = gemData and gemData.grantedEffect
	local requiredColour = effect and ({ [1] = "R", [2] = "G", [3] = "B" })[effect.color]
	if not requiredColour then return nil end
	local activeWeaponSet = itemSet.useSecondWeaponSet and 2 or 1

	-- The native Skills tab maps each group to the next sockets in that item slot.
	-- Only use the next socket when it begins a distinct physical link group;
	-- otherwise this would silently split one linked group into two PoB groups.
	for _, slotName in ipairs(Equipment.GetSlots(build)) do
		local slot = itemsTab.slots[slotName]
		if not (slot and slot.weaponSet and slot.weaponSet ~= activeWeaponSet) then
			local entry = itemSet[slotName]
			local itemId = entry and tonumber(entry.selItemId)
			local item = itemId and itemId > 0 and itemsTab.items and itemsTab.items[itemId]
			local sockets = item and item.sockets
			if type(sockets) == "table" and #sockets > 0 then
				local validCall, validForSlot = pcall(itemsTab.IsItemValidForSlot, itemsTab, item, slotName, itemSet)
				if validCall and validForSlot == true then
					local socketOffset = 0
					for _, group in ipairs(sourceGroups or { }) do
						if group.slot == slotName then socketOffset = socketOffset + #(group.gemList or { }) end
					end
					local socketIndex = socketOffset + 1
					local socket = sockets[socketIndex]
					local previousSocket = socketIndex > 1 and sockets[socketIndex - 1] or nil
					local beginsNewLink = socket and socket.group ~= nil
						and (socketIndex == 1 or (previousSocket and previousSocket.group ~= socket.group))
					local colourMatches = socket and (sockets.colourAlwaysMatches
						or tostring(socket.color or ""):upper() == requiredColour
						or tostring(socket.color or ""):upper() == "W")
					if beginsNewLink and colourMatches then
						local linkSocketCount = 0
						for index = socketIndex, #sockets do
							if sockets[index].group ~= socket.group then break end
							linkSocketCount = linkSocketCount + 1
						end
						return {
							slot = slotName,
							socketIndex = socketIndex,
							socketColour = tostring(socket.color or ""):upper(),
							linkSocketCount = linkSocketCount,
						}
					end
				end
			end
		end
	end
	return nil
end

local function exactClassRootOutput(build, classId, skillSet, groupIndex)
	local rootSpec, rootError = Candidate.BuildPassiveSpec(build, { }, { }, { classId = classId })
	if not rootSpec or not rootSpec.build then
		return nil, rootError or "PoB could not create an isolated root for the selected class"
	end
	local rootBuild = rootSpec.build
	local skillsTab = shallowCopy(build.skillsTab)
	setmetatable(skillsTab, getmetatable(build.skillsTab))
	skillsTab.skillSets = shallowCopy(build.skillsTab.skillSets)
	skillsTab.skillSets[skillSet.id] = skillSet
	skillsTab.activeSkillSetId = skillSet.id
	skillsTab.socketGroupList = skillSet.socketGroupList
	skillsTab.build = rootBuild
	rootBuild.skillsTab = skillsTab
	rootBuild.mainSocketGroup = groupIndex

	local calcsTab = shallowCopy(build.calcsTab)
	setmetatable(calcsTab, getmetatable(build.calcsTab))
	calcsTab.build = rootBuild
	calcsTab.input = shallowCopy(build.calcsTab.input)
	calcsTab.input.skill_number = groupIndex
	calcsTab.displayData = nil -- prevent the exact proxy calculation from touching live UI breakdown controls
	rootBuild.calcsTab = calcsTab
	local ok, err = pcall(calcsTab.BuildOutput, calcsTab)
	if not ok then return nil, "PoB could not exact-calculate the selected class root: " .. tostring(err) end
	if type(calcsTab.mainOutput) ~= "table" then
		return nil, "PoB did not provide exact attributes for the selected class root"
	end
	return calcsTab.mainOutput
end

function seed.Create(build, gemId, requestedClassId)
	if not build or not build.skillsTab or type(gemId) ~= "string" or #gemId < 1 or #gemId > 100 or gemId:find("[%c]") then
		return nil, "Select a loaded PoB active-skill gem ID"
	end
	local gemData = build.data and build.data.gems and build.data.gems[gemId]
	if not SkillCatalog.IsActiveSkillGem(gemData) then
		return nil, "The selected ID is not a supported active skill in PoB's loaded gem database"
	end
	local skillsTab = build.skillsTab
	for _, method in ipairs({ "CreateUndoState", "RestoreUndoState", "SetActiveSkillSet", "ProcessSocketGroup", "UpdateSocketGroups", "AddUndoState" }) do
		if type(skillsTab[method]) ~= "function" then
			return nil, "PoB's native skill-set API is missing " .. method
		end
	end
	local state = skillsTab:CreateUndoState()
	local undoCheckpointExists = type(skillsTab.undo) == "table" and skillsTab.undo[1] ~= nil
	local sourceSetId = state.activeSkillSetId
	local sourceSet = state.skillSets and state.skillSets[sourceSetId]
	if not sourceSet then return nil, "The active PoB skill set could not be copied safely" end
	if not build.calcsTab or type(build.calcsTab.BuildOutput) ~= "function" then
		return nil, "PoB's exact calculator is unavailable for the starting skill"
	end
	if not calcLib or type(calcLib.getGemStatRequirement) ~= "function" then
		return nil, "PoB's native gem-requirement calculator is unavailable"
	end
	build.calcsTab:BuildOutput()
	local baselineOutput = build.calcsTab.mainOutput
	if type(baselineOutput) ~= "table" then return nil, "PoB did not provide a baseline output for the starting skill" end
	local optimizerTab = build.optimizerTab
	local classId = tonumber(requestedClassId)
	if requestedClassId ~= nil and (not classId or classId ~= math.floor(classId)) then
		return nil, "The selected base class ID must be an integer from the active PoB tree"
	end
	if classId == nil and optimizerTab and optimizerTab.textValues then
		classId = tonumber(optimizerTab.textValues.baseClassId)
	end
	if classId == nil then classId = build.spec and build.spec.curClassId end
	if not classId or not (build.spec and build.spec.tree and build.spec.tree.classes and build.spec.tree.classes[classId]) then
		return nil, "Choose a base class available in the active PoB passive-tree version"
	end

	local newSetId = nextSkillSetId(skillsTab.skillSets or { })
	if type(copyTable) ~= "function" then
		return nil, "PoB's native deep-copy helper is unavailable for a safe skill-set variation"
	end
	-- `state` is the rollback/undo snapshot. Never mutate its source set while
	-- deriving the new variation, or a failed calculation could corrupt both
	-- rollback and the first Undo checkpoint.
	local newSet = copySkillSet(sourceSet)
	newSet.id = newSetId
	local socketBinding = findCompatibleSocketBinding(build, sourceSet.socketGroupList, gemData)
	local bindingLabel = socketBinding and ("linked: " .. socketBinding.slot) or "unlinked"
	newSet.title = ("AI Planner — " .. tostring(gemData.name or gemData.id) .. " (" .. bindingLabel .. " seed)"):sub(1, 100)
	newSet.socketGroupList = newSet.socketGroupList or { }
	local group = {
		label = ("AI Planner — " .. tostring(gemData.name or gemData.id) .. " (" .. bindingLabel .. ")"):sub(1, 100),
		enabled = true,
		includeInFullDPS = true,
		mainActiveSkill = 1,
		mainActiveSkillCalcs = 1,
		slot = socketBinding and socketBinding.slot or nil,
		gemList = {
			{
				gemId = gemData.id,
				skillId = gemData.grantedEffectId,
				nameSpec = gemData.name,
				level = 1,
				quality = 0,
				enabled = true,
				enableGlobal1 = true,
				enableGlobal2 = false,
				count = 1,
			},
		},
	}
	newSet.socketGroupList[#newSet.socketGroupList + 1] = group
	local groupIndex = #newSet.socketGroupList

	local proxyTab = { }
	for key, value in pairs(skillsTab) do proxyTab[key] = value end
	setmetatable(proxyTab, getmetatable(skillsTab))
	proxyTab.build = build
	proxyTab.socketGroupList = newSet.socketGroupList
	local selectedLevel, selectedRequirements, targetClassMaxGemLevel
	local ok, err = pcall(function()
		proxyTab:ProcessSocketGroup(group)
		proxyTab:UpdateSocketGroups()
		local activeIndex = SkillCatalog.ResolveMainSkillIndex(group, 1, gemData.grantedEffectId)
		if not activeIndex then error("PoB could not resolve the selected gem as an active skill") end
		group.mainActiveSkill = activeIndex
		group.mainActiveSkillCalcs = activeIndex
		local requirementOutput = baselineOutput
		if classId ~= build.spec.curClassId then
			local rootOutput, rootError = exactClassRootOutput(build, classId, newSet, groupIndex)
			if not rootOutput then error(rootError) end
			requirementOutput = rootOutput
		end
		local level, requirementsOrError = seedLevel(gemData,
			math.max(1, math.floor(tonumber(build.characterLevel) or 1)), requirementOutput)
		if not level then error(requirementsOrError) end
		targetClassMaxGemLevel = level
		if classId ~= build.spec.curClassId then
			local activeClassLevel, activeClassRequirements = seedLevel(gemData,
				math.max(1, math.floor(tonumber(build.characterLevel) or 1)), baselineOutput)
			if not activeClassLevel then error(activeClassRequirements) end
			-- The source build remains on its current class until a candidate is
			-- applied. Keep the seed legal there and at the chosen class root; the
			-- Skills phase can raise its level after the target tree is applied.
			if activeClassLevel < level then
				level, requirementsOrError = activeClassLevel, activeClassRequirements
			end
		end
		selectedLevel, selectedRequirements = level, requirementsOrError
		group.gemList[1].level = level
		proxyTab:ProcessSocketGroup(group)
		proxyTab:UpdateSocketGroups()
		local selectedIndex = SkillCatalog.ResolveMainSkillIndex(group, 1, gemData.grantedEffectId)
		if not selectedIndex then error("PoB could not resolve the selected gem after applying its legal level") end
		group.mainActiveSkill = selectedIndex
		group.mainActiveSkillCalcs = selectedIndex
		-- Install the complete copied set as a separate native variation. The
		-- original set and its socket groups remain untouched and can be restored
		-- with the Skills tab's ordinary Undo control.
		skillsTab.skillSets[newSetId] = newSet
		table.insert(skillsTab.skillSetOrderList, newSetId)
		skillsTab:SetActiveSkillSet(newSetId)
		skillsTab:SetDisplayGroup(group)
		build.mainSocketGroup = groupIndex
		build.calcsTab.input.skill_number = groupIndex
		if build.calcsTab and type(build.calcsTab.BuildOutput) == "function" then
			build.calcsTab:BuildOutput()
		end
		local activeGroup = skillsTab.socketGroupList[groupIndex]
		local activeSkill = activeGroup and activeGroup.displaySkillList and activeGroup.displaySkillList[activeIndex]
		local activeEffect = activeSkill and activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
		if not activeEffect or activeEffect.id ~= gemData.grantedEffectId then
			error("PoB's exact calculator did not resolve the seeded gem/effect")
		end
		if build.controls and build.controls.mainSocketGroup and type(build.RefreshSkillSelectControls) == "function" then
			build:RefreshSkillSelectControls(build.controls, groupIndex, "")
		end
	end)
	if not ok then
		pcall(function() skillsTab:RestoreUndoState(state) end)
		if build.calcsTab and type(build.calcsTab.BuildOutput) == "function" then
			pcall(build.calcsTab.BuildOutput, build.calcsTab)
		end
		return nil, "Could not create a PoB-calculated skill-set seed: " .. tostring(err)
	end
	skillsTab:AddUndoState()
	if not undoCheckpointExists then
		-- Fresh PoB builds can have no undo baseline yet. Preserve the snapshot
		-- captured before the seed as UndoHandler's second state so the first
		-- native Undo reliably restores the original skill set.
		table.insert(skillsTab.undo, 2, state)
	end
	skillsTab.modFlag = true
	build.modFlag = true
	build.buildFlag = true

	local message
	if socketBinding then
		message = string.format("Created and exact-calculated the Main Skill in the equipped %s item, at the start of a native %d-socket link. The group has no supports yet; add only supports that fit this link and pass PoB's exact calculation.",
			socketBinding.slot, socketBinding.linkSocketCount)
		if classId ~= build.spec.curClassId then
			message = message .. " The chosen class differs from the source class; the source remains unchanged until a Tree result is applied."
		end
	else
		message = "Created and exact-calculated an unlinked Main Skill seed in a new reversible PoB skill set. No unused compatible socket link was found in the active equipment set; assign an item socket and recalculate before treating it as playable."
		if classId ~= build.spec.curClassId then
			message = "Created an unlinked seed legal for both the current build and selected class root. The source class is unchanged; apply the Tree result, then optimize gem level in Skills. No unused compatible socket link was found in the active equipment set."
		end
	end
	if optimizerTab and optimizerTab.textValues then
		optimizerTab.textValues.generationPhase = "tree"
		optimizerTab.textValues.targetSkillGroupIndex = tostring(groupIndex)
		optimizerTab.textValues.targetSkillIndex = tostring(group.mainActiveSkill)
		optimizerTab.textValues.targetSkillGemId = gemData.id
		optimizerTab.result = nil
		optimizerTab.modFlag = true
		optimizerTab.statusMessage = message
	end

	local output = build.calcsTab and build.calcsTab.mainOutput or { }
	return {
		created = true,
		gemId = gemData.id,
		gemName = gemData.name,
		level = selectedLevel,
		requirements = selectedRequirements,
		baseClassId = classId,
		targetClassMaxGemLevel = targetClassMaxGemLevel,
		calculationClassId = build.spec.curClassId,
		calculationContext = "current_source_build",
		skillSetId = newSetId,
		skillSetTitle = newSet.title,
		groupIndex = groupIndex,
		skillIndex = group.mainActiveSkill,
		linked = socketBinding ~= nil,
		socketBinding = socketBinding,
		metrics = {
			CombinedDPS = tonumber(output.CombinedDPS),
			FullDPS = tonumber(output.FullDPS),
			TotalEHP = tonumber(output.TotalEHP),
		},
		message = message,
	}
end

return seed
