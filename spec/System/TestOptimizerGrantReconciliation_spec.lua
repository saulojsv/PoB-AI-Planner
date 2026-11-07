local SkillCatalog = require("Modules.Optimizer.SkillCatalog")

describe("Optimizer granted-skill reconciliation", function()
	it("keeps gem-backed item grants stable when PoB canonicalizes their display name", function()
		local source = "Item:19:Granted Skill Item"
		local grantedGem = {
			id = "Metadata/Items/Gems/SkillGemGrantedSkill",
			name = "Canonical Granted Skill",
			grantedEffectId = "GrantedSkill",
			naturalMaxLevel = 20,
			grantedEffect = { levels = { [1] = { } } },
		}
		local skillsTab = {
			socketGroupList = { },
			ProcessSocketGroup = function(_, group)
				local gem = group.gemList[1]
				if gem and gem.skillId == "GrantedSkill" then
					gem.nameSpec = grantedGem.name
				end
			end,
			UpdateSocketGroups = function() end,
		}
		local build = {
			data = {
				gemForSkill = { GrantedSkill = grantedGem.id },
				gems = { [grantedGem.id] = grantedGem },
			},
			skillsTab = skillsTab,
		}
		local function grant()
			return {
				source = source,
				slotName = "Body Armour",
				skillId = "GrantedSkill",
				nameSpec = nil,
				level = 1,
				sourceItem = { modSource = source },
			}
		end

		local first = assert(SkillCatalog.ReconcileGrantedSkillGroups(build, {
			grantedSkills = { grant() }, explodeSources = { },
		}))
		assert.is_true(first.changed)
		assert.are.equal("Canonical Granted Skill", skillsTab.socketGroupList[1].gemList[1].nameSpec)

		local second = assert(SkillCatalog.ReconcileGrantedSkillGroups(build, {
			grantedSkills = { grant() }, explodeSources = { },
		}))
		assert.is_false(second.changed,
			"candidate recalculation must not alternate between an empty grant name and PoB's canonical gem name")
	end)

	it("treats candidate tree-node references as the same native grant by node id", function()
		local source = "Tree:55509"
		local skillsTab = {
			socketGroupList = { {
				label = "",
				enabled = true,
				gemList = { {
					quality = 0,
					enabled = true,
					fromItem = false,
					gemId = nil,
					skillId = "AilmentBearer",
					nameSpec = "Ailment Bearer",
					level = 20,
					enableGlobal1 = true,
				} },
				source = source,
				slot = nil,
				sourceNode = { name = "Unbound Avatar" },
			} },
			ProcessSocketGroup = function() end,
			UpdateSocketGroups = function() end,
		}
		local build = {
			data = { skills = { AilmentBearer = { name = "Unbound Avatar" } } },
			skillsTab = skillsTab,
		}
		local environmentCount = 0
		local function environment()
			environmentCount = environmentCount + 1
			return {
				grantedSkills = { {
					source = source,
					skillId = "AilmentBearer",
					nameSpec = environmentCount == 1 and "Ailment Bearer Variant" or nil,
					level = 20,
					sourceNode = { name = "Unbound Avatar" },
				} },
				explodeSources = { },
			}
		end

		local first = assert(SkillCatalog.ReconcileGrantedSkillGroups(build, environment()))
		local second = assert(SkillCatalog.ReconcileGrantedSkillGroups(build, environment()))
		assert.is_true(first.changed, "the existing display name must normalize once to PoB's native skill name")
		assert.are.equal("Unbound Avatar", skillsTab.socketGroupList[1].gemList[1].nameSpec)
		assert.is_false(second.changed,
			"the source key Tree:55509 and native skill name must identify cloned candidate grant records")
	end)
end)
