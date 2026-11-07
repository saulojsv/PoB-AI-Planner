local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local SkillSeed = require("Modules.Optimizer.SkillSeed")

describe("AI Planner starting skill seed", function()
	it("creates an exact, unlinked skill-set variation and keeps the source set reversible", function()
		newBuild()
		build.characterLevel = 1
		build.characterLevelAutoMode = false
		local skillTab = build.skillsTab
		local sourceSetId = skillTab.activeSkillSetId
		local sourceSet = skillTab.skillSets[sourceSetId]
		local sourceSetCount = #skillTab.skillSetOrderList
		assert.are.equal(0, #skillTab.socketGroupList)
		-- PoB skill-set records may carry derived runtime objects with back-references.
		-- Creating a new variation must not recursively walk those objects.
		local cyclicRuntimeReference = { }
		cyclicRuntimeReference.self = cyclicRuntimeReference
		sourceSet.runtimeReference = cyclicRuntimeReference
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local result, seedError = SkillSeed.Create(build, gemId)
		assert.is_truthy(result, seedError)
		assert.is_true(result.created)
		assert.is_false(result.linked)
		assert.are_not.equal(sourceSetId, skillTab.activeSkillSetId)
		assert.are.equal(sourceSetId, skillTab.skillSetOrderList[1])
		assert.are.equal(cyclicRuntimeReference, skillTab.skillSets[result.skillSetId].runtimeReference,
			"the skill-set variation must preserve non-owned runtime references without deep-copy recursion")
		assert.are.equal(0, #skillTab.skillSets[sourceSetId].socketGroupList,
			"creating the seed must preserve the original empty PoB skill set")
		assert.are.equal(skillTab.activeSkillSetId, result.skillSetId)
		assert.are.equal(gemId, result.gemId)
		assert.is_true(result.level >= 1)
		assert.is_nil(skillTab.socketGroupList[result.groupIndex].slot,
			"the seed must not pretend an equipment item or socket exists")
		assert.are.equal(gemId, skillTab.socketGroupList[result.groupIndex].gemList[1].gemData.id)
		assert.are.equal(gemId, skillTab.socketGroupList[result.groupIndex].displaySkillList[result.skillIndex].activeEffect.srcInstance.gemData.id)
		assert.is_true(type(result.metrics.CombinedDPS) == "number")

		local sameGem = SkillCatalog.ResolveTarget(build, result.groupIndex, result.skillIndex, gemId)
		assert.is_truthy(sameGem, "the exact current Main Skill can direct a tree search without a gear item")
		local incompatible, socketError = SkillCatalog.ResolveTarget(build, result.groupIndex, result.skillIndex,
			"Metadata/Items/Gems/SkillGemArc")
		assert.is_nil(incompatible)
		assert.is_truthy(socketError:find("equipment slot", 1, true))

		skillTab:Undo()
		assert.are.equal(sourceSetId, skillTab.activeSkillSetId)
		assert.are.equal(sourceSetCount, #skillTab.skillSetOrderList)
		assert.are.equal(0, #skillTab.socketGroupList)
		newBuild()
	end)

	it("binds a selected gem to an unused, compatible native item link", function()
		newBuild()
		local item = new("Item"):Item("Rarity: RARE\nAI Planner Socket Test\nSage's Robe\nQuality: 0\nSockets: B-B-B\nImplicits: 0\n")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = item.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local result, seedError = SkillSeed.Create(build, "Metadata/Items/Gems/SkillGemFireball")
		assert.is_truthy(result, seedError)
		assert.is_true(result.linked)
		assert.are.equal("Body Armour", result.socketBinding.slot)
		assert.are.equal(1, result.socketBinding.socketIndex)
		assert.are.equal(3, result.socketBinding.linkSocketCount)
		local group = build.skillsTab.socketGroupList[result.groupIndex]
		assert.are.equal("Body Armour", group.slot)
		assert.is_true(group.slotEnabled)
		assert.are.equal(item.id, build.itemsTab.activeItemSet["Body Armour"].selItemId)

		local blueSupport
		for _, gemData in pairs(build.data.gems) do
			if gemData.grantedEffect and gemData.grantedEffect.support and gemData.grantedEffect.color == 3 then
				blueSupport = gemData
				break
			end
		end
		assert.is_truthy(blueSupport, "PoB's loaded data must include a blue support gem")
		local canAddSupport, linkInfo = SkillCatalog.CanAddSupportAtSlot(build, result.groupIndex, 2, blueSupport)
		assert.is_true(canAddSupport, type(linkInfo) == "string" and linkInfo or "a free socket in the same native link should accept this support")
		assert.is_true(linkInfo.linked)
		build.skillsTab:Undo()
		assert.are.equal(0, #build.skillsTab.socketGroupList)
		assert.are.equal(item.id, build.itemsTab.activeItemSet["Body Armour"].selItemId,
			"Undoing the seed must leave the original equipment state intact")
		newBuild()
	end)

	it("keeps the seed unlinked when the equipped item's next socket has the wrong color", function()
		newBuild()
		local item = new("Item"):Item("Rarity: RARE\nAI Planner Socket Test\nSage's Robe\nQuality: 0\nSockets: R-R-R\nImplicits: 0\n")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = item.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local result, seedError = SkillSeed.Create(build, "Metadata/Items/Gems/SkillGemFireball")
		assert.is_truthy(result, seedError)
		assert.is_false(result.linked)
		assert.is_nil(result.socketBinding)
		assert.is_nil(build.skillsTab.socketGroupList[result.groupIndex].slot,
			"the seed must not claim an incompatible equipment socket")
		assert.is_truthy(result.message:find("No unused compatible socket link", 1, true))
		newBuild()
	end)

	it("offers gem creation when Build Direction has no active skill group", function()
		newBuild()
		local tab = build.optimizerTab
		tab:OpenBuildDirection()
		local popup = main.popups[1]
		assert.are.equal("AI Planner — Build Direction", popup.title)
		assert.is_true(popup.controls.targetGem.enabled(), "the loaded PoB gem catalog must remain selectable")
		assert.is_false(popup.controls.notes.enabled, "leveling notes need a selected active skill first")
		assert.is_true(popup.controls.createSeed.enabled)
		local witchClassId
		for classId, class in pairs(build.spec.tree.classes) do
			if class.name == "Witch" then witchClassId = classId break end
		end
		assert.is_truthy(witchClassId)
		popup.controls["class_" .. tostring(witchClassId)].changeFunc()
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		popup.controls.targetGem:SelByValue(gemId, "val")
		popup.controls.createSeed:Click()
		assert.is_nil(main.popups[1], "successful seed creation should return to the AI Planner")
		assert.are.equal(gemId, tab.textValues.targetSkillGemId)
		assert.are.equal(tostring(witchClassId), tab.textValues.baseClassId,
			"the class chosen in Build Direction must be used for the exact seed")
		assert.are.equal("1", tab.textValues.targetSkillGroupIndex)
		assert.are.equal(tostring(build.skillsTab.socketGroupList[1].mainActiveSkill), tab.textValues.targetSkillIndex,
			"Build Direction must retain PoB's native active-effect index for this gem")
		assert.are.equal("tree", tab.textValues.generationPhase)
		assert.is_truthy(tab.statusMessage:find("unlinked seed", 1, true))
		assert.is_truthy(tab.statusMessage:find("source class is unchanged", 1, true))
		assert.is_truthy(build.skillsTab.socketGroupList[1].displaySkillList[1].activeEffect)
		newBuild()
	end)

	it("levels the starting gem against the selected class root when it differs from the active class", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local sourceClassId = build.spec.curClassId
		local sourceResult, sourceError = SkillSeed.Create(build, gemId, sourceClassId)
		assert.is_truthy(sourceResult, sourceError)
		local sourceLevel = sourceResult.level
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local witchClassId
		for classId, class in pairs(build.spec.tree.classes) do
			if class.name == "Witch" then witchClassId = classId break end
		end
		assert.is_truthy(witchClassId)
		assert.are_not.equal(sourceClassId, witchClassId)
		local result, classError = SkillSeed.Create(build, gemId, witchClassId)
		assert.is_truthy(result, classError)
		assert.are.equal(witchClassId, result.baseClassId)
		assert.is_true(result.targetClassMaxGemLevel > sourceLevel,
			"the Witch root's exact Intelligence should allow a higher Fireball level than the active source root")
		assert.is_true(result.level <= sourceLevel,
			"the active seed must remain legal while the source build still uses its original class")
		assert.are.equal(sourceClassId, result.calculationClassId)
		assert.are.equal(gemId,
			build.skillsTab.socketGroupList[result.groupIndex].displaySkillList[result.skillIndex].activeEffect.srcInstance.gemData.id)
		newBuild()
	end)
end)
