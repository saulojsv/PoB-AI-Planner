local Candidate = require("Modules.Optimizer.Candidate")
local Inputs = require("Modules.Optimizer.Inputs")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local SkillSeed = require("Modules.Optimizer.SkillSeed")
local Equipment = require("Modules.Optimizer.Equipment")

local function prepareCharacter()
	build.characterLevel = 90
	build.characterLevelAutoMode = false
	local config = build.configTab.configSets[build.configTab.activeConfigSetId]
	config.customModsList[1].text = "Regenerate 100 Mana per second"
	config.customModsList[#config.customModsList + 1] = { text = "+200 to all Attributes" }
	build.configTab:BuildModList()
end

local function equipItem(slotName, itemText)
	local item = new("Item"):Item(itemText)
	build.itemsTab:AddItem(item, true)
	build.itemsTab.activeItemSet[slotName].selItemId = item.id
	build.itemsTab.slots[slotName]:SetSelItemId(item.id)
	build.itemsTab:PopulateSlots()
	build:SyncLoadouts()
	return item
end

local function runSkillsSearch(gemId, groupIndex, skillIndex, budget)
	local parsed = assert(Inputs.Parse({
		generationPhase = "skills",
		objectiveMetric = "CombinedDPS",
		evaluationBudget = tostring(budget),
		maxAddedPoints = "0",
		maxTotalPoints = "120",
		targetSkillGroupIndex = tostring(groupIndex),
		targetSkillIndex = tostring(skillIndex),
		targetSkillGemId = gemId,
		seed = "1",
	}))
	local valid, validationError = Inputs.ValidateBuild(build, parsed)
	assert.is_true(valid, validationError)
	local sourceSignature = Candidate.BuildSignature(build)
	local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
	local status, result = "running", nil
	for _ = 1, 5000 do
		status, result = job:Step()
		if status ~= "running" then break end
	end
	assert.is_true(status ~= "running", "linked support search stalled in " .. tostring(job.progress and job.progress.phase))
	assert.is_true(status ~= "error", result and result.message or job.error)
	assert.are.equal("skills", result.generationPhase)
	assert.is_true(result.evaluations > 0 and result.evaluations <= parsed.search.evaluationBudget)
	assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "exact linked support search must preserve its source build")
	return result, sourceSignature
end

local function runEquipmentSearch(gemId, groupIndex, skillIndex, budget, equipmentOverrides)
	local parsed = assert(Inputs.Parse({
		generationPhase = "equipment",
		objectiveMetric = "CombinedDPS",
		evaluationBudget = tostring(budget),
		maxAddedPoints = "0",
		maxTotalPoints = "120",
		targetSkillGroupIndex = tostring(groupIndex),
		targetSkillIndex = tostring(skillIndex),
		targetSkillGemId = gemId,
		searchStoredItems = false,
		searchSyntheticGear = false,
		requiredItemsJson = Equipment.EncodeOverrides(equipmentOverrides or { }),
		seed = "1",
	}))
	local valid, validationError = Inputs.ValidateBuild(build, parsed)
	assert.is_true(valid, validationError)
	local sourceSignature = Candidate.BuildSignature(build)
	local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
	local status, result = "running", nil
	for _ = 1, 5000 do
		status, result = job:Step()
		if status ~= "running" then break end
	end
	assert.is_true(status ~= "running", "equipment search stalled in " .. tostring(job.progress and job.progress.phase))
	assert.is_true(status ~= "error", result and result.message or job.error)
	assert.are.equal("equipment", result.generationPhase)
	assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "exact equipment search must preserve its source build")
	return result, sourceSignature
end

local function variantsOf(candidate)
	if type(candidate and candidate.gemVariants) == "table" then return candidate.gemVariants end
	return candidate and candidate.gemVariant and { candidate.gemVariant } or { }
end

