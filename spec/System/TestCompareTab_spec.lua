describe("CompareTab", function()
	it("rejects oversized comparison build codes before decompression", function()
		newBuild()
		local compareTab = build.compareTab
		local previousLimit = buildSites.MAX_BUILD_CODE_BYTES
		buildSites.MAX_BUILD_CODE_BYTES = 3
		local imported = compareTab:ImportFromCode("AAAA")
		buildSites.MAX_BUILD_CODE_BYTES = previousLimit
		assert.is_false(imported)
		assert.are.equal(0, #compareTab.compareEntries)
	end)
	it("hides skill detail controls after removing the final comparison", function()
		newBuild()
		local compareTab = build.compareTab
		compareTab.compareEntries = { { label = "Test" } }
		compareTab.activeCompareIndex = 1
		local controls = {
			compareTab.controls.cmpMainSkill,
			compareTab.controls.cmpSkillPart,
			compareTab.controls.cmpStageCount,
			compareTab.controls.cmpMineCount,
			compareTab.controls.cmpMinion,
			compareTab.controls.cmpMinionSkill,
		}
		for _, control in ipairs(controls) do
			control.shown = true
		end

		compareTab:RemoveBuild(1)

		for _, control in ipairs(controls) do
			assert.is_false(control:IsShown())
		end
	end)
	it("reproduces matching-socket gem quality when comparing a build with itself", function()
		newBuild()
		build.itemsTab:CreateDisplayItemFromRaw(
			"Rarity: RARE\nTest Subject\nSage's Robe\nQuality: 0\nSockets: B-B-B\nImplicits: 0\n")
		build.itemsTab:AddDisplayItem()
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 20/0  1\n")
		runCallback("OnFrame")
		assert.are.equal(10, build.calcsTab.mainOutput.GemQuality)

		-- doesn't actually save to a file, just encodes as xml
		local entry = new("CompareEntry"):CompareEntry(build:SaveDB("code"), "Self")

		assert.is_true(entry.skillsTab.socketGroupList[1].gemList[1].matchesSocket)
		assert.are.equal(build.calcsTab.mainOutput.GemQuality, entry.calcsTab.mainOutput.GemQuality)
		assert.are.equal(build.calcsTab.mainOutput.CombinedDPS, entry.calcsTab.mainOutput.CombinedDPS)
	end)
end)
