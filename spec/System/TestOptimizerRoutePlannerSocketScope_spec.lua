local SkillCatalog = require("Modules.Optimizer.SkillCatalog")

describe("AI Planner Single Skill socket proof scope", function()
	local originalValidateSocketGroup

	before_each(function()
		originalValidateSocketGroup = SkillCatalog.ValidateSocketGroup
		SkillCatalog.ValidateSocketGroup = function(build, groupIndex, itemsTab, itemSet, group)
			group = group or build.skillsTab.socketGroupList[groupIndex]
			if group.testStatus ~= "linked" then
				return false, "synthetic pre-existing socket mismatch"
			end
			return true, {
				status = "linked",
				groupIndex = groupIndex,
				slot = group.slot,
				itemId = group.itemId,
				socketCount = #group.gemList,
				linkGroup = 1,
			}
		end
	end)

	after_each(function()
		SkillCatalog.ValidateSocketGroup = originalValidateSocketGroup
	end)

	local function makeGroup(slot, gemId, testStatus, source, sourceKind)
		return {
			enabled = true,
			slotEnabled = true,
			slot = slot,
			source = source,
			sourceKind = sourceKind,
			itemId = "item:" .. slot,
			testStatus = testStatus,
			gemList = { { gemId = gemId } },
		}
	end

	local function makeBuild(groups)
		return {
			skillsTab = { socketGroupList = groups },
			itemsTab = { activeItemSet = { } },
			data = { },
		}
	end

	it("ignores an already-invalid secondary group but preserves previously linked groups", function()
		local source = makeBuild({
			makeGroup("Body Armour", "main-skill", "linked"),
			makeGroup("Helmet", "broken-secondary", "invalid"),
			makeGroup("Gloves", "valid-secondary", "linked"),
		})
		local candidate = makeBuild({
			makeGroup("Body Armour", "main-skill", "linked"),
			makeGroup("Helmet", "broken-secondary", "invalid"),
			makeGroup("Gloves", "valid-secondary", "linked"),
		})

		local valid, proof = SkillCatalog.ValidatePlannerSocketGroups(source, candidate, 1, candidate.itemsTab)

		assert.is_true(valid)
		assert.are.equal("single_skill_preserve_existing_links", proof.scope)
		assert.are.equal(1, proof.ignoredInvalidBaselineGroups)
		assert.are.equal(2, #proof.groups, "proof covers the selected skill and the secondary group that was already linked")
	end)

	it("rejects a route that breaks a previously linked secondary group", function()
		local source = makeBuild({
			makeGroup("Body Armour", "main-skill", "linked"),
			makeGroup("Helmet", "broken-secondary", "invalid"),
			makeGroup("Gloves", "valid-secondary", "linked"),
		})
		local candidate = makeBuild({
			makeGroup("Body Armour", "main-skill", "linked"),
			makeGroup("Helmet", "broken-secondary", "invalid"),
			makeGroup("Gloves", "valid-secondary", "invalid"),
		})

		local valid, proof = SkillCatalog.ValidatePlannerSocketGroups(source, candidate, 1, candidate.itemsTab)

		assert.is_false(valid)
		assert.are.equal(1, #proof.violations)
		assert.are.equal(3, proof.violations[1].groupIndex)
	end)

	it("matches a preserved playable group when a candidate rebinds its native source metadata", function()
		local source = makeBuild({
			makeGroup("Body Armour", "main-skill", "linked"),
			makeGroup("Helmet", "granted-secondary", "linked", "Item:17", "item"),
		})
		local candidate = makeBuild({
			makeGroup("Body Armour", "main-skill", "linked"),
			makeGroup("Helmet", "granted-secondary", "linked", "Item:42", "item"),
		})

		local valid, proof = SkillCatalog.ValidatePlannerSocketGroups(source, candidate, 1, candidate.itemsTab)

		assert.is_true(valid)
		assert.are.equal(2, #proof.groups)
	end)

	it("requires the candidate to preserve duplicate linked secondary groups separately", function()
		local source = makeBuild({
			makeGroup("Body Armour", "main-skill", "linked"),
			makeGroup("Weapon 1", "duplicate-secondary", "linked"),
			makeGroup("Weapon 1", "duplicate-secondary", "linked"),
		})
		local candidate = makeBuild({
			makeGroup("Body Armour", "main-skill", "linked"),
			makeGroup("Weapon 1", "duplicate-secondary", "linked"),
		})

		local valid, proof = SkillCatalog.ValidatePlannerSocketGroups(source, candidate, 1, candidate.itemsTab)

		assert.is_false(valid)
		assert.are.equal(1, #proof.violations)
		assert.are.equal("Previously linked secondary skill group", proof.violations[1].label)
	end)

	it("still rejects the selected Main Skill when its exact socket proof fails", function()
		local source = makeBuild({ makeGroup("Body Armour", "main-skill", "linked") })
		local candidate = makeBuild({ makeGroup("Body Armour", "main-skill", "invalid") })

		local valid, proof = SkillCatalog.ValidatePlannerSocketGroups(source, candidate, 1, candidate.itemsTab)

		assert.is_false(valid)
		assert.are.equal(1, #proof.violations)
		assert.are.equal(1, proof.violations[1].groupIndex)
	end)

	it("rebinds an exact item-granted group to the candidate's equipped native item", function()
		local source = "Item:42:Candidate Grant"
		local item = {
			id = 42,
			modSource = source,
			grantedSkills = { { source = source, skillId = "CandidateSkill", slotName = "Body Armour" } },
		}
		local itemsTab = {
			slots = { ["Body Armour"] = { } },
			activeItemSet = { ["Body Armour"] = { selItemId = 42 } },
			items = { [42] = item },
		}
		local group = makeGroup("Body Armour", "CandidateSkill", "linked", "Item:17:Source Grant", "item")
		group.gemList[1].skillId = "CandidateSkill"
		local groups = { group }
		local build = { itemsTab = itemsTab, data = { skills = { CandidateSkill = { name = "Candidate Skill" } } } }
		local proof = { groups = { {
			groupIndex = 1,
			status = "granted_skill",
			group = { status = "granted_skill", sourceKind = "item", itemId = 42,
				slot = "Body Armour", source = source, skillId = "CandidateSkill" },
		} } }

		local rebound, err = SkillCatalog.RebindPlannerGrantedSkillGroups(build, proof, itemsTab, nil, groups)

		assert.is_true(rebound, err)
		assert.are.equal(source, groups[1].source)
		assert.are.equal(item, groups[1].sourceItem)
		assert.are.equal("CandidateSkill", groups[1].gemList[1].skillId)
	end)

	it("rejects a stale item-grant proof when the candidate item does not grant that skill", function()
		local source = "Item:42:Candidate Grant"
		local item = { id = 42, modSource = source,
			grantedSkills = { { source = source, skillId = "OtherSkill", slotName = "Body Armour" } } }
		local itemsTab = {
			slots = { ["Body Armour"] = { } },
			activeItemSet = { ["Body Armour"] = { selItemId = 42 } },
			items = { [42] = item },
		}
		local groups = { makeGroup("Body Armour", "CandidateSkill", "linked", "Item:17:Source Grant", "item") }
		local proof = { groups = { {
			groupIndex = 1,
			status = "granted_skill",
			group = { status = "granted_skill", sourceKind = "item", itemId = 42,
				slot = "Body Armour", source = source, skillId = "CandidateSkill" },
		} } }

		local rebound, err = SkillCatalog.RebindPlannerGrantedSkillGroups(
			{ itemsTab = itemsTab, data = { } }, proof, itemsTab, nil, groups)

		assert.is_false(rebound)
		assert.matches("no longer grants the exact skill", err)
	end)
end)
