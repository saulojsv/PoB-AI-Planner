local Candidate = require("Modules.Optimizer.Candidate")
local DisplayText = require("Modules.Optimizer.DisplayText")
local Version = require("Modules.Optimizer.Version")
local RoutePlanner = require("Modules.Optimizer.RoutePlanner")

describe("AI Planner bounded combination popup", function()
	local restoreMainSkill
	after_each(function()
		if restoreMainSkill then restoreMainSkill(); restoreMainSkill = nil end
		while main.popups and main.popups[1] do main:ClosePopup() end
	end)

	it("draws focus, proposal budget, and exact native search controls without mutating the build", function()
		newBuild()
		local originalGetMainSkill = RoutePlanner.GetMainSkill
		restoreMainSkill = function() RoutePlanner.GetMainSkill = originalGetMainSkill end
		local skill = { effectId = "Fireball", gemId = "Metadata/Items/Gems/SkillGemFireball",
			slot = "Body Armour", socketEvidence = { status = "linked", socketCount = 1 } }
		RoutePlanner.GetMainSkill = function()
			return skill, nil, { skill = skill, baseline = { CombinedDPS = 12000000, TotalEHP = 60000 },
				objectiveMetric = "CombinedDPS" }
		end

		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		tab:OpenRoutePlanner()
		assert.are.equal("true", tab.textValues.useImportedRouteMemory,
			"the checked archive-pattern option must reach the solver even before the user clicks it")
		local popup = assert(main.popups[1])
		assert.are.equal("AI Planner — Combinações", popup.title)
		assert.is_truthy(popup.controls.engineStatus, "the primary view should explain native exact calculation")
		assert.is_nil(popup.controls.routePlannerModelPackageId, "optional model selection should not crowd route setup")
		assert.is_nil(popup.controls.openArchivedSeeds, "seed-library navigation belongs in advanced settings")
		assert.is_truthy(popup.controls.advanced)
		popup.controls.advanced:Click()
		popup = assert(main.popups[1])
		assert.is_truthy(popup.controls.routePlannerModelPackageId, "approved model packages should be selectable in advanced settings")
		assert.is_truthy(popup.controls.modelStatus, "model availability should be visible in advanced settings")
		assert.is_truthy(popup.controls.openArchivedSeeds, "collected native XML seeds should have their own selector")
		assert.is_truthy(popup.controls.archivedSeedStatus, "the seed archive state should be visible separately from GNN status")
		assert.is_true(popup.controls.useImportedRoutes.state, "compatible build patterns should be enabled by default")
		popup.controls.useImportedRoutes.state = false
		popup.controls.useImportedRoutes.changeFunc(false)
		assert.are.equal("false", tab.textValues.useImportedRouteMemory,
			"turning off archive patterns must disable them in the RunSpec")
		popup.controls.useImportedRoutes.state = true
		popup.controls.useImportedRoutes.changeFunc(true)
		assert.are.equal("true", tab.textValues.useImportedRouteMemory)
		assert.is_truthy(popup.controls.damageFocus)
		assert.is_truthy(popup.controls.defenseProfile)
		assert.is_truthy(popup.controls.rankingPriority)
		assert.is_truthy(popup.controls.routePlannerProposalLimit)
		assert.is_truthy(popup.controls.useNodePower)
		assert.is_truthy(popup.controls.run)

		for name, control in pairs(popup.controls) do
			local ok, err = pcall(function() return control:IsShown() end)
			assert.is_true(ok, "control '" .. tostring(name) .. "' must be safe to draw: " .. tostring(err))
		end

		assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
			"opening/drawing route settings must leave the active build unchanged")
		local engine = Version.Snapshot(build)
		tab.routePlannerSeedCatalogJobs = { }
		tab.routePlannerSeedCatalogJob = nil
		tab.routePlannerSeedCatalog = {
			key = table.concat({ tostring(main.userPath or ""), tostring(engine.dataVersion), tostring(engine.treeVersion) }, "\31"),
			status = "ready",
			seeds = {
				{ xmlSha256 = string.rep("a", 64), patch = tostring(engine.dataVersion), treeVersion = tostring(engine.treeVersion),
					skill = { name = "Fireball" }, class = "Witch", ascendancy = "Elementalist", level = 90, label = "QA seed A" },
				{ xmlSha256 = string.rep("b", 64), patch = tostring(engine.dataVersion), treeVersion = tostring(engine.treeVersion),
					skill = { name = "Cyclone" }, class = "Duelist", ascendancy = "Slayer", level = 95, label = "QA seed B" },
			},
		}
		popup.controls.openArchivedSeeds:Click()
		local seedPopup = assert(main.popups[1])
		assert.are.equal(1, #main.popups, "the archive picker must replace the route dialog, avoiding stale build snapshots")
		assert.are.equal(DisplayText.Native("Builds-semente arquivadas"), seedPopup.title)
		assert.is_truthy(seedPopup.controls.search)
		assert.is_truthy(seedPopup.controls.seed)
		assert.is_truthy(seedPopup.controls.openSeed)
		seedPopup.controls.seed:SetSel(2)
		assert.are.equal(string.rep("b", 64), tab.textValues.routePlannerSeedXmlSha256)
		seedPopup.controls.search:SetText("Cyclone")
		assert.is_truthy(seedPopup.controls.summary:GetProperty("label"):find("Direitos não verificados", 1, true))
		assert.is_true(seedPopup.controls.openSeed.enabled())
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "listing or selecting a seed must not replace the active build")
		seedPopup.controls.close:Click()
	end)
end)
