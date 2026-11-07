local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local Inputs = require("Modules.Optimizer.Inputs")
local Candidate = require("Modules.Optimizer.Candidate")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local MCPBridge = require("Modules.Optimizer.MCPBridge")

local function gemData(id, name, color)
	local effect = {
		id = name,
		name = name,
		color = color,
		levels = { { levelRequirement = 1 } },
	}
	return {
		id = id,
		name = name,
		variantId = name,
		gameId = id,
		grantedEffectId = name,
		grantedEffect = effect,
		grantedEffectList = { effect },
		tags = { grants_active_skill = true },
		tagString = "Spell",
		naturalMaxLevel = 1,
	}
end

describe("Optimizer selected active-skill gem direction", function()
	it("searches only PoB's loaded active-gem data and reports the stable internal ID", function()
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local arcId = "Metadata/Items/Gems/SkillGemArc"
		local buildMock = {
			data = { gems = {
				[fireballId] = gemData(fireballId, "Fireball", 3),
				[arcId] = gemData(arcId, "Arc", 3),
				["support"] = { id = "support", name = "Support", tags = { support = true }, grantedEffect = { support = true } },
			} },
		}
		local result = assert(SkillCatalog.ListActive(buildMock, "arc", 10))
		assert.are.equal(1, result.count)
		assert.are.equal(arcId, result.gems[1].id)
		assert.are.equal("loaded_pob_gem_database", result.source)
	end)

	it("anchors context to one unambiguous native active gem before display skills resolve", function()
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local arcId = "Metadata/Items/Gems/SkillGemArc"
		local fireball = gemData(fireballId, "Fireball", 3)
		local arc = gemData(arcId, "Arc", 3)
		local fireballInstance = { enabled = true, gemData = fireball }
		local arcInstance = { enabled = true, gemData = arc }
		local buildMock = {
			data = { gems = { [fireballId] = fireball, [arcId] = arc } },
			skillsTab = { socketGroupList = { {
				enabled = true, slotEnabled = true, gemList = { fireballInstance }, displaySkillList = { },
			} } },
		}
		assert.are.equal(fireballId, SkillCatalog.CurrentMainGemId(buildMock, 1, 1),
			"the single enabled active gem is safe to use while PoB is rebuilding display effects")
		buildMock.skillsTab.socketGroupList[1].gemList[2] = arcInstance
		assert.is_nil(SkillCatalog.CurrentMainGemId(buildMock, 1, 1),
			"multiple active gems must not be guessed before PoB resolves the selected effect")
		arcInstance.enabled = false
		assert.are.equal(fireballId, SkillCatalog.CurrentMainGemId(buildMock, 1, 1),
			"disabled active gems do not make the source identity ambiguous")
	end)

	it("reports complete PoE 1 active-effect and support catalog coverage without claiming exact evaluation", function()
		local function supportGem(id, effectId, variantId)
			return {
				id = id, name = "Added Cold Damage", variantId = variantId, gameId = "Support/AddCold",
				grantedEffectId = effectId,
				grantedEffect = { id = effectId, name = "Added Cold Damage", support = true, color = 3, levels = { } },
			}
		end
		local arc = gemData("arc", "Arc", 3)
		local vaal = gemData("vaal-arc", "Vaal Arc", 3)
		vaal.grantedEffectList = {
			vaal.grantedEffect,
			{ id = "VaalArc", name = "Vaal Arc", color = 3 },
		}
		local buildMock = {
			data = { version = "3.29", gems = {
				arc = arc,
				["vaal-arc"] = vaal,
				["added-cold-a"] = supportGem("added-cold-a", "SupportAddedColdDamage", "normal"),
				["added-cold-b"] = supportGem("added-cold-b", "SupportAddedColdDamageVaal", "alternate"),
			} },
			spec = { treeVersion = "3.29" },
		}
		local effects = assert(SkillCatalog.ListActiveEffects(buildMock, "", 20))
		local supports = assert(SkillCatalog.ListSupports(buildMock, "", 1))
		local summary = assert(SkillCatalog.Summary(buildMock))
		assert.are.equal(3, effects.available, "Vaal and normal effects remain distinct in PoB's loaded data")
		assert.are.equal(2, supports.available, "alternate support gem variants sharing a gameId remain visible")
		assert.is_true(supports.truncated)
		assert.are.equal("Path of Exile 1", summary.game)
		assert.are.equal("catalog_only", summary.evaluationStatus)
		assert.is_false(summary.exactEvaluated)
		assert.are.equal(2, summary.counts.activeGemEntries)
		assert.are.equal(2, summary.counts.declaredActiveSkillGemRecords)
		assert.are.equal(2, summary.counts.selectableActiveSkillGemRecords)
		assert.are.equal(0, summary.counts.excludedActiveSkillGemRecords)
		assert.are.equal(3, summary.counts.activeSkillEffects)
		assert.are.equal(2, summary.counts.supportGemVariants)
		assert.are.equal(1, summary.counts.supportGameIds)
		assert.are.equal(2, summary.counts.supportEffects)
		assert.are.equal("3.29", summary.version.dataVersion)
	end)

	it("resolves imported-route evidence to the exact selected effect of a multi-effect gem", function()
		local vaalArcId = "Metadata/Items/Gems/SkillGemVaalArc"
		local alternateArcId = "Metadata/Items/Gems/SkillGemAlternateArc"
		local vaalArc = gemData(vaalArcId, "Vaal Arc", 3)
		local normalEffect = vaalArc.grantedEffect
		local selectedVaalEffect = { id = "VaalArc", name = "Vaal Arc", color = 3 }
		vaalArc.grantedEffectId = "Arc"
		vaalArc.grantedEffectList = { normalEffect, selectedVaalEffect }
		local source = { enabled = true, gemData = vaalArc }
		local buildMock = {
			data = { gems = {
				[vaalArcId] = vaalArc,
				[alternateArcId] = gemData(alternateArcId, "Alternate Arc", 3),
			} },
			skillsTab = { socketGroupList = { {
				enabled = true, slotEnabled = true, gemList = { source },
				displaySkillList = { { activeEffect = { srcInstance = source, grantedEffect = selectedVaalEffect } } },
			} } },
		}

		assert.are.equal("VaalArc", SkillCatalog.ResolveTargetEffectId(buildMock, 1, 1, vaalArcId),
			"an installed gem must retain the exact effect selected in PoB")
		assert.are.equal("Alternate Arc", SkillCatalog.ResolveTargetEffectId(buildMock, 1, 1, alternateArcId),
			"a replacement gem must use the same declared primary effect as ResolveTarget")
	end)

	it("preserves an imported over-levelled source gem for an exact baseline but clamps replacements", function()
		local function leveledGem(id, name, maximumLevel)
			local data = gemData(id, name, 2)
			data.naturalMaxLevel = maximumLevel
			data.grantedEffect.levels = { }
			for level = 1, maximumLevel do
				data.grantedEffect.levels[level] = { levelRequirement = 1 }
			end
			return data
		end
		local sourceId = "Metadata/Items/Gems/SkillGemCycloneAltX"
		local replacementId = "Metadata/Items/Gems/SkillGemReplacementTest"
		local sourceData = leveledGem(sourceId, "Cyclone of Tumult", 20)
		local replacementData = leveledGem(replacementId, "Replacement Attack", 10)
		local source = { enabled = true, gemData = sourceData, level = 21, quality = 23 }
		local group = {
			enabled = true, slotEnabled = true, slot = "Body Armour", mainActiveSkill = 1,
			gemList = { source },
			displaySkillList = { { activeEffect = { srcInstance = source, grantedEffect = sourceData.grantedEffect } } },
		}
		local itemSet = { ["Body Armour"] = { selItemId = 7 } }
		local buildMock = {
			characterLevel = 100,
			data = { gems = { [sourceId] = sourceData, [replacementId] = replacementData } },
			skillsTab = { socketGroupList = { group } },
			itemsTab = {
				activeItemSet = itemSet,
				itemSets = { [1] = itemSet },
				activeItemSetId = 1,
				items = { [7] = { sockets = { { color = "G" } } } },
			},
		}

		local baselineVariant = assert(SkillCatalog.ResolveTarget(buildMock, 1, 1, sourceId))
		assert.are.equal(21, baselineVariant.level, "the source build's loaded over-levelled gem must not be silently downgraded")
		assert.are.equal(23, baselineVariant.quality, "the source build's imported quality must remain exact")

		local replacementVariant = assert(SkillCatalog.ResolveTarget(buildMock, 1, 1, replacementId))
		assert.are.equal(10, replacementVariant.level, "a new gem must stay within its native natural maximum")
		assert.are.equal(0, replacementVariant.quality, "new replacement gems do not inherit source quality")
	end)

	it("rotates a seeded support proposal window through every loaded variant", function()
		local choices = { }
		for index = 0, 79 do
			choices[#choices + 1] = {
				id = string.format("support-%03d", index),
				gem = { id = string.format("support-%03d", index), variantId = string.format("%03d", index) },
				priority = 0,
			}
		end
		local visited = { }
		for seed = 0, 7 do
			local selected, coverage = SkillCatalog.SelectSupportVariants(choices, 10, seed * 10)
			local repeatSelection = assert(SkillCatalog.SelectSupportVariants(choices, 10, seed * 10))
			assert.are.equal(10, #selected)
			assert.are.equal(10, #repeatSelection)
			assert.are.equal(80, coverage.available)
			assert.is_true(coverage.truncated)
			for index, entry in ipairs(selected) do
				assert.are.equal(entry.id, repeatSelection[index].id)
				visited[entry.id] = true
			end
		end
		local visitedCount = 0
		for _ in pairs(visited) do visitedCount = visitedCount + 1 end
		assert.are.equal(80, visitedCount, "changing a reproducible search seed must reach the full support pool")
		local priorityChoices = { }
		for index = 1, 4 do priorityChoices[#priorityChoices + 1] = { id = "compatible-" .. index, priority = 0 } end
		for index = 1, 4 do priorityChoices[#priorityChoices + 1] = { id = "unsupported-" .. index, priority = 2 } end
		local prioritized = assert(SkillCatalog.SelectSupportVariants(priorityChoices, 3, 7))
		for _, choice in ipairs(prioritized) do
			assert.are.equal(0, choice.priority, "native-compatible supports must fill the budget before lower-priority choices")
		end
	end)

	it("prioritizes support metadata matching the selected damage focus without claiming compatibility", function()
		local addedFire = { name = "Added Fire Damage Support", tagString = "Fire, Attack", grantedEffect = { name = "Added Fire Damage" } }
		local addedCold = { name = "Added Cold Damage Support", tagString = "Cold, Attack", grantedEffect = { name = "Added Cold Damage" } }
		assert.are.equal(0, SkillCatalog.SupportFocusPenalty(addedFire, "Fire"))
		assert.are.equal(1, SkillCatalog.SupportFocusPenalty(addedCold, "Fire"))
		assert.are.equal(0, SkillCatalog.SupportFocusPenalty(addedCold, "Cold"))
		assert.are.equal(0, SkillCatalog.SupportFocusPenalty(addedCold, "Auto"),
			"Auto keeps the existing deterministic selection order")
	end)

	it("fails closed when the requested gem color does not match the selected PoB item socket", function()
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local arcId = "Metadata/Items/Gems/SkillGemArc"
		local fireball = gemData(fireballId, "Fireball", 3)
		local source = { enabled = true, gemData = fireball, level = 1, quality = 0 }
		local buildMock = {
			characterLevel = 10,
			data = { gems = { [fireballId] = fireball, [arcId] = gemData(arcId, "Arc", 3) } },
			skillsTab = { socketGroupList = { {
				enabled = true, slotEnabled = true, slot = "Body Armour", mainActiveSkill = 1,
				gemList = { source },
				displaySkillList = { { activeEffect = { srcInstance = source, grantedEffect = fireball.grantedEffect } } },
			} } },
			itemsTab = {
				activeItemSet = { ["Body Armour"] = { selItemId = 1 } },
				items = { [1] = { sockets = { { color = "R" } } } },
			},
		}
		local variant, err = SkillCatalog.ResolveTarget(buildMock, 1, 1, arcId)
		assert.is_nil(variant)
		assert.is_truthy(err:find("needs a B socket", 1, true))
	end)

	it("validates every gem against one native socket link and its PoB color", function()
		local activeId, supportId = "native-active", "native-support"
		local active = { id = activeId, name = "Arc", grantedEffect = { color = 3 } }
		local support = { id = supportId, name = "Added Cold Damage", grantedEffect = { color = 3, support = true } }
		local group = {
			enabled = true,
			slotEnabled = true,
			slot = "Body Armour",
			gemList = {
				{ gemId = activeId, gemData = active, grantedEffect = active.grantedEffect },
				{ gemId = supportId, gemData = support, grantedEffect = support.grantedEffect },
			},
		}
		local sockets = { { color = "B", group = 0 }, { color = "B", group = 0 } }
		local itemSet = { ["Body Armour"] = { selItemId = 7 } }
		local buildMock = {
			skillsTab = { socketGroupList = { group } },
			data = { gems = { [activeId] = active, [supportId] = support } },
			itemsTab = {
				activeItemSet = itemSet,
				itemSets = { [1] = itemSet },
				activeItemSetId = 1,
				slots = { ["Body Armour"] = { } },
				items = { [7] = { sockets = sockets } },
			},
		}
		local valid, details = SkillCatalog.ValidateSocketGroup(buildMock, 1)
		assert.is_true(valid)
		assert.are.equal(2, details.socketCount)
		assert.are.equal(0, details.linkGroup)

		sockets[2].group = 1
		local splitLink, linkError = SkillCatalog.ValidateSocketGroup(buildMock, 1)
		assert.is_false(splitLink)
		assert.is_truthy(linkError:find("span more than one native item link", 1, true))

		sockets[2].group = 0
		sockets[2].color = "R"
		local wrongColor, colorError = SkillCatalog.ValidateSocketGroup(buildMock, 1)
		assert.is_false(wrongColor)
		assert.is_truthy(colorError:find("needs a B socket", 1, true))
	end)

	it("validates an item-granted skill against its exact active PoB item source", function()
		local source = "Item:7:Granted Skill Item"
		local item = {
			id = 7,
			name = "Granted Skill Item",
			modSource = source,
			grantedSkills = { { source = source, skillId = "GrantedSkill" } },
		}
		local itemSet = { ["Body Armour"] = { selItemId = 7 } }
		local group = {
			enabled = true,
			slotEnabled = true,
			slot = "Body Armour",
			source = source,
			gemList = { { skillId = "GrantedSkill", fromItem = true } },
		}
		local buildMock = {
			skillsTab = { socketGroupList = { group } },
			itemsTab = {
				activeItemSet = itemSet,
				slots = { ["Body Armour"] = { } },
				items = { [7] = item },
			},
		}
		local valid, details = SkillCatalog.ValidateSocketGroup(buildMock, 1)
		assert.is_true(valid)
		assert.are.equal("granted_skill", details.status)
		assert.are.equal("item", details.sourceKind)
		assert.are.equal("Body Armour", details.slot)
		assert.are.equal(7, details.itemId)

		itemSet["Body Armour"].selItemId = 8
		local mismatched, mismatchError = SkillCatalog.ValidateSocketGroup(buildMock, 1)
		assert.is_false(mismatched)
		assert.is_truthy(mismatchError:find("not the item currently equipped", 1, true))

		itemSet["Body Armour"].selItemId = 7
		item.grantedSkills = { { source = source, skillId = "DifferentSkill" } }
		local stale, staleError = SkillCatalog.ValidateSocketGroup(buildMock, 1)
		assert.is_false(stale)
		assert.is_truthy(staleError:find("does not grant the skill recorded", 1, true))
	end)

	it("disables stale item-granted groups without shifting native group indices", function()
		local source = "Item:7:Granted Skill Item"
		local originalGroup = {
			enabled = true,
			source = source,
			slot = "Body Armour",
			sourceItem = { id = 7, modSource = source },
			gemList = { { skillId = "GrantedSkill", enabled = true } },
			displaySkillList = { { skillId = "GrantedSkill" } },
		}
		local candidateGroup = {
			enabled = true,
			source = source,
			slot = "Body Armour",
			sourceItem = { id = 7, modSource = source },
			gemList = { { skillId = "GrantedSkill", enabled = true } },
			displaySkillList = { { skillId = "GrantedSkill" } },
		}
		local updateCount = 0
		local candidateSkills = {
			socketGroupList = { candidateGroup },
			ProcessSocketGroup = function() end,
			UpdateSocketGroups = function() updateCount = updateCount + 1 end,
		}
		local candidateBuild = { skillsTab = candidateSkills }
		local reconciled = assert(SkillCatalog.ReconcileGrantedSkillGroups(candidateBuild, {
			grantedSkills = { }, explodeSources = { },
		}))
		assert.is_true(reconciled.changed)
		assert.are.equal(1, reconciled.disabled)
		assert.are.equal(candidateGroup, candidateSkills.socketGroupList[1])
		assert.is_false(candidateGroup.enabled)
		assert.are.equal(0, #candidateGroup.gemList)
		assert.is_true(originalGroup.enabled)
		assert.are.equal("GrantedSkill", originalGroup.gemList[1].skillId)
		local stable = assert(SkillCatalog.ReconcileGrantedSkillGroups(candidateBuild, {
			grantedSkills = { }, explodeSources = { },
		}))
		assert.is_false(stable.changed)
		assert.are.equal(1, updateCount)
	end)

	it("adds newly granted item skills and stabilizes across a fresh native environment", function()
		local oldSource = "Item:7:Old Skill Item"
		local newSource = "Item:8:New Skill Item"
		local staleGroup = {
			enabled = true, source = oldSource, slot = "Weapon 1",
			sourceItem = { id = 7, modSource = oldSource },
			gemList = { { skillId = "OldSkill", enabled = true } },
			displaySkillList = { { skillId = "OldSkill" } },
		}
		local candidateSkills = {
			socketGroupList = { staleGroup },
			ProcessSocketGroup = function(_, group)
				group.processed = (group.processed or 0) + 1
			end,
			UpdateSocketGroups = function() end,
		}
		local candidateBuild = {
			skillsTab = candidateSkills,
			data = { skills = { NewSkill = { levels = { [1] = { } } } } },
		}
		local function freshGrant()
			local item = { id = 8, modSource = newSource }
			return { source = newSource, slotName = "Weapon 1", skillId = "NewSkill",
				nameSpec = "New Skill", level = 1, sourceItem = item }
		end
		local first = assert(SkillCatalog.ReconcileGrantedSkillGroups(candidateBuild, {
			grantedSkills = { freshGrant() }, explodeSources = { },
		}))
		assert.is_true(first.changed)
		assert.are.equal(1, first.added)
		assert.is_false(staleGroup.enabled)
		assert.are.equal(2, #candidateSkills.socketGroupList)
		local newGroup = candidateSkills.socketGroupList[2]
		assert.is_true(newGroup.enabled)
		assert.are.equal(newSource, newGroup.source)
		assert.are.equal("NewSkill", newGroup.gemList[1].skillId)
		assert.is_nil(newGroup.includeInFullDPS)
		local second = assert(SkillCatalog.ReconcileGrantedSkillGroups(candidateBuild, {
			grantedSkills = { freshGrant() }, explodeSources = { },
		}))
		assert.is_false(second.changed)
		assert.are.equal(2, #candidateSkills.socketGroupList)
	end)

	it("validates tree-granted skills only from the allocated source node", function()
		local source = "Tree:123"
		local group = {
			enabled = true,
			slotEnabled = true,
			source = source,
			gemList = { { skillId = "GrantedSkill" } },
		}
		local node = { grantedSkills = { { source = source, skillId = "GrantedSkill" } } }
		local buildMock = {
			skillsTab = { socketGroupList = { group } },
			spec = { allocNodes = { [123] = node } },
		}
		local valid, details = SkillCatalog.ValidateSocketGroup(buildMock, 1)
		assert.is_true(valid)
		assert.are.equal("tree", details.sourceKind)

		buildMock.spec.allocNodes[123] = nil
		local unallocated, unallocatedError = SkillCatalog.ValidateSocketGroup(buildMock, 1)
		assert.is_false(unallocated)
		assert.is_truthy(unallocatedError:find("source node is not allocated", 1, true))
	end)

	it("rejects an item source that is missing its active item slot", function()
		local group = {
			enabled = true,
			slotEnabled = true,
			source = "Item:7:Granted Skill Item",
			gemList = { { skillId = "GrantedSkill" } },
		}
		local valid, err = SkillCatalog.ValidateSocketGroup({ skillsTab = { socketGroupList = { group } } }, 1)
		assert.is_false(valid)
		assert.is_truthy(err:find("invalid or unavailable native slot", 1, true))
	end)

	it("parses a target gem only with the active PoB group and skill indexes", function()
		local arcId = "Metadata/Items/Gems/SkillGemArc"
		local parsed = assert(Inputs.Parse({
			targetSkillGroupIndex = "2",
			targetSkillIndex = "1",
			targetSkillGemId = arcId,
		}))
		assert.are.equal(arcId, parsed.search.targetSkillGemId)
		assert.are.equal(2, parsed.search.targetSkillGroupIndex)
		assert.are.equal(1, parsed.search.targetSkillIndex)
		assert.is_nil(Inputs.Parse({ targetSkillGemId = arcId }))
		assert.is_nil(Inputs.Parse({ targetSkillGroupIndex = "1", targetSkillIndex = "1", targetSkillGemId = "Arc\n" }))
	end)

	it("reports the exact gem level requirement when a saved target is too high for the character", function()
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local eviscerateId = "Metadata/Items/Gems/SkillGemEviscerate"
		local fireball = gemData(fireballId, "Fireball", 3)
		local eviscerate = gemData(eviscerateId, "Eviscerate", 1)
		eviscerate.grantedEffect.levels = { { levelRequirement = 28 } }
		local source = { enabled = true, gemData = fireball, level = 1, quality = 0 }
		local buildMock = {
			characterLevel = 1,
			data = { gems = { [fireballId] = fireball, [eviscerateId] = eviscerate } },
			skillsTab = { socketGroupList = { {
				enabled = true, slotEnabled = true, slot = "", mainActiveSkill = 1,
				gemList = { source },
				displaySkillList = { { activeEffect = { srcInstance = source, grantedEffect = fireball.grantedEffect } } },
			} } },
		}
		local variant, err = SkillCatalog.ResolveTarget(buildMock, 1, 1, eviscerateId, { allowUnlinkedPlanning = true })
		assert.is_nil(variant)
		assert.are.equal("Eviscerate requires character level 28; the active PoB character is level 1", err)
	end)

	it("exact-calculates a selected native gem in isolation and applies it as a reversible PoB skill set", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local bodyArmour = new("Item"):Item("Optimizer Gem Direction Test\nVaal Regalia\nQuality: 0\nSockets: B-B-B-B-B-B\nImplicits: 0\n")
		build.itemsTab:AddItem(bodyArmour, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = bodyArmour.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(bodyArmour.id)
		build.itemsTab:PopulateSlots()
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 1/0  1\n")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		local config = build.configTab.configSets[build.configTab.activeConfigSetId]
		config.customModsList[1].text = "Regenerate 100 Mana per second"
		config.customModsList[#config.customModsList + 1] = { text = "+200 to all Attributes" }
		build.configTab:BuildModList()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		local gemCatalog = assert(MCPBridge:CallLocal("list_optimizer_skill_gems", {
			query = "Arc", limit = 10, groupIndex = 1, skillIndex = 1,
		}))
		local compatibleArc
		for _, gem in ipairs(gemCatalog.gems) do
			if gem.id == "Metadata/Items/Gems/SkillGemArc" then compatibleArc = gem break end
		end
		assert.is_truthy(compatibleArc)
		assert.is_true(compatibleArc.socketCompatible, compatibleArc.socketReason)

		local sourceSkillSetId = build.skillsTab.activeSkillSetId
		local sourceSkillSetCount = #build.skillsTab.skillSetOrderList
		local sourceSignature = Candidate.BuildSignature(build)
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local arcId = "Metadata/Items/Gems/SkillGemArc"
		local parsed = assert(Inputs.Parse({
			generationPhase = "skills",
			objectiveMetric = "CombinedDPS",
			targetSkillGroupIndex = "1",
			targetSkillIndex = "1",
			targetSkillGemId = arcId,
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			evaluationBudget = "8",
			seed = "1",
		}))
		local valid, validationError = Inputs.ValidateBuild(build, parsed)
		assert.is_true(valid, validationError)

		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		while job.status == "running" do job:Step() end
		local failureDetails = job.error or (job.result and job.result.message) or "exact PoB search did not find a feasible selected-gem candidate"
		for _, violation in ipairs(job.result and job.result.bestObservedViolations or { }) do
			failureDetails = failureDetails .. "; " .. tostring(violation.label or violation.key) .. ": " .. tostring(violation.reason or violation.deficit)
		end
		assert.are.equal("feasible", job.status, failureDetails)
		assert.is_truthy(job.result.candidate)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "phantom evaluation must not mutate the active build")
		build.optimizerTab.textValues.generationPhase = "skills"
		local applied, applyMessage = build.optimizerTab:ApplyCandidate(job.result.candidate)
		assert.is_true(applied, applyMessage)
		assert.are.equal("skills", build.optimizerTab.textValues.generationPhase,
			"the Skills checkpoint must remain selected until the user confirms the next phase")
		local phasePrompt = main.popups[1]
		assert.are.equal("AI Planner — Skills checkpoint", phasePrompt.title)
		phasePrompt.controls.yes:Click()
		assert.are.equal("equipment", build.optimizerTab.textValues.generationPhase,
			"confirming the exact Skills checkpoint should select Equipment")
		assert.are.equal(sourceSkillSetCount + 1, #build.skillsTab.skillSetOrderList)
		assert.are_not.equal(sourceSkillSetId, build.skillsTab.activeSkillSetId)
		assert.are.equal(fireballId, build.skillsTab.skillSets[sourceSkillSetId].socketGroupList[1].gemList[1].gemId)
		assert.are.equal(arcId, build.skillsTab.socketGroupList[1].gemList[1].gemId)
		assert.are.equal(1, build.mainSocketGroup)
		build.calcsTab:BuildOutput()
		local selected = build.skillsTab.socketGroupList[1].displaySkillList[build.skillsTab.socketGroupList[1].mainActiveSkill]
		assert.are.equal(arcId, selected.activeEffect.srcInstance.gemData.id)
	end)

	it("runs the complete Tree to Skills to Equipment workflow through exact PoB calculations", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local bodyArmour = new("Item"):Item("Optimizer Phase Workflow Test\nVaal Regalia\nQuality: 0\nSockets: B-B-B-B-B-B\nImplicits: 0\n")
		build.itemsTab:AddItem(bodyArmour, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = bodyArmour.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(bodyArmour.id)
		build.itemsTab:PopulateSlots()
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 1/0  1\n")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		local config = build.configTab.configSets[build.configTab.activeConfigSetId]
		config.customModsList[1].text = "Regenerate 100 Mana per second"
		config.customModsList[#config.customModsList + 1] = { text = "+200 to all Attributes" }
		build.configTab:BuildModList()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local tab = build.optimizerTab
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local arcId = "Metadata/Items/Gems/SkillGemArc"
		local classStart = build.spec.nodes[build.spec.curClass.startNodeId]
		local treeTarget
		for _, node in ipairs(classStart.linked or { }) do
			if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not node.ascendancyName
				and node.type ~= "Mastery" and node.type ~= "Socket" and not node.isProxy
				and not node.isMultipleChoiceOption and not node.isTattoo then
				treeTarget = node
				break
			end
		end
		assert.is_truthy(treeTarget, "the selected native class start must have a direct allocatable tree neighbor")
		local function exactPhase(phase, gemId, budget)
			local matrix = {
				generationPhase = phase,
				objectiveMetric = "CombinedDPS",
				baseClassId = tostring(build.spec.curClassId),
				targetSkillGroupIndex = "1",
				targetSkillIndex = "1",
				targetSkillGemId = gemId,
				maxAddedPoints = phase == "tree" and "1" or "0",
				maxTotalPoints = "120",
				evaluationBudget = tostring(budget),
				seed = "1",
				searchStoredItems = "false",
				searchSyntheticGear = "false",
			}
		if phase == "tree" then matrix.addNodeIds = tostring(treeTarget.id) end
			local started, startError = tab:StartOptimizer(matrix)
			assert.is_true(started, startError)
			while tab.job and tab.job.status == "running" do tab:Tick() end
			assert.are.equal("feasible", tab.result and tab.result.status,
				phase .. " must produce a strictly feasible exact PoB result: " .. tostring(tab.statusMessage))
			assert.is_true(tab.result.evaluations >= 1, phase .. " must use the exact PoB evaluator")
			assert.are.equal(phase, tab.result.generationPhase)
			local applied, applyError = tab:ApplyResult()
			assert.is_true(applied, applyError)
			if phase == "skills" then
				assert.are.equal("AI Planner — Skills checkpoint", main.popups[1].title)
				main.popups[1].controls.yes:Click()
			end
			build.calcsTab:BuildOutput()
		end

		local selectedClassId = build.spec.curClassId
		exactPhase("tree", fireballId, 2)
		assert.are.equal("skills", tab.textValues.generationPhase)
		assert.are.equal(selectedClassId, build.spec.curClassId,
			"the selected Tree foundation must preserve the chosen native class start")
		assert.is_truthy(build.spec.allocNodes[build.spec.curClass.startNodeId],
			"the applied Tree foundation must retain exactly the selected class's native root")
		assert.is_truthy(build.spec.allocNodes[treeTarget.id],
			"the applied Tree phase must contain its required native passive node")
		assert.are.equal("", tab.textValues.addNodeIds,
			"Tree-only node filters must clear automatically before the Skills phase")
		assert.are.equal("0", tab.textValues.maxAddedPoints,
			"the next fixed-tree phase must not retain a misleading passive-addition budget")
		assert.is_false(tab.controls.text_addNodeIds.enabled(),
			"tree-only node controls must be disabled during the fixed-tree Skills phase")
		assert.is_false(tab.controls.text_allowedRegions.enabled(),
			"branch filters must be disabled during the fixed-tree Skills phase")
		assert.is_false(tab.controls.text_maxAddedPoints.enabled(),
			"passive-addition budget must be disabled during the fixed-tree Skills phase")
		assert.is_truthy(tab.statusMessage:find("Tree-only passive and branch constraints were cleared", 1, true))
		assert.are.equal(fireballId, build.skillsTab.socketGroupList[1].gemList[1].gemId,
			"Tree phase must leave the selected Main Skill unchanged")

		local oldSkillSetId = build.skillsTab.activeSkillSetId
		exactPhase("skills", arcId, 8)
		assert.are.equal("equipment", tab.textValues.generationPhase)
		assert.are_not.equal(oldSkillSetId, build.skillsTab.activeSkillSetId,
			"the selected active gem must be applied as its own reversible native PoB skill-set variation")
		local selectedArc = build.skillsTab.socketGroupList[1].displaySkillList[build.skillsTab.socketGroupList[1].mainActiveSkill]
		assert.are.equal(arcId, selectedArc.activeEffect.srcInstance.gemData.id)

		exactPhase("equipment", arcId, 1)
		assert.are.equal("equipment", tab.textValues.generationPhase)
		assert.is_truthy(tab.statusMessage:find("phases are complete", 1, true))
		build.calcsTab:BuildOutput()
		local finalOutput = build.calcsTab.mainOutput
		assert.is_true(type(finalOutput) == "table" and type(finalOutput.CombinedDPS) == "number",
			"the finished phased build must remain calculable by the ordinary PoB engine")
		newBuild()
	end)

	it("generates a new build from class and Main Skill through a linked equipment result", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local sourceClassId = build.spec.curClassId
		local witchClassId
		for classId, class in pairs(build.spec.tree.classes) do
			if class.name == "Witch" then witchClassId = classId; break end
		end
		assert.is_truthy(witchClassId, "the loaded PoB tree must expose its native Witch start")

		local tab = build.optimizerTab
		tab:OpenBuildDirection()
		local popup = main.popups[1]
		assert.is_truthy(popup and popup.controls, "Build Direction must open before the new-build seed is created")
		popup.controls["class_" .. tostring(witchClassId)].changeFunc()
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		popup.controls.targetGem:SelByValue(fireballId, "val")
		popup.controls.createSeed:Click()
		assert.is_nil(main.popups[1], "creating the native seed should return to the Planner")
		assert.are.equal(sourceClassId, build.spec.curClassId,
			"choosing a class in Build Direction must not mutate the source before Tree Apply")
		assert.are.equal(tostring(witchClassId), tab.textValues.baseClassId)
		assert.are.equal("tree", tab.textValues.generationPhase)
		local groupIndex = tonumber(tab.textValues.targetSkillGroupIndex)
		local skillIndex = tonumber(tab.textValues.targetSkillIndex)
		local group = build.skillsTab.socketGroupList[groupIndex]
		assert.is_truthy(group and group.gemList[1].gemData)
		assert.is_nil(group.slot, "a new build must begin with an honest unlinked active-skill seed")
		assert.are.equal(fireballId, group.gemList[1].gemId)

		local witchClass = build.spec.tree.classes[witchClassId]
		local witchStart = build.spec.nodes[witchClass.startNodeId]
		local treeTarget
		for _, node in ipairs(witchStart.linked or { }) do
			if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not node.ascendancyName
				and node.type ~= "Mastery" and node.type ~= "Socket" and not node.isProxy
				and not node.isMultipleChoiceOption and not node.isTattoo then
				treeTarget = node
				break
			end
		end
		assert.is_truthy(treeTarget, "the selected class root must have a legal native tree neighbor")

		local function runAndApply(phase, budget, syntheticGear)
			local matrix = {
				generationPhase = phase,
				objectiveMetric = "CombinedDPS",
				baseClassId = tostring(witchClassId),
				targetSkillGroupIndex = tostring(groupIndex),
				targetSkillIndex = tostring(skillIndex),
				targetSkillGemId = fireballId,
				maxAddedPoints = phase == "tree" and "1" or "0",
				maxTotalPoints = "120",
				evaluationBudget = tostring(budget),
				syntheticItemLevel = "86",
				searchStoredItems = "false",
				searchSyntheticGear = syntheticGear and "true" or "false",
				seed = "30102026",
			}
			if phase == "tree" then matrix.addNodeIds = tostring(treeTarget.id) end
			local started, startError = tab:StartOptimizer(matrix)
			assert.is_true(started, startError)
			for _ = 1, 10000 do
				if not tab.job or tab.job.status ~= "running" then break end
				tab:Tick()
			end
			assert.is_nil(tab.job, phase .. " phase must finish within its bounded work budget")
			assert.are.equal("feasible", tab.result and tab.result.status,
				phase .. " phase did not find an exact-feasible candidate: " .. tostring(tab.statusMessage)
					.. (tab.result and tab.result.message and (" / " .. tab.result.message) or ""))
			assert.are.equal(phase, tab.result.generationPhase)
			assert.is_true(tab.result.evaluations > 0, phase .. " must reach the exact PoB calculator")
			local applied, applyError = tab:ApplyResult()
			assert.is_true(applied, applyError)
			build.calcsTab:BuildOutput()
		end

		runAndApply("tree", 16, false)
		assert.are.equal(witchClassId, build.spec.curClassId,
			"Tree Apply must move the generated build to the selected native class")
		assert.is_truthy(build.spec.allocNodes[witchClass.startNodeId], "the Witch start node must remain allocated")
		assert.is_truthy(build.spec.allocNodes[treeTarget.id], "the exact Tree foundation must contain its required passive")
		assert.are.equal("skills", tab.textValues.generationPhase)
		assert.are.equal(fireballId, build.skillsTab.socketGroupList[groupIndex].gemList[1].gemId,
			"the Tree phase must preserve the selected Main Skill")

		runAndApply("skills", 36, false)
		assert.are.equal("skills", tab.textValues.generationPhase,
			"the generated build must stop at the Skills checkpoint until Equipment is explicitly accepted")
		assert.are.equal("AI Planner — Skills checkpoint", main.popups[1].title)
		main.popups[1].controls.yes:Click()
		assert.are.equal("equipment", tab.textValues.generationPhase)
		assert.are.equal(fireballId, build.skillsTab.socketGroupList[groupIndex].gemList[1].gemId,
			"the Skills phase must preserve the chosen active gem while evaluating its exact PoB package")

		runAndApply("equipment", 32, true)
		local linked, socketInfo = SkillCatalog.ValidateSocketGroup(build, groupIndex)
		assert.is_true(linked, type(socketInfo) == "string" and socketInfo or "the final Main Skill must be assigned to a real item link")
		assert.are.equal("equipment", tab.textValues.generationPhase)
		assert.is_truthy(tab.statusMessage:find("phases are complete", 1, true))
		local output = build.calcsTab.mainOutput
		assert.is_true(type(output) == "table" and type(output.CombinedDPS) == "number" and output.CombinedDPS > 0,
			"the completed generated build must produce positive ordinary PoB CombinedDPS")
		newBuild()
	end)
end)

describe("Optimizer support socket provenance v2", function()
	local validGroup = { slot = "Body Armour", enabled = true, slotEnabled = true }
	local validSocketEvidence = { valid = true, status = "linked" }
	local itemFingerprints = { ["Body Armour"] = string.rep("a", 64) }

	it("requires native group, link, and physical socket evidence for socketed supports", function()
		local gem = { enabled = true, matchesSocket = true }
		local group = { slot = "Body Armour", enabled = true, slotEnabled = true, gemList = { gem } }
		local support = { origin = "socketed_gem", srcInstance = gem, enabled = true,
			grantedEffect = { support = true, id = "SupportAddedFireDamage" } }
		local applied = { [support] = true }
		local legal = SkillCatalog.SupportEvidence({ }, 1, group, support, applied, itemFingerprints, validSocketEvidence)
		assert.is_true(legal.calculatorApplied)
		assert.is_true(legal.playableActive)
		assert.are.equal("matched", legal.socketState)
		assert.are.equal("validated_link", legal.linkState)

		gem.matchesSocket = false
		local staleUiMatch = SkillCatalog.SupportEvidence({ }, 1, group, support, applied, itemFingerprints, validSocketEvidence)
		assert.is_true(staleUiMatch.calculatorApplied,
			"PoB's calculation relationship and physical socket legality must remain separate")
		assert.is_true(staleUiMatch.playableActive,
			"a stale UI matchesSocket flag must not overrule a passing native physical group validation")
		assert.are.equal("matched", staleUiMatch.socketState)

		local mismatched = SkillCatalog.SupportEvidence({ }, 1, group, support, applied, itemFingerprints,
			{ valid = false, status = "invalid" })
		assert.is_false(mismatched.playableActive,
			"native rejection of a physical socket/link must keep the support out of playable features")
		assert.are.equal("invalid", mismatched.socketState)
		assert.are.equal("invalid", mismatched.linkState)

		gem.matchesSocket = true
		group.gemList = { }
		local crossGroup = SkillCatalog.SupportEvidence({ }, 1, group, support, applied, itemFingerprints, validSocketEvidence)
		assert.is_false(crossGroup.playableActive)
		assert.are.equal("not_same_skill_group", crossGroup.linkState)
	end)

	it("keeps item-granted and imbued support origins without inventing socket matches", function()
		local granted = { enabled = true, origin = "item_granted", sourceSlot = "Body Armour",
			grantedEffect = { support = true, fromItem = true, id = "SupportHypothermia" } }
		local applied = { [granted] = true }
		local itemEvidence = SkillCatalog.SupportEvidence({ }, 1, validGroup, granted, applied,
			itemFingerprints, validSocketEvidence)
		assert.is_true(itemEvidence.playableActive)
		assert.are.equal("not_applicable", itemEvidence.socketState)
		assert.are.equal("verified_item_local", itemEvidence.linkState)
		assert.are.equal(itemFingerprints["Body Armour"], itemEvidence.sourceItemFingerprint)

		granted.sourceSlot = "Helmet"
		local crossSlot = SkillCatalog.SupportEvidence({ }, 1, validGroup, granted, applied,
			{ Helmet = string.rep("b", 64) }, validSocketEvidence)
		assert.is_false(crossSlot.playableActive)
		assert.are.equal("cross_slot_unverified", crossSlot.linkState)

		local imbuedEffect = { id = "SupportEmpower", support = true }
		local build = { skillsTab = { imbuedSupportBySlot = { ["Body Armour"] = imbuedEffect } } }
		local group = { slot = "Body Armour", enabled = true, slotEnabled = true, imbuedSupport = "Empower" }
		local imbued = { origin = "imbued", enabled = true, grantedEffect = imbuedEffect }
		local imbuedEvidence = SkillCatalog.SupportEvidence(build, 1, group, imbued, { [imbued] = true },
			itemFingerprints, validSocketEvidence)
		assert.is_true(imbuedEvidence.playableActive)
		assert.are.equal("not_applicable", imbuedEvidence.socketState)
		assert.are.equal("verified_imbued_slot", imbuedEvidence.linkState)
	end)
end)
