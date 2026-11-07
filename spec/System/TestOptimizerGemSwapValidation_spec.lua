local MCPBridge = require("Modules.Optimizer.MCPBridge")
local Candidate = require("Modules.Optimizer.Candidate")

describe("Optimizer exact gem comparison slot validation", function()
	it("exact-calculates an alternate Main Skill in an unlinked planning group", function()
		newBuild()
		local sourceBuild = build
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local arcGem
		for _, gemData in pairs(sourceBuild.data.gems or { }) do
			if gemData.name == "Arc" and gemData.grantedEffect and not gemData.grantedEffect.support
				and not gemData.grantedEffect.unsupported and gemData.tags
				and gemData.tags.grants_active_skill == true then
				if not arcGem or tostring(gemData.id) < tostring(arcGem.id) then arcGem = gemData end
			end
		end
		assert.is_truthy(arcGem, "the loaded PoB database must expose the native Arc Main Skill")

		local result, err = MCPBridge:CallLocal("evaluate_gem_swap", {
			groupIndex = 1, gemIndex = 1, gemId = arcGem.id, level = 1, quality = 0,
		})
		assert.is_truthy(result, err)
		assert.is_true(result.readOnly)
		assert.is_true(result.activeBuildPreserved)
		assert.are.equal("unlinked_planning", result.socketStatus)
		assert.are.equal("Arc", result.selectedSkill.name)
		assert.are.equal(tostring(arcGem.grantedEffect.id), result.selectedSkill.effectId)
		assert.is_table(result.candidateMetrics)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild),
			"an exact alternate-skill comparison must leave the source build unchanged")
		newBuild()
	end)

	it("rejects a support gem when evaluating a Main Skill gem slot", function()
		newBuild()
		local sourceBuild = build
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.calcsTab:BuildOutput()
		local supportGem
		for _, gemData in pairs(sourceBuild.data.gems or { }) do
			local effect = gemData.grantedEffect or gemData.secondaryGrantedEffect
			if effect and effect.support and not effect.unsupported then
				supportGem = gemData
				break
			end
		end
		assert.is_truthy(supportGem, "the loaded PoB database must expose a supported support gem for this role check")

		local result, err = MCPBridge:CallLocal("evaluate_gem_swap", {
			groupIndex = 1, gemIndex = 1, gemId = supportGem.id, level = 1, quality = 0,
		})
		assert.is_nil(result)
		assert.is_truthy(err and err:find("Replacement must be a supported active skill gem", 1, true),
			"the MCP comparison must reject a support gem before exact calculation in a Main Skill slot")
		newBuild()
	end)

	it("rejects an active skill when evaluating a support gem slot", function()
		newBuild()
		local sourceBuild = build
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 1/0  1\nAdded Lightning Damage 1/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local arcGem
		for _, gemData in pairs(sourceBuild.data.gems or { }) do
			if gemData.name == "Arc" and gemData.grantedEffect and not gemData.grantedEffect.support
				and not gemData.grantedEffect.unsupported and gemData.tags
				and gemData.tags.grants_active_skill == true then
				arcGem = gemData
				break
			end
		end
		assert.is_truthy(sourceBuild.skillsTab.socketGroupList[1].gemList[2],
			"the fixture must retain its native support gem in slot two")
		assert.is_truthy(arcGem, "the loaded PoB database must expose the native Arc Main Skill")

		local result, err = MCPBridge:CallLocal("evaluate_gem_swap", {
			groupIndex = 1, gemIndex = 2, gemId = arcGem.id, level = 1, quality = 0,
		})
		assert.is_nil(result)
		assert.is_truthy(err and err:find("Replacement must be a supported support gem", 1, true),
			"the MCP comparison must reject an active skill in a native support slot")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild),
			"a rejected replacement must leave the source build unchanged")
		newBuild()
	end)

	it("exact-calculates a support replacement while preserving the selected Main Skill", function()
		newBuild()
		local sourceBuild = build
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 1/0  1\nAdded Lightning Damage 1/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local alternateSupport
		for _, gemData in pairs(sourceBuild.data.gems or { }) do
			if gemData.name == "Added Chaos Damage" and gemData.grantedEffect
				and gemData.grantedEffect.support and not gemData.grantedEffect.unsupported then
				alternateSupport = gemData
				break
			end
		end
		assert.is_truthy(alternateSupport, "the loaded PoB database must expose the native Added Chaos Damage support")

		local result, err = MCPBridge:CallLocal("evaluate_gem_swap", {
			groupIndex = 1, gemIndex = 2, gemId = alternateSupport.id, level = 1, quality = 0,
		})
		assert.is_truthy(result, err)
		assert.is_true(result.activeBuildPreserved)
		assert.are.equal("unlinked_planning_group", result.socketStatus)
		assert.are.equal("Fireball", result.selectedSkill.name)
		assert.is_table(result.candidateMetrics)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild),
			"an exact support comparison must leave the source build unchanged")
		newBuild()
	end)
end)