local function findFeasibleGemCandidate(result, kind)
	local candidates = { result.candidate }
	for _, candidate in ipairs(result.paretoFront or { }) do candidates[#candidates + 1] = candidate end
	local seen = { }
	for _, candidate in ipairs(candidates) do
		if candidate and not seen[candidate] then
			seen[candidate] = true
			local hasKind = false
			for _, variant in ipairs(variantsOf(candidate)) do
				if variant.kind == kind then hasKind = true; break end
			end
			if hasKind and candidate.feasible == true then return candidate end
		end
	end
	return nil
end

local function assertLinkedSupportGroup(groupIndex, expectedGemId, expectedSlot, itemId)
	build.calcsTab:BuildOutput()
	local group = assert(build.skillsTab.socketGroupList[groupIndex])
	assert.are.equal(expectedSlot, group.slot)
	assert.are.equal(expectedGemId, group.gemList[1].gemData.id)
	local valid, details = SkillCatalog.ValidateSocketGroup(build, groupIndex)
	assert.is_true(valid, type(details) == "string" and details or "PoB's native socket/link validator must accept the whole group")
	assert.are.equal("linked", details.status)
	assert.are.equal(itemId, details.itemId)
	assert.are.equal(#group.gemList, details.socketCount)
	local item = build.itemsTab.items[itemId]
	local baseSocket = item.sockets[details.firstSocketIndex]
	local foundAppliedSupport = false
	for gemIndex = 2, #group.gemList do
		local gem = group.gemList[gemIndex]
		local socket = item.sockets[details.firstSocketIndex + gemIndex - 1]
		local effect = gem.gemData.grantedEffect
		if not (effect and effect.support) then effect = gem.gemData.secondaryGrantedEffect end
		assert.is_true(effect and effect.support, "every added socketed gem must be a loaded support")
		assert.are.equal(baseSocket.group, socket.group, "all planned gems must remain in the Main Skill's physical link")
		local requiredColor = ({ [1] = "R", [2] = "G", [3] = "B", [4] = "W" })[effect.color]
		assert.is_truthy(requiredColor)
		assert.is_true(socket.color == "W" or socket.color == requiredColor,
			"support " .. tostring(gem.gemData.name) .. " must match its native PoB socket color")
		for _, activeSkill in ipairs(build.calcsTab.mainEnv.player.activeSkillList or { }) do
			if activeSkill.socketGroup == group then
				for _, applied in ipairs(activeSkill.effectList or { }) do
					if applied.srcInstance == gem and applied.grantedEffect and applied.grantedEffect.support then
						foundAppliedSupport = true
					end
				end
			end
		end
	end
	if #group.gemList > 1 then
		assert.is_true(foundAppliedSupport, "ordinary PoB BuildOutput must apply the socketed support to its selected skill")
	end
	return group, build.calcsTab.mainOutput
end

describe("Optimizer exact support search on equipment-backed links", function()
	it("adds and applies exact supports inside a real six-blue Vaal Regalia link", function()
		newBuild()
		prepareCharacter()
		local body = equipItem("Body Armour",
			"Rarity: RARE\nAI Planner Linked Support Six-Link\nVaal Regalia\nQuality: 0\nSockets: B-B-B-B-B-B\nImplicits: 0\n+80 to maximum Life\n")
		build.calcsTab:BuildOutput()
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local seed, seedError = SkillSeed.Create(build, gemId)
		assert.is_truthy(seed, seedError)
		assert.is_true(seed.linked)
		assert.are.equal("Body Armour", seed.socketBinding.slot)
		assert.are.equal(6, seed.socketBinding.linkSocketCount)
		assertLinkedSupportGroup(seed.groupIndex, gemId, "Body Armour", body.id)

		local baseline = build.calcsTab.mainOutput.CombinedDPS
		local sourceSkillSetId = build.skillsTab.activeSkillSetId
		local result, sourceSignature = runSkillsSearch(gemId, seed.groupIndex, seed.skillIndex, 32)
		local coverage = result.searchCoverage.phase
		assert.is_true(coverage.generatedSupportAddCandidates > 0)
		assert.is_true(coverage.exactSupportAddEvaluations > 0)
		assert.is_true(coverage.compatibleSupportAddEvaluations > 0)
		assert.is_true(coverage.generatedSupportAddCombinationCandidates > 0)
		assert.is_true(coverage.exactSupportAddCombinationEvaluations > 0)
		assert.is_true(coverage.compatibleSupportAddCombinationEvaluations > 0)

		local candidate = assert(findFeasibleGemCandidate(result, "support_add"),
			"the exact Pareto result must retain an equipment-backed support addition")
		assert.is_true(candidate.evaluation.metrics.CombinedDPS > baseline,
			"the selected exact support plan must improve the configured Main Skill metric")
		local applied, applyError = Candidate.Apply(build, candidate)
		assert.is_true(applied, applyError)
		local appliedGroup, appliedOutput = assertLinkedSupportGroup(seed.groupIndex, gemId, "Body Armour", body.id)
		assert.is_true(#appliedGroup.gemList > 1)
		assert.is_true(math.abs(appliedOutput.CombinedDPS - candidate.evaluation.metrics.CombinedDPS)
			<= math.max(1e-7, math.abs(candidate.evaluation.metrics.CombinedDPS) * 1e-8),
			"normal PoB output after Apply must reproduce the optimizer's exact candidate metric")
		assert.are_not.equal(sourceSkillSetId, build.skillsTab.activeSkillSetId,
			"applying the optimized support plan must create a separate PoB skill-set variation")
		local originalSkillSet = assert(build.skillsTab.skillSets[sourceSkillSetId])
		assert.are.equal(gemId, originalSkillSet.socketGroupList[seed.groupIndex].gemList[1].gemId,
			"the original seeded variation must remain available after Apply")
		assert.are.equal(1, #originalSkillSet.socketGroupList[seed.groupIndex].gemList,
			"the original seed must not inherit the optimizer's added support")
		build.skillsTab:Undo()
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "native Undo must restore the linked seed")
		assert.are.equal(sourceSkillSetId, build.skillsTab.activeSkillSetId)
		local restored = build.skillsTab.socketGroupList[seed.groupIndex]
		assert.are.equal(1, #restored.gemList)
		assert.are.equal(body.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)
		newBuild()
	end)

	it("calculates a weapon-restricted support on a real linked Cyclone claw setup", function()
		newBuild()
		prepareCharacter()
		local claw = equipItem("Weapon 1",
			"Rarity: RARE\nAI Planner Nightblade Claw\nGemini Claw\nQuality: 0\nSockets: G-G-R\nImplicits: 0\n")
		local cycloneId = "Metadata/Items/Gems/SkillGemCyclone"
		local nightbladeId = build.data.gemForBaseName["nightblade support"]
		local nightblade = nightbladeId and build.data.gems[nightbladeId]
		local nightbladeEffect = nightblade and (nightblade.grantedEffect and nightblade.grantedEffect.support
			and nightblade.grantedEffect or nightblade.secondaryGrantedEffect)
		assert.is_truthy(nightbladeEffect and nightbladeEffect.support, "PoB data must expose Nightblade Support")
		assert.is_truthy(nightbladeEffect.weaponTypes, "Nightblade must expose its native weapon restriction")
		build.skillsTab:PasteSocketGroup("Slot: Weapon 1\nCyclone 20/0 1\nNightblade Support 1/0 1\n")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		-- The clipboard parser stores display names first. Bind canonical IDs as
		-- native PoB persistence does so this fixture is deterministic across gem
		-- aliases and duplicate display-name variants.
		build.skillsTab.socketGroupList[1].gemList[1].gemId = cycloneId
		build.skillsTab.socketGroupList[1].gemList[2].gemId = nightblade.id
		build.skillsTab:ProcessSocketGroup(build.skillsTab.socketGroupList[1])
		build.skillsTab:AddUndoState()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		local group = build.skillsTab.socketGroupList[1]
		assert.are.equal("Weapon 1", group.slot)
		assert.are.equal(cycloneId, group.gemList[1].gemData.id)
		assert.are.equal(nightblade.id, group.gemList[2].gemData.id)
		local linked, socketDetails = SkillCatalog.ValidateSocketGroup(build, 1)
		assert.is_true(linked, type(socketDetails) == "string" and socketDetails or "Cyclone and Nightblade must occupy the native claw link")
		assert.are.equal("linked", socketDetails.status)
		assert.are.equal(claw.id, socketDetails.itemId)
		assert.are.equal("Claw", build.calcsTab.mainEnv.player.mainSkill.actor.weaponData1.type)
		local appliedNightblade = false
		for _, effect in ipairs(build.calcsTab.mainEnv.player.mainSkill.effectList or { }) do
			if effect.srcInstance == group.gemList[2] and effect.grantedEffect.id == nightbladeEffect.id then
				appliedNightblade = true
			end
		end
		assert.is_true(appliedNightblade, "PoB's exact skill model must apply Nightblade with the equipped claw")

		local sourceSkillSetId = build.skillsTab.activeSkillSetId
		local sourceSignature = Candidate.BuildSignature(build)
		local result = runSkillsSearch(cycloneId, 1, 1, 24)
		local coverage = result.searchCoverage.phase
		assert.is_true(coverage.generatedSupportSwapCandidates > 0)
		assert.is_true(coverage.exactSupportSwapEvaluations > 0)
		assert.is_true(coverage.compatibleSupportSwapEvaluations > 0,
			"at least one replacement must pass PoB's weapon-aware support model")
		local candidate = assert(findFeasibleGemCandidate(result, "support_add"),
			"the exact result must retain a support addition that fits the remaining native claw socket")
		local addedVariant
		for _, variant in ipairs(variantsOf(candidate)) do
			if variant.kind == "support_add" then addedVariant = variant; break end
		end
		assert.is_truthy(addedVariant)
		local applied, applyError = Candidate.Apply(build, candidate)
		assert.is_true(applied, applyError)
		local appliedGroup, appliedOutput = assertLinkedSupportGroup(1, cycloneId, "Weapon 1", claw.id)
		assert.are.equal(addedVariant.gemId, appliedGroup.gemList[addedVariant.gemIndex].gemData.id,
			"the applied support must match the optimizer's selected native claw-socket variant")
		assert.is_true(math.abs(appliedOutput.CombinedDPS - candidate.evaluation.metrics.CombinedDPS)
			<= math.max(1e-7, math.abs(candidate.evaluation.metrics.CombinedDPS) * 1e-8),
			"normal PoB output after Apply must reproduce the exact weapon-linked candidate metric")
		assert.are_not.equal(sourceSkillSetId, build.skillsTab.activeSkillSetId)
		local sourceSet = assert(build.skillsTab.skillSets[sourceSkillSetId])
		assert.are.equal(nightblade.id, sourceSet.socketGroupList[1].gemList[2].gemId,
			"applying a support swap must preserve the original Nightblade seed")
		build.skillsTab:Undo()
		assert.are.equal(sourceSkillSetId, build.skillsTab.activeSkillSetId)
		build.calcsTab:BuildOutput()
		local restoredGroup = build.skillsTab.socketGroupList[1]
		assert.are.equal("Weapon 1", restoredGroup.slot)
		assert.are.equal(cycloneId, restoredGroup.gemList[1].gemId)
		assert.are.equal(nightblade.id, restoredGroup.gemList[2].gemId)
		assert.are.equal(claw.id, build.itemsTab.activeItemSet["Weapon 1"].selItemId)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
			"native Undo must restore the original weapon-linked Nightblade setup")
		newBuild()
	end)

	it("applies a white-socket support in the active weapon-swap link", function()
		newBuild()
		prepareCharacter()
		build.itemsTab.activeItemSet.useSecondWeaponSet = true
		local claw = equipItem("Weapon 1 Swap",
			"Rarity: RARE\nAI Planner Swap White Socket Claw\nGemini Claw\nQuality: 0\nSockets: G-W-R\nImplicits: 0\n")
		build.calcsTab:BuildOutput()
		local cycloneId = "Metadata/Items/Gems/SkillGemCyclone"
		local seed, seedError = SkillSeed.Create(build, cycloneId)
		assert.is_truthy(seed, seedError)
		assert.is_true(seed.linked)
		assert.are.equal("Weapon 1 Swap", seed.socketBinding.slot)
		assert.are.equal(3, seed.socketBinding.linkSocketCount)
		local group = build.skillsTab.socketGroupList[seed.groupIndex]
		assert.are.equal("Weapon 1 Swap", group.slot)
		local linked, socketDetails = SkillCatalog.ValidateSocketGroup(build, seed.groupIndex)
		assert.is_true(linked, type(socketDetails) == "string" and socketDetails or "Cyclone must validate on the active weapon-swap set")
		assert.are.equal(claw.id, socketDetails.itemId)
		assert.are.equal("Claw", build.calcsTab.mainEnv.player.mainSkill.actor.weaponData1.type)

		local activeSlot = group.slot
		group.slot = "Weapon 1"
		local inactiveValid, inactiveReason = SkillCatalog.ValidateSocketGroup(build, seed.groupIndex)
		assert.is_false(inactiveValid)
		assert.is_truthy(inactiveReason:find("inactive weapon set", 1, true))
		group.slot = activeSlot
		build.calcsTab:BuildOutput()

		local sourceSkillSetId = build.skillsTab.activeSkillSetId
		local result, sourceSignature = runSkillsSearch(cycloneId, seed.groupIndex, seed.skillIndex, 24)
		local coverage = result.searchCoverage.phase
		assert.is_true(coverage.generatedSupportAddCandidates > 0)
		assert.is_true(coverage.exactSupportAddEvaluations > 0)
		local candidate = assert(findFeasibleGemCandidate(result, "support_add"),
			"the exact result must retain an addition for the active weapon-swap link")
		local addedVariant
		for _, variant in ipairs(variantsOf(candidate)) do
			if variant.kind == "support_add" then addedVariant = variant; break end
		end
		assert.is_truthy(addedVariant)
		assert.are.equal("W", claw.sockets[addedVariant.gemIndex].color,
			"the selected support addition must occupy the real white socket")
		local applied, applyError = Candidate.Apply(build, candidate)
		assert.is_true(applied, applyError)
		local appliedGroup, appliedOutput = assertLinkedSupportGroup(seed.groupIndex, cycloneId, "Weapon 1 Swap", claw.id)
		assert.are.equal(addedVariant.gemId, appliedGroup.gemList[addedVariant.gemIndex].gemData.id)
		assert.is_true(math.abs(appliedOutput.CombinedDPS - candidate.evaluation.metrics.CombinedDPS)
			<= math.max(1e-7, math.abs(candidate.evaluation.metrics.CombinedDPS) * 1e-8),
			"ordinary PoB output must reproduce the exact white-socket candidate metric")
		build.skillsTab:Undo()
		build.calcsTab:BuildOutput()
		assert.are.equal(sourceSkillSetId, build.skillsTab.activeSkillSetId)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
		assert.are.equal("Weapon 1 Swap", build.skillsTab.socketGroupList[seed.groupIndex].slot)
		assert.are.equal(claw.id, build.itemsTab.activeItemSet["Weapon 1 Swap"].selItemId)
		assert.is_true(build.itemsTab.activeItemSet.useSecondWeaponSet)
		newBuild()
	end)

	it("rejects support additions that would cross a physical split link", function()
		newBuild()
		prepareCharacter()
		local body = equipItem("Body Armour",
			"Rarity: RARE\nAI Planner Split Link Chest\nVaal Regalia\nQuality: 0\nSockets: B R-G-G-G-G\nImplicits: 0\n")
		build.calcsTab:BuildOutput()
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local seed, seedError = SkillSeed.Create(build, fireballId)
		assert.is_truthy(seed, seedError)
		assert.is_true(seed.linked)
		assert.are.equal(1, seed.socketBinding.linkSocketCount,
			"the first group must retain only its real single-socket link")
		assert.are_not.equal(body.sockets[1].group, body.sockets[2].group)
		local linked, socketDetails = SkillCatalog.ValidateSocketGroup(build, seed.groupIndex)
		assert.is_true(linked, type(socketDetails) == "string" and socketDetails or "Fireball's first link must remain valid")
		assert.are.equal(1, socketDetails.socketCount)
		local supportId = build.data.gemForBaseName["added fire damage support"]
		local support = supportId and build.data.gems[supportId]
		assert.is_truthy(support)
		local addAllowed, addReason = SkillCatalog.CanAddSupportAtSlot(build, seed.groupIndex, 2, support)
		assert.is_false(addAllowed)
		assert.is_truthy(addReason:find("not linked", 1, true))

		local result = runSkillsSearch(fireballId, seed.groupIndex, seed.skillIndex, 8)
		local coverage = result.searchCoverage.phase
		assert.are.equal(0, coverage.generatedSupportAddCandidates,
			"support generation must stop at the first socket in another native link group")
		assert.are.equal(0, coverage.exactSupportAddEvaluations,
			"the optimizer must not spend an exact calculation on an illegal cross-link support")
		assert.are.equal(1, #build.skillsTab.socketGroupList[seed.groupIndex].gemList)
		assert.are.equal(body.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)
		newBuild()
	end)

	it("replaces a claw-only support on a two-handed staff and preserves another equipped skill group", function()
		newBuild()
		prepareCharacter()
		local staff = equipItem("Weapon 1",
			"Rarity: RARE\nAI Planner Two-Handed Staff Support\nJudgement Staff\nQuality: 0\nSockets: G-G-R\nImplicits: 0\n")
		local body = equipItem("Body Armour",
			"Rarity: RARE\nAI Planner Multi-Slot Fireball\nVaal Regalia\nQuality: 0\nSockets: B-B\nImplicits: 0\n")
		local cycloneId = "Metadata/Items/Gems/SkillGemCyclone"
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local nightbladeId = build.data.gemForBaseName["nightblade support"]
		local nightblade = nightbladeId and build.data.gems[nightbladeId]
		local nightbladeEffect = nightblade and (nightblade.grantedEffect and nightblade.grantedEffect.support
			and nightblade.grantedEffect or nightblade.secondaryGrantedEffect)
		assert.is_truthy(nightbladeEffect and nightbladeEffect.support)

		build.skillsTab:PasteSocketGroup("Slot: Weapon 1\nCyclone 20/0 1\nNightblade Support 1/0 1\n")
		local weaponGroup = build.skillsTab.socketGroupList[1]
		weaponGroup.gemList[1].gemId = cycloneId
		weaponGroup.gemList[2].gemId = nightblade.id
		build.skillsTab:ProcessSocketGroup(weaponGroup)
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 20/0 1\n")
		local bodyGroup = build.skillsTab.socketGroupList[2]
		bodyGroup.gemList[1].gemId = fireballId
		build.skillsTab:ProcessSocketGroup(bodyGroup)
		build.mainSocketGroup = 1
		weaponGroup.mainActiveSkill = 1
		weaponGroup.includeInFullDPS = true
		bodyGroup.mainActiveSkill = 1
		bodyGroup.includeInFullDPS = true
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local staffBase = assert(build.data.itemBases["Judgement Staff"])
		assert.are.equal("Staff", staffBase.type)
		assert.is_true(staffBase.tags.two_hand_weapon)
		local linkedWeapon, weaponSockets = SkillCatalog.ValidateSocketGroup(build, 1)
		assert.is_true(linkedWeapon, type(weaponSockets) == "string" and weaponSockets or "Cyclone and Nightblade must occupy one staff link")
		assert.are.equal(staff.id, weaponSockets.itemId)
		assert.are.equal("Weapon 1", weaponSockets.slot)
		local linkedBody, bodySockets = SkillCatalog.ValidateSocketGroup(build, 2)
		assert.is_true(linkedBody, type(bodySockets) == "string" and bodySockets or "Fireball must remain linked in the chest")
		assert.are.equal(body.id, bodySockets.itemId)
		assert.are.equal("Body Armour", bodySockets.slot)
		local cycloneSkill = assert(build.calcsTab.mainEnv.player.mainSkill)
		assert.are.equal("Staff", cycloneSkill.actor.weaponData1.type)
		assert.is_true(cycloneSkill.skillFlags.disable,
			"PoB's exact weapon calculation must disable a staff attack carrying the claw-only Nightblade restriction")
		assert.are.equal("No usable weapon equipped", cycloneSkill.disableReason)

		local baseline = build.calcsTab.mainOutput.CombinedDPS
		local sourceSkillSetId = build.skillsTab.activeSkillSetId
		local result = runSkillsSearch(cycloneId, 1, 1, 32)
		local coverage = result.searchCoverage.phase
		assert.is_true(coverage.generatedSupportSwapCandidates > 0)
		assert.is_true(coverage.exactSupportSwapEvaluations > 0)
		assert.is_true(coverage.compatibleSupportSwapEvaluations > 0)
		local candidate = assert(findFeasibleGemCandidate(result, "support_swap"),
			"the exact search must retain a compatible replacement for the weapon-restricted support")
		assert.is_true(candidate.evaluation.metrics.CombinedDPS > baseline)
		local replacement
		for _, variant in ipairs(variantsOf(candidate)) do
			if variant.kind == "support_swap" and variant.groupIndex == 1 then replacement = variant; break end
		end
		assert.is_truthy(replacement)
		assert.are_not.equal(nightblade.id, replacement.gemId)

		local applied, applyError = Candidate.Apply(build, candidate)
		assert.is_true(applied, applyError)
		local appliedWeaponGroup, appliedOutput = assertLinkedSupportGroup(1, cycloneId, "Weapon 1", staff.id)
		assert.are_not.equal(nightblade.id, appliedWeaponGroup.gemList[2].gemData.id)
		local appliedBodyGroup = assert(build.skillsTab.socketGroupList[2])
		assert.are.equal("Body Armour", appliedBodyGroup.slot)
		assert.are.equal(fireballId, appliedBodyGroup.gemList[1].gemData.id,
			"applying a weapon-group support change must preserve the second equipped skill group")
		assert.are.equal(body.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)
		local bodyStillLinked, bodyAfterApply = SkillCatalog.ValidateSocketGroup(build, 2)
		assert.is_true(bodyStillLinked, type(bodyAfterApply) == "string" and bodyAfterApply or "the secondary group must remain natively linked after Apply")
		assert.are.equal(body.id, bodyAfterApply.itemId)
		local _, fullDpsOutput = require("Modules.Calcs").getMiscCalculator(build)
		assert.is_false(fullDpsOutput.FullDPSActivityTruncated,
			"the exact Full DPS audit must retain all active skill groups in this fixture")
	local sawCyclone, sawFireball = false, false
	local activityDebug = { }
	for _, activity in ipairs(fullDpsOutput.FullDPSActivity or { }) do
		activityDebug[#activityDebug + 1] = table.concat({ tostring(activity.name), tostring(activity.group), tostring(activity.identity) }, " | ")
		if activity.name == "Cyclone" then sawCyclone = true end
		if activity.name == "Fireball" then sawFireball = true end
	end
	assert.is_true(sawCyclone, "Full DPS activity must identify the optimized weapon skill; got: " .. table.concat(activityDebug, "; "))
	assert.is_true(sawFireball, "Full DPS activity must retain the other equipped skill group")
		assert.is_true(math.abs(appliedOutput.CombinedDPS - candidate.evaluation.metrics.CombinedDPS)
			<= math.max(1e-7, math.abs(candidate.evaluation.metrics.CombinedDPS) * 1e-8),
			"normal PoB output across both equipped groups must reproduce the exact candidate metric")
		build.skillsTab:Undo()
		build.calcsTab:BuildOutput()
		assert.are.equal(sourceSkillSetId, build.skillsTab.activeSkillSetId)
		assert.are.equal(staff.id, build.itemsTab.activeItemSet["Weapon 1"].selItemId)
		assert.are.equal(body.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)
		local restoredWeaponGroup = build.skillsTab.socketGroupList[1]
		assert.are.equal("Weapon 1", restoredWeaponGroup.slot)
		assert.are.equal(2, #restoredWeaponGroup.gemList)
		assert.are.equal(cycloneId, restoredWeaponGroup.gemList[1].gemData.id)
		assert.are.equal(20, restoredWeaponGroup.gemList[1].level)
		assert.are.equal(nightblade.id, restoredWeaponGroup.gemList[2].gemData.id)
		assert.are.equal(1, restoredWeaponGroup.gemList[2].level)
		local restoredBodyGroup = build.skillsTab.socketGroupList[2]
		assert.are.equal("Body Armour", restoredBodyGroup.slot)
		assert.are.equal(1, #restoredBodyGroup.gemList)
		assert.are.equal(fireballId, restoredBodyGroup.gemList[1].gemData.id)
		assert.are.equal(20, restoredBodyGroup.gemList[1].level)
		newBuild()
	end)

	it("calculates weapon-restricted Shockwave on a real two-handed staff and preserves the body link", function()
		newBuild()
		prepareCharacter()
		local staff = equipItem("Weapon 1",
			"Rarity: RARE\nAI Planner Melee Staff Link\nJudgement Staff\nQuality: 0\nSockets: R-R-G-B\nImplicits: 0\n")
		local body = equipItem("Body Armour",
			"Rarity: RARE\nAI Planner Melee Secondary Link\nVaal Regalia\nQuality: 0\nSockets: B-B\nImplicits: 0\n")
		local groundSlamId = "Metadata/Items/Gems/SkillGemGroundSlam"
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local shockwaveId = assert(build.data.gemForBaseName["shockwave support"])
		local shockwave = assert(build.data.gems[shockwaveId])
		local shockwaveEffect = shockwave.grantedEffect and shockwave.grantedEffect.support
			and shockwave.grantedEffect or shockwave.secondaryGrantedEffect
		assert.is_truthy(shockwaveEffect and shockwaveEffect.support)
		assert.is_truthy(shockwaveEffect.weaponTypes and shockwaveEffect.weaponTypes.Staff,
			"PoB must declare the native staff restriction for Shockwave Support")

		build.skillsTab:PasteSocketGroup("Slot: Weapon 1\nGround Slam 20/0 1\nShockwave Support 1/0 1\n")
		local weaponGroup = build.skillsTab.socketGroupList[1]
		weaponGroup.gemList[1].gemId = groundSlamId
		weaponGroup.gemList[2].gemId = shockwaveId
		build.skillsTab:ProcessSocketGroup(weaponGroup)
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 20/0 1\n")
		local bodyGroup = build.skillsTab.socketGroupList[2]
		bodyGroup.gemList[1].gemId = fireballId
		build.skillsTab:ProcessSocketGroup(bodyGroup)
		build.mainSocketGroup = 1
		weaponGroup.mainActiveSkill, weaponGroup.includeInFullDPS = 1, true
		bodyGroup.mainActiveSkill, bodyGroup.includeInFullDPS = 1, true
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local staffBase = assert(build.data.itemBases["Judgement Staff"])
		assert.is_true(staffBase.tags.two_hand_weapon)
		local linkedWeapon, weaponSockets = SkillCatalog.ValidateSocketGroup(build, 1)
		assert.is_true(linkedWeapon, type(weaponSockets) == "string" and weaponSockets or "Ground Slam and Shockwave must occupy the native staff link")
		assert.are.equal(staff.id, weaponSockets.itemId)
		local linkedBody, bodySockets = SkillCatalog.ValidateSocketGroup(build, 2)
		assert.is_true(linkedBody, type(bodySockets) == "string" and bodySockets or "the secondary Fireball group must remain linked")
		assert.are.equal(body.id, bodySockets.itemId)
		local mainSkill = assert(build.calcsTab.mainEnv.player.mainSkill)
		assert.are.equal("Staff", mainSkill.actor.weaponData1.type)
		assert.falsy(mainSkill.skillFlags.disable,
			"the exact PoB model must leave Ground Slam enabled with Shockwave on a staff")
		local supportApplied = false
		for _, effect in ipairs(mainSkill.effectList or { }) do
			if effect.srcInstance == weaponGroup.gemList[2] and effect.grantedEffect.id == shockwaveEffect.id then
				supportApplied = true
			end
		end
		assert.is_true(supportApplied, "PoB must apply staff-compatible Shockwave to Ground Slam")
		local fullDpsCalc, fullDpsOutput = require("Modules.Calcs").getMiscCalculator(build)
		assert.is_truthy(fullDpsCalc)
		assert.is_true(fullDpsOutput.FullDPS > 0)
		local sawGroundSlam, sawFireball = false, false
		for _, activity in ipairs(fullDpsOutput.FullDPSActivity or { }) do
			if activity.name == "Ground Slam" and activity.group == weaponGroup.label then sawGroundSlam = true end
			if activity.name == "Fireball" and activity.group == bodyGroup.label then sawFireball = true end
		end
		assert.is_true(sawGroundSlam, "Full DPS must retain the staff skill group")
		assert.is_true(sawFireball, "Full DPS must retain the other equipped skill group")
		assert.are.equal(staff.id, build.itemsTab.activeItemSet["Weapon 1"].selItemId)
		assert.are.equal(body.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)
		newBuild()
	end)

	it("calculates bow-restricted Mirage Archer on a real bow and preserves the body link", function()
		newBuild()
		prepareCharacter()
		local bow = equipItem("Weapon 1",
			"Rarity: RARE\nAI Planner Mirage Archer Bow Link\nThicket Bow\nQuality: 0\nSockets: G-G-B\nImplicits: 0\n")
		local body = equipItem("Body Armour",
			"Rarity: RARE\nAI Planner Mirage Archer Secondary Link\nVaal Regalia\nQuality: 0\nSockets: B-B\nImplicits: 0\n")
		local lightningArrowId = "Metadata/Items/Gems/SkillGemLightningArrow"
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local mirageArcherId = assert(build.data.gemForBaseName["mirage archer support"])
		local mirageArcher = assert(build.data.gems[mirageArcherId])
		local mirageArcherEffect = mirageArcher.grantedEffect and mirageArcher.grantedEffect.support
			and mirageArcher.grantedEffect or mirageArcher.secondaryGrantedEffect
		assert.is_truthy(mirageArcherEffect and mirageArcherEffect.support)
		assert.is_truthy(mirageArcherEffect.stats and table.concat(mirageArcherEffect.stats, ","):find("disable_skill_if_weapon_not_bow"),
			"PoB must declare the native bow gate for Mirage Archer Support")

		build.skillsTab:PasteSocketGroup("Slot: Weapon 1\nLightning Arrow 20/0 1\nMirage Archer Support 1/0 1\n")
		local weaponGroup = build.skillsTab.socketGroupList[1]
		weaponGroup.gemList[1].gemId = lightningArrowId
		weaponGroup.gemList[2].gemId = mirageArcherId
		build.skillsTab:ProcessSocketGroup(weaponGroup)
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 20/0 1\n")
		local bodyGroup = build.skillsTab.socketGroupList[2]
		bodyGroup.gemList[1].gemId = fireballId
		build.skillsTab:ProcessSocketGroup(bodyGroup)
		build.mainSocketGroup = 1
		weaponGroup.mainActiveSkill, weaponGroup.includeInFullDPS = 1, true
		bodyGroup.mainActiveSkill, bodyGroup.includeInFullDPS = 1, true
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local bowBase = assert(build.data.itemBases["Thicket Bow"])
		assert.are.equal("Bow", bowBase.type)
		assert.is_true(bowBase.tags.two_hand_weapon)
		local linkedWeapon, weaponSockets = SkillCatalog.ValidateSocketGroup(build, 1)
		assert.is_true(linkedWeapon, type(weaponSockets) == "string" and weaponSockets or "Lightning Arrow and Mirage Archer must occupy the native bow link")
		assert.are.equal(bow.id, weaponSockets.itemId)
		local linkedBody, bodySockets = SkillCatalog.ValidateSocketGroup(build, 2)
		assert.is_true(linkedBody, type(bodySockets) == "string" and bodySockets or "the secondary Fireball group must remain linked")
		assert.are.equal(body.id, bodySockets.itemId)
		local mainSkill = assert(build.calcsTab.mainEnv.player.mainSkill)
		assert.are.equal("Bow", mainSkill.actor.weaponData1.type)
		assert.falsy(mainSkill.skillFlags.disable,
			"the exact PoB model must leave Lightning Arrow enabled with Mirage Archer on a bow")
		local supportApplied = false
		for _, effect in ipairs(mainSkill.effectList or { }) do
			if effect.srcInstance == weaponGroup.gemList[2] and effect.grantedEffect.id == mirageArcherEffect.id then
				supportApplied = true
			end
		end
		assert.is_true(supportApplied, "PoB must apply bow-gated Mirage Archer to Lightning Arrow")
		local fullDpsCalc, fullDpsOutput = require("Modules.Calcs").getMiscCalculator(build)
		assert.is_truthy(fullDpsCalc)
		assert.is_true(fullDpsOutput.FullDPS > 0)
		local sawLightningArrow, sawFireball = false, false
		for _, activity in ipairs(fullDpsOutput.FullDPSActivity or { }) do
			if activity.name == "Lightning Arrow" and activity.group == weaponGroup.label then sawLightningArrow = true end
			if activity.name == "Fireball" and activity.group == bodyGroup.label then sawFireball = true end
		end
		assert.is_true(sawLightningArrow, "Full DPS must retain the bow skill group")
		assert.is_true(sawFireball, "Full DPS must retain the other equipped skill group")
		assert.are.equal(bow.id, build.itemsTab.activeItemSet["Weapon 1"].selItemId)
		assert.are.equal(body.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)
		newBuild()
	end)

	it("rejects gear that breaks a secondary Full DPS link and revalidates every group on Apply", function()
		newBuild()
		prepareCharacter()
		local arcId = "Metadata/Items/Gems/SkillGemArc"
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local addedColdId = assert(build.data.gemForBaseName["added cold damage support"])
		local addedCold = assert(build.data.gems[addedColdId])
		local addedColdEffect = addedCold.grantedEffect
		local socketColor = ({ [1] = "R", [2] = "G", [3] = "B", [4] = "W" })[addedColdEffect.color]
			or tostring(addedColdEffect.color or "W")
		local bodySockets = "B-" .. socketColor
		local staff = equipItem("Weapon 1",
			"Rarity: RARE\nAI Planner Arc Main Link\nJudgement Staff\nQuality: 0\nSockets: B\nImplicits: 0\n")
		local body = equipItem("Body Armour",
			"Rarity: RARE\nAI Planner Secondary Full DPS Link\nVaal Regalia\nQuality: 0\nSockets: " .. bodySockets .. "\nImplicits: 0\n")
		build.skillsTab:PasteSocketGroup("Slot: Weapon 1\nArc 20/0 1\n")
		local arcGroup = build.skillsTab.socketGroupList[1]
		arcGroup.gemList[1].gemId = arcId
		arcGroup.gemList[1].skillId = build.data.gems[arcId].grantedEffectId
		arcGroup.includeInFullDPS = true
		build.skillsTab:ProcessSocketGroup(arcGroup)
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 20/0 1\nAdded Cold Damage 20/0 1\n")
		local bodyGroup = build.skillsTab.socketGroupList[2]
		bodyGroup.gemList[1].gemId = fireballId
		bodyGroup.gemList[1].skillId = build.data.gems[fireballId].grantedEffectId
		bodyGroup.gemList[2].gemId = addedColdId
		bodyGroup.gemList[2].skillId = addedCold.grantedEffectId
		bodyGroup.gemList[2].nameSpec = addedCold.name
		bodyGroup.includeInFullDPS = true
		build.skillsTab:ProcessSocketGroup(bodyGroup)
		local swapWeapon = equipItem("Weapon 1 Swap",
			"Rarity: RARE\nAI Planner Inactive Weapon Link\nGemini Claw\nQuality: 0\nSockets: B\nImplicits: 0\n")
		build.skillsTab:PasteSocketGroup("Slot: Weapon 1 Swap\nFireball 20/0 1\n")
		local inactiveGroup = build.skillsTab.socketGroupList[3]
		inactiveGroup.gemList[1].gemId = fireballId
		inactiveGroup.gemList[1].skillId = build.data.gems[fireballId].grantedEffectId
		inactiveGroup.includeInFullDPS = true
		build.skillsTab:ProcessSocketGroup(inactiveGroup)
		build.mainSocketGroup = 1
		arcGroup.mainActiveSkill = 1
		arcGroup.mainActiveSkillCalcs = 1
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		assert.are.equal(staff.id, build.itemsTab.activeItemSet["Weapon 1"].selItemId)
		assert.are.equal(body.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)
		assert.are.equal(swapWeapon.id, build.itemsTab.activeItemSet["Weapon 1 Swap"].selItemId)
		assert.is_false(inactiveGroup.slotEnabled,
			"PoB's exact calculation must mark the alternate weapon-set group inactive")
		local allFullDpsGroupsLinked, activeGroupProof = SkillCatalog.ValidateFullDPSSocketGroups(build)
		assert.is_true(allFullDpsGroupsLinked)
		assert.are.equal(2, #activeGroupProof.groups,
			"the full-DPS proof must omit a skill group from the inactive weapon set")
		local secondaryLinked, secondaryProof = SkillCatalog.ValidateSocketGroup(build, 2)
		assert.is_true(secondaryLinked, type(secondaryProof) == "string" and secondaryProof or "the baseline secondary skill must be linked")

		local linkedReplacement = new("Item"):Item(
			"Rarity: RARE\nAI Planner Replacement Linked Body\nVaal Regalia\nQuality: 0\nSockets: " .. bodySockets .. "\nImplicits: 0\n")
		build.itemsTab:AddItem(linkedReplacement, true)
		local brokenReplacement = new("Item"):Item(
			"Rarity: RARE\nAI Planner Replacement Broken Body\nVaal Regalia\nQuality: 0\nSockets: B\nImplicits: 0\n")
		build.itemsTab:AddItem(brokenReplacement, true)
		build.itemsTab:ResetUndo()
		local sourceSignature = Candidate.BuildSignature(build)

		local validResult, validatedSourceSignature = runEquipmentSearch(arcId, 1, 1, 16,
			{ ["Body Armour"] = linkedReplacement.id })
		assert.are.equal(sourceSignature, validatedSourceSignature,
			"the exact equipment search must bind to the same complete active build signature")
		assert.are.equal("feasible", validResult.status,
			validResult.message or "a replacement preserving both Full DPS links must pass the exact gates")
		local candidate = assert(validResult.candidate)
		local proof = assert(candidate.evaluation.skillGroupSockets)
		assert.are.equal("pass", proof.status)
		local expectedFullDpsGroups = 0
		for _, group in ipairs(build.skillsTab.socketGroupList) do
			if not group.source and group.includeInFullDPS == true and group.enabled ~= false and group.slotEnabled ~= false then
				expectedFullDpsGroups = expectedFullDpsGroups + 1
			end
		end
		assert.are.equal(expectedFullDpsGroups, #proof.groups,
			"every enabled manual Full DPS group needs an exact native socket proof")
		assert.are.equal(1, proof.groups[1].groupIndex)
		assert.are.equal(2, proof.groups[2].groupIndex)
		assert.are.equal(linkedReplacement.id, proof.groups[2].group.itemId)
		assert.are.equal(bodyGroup, build.skillsTab.socketGroupList[2], "the isolated search must preserve the active source group")
		assert.are.equal(linkedReplacement.id, candidate.gearVariant.overrides["Body Armour"])

		candidate.evaluation.skillGroupSockets = nil
		local appliedWithoutProof, missingProofError = Candidate.Apply(build, candidate)
		assert.is_false(appliedWithoutProof)
		assert.is_truthy(missingProofError:find("socket/link proofs", 1, true))
		candidate.evaluation.skillGroupSockets = proof
		local applied, applyError = Candidate.Apply(build, candidate)
		assert.is_true(applied, applyError)
		assert.are.equal(linkedReplacement.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)
		local appliedSecondaryLinked, appliedSecondaryProof = SkillCatalog.ValidateSocketGroup(build, 2)
		assert.is_true(appliedSecondaryLinked,
			type(appliedSecondaryProof) == "string" and appliedSecondaryProof or "Apply must preserve the secondary link")
		build.calcsTab:BuildOutput()
		assert.is_true(math.abs(build.calcsTab.mainOutput.CombinedDPS - candidate.evaluation.metrics.CombinedDPS)
			<= math.max(1e-7, math.abs(candidate.evaluation.metrics.CombinedDPS) * 1e-8),
			"the standard PoB calculation after Apply must match the exact candidate output")
		build.itemsTab:Undo()
		build.calcsTab:BuildOutput()
		assert.are.equal(body.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)
		local restoredSignature = Candidate.BuildSignature(build)
		assert.are.equal(sourceSignature, restoredSignature,
			"native Apply/Undo must restore the complete active build, including its linked groups and weapon sets")

		local brokenResult = runEquipmentSearch(arcId, 1, 1, 16, { ["Body Armour"] = brokenReplacement.id })
		assert.are.equal("no_feasible_candidate", brokenResult.status,
			"the exact gate must reject replacement gear that removes the secondary Full DPS link")
		local foundSecondaryViolation = false
		for _, violation in ipairs(brokenResult.bestObservedViolations or { }) do
			if violation.key == "skill_group_socket_link" and violation.groupIndex == 2 then
				foundSecondaryViolation = true
				break
			end
		end
		assert.is_true(foundSecondaryViolation,
			"the rejection report must identify the broken non-main skill group")
		assert.are.equal(body.id, build.itemsTab.activeItemSet["Body Armour"].selItemId,
			"failed exact gear candidates must never change the active PoB equipment")
		newBuild()
	end)
end)
