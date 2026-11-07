local SkillCatalog = require("Modules.Optimizer.SkillCatalog")

describe("Optimizer native socket validation for changed gem groups", function()
	it("rejects a support replacement when its physical item socket color is invalid", function()
		newBuild()
		local socketItem = new("Item"):Item("Rarity: Rare\nSocket Gate Seed\nNightmare Bascinet\nSockets: B-R R-R\n--------\n+80 to maximum Life")
		build.itemsTab:AddItem(socketItem, true)
		build.itemsTab.activeItemSet["Helmet"].selItemId = socketItem.id
		build.itemsTab.slots["Helmet"]:SetSelItemId(socketItem.id)
		build.itemsTab:PopulateSlots()
		build.skillsTab:PasteSocketGroup("Slot: Helmet\nVulnerability 1/0 1\nBlasphemy 1/0 1")
		local group = build.skillsTab.socketGroupList[#build.skillsTab.socketGroupList]
		group.slot = "Helmet"
		build.skillsTab:ProcessSocketGroup(group)
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		local enlighten = build.data.gems["Metadata/Items/Gems/SkillGemSupportEnlighten"]
		assert.is_table(enlighten, "the active PoB gem database must expose Enlighten")
		local replacement = group.gemList[2]
		assert.is_truthy(replacement, "the fixture must have a replaceable second support slot")
		replacement.gemId = enlighten.id
		replacement.gemData = enlighten
		replacement.grantedEffect = enlighten.grantedEffect
		group.displaySkillList = { }

		local candidate = { gemVariants = { {
			kind = "support_swap", groupIndex = #build.skillsTab.socketGroupList,
			gemIndex = 2, gemId = enlighten.id,
		} } }
		local proof = SkillCatalog.ValidateChangedGemGroupSockets(candidate, build, build.itemsTab)
		assert.are.equal("invalid", proof.status,
			"exact PoB support application must not certify an invalid physical socket layout")
		assert.is_truthy(proof.violations[1].reason:find("needs a R socket", 1, true))

		socketItem.sockets[1].color = "R"
		socketItem.sockets[2].color = "B"
		local repairedProof = SkillCatalog.ValidateChangedGemGroupSockets(candidate, build, build.itemsTab)
		assert.are.equal("pass", repairedProof.status,
			"the same support proposal should pass when its native item sockets are legal")
		assert.are.equal(1, #repairedProof.groups)
		assert.are.equal("linked", repairedProof.groups[1].status)
		newBuild()
	end)
end)
