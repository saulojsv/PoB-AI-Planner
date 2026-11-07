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

	local function makeGroup(slot, gemId, testStatus)
		return {
			enabled = true,
			slotEnabled = true,
			slot = slot,
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

	it("still rejects the selected Main Skill when its exact socket proof fails", function()
		local source = makeBuild({ makeGroup("Body Armour", "main-skill", "linked") })
		local candidate = makeBuild({ makeGroup("Body Armour", "main-skill", "invalid") })

		local valid, proof = SkillCatalog.ValidatePlannerSocketGroups(source, candidate, 1, candidate.itemsTab)

		assert.is_false(valid)
		assert.are.equal(1, #proof.violations)
		assert.are.equal(1, proof.violations[1].groupIndex)
	end)
end)
