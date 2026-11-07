local Candidate = require("Modules.Optimizer.Candidate")
local Inputs = require("Modules.Optimizer.Inputs")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local SkillSeed = require("Modules.Optimizer.SkillSeed")

describe("Optimizer native support replacement search", function()
	it("resolves each support candidate through PoB and preserves the active source build", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1\r\nAdded Fire Damage 1/0 1\r\nControlled Destruction 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()

		local group = build.skillsTab.socketGroupList[1]
		assert.is_true(#group.gemList >= 2, "the fixture needs a linked support socket")
		assert.is_true(group.gemList[2].gemData.grantedEffect.support, "the second gem must resolve as a native support")
		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			generationPhase = "skills",
			objectiveMetric = "TotalEHP",
			evaluationBudget = "12",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
		}))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 5000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "support search should finish; last phase: " .. tostring(job.progress and job.progress.phase))
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.are.equal("skills", result.generationPhase)
		assert.is_true(result.searchCoverage.phase.generatedSupportSwapCandidates > 0,
			"the skills phase must include alternatives from PoB's loaded support-gem database")
		assert.is_true(result.searchCoverage.phase.exactSupportSwapEvaluations > 0,
			"support swaps must reach the exact PoB calculator")
		assert.is_true(result.searchCoverage.phase.compatibleSupportSwapEvaluations > 0,
			"at least one fixture support must be confirmed by PoB as supporting an active skill; exact="
				.. tostring(result.searchCoverage.phase.exactSupportSwapEvaluations)
				.. ", rejected=" .. tostring(result.searchCoverage.phase.rejectedSupportSwapEvaluations)
				.. ", first=" .. tostring(result.searchCoverage.phase.firstSupportSwapRejection and result.searchCoverage.phase.firstSupportSwapRejection.reason)
				.. ", replacement=" .. tostring(result.searchCoverage.phase.firstSupportSwapRejection and result.searchCoverage.phase.firstSupportSwapRejection.name)
				.. ", group skills=" .. tostring(result.searchCoverage.phase.firstSupportSwapRejection and result.searchCoverage.phase.firstSupportSwapRejection.groupSkillCount)
				.. ", support sources=" .. tostring(result.searchCoverage.phase.firstSupportSwapRejection and result.searchCoverage.phase.firstSupportSwapRejection.supportSourceCount)
				.. ", applied sources=" .. tostring(result.searchCoverage.phase.firstSupportSwapRejection and result.searchCoverage.phase.firstSupportSwapRejection.appliedSourceCount))
		assert.is_true(result.searchCoverage.phase.generatedSupportCombinationCandidates > 0,
			"the skills phase must combine two support-slot mutations under the same bounded search")
		assert.is_true(result.searchCoverage.phase.exactSupportCombinationEvaluations > 0,
			"support combinations must reach the exact PoB calculator")
		assert.is_true(result.searchCoverage.phase.compatibleSupportCombinationEvaluations > 0,
			"at least one two-support candidate must be confirmed by the exact PoB skill effects")
		assert.are.equal(result.evaluations, result.searchCoverage.phase.exactEvaluations)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "the isolated support search must not mutate the active build")
	end)

	it("applies a selected native support swap as a reversible skill-set variation", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1\r\nAdded Fire Damage 1/0 1\r\nControlled Destruction 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local oldSupport = build.skillsTab.socketGroupList[1].gemList[2]
		local replacementId = build.data.gemForBaseName["added chaos damage"]
			or build.data.gemForBaseName["added chaos damage support"]
		local replacement = replacementId and build.data.gems[replacementId]
		assert.is_truthy(replacement and replacement.grantedEffect and replacement.grantedEffect.support,
			"the replacement must be resolved from native PoB support data")
		local sourceSkillSetId = build.skillsTab.activeSkillSetId
		local sourceSupportName = build.skillsTab.skillSets[sourceSkillSetId].socketGroupList[1].gemList[2].nameSpec
		local sourceSignature = Candidate.BuildSignature(build)
		build.skillsTab.undo = { }
		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { },
			removeNodeIds = { },
			gemVariant = {
				groupIndex = 1,
				gemIndex = 2,
				gemId = replacement.id,
				skillId = replacement.grantedEffectId,
				nameSpec = replacement.name,
				level = 1,
				quality = 0,
				kind = "support_swap",
				fromGemId = oldSupport.gemData.id,
			},
		})
		assert.is_true(applied, applyError)
		local activeSet = build.skillsTab.skillSets[build.skillsTab.activeSkillSetId]
		local activeSupport = activeSet.socketGroupList[1].gemList[2]
		assert.are.equal(replacement.id, activeSupport.gemId)
		local retainedSourceName = build.skillsTab.skillSets[sourceSkillSetId].socketGroupList[1].gemList[2].nameSpec
		assert.are.equal(sourceSupportName, retainedSourceName,
			"source name changed; before=" .. tostring(sourceSupportName) .. ", after=" .. tostring(retainedSourceName)
				.. ", source set=" .. tostring(sourceSkillSetId) .. ", active set=" .. tostring(build.skillsTab.activeSkillSetId))
		build.skillsTab:Undo()
		assert.are.equal(sourceSkillSetId, build.skillsTab.activeSkillSetId,
			"native Undo must restore the source skill set when the build had no previous undo checkpoint")
		assert.are.equal(sourceSupportName, build.skillsTab.socketGroupList[1].gemList[2].nameSpec)
	end)
	it("applies an exact support pair as one reversible skill-set variation", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1\r\nAdded Fire Damage 1/0 1\r\nControlled Destruction 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local group = build.skillsTab.socketGroupList[1]
		local activeSkill
		for _, skill in ipairs(build.calcsTab.mainEnv.player.activeSkillList or { }) do
			if skill.socketGroup == group then activeSkill = skill; break end
		end
		assert.is_truthy(activeSkill, "the fixture must expose the native Fireball active skill")
		local currentGameIds = { }
		for _, gemIndex in ipairs({ 2, 3 }) do currentGameIds[group.gemList[gemIndex].gemData.gameId] = true end
		local compatibleGems, seenGameIds = { }, { }
		for _, gemData in pairs(build.data.gems or { }) do
			local effect = gemData.grantedEffect
			if effect and effect.support and not effect.unsupported and gemData.grantedEffectId
				and not currentGameIds[gemData.gameId] and not seenGameIds[gemData.gameId]
				and calcLib.canGrantedEffectSupportActiveSkill(effect, activeSkill) then
				seenGameIds[gemData.gameId] = true
				compatibleGems[#compatibleGems + 1] = gemData
			end
		end
		table.sort(compatibleGems, function(a, b) return tostring(a.id) < tostring(b.id) end)
		assert.is_true(#compatibleGems >= 2, "the fixture requires two distinct native supports for Fireball")
		local sourceSkillSetId = build.skillsTab.activeSkillSetId
		local sourceNames = { group.gemList[2].nameSpec, group.gemList[3].nameSpec }
		local sourceSignature = Candidate.BuildSignature(build)
		local replacements = { compatibleGems[1], compatibleGems[2] }
		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { },
			removeNodeIds = { },
			gemVariants = {
				{ groupIndex = 1, gemIndex = 2, gemId = replacements[1].id, skillId = replacements[1].grantedEffectId, nameSpec = replacements[1].name, level = 1, quality = 0, kind = "support_swap" },
				{ groupIndex = 1, gemIndex = 3, gemId = replacements[2].id, skillId = replacements[2].grantedEffectId, nameSpec = replacements[2].name, level = 1, quality = 0, kind = "support_swap" },
			},
		})
		assert.is_true(applied, applyError)
		local activeSet = build.skillsTab.skillSets[build.skillsTab.activeSkillSetId]
		assert.are_not.equal(sourceSkillSetId, build.skillsTab.activeSkillSetId)
		for index, gemIndex in ipairs({ 2, 3 }) do
			local appliedGem = activeSet.socketGroupList[1].gemList[gemIndex]
			assert.are.equal(replacements[index].id, appliedGem.gemId)
			assert.are.equal(sourceNames[index], build.skillsTab.skillSets[sourceSkillSetId].socketGroupList[1].gemList[gemIndex].nameSpec,
				"the source skill set must remain unchanged after a paired replacement")
			assert.is_true(appliedGem.gemData and appliedGem.gemData.grantedEffect and appliedGem.gemData.grantedEffect.support)
			assert.is_true(type(appliedGem.reqLevel) == "number", "PoB must recalculate gem requirements on the new variation")
		end
		build.calcsTab:BuildOutput()
		assert.is_true(build.calcsTab.mainOutput and build.calcsTab.mainOutput.TotalDPS > 0,
			"the paired variation must recalculate through the native PoB engine")
	end)

	it("proposes compatible support additions for an unlinked active-skill seed through exact PoB", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local seed, seedError = SkillSeed.Create(build, gemId)
		assert.is_truthy(seed, seedError)
		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			generationPhase = "skills",
			objectiveMetric = "CombinedDPS",
			evaluationBudget = "36",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			targetSkillGroupIndex = tostring(seed.groupIndex),
			targetSkillIndex = tostring(seed.skillIndex),
			targetSkillGemId = gemId,
		}))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 5000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "support-add search should finish; last phase: " .. tostring(job.progress and job.progress.phase))
		assert.is_true(status ~= "error", result and result.message or job.error)
		local coverage = result.searchCoverage.phase
		assert.is_true(coverage.generatedSupportAddCandidates > 0, "the Skills phase must add bounded supports to the selected seed")
		assert.is_true(coverage.exactSupportAddEvaluations > 0, "support additions must reach the exact PoB calculator")
		assert.is_true(coverage.compatibleSupportAddEvaluations > 0,
			"PoB must confirm that an added support is applied to the active skill; rejected="
				.. tostring(coverage.rejectedSupportAddEvaluations)
				.. ", first=" .. tostring(coverage.firstSupportAddRejection and coverage.firstSupportAddRejection.reason))
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "isolated support-add search must not mutate the source build")
		newBuild()
	end)

	it("searches deterministic support packages from two through five gems with exact PoB checks", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local seed, seedError = SkillSeed.Create(build, gemId)
		assert.is_truthy(seed, seedError)
		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			generationPhase = "skills",
			objectiveMetric = "CombinedDPS",
			evaluationBudget = "128",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			targetSkillGroupIndex = tostring(seed.groupIndex),
			targetSkillIndex = tostring(seed.skillIndex),
			targetSkillGemId = gemId,
		}))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 5000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "support-package search should finish; last phase: " .. tostring(job.progress and job.progress.phase))
		assert.is_true(status ~= "error", result and result.message or job.error)
		local additions = result.searchCoverage.phase.supportPackages.additions
		local catalogCoverage = result.searchCoverage.phase.skillCatalog
		local catalogSummary = assert(SkillCatalog.Summary(build))
		assert.are.equal("catalog_only", catalogCoverage.catalog.evaluationStatus)
		assert.is_false(catalogCoverage.catalog.exactEvaluated)
		assert.are.equal(catalogSummary.counts.activeGemEntries, catalogCoverage.catalog.counts.activeGemEntries)
		assert.are.equal(catalogSummary.counts.supportGemVariants, catalogCoverage.catalog.counts.supportGemVariants)
		assert.is_true(catalogCoverage.supportAddEligibleGemVariants >= catalogCoverage.supportAddSelectedGemVariants)
		assert.is_true(catalogCoverage.supportAddGeneratedCandidates > 0,
			"catalog support variants must reach bounded candidate generation")
		for arity = 2, 5 do
			assert.is_true(additions[arity].generated > 0,
				"bounded generation must cover support-package arity " .. tostring(arity))
			assert.is_true(additions[arity].exact > 0,
				"each generated arity must reach PoB's exact calculator: " .. tostring(arity))
		end
		assert.is_true(additions[3].compatible > 0,
			"PoB must confirm at least one three-support package on Fireball")
		assert.is_true(result.evaluations <= parsed.search.evaluationBudget,
			"support package generation must remain within the exact evaluation budget")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
			"support-package simulation must preserve the active source build")
		newBuild()
	end)

	it("applies an exact support plan reversibly and labels the missing item link", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local seed, seedError = SkillSeed.Create(build, gemId)
		assert.is_truthy(seed, seedError)
		local group = build.skillsTab.socketGroupList[seed.groupIndex]
		local activeSkill
		for _, skill in ipairs(build.calcsTab.mainEnv.player.activeSkillList or { }) do
			if skill.socketGroup == group and skill.activeEffect and skill.activeEffect.grantedEffect.id == group.gemList[1].skillId then
				activeSkill = skill
				break
			end
		end
		assert.is_truthy(activeSkill, "PoB must expose the selected Main Skill for native support compatibility")
		local supportGem
		for _, gemData in pairs(build.data.gems or { }) do
			local effect = gemData.grantedEffect
			if effect and effect.support and not effect.unsupported and gemData.grantedEffectId
				and calcLib.canGrantedEffectSupportActiveSkill(effect, activeSkill) then
				supportGem = gemData
				break
			end
		end
		assert.is_truthy(supportGem, "PoB's loaded data must expose a compatible support for the fixture")
		local sourceSetId = build.skillsTab.activeSkillSetId
		local sourceSignature = Candidate.BuildSignature(build)
		local applied, applyMessage = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { },
			removeNodeIds = { },
			gemVariant = {
				groupIndex = seed.groupIndex,
				gemIndex = 2,
				gemId = supportGem.id,
				skillId = supportGem.grantedEffectId,
				nameSpec = supportGem.name,
				level = 1,
				quality = 0,
				kind = "support_add",
				targetSkillId = group.gemList[1].skillId,
			},
		})
		assert.is_true(applied, applyMessage)
		assert.is_truthy(applyMessage:find("no equipment socket or link", 1, true),
			"an exact provisional support must never be described as a playable link")
		assert.are_not.equal(sourceSetId, build.skillsTab.activeSkillSetId)
		local activeGroup = build.skillsTab.socketGroupList[seed.groupIndex]
		assert.is_nil(activeGroup.slot, "support planning on the seed must remain unassigned")
		assert.are.equal(supportGem.id, activeGroup.gemList[2].gemId)
		build.calcsTab:BuildOutput()
		local appliedSupport = activeGroup.gemList[2]
		local confirmed = false
		for _, skill in ipairs(build.calcsTab.mainEnv.player.activeSkillList or { }) do
			if skill.socketGroup == activeGroup then
				for _, effect in ipairs(skill.effectList or { }) do
					if effect.srcInstance == appliedSupport and effect.grantedEffect and effect.grantedEffect.support then confirmed = true end
				end
			end
		end
		assert.is_true(confirmed, "the normal PoB calculation must apply the selected support gem")
		build.skillsTab:Undo()
		assert.are.equal(sourceSetId, build.skillsTab.activeSkillSetId, "native Undo must restore the original seed variation")
		assert.are.equal(1, #build.skillsTab.socketGroupList[seed.groupIndex].gemList)
		newBuild()
	end)

	it("requires an equipment-backed support addition to use a free socket in the same link and color", function()
		newBuild()
		local supportGem
		local redSupportGem
		for _, gemData in pairs(build.data.gems or { }) do
			if gemData.grantedEffect and gemData.grantedEffect.support and not gemData.grantedEffect.unsupported then
				if gemData.grantedEffect.color == 3 and not supportGem then supportGem = gemData end
				if gemData.grantedEffect.color == 1 and not redSupportGem then redSupportGem = gemData end
			end
		end
		assert.is_truthy(supportGem, "fixture requires a native blue support gem")
		assert.is_truthy(redSupportGem, "fixture requires a native red support gem")
		local group = {
			slot = "Helmet",
			gemList = { { gemData = { id = "active-gem" } } },
			displaySkillList = { { activeEffect = { grantedEffect = { } } } },
		}
		local item = { sockets = {
			{ group = 1, color = "B" },
			{ group = 1, color = "B" },
			{ group = 1, color = "R" },
		} }
		local fakeBuild = {
			skillsTab = { socketGroupList = { group } },
			itemsTab = {
				activeItemSet = { Helmet = { selItemId = 1 } },
				items = { [1] = item },
			},
		}
		local valid, info = SkillCatalog.CanAddSupportAtSlot(fakeBuild, 1, 2, supportGem)
		assert.is_true(valid, "a free native socket with matching color and link should be accepted")
		assert.is_true(info.linked)
		local firstRed, firstRedError = SkillCatalog.CanAddSupportAtSlot(fakeBuild, 1, 2, redSupportGem)
		assert.is_false(firstRed, "a red support must not be proposed into the first blue socket")
		assert.is_truthy(firstRedError:find("needs a R socket", 1, true))
		local laterRed, laterRedError = SkillCatalog.CanAddSupportAtSlot(fakeBuild, 1, 3, redSupportGem, 1)
		assert.is_true(laterRed,
			"the same red support must remain eligible in its later red socket after the blue socket is filled: " .. tostring(laterRedError))
		item.sockets[2].group = 2
		local linked, linkError = SkillCatalog.CanAddSupportAtSlot(fakeBuild, 1, 2, supportGem)
		assert.is_false(linked)
		assert.is_truthy(linkError:find("not linked", 1, true))
		item.sockets[2].group = 1
		item.sockets[2].color = "R"
		local colored, colorError = SkillCatalog.CanAddSupportAtSlot(fakeBuild, 1, 2, supportGem)
		assert.is_false(colored)
		assert.is_truthy(colorError:find("needs a B socket", 1, true))
		newBuild()
	end)
end)
