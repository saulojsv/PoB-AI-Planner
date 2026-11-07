local DisplayText = require("Modules.Optimizer.DisplayText")
local Candidate = require("Modules.Optimizer.Candidate")
local OptimizerTab = require("Classes.OptimizerTab")
local RoutePlanner = require("Modules.Optimizer.RoutePlanner")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local GNNIPC = require("Modules.Optimizer.GNNIPC")
local Version = require("Modules.Optimizer.Version")
local Calcs = require("Modules.Calcs")

describe("AI Planner combination workflow", function()
	local restorePlannerCatalogStubs
	before_each(function()
		while main.popups and main.popups[1] do main:ClosePopup() end
	end)
	after_each(function()
		if restorePlannerCatalogStubs then
			restorePlannerCatalogStubs()
			restorePlannerCatalogStubs = nil
		end
		while main.popups and main.popups[1] do main:ClosePopup() end
	end)

	it("keeps combinations searchable for an unlinked Main Skill while warning that results need native socket proof", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local tab = build.optimizerTab
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1], "the combination setup should open a popup")
		assert.are.equal(DisplayText.Native("AI Planner — Combinações"), popup.title)
		assert.is_true(popup.controls.run.enabled(), "a valid selected effect must be searchable even while its physical link is unresolved")
		assert.is_truthy(popup.controls.skill:GetProperty("label"):find("vínculo físico pendente", 1, true))
		local blockedSkillLabel = popup.controls.skill:GetProperty("label")
		assert.is_truthy(type(blockedSkillLabel) == "string"
			and blockedSkillLabel:lower():find("fireball", 1, true),
			"the selected Main Skill identity must remain visible: " .. tostring(blockedSkillLabel))
		local baselineLabel = popup.controls.baseline:GetProperty("label")
		assert.is_truthy(baselineLabel:find("Baseline nativo", 1, true))
		assert.is_truthy(baselineLabel:find("DPS da Main Skill", 1, true),
			"the baseline must use a readable DPS label instead of the internal metric key")
		assert.is_nil(baselineLabel:find("CombinedDPS", 1, true),
			"the baseline must not expose the internal metric key")
		local floorStatus = popup.controls.floorStatus:GetProperty("label")
		assert.is_truthy(type(floorStatus) == "string" and floorStatus:lower():find("piso", 1, true),
			"the exact baseline/floor comparison should be visible: " .. tostring(floorStatus))
		assert.is_truthy(popup.controls.configure, "the setup action remains available while searching")
		assert.is_truthy(popup.controls.socketWarning, "unlinked inputs need a visible warning without disabling generation")
		assert.is_truthy(popup.controls.socketWarning:GetProperty("label"):find("Busca habilitada", 1, true))
		assert.is_nil(popup.controls.fixSkills, "a repair hint must not turn a searchable build into a hard UI block")
		assert.is_truthy(popup.controls.combinationScope:GetProperty("label"):lower():find("build aberta", 1, true))
		assert.is_truthy(popup.controls.combinationScope:GetProperty("label"):find("Raros teóricos", 1, true))
		assert.is_truthy(popup.controls.combinationScope:GetProperty("label"):find("frascos ficam intactos", 1, true))
		assert.is_truthy(popup.controls.damageFocus, "elemental focus must be selectable in the planner")
		assert.are.equal("Auto", popup.controls.damageFocus:GetSelValue().val, "the default focus remains automatic unless changed")
		assert.is_truthy(popup.controls.defenseProfile, "Energy Shield and other defense profiles must be selectable")
		assert.is_truthy(popup.controls.routePlannerProposalLimit, "bounded 10k/40k/100k exploration limits must be selectable")
		assert.is_truthy(popup.controls.routePlannerExactEvaluationBudget,
			"the exact-calculation budget should be available beside the proposal count")
		assert.is_truthy(popup.controls.targetNodeSummary:GetProperty("label"):find("busca geral", 1, true))
		popup.controls.damageFocus:SetSel(5)
		popup.controls.defenseProfile:SetSel(3)
		popup.controls.routePlannerProposalLimit:SetSel(3)
		popup.controls.routePlannerExactEvaluationBudget:SetSel(3)
		assert.are.equal("Fire", tab.textValues.damageFocus, "the fire selector must persist its categorical value")
		assert.are.equal("EnergyShield", tab.textValues.defenseProfile, "the Energy Shield selector must persist its categorical value")
		assert.are.equal("100000", tab.textValues.routePlannerProposalLimit, "the proposal selector must persist its categorical value")
		assert.are.equal("1000", tab.textValues.routePlannerExactEvaluationBudget)
		assert.is_nil(popup.controls.routePlannerModelPackageId,
			"model selection should stay out of the primary route-generation screen")
		assert.is_nil(popup.controls.openArchivedSeeds,
			"seed-library navigation should stay out of the primary route-generation screen")
		assert.is_truthy(popup.controls.engineStatus:GetProperty("label"):find("motor nativo do PoB", 1, true),
			"the first screen should state that exact calculation remains native to PoB")
		assert.is_nil(popup.controls.routePlannerCrossSkillMode, "unsupported triggers should not appear as selectable modes")
		assert.is_nil(popup.controls.trainingConsent, "combination search should not present a training export toggle")
		assert.is_nil(popup.controls.routePlannerElementalHitTier, "secondary defensive floors should start collapsed")
		assert.is_nil(popup.controls.rankingPriority, "ranking detail should start collapsed")
		assert.is_nil(popup.controls.routePlannerConversionRoute, "conversion requirements belong in advanced settings")
		assert.is_nil(popup.controls.useImportedRoutes, "archive filters should not crowd the first view")
		assert.is_truthy(popup.controls.advanced)
		assert.is_truthy(popup.controls.budgetNote:GetProperty("label"):find("10k/40k/100k", 1, true))
		assert.is_truthy(popup.controls.budgetNote:GetProperty("label"):find("até 1,000 recálculos exatos", 1, true))
		popup.controls.advanced:Click()
		local expanded = assert(main.popups[1], "advanced controls should reopen the setup")
		assert.is_truthy(expanded.controls.routePlannerModelPackageId,
			"approved model selection should remain available in advanced settings")
		assert.are.equal("", expanded.controls.routePlannerModelPackageId:GetSelValue().val,
			"native PoB is the explicit fallback when no compatible GNN package is selected")
		assert.is_truthy(expanded.controls.modelStatus, "model-catalog details should be available in advanced settings")
		assert.is_truthy(expanded.controls.routePlannerModelPackageId.tooltipText:find("XMLs arquivados", 1, true),
			"archived build XMLs must not be presented as trained model packages")
		assert.is_truthy(expanded.controls.openArchivedSeeds,
			"the archived seed library remains available in advanced settings")
		assert.is_truthy(expanded.controls.rankingPriority, "ranking should be available for detailed control")
		assert.is_truthy(expanded.controls.routePlannerDpsGain,
			"post-nerf recovery should support an exact relative DPS floor")
		assert.are.equal("NO_LOSS", expanded.controls.routePlannerDpsGain:GetSelValue().val)
		expanded.controls.routePlannerDpsGain:SetSel(4)
		assert.are.equal("GAIN_10_PERCENT", tab.textValues.routePlannerDpsGain)
		local relativeFloorStatus = expanded.controls.floorStatus:GetProperty("label")
		assert.is_truthy(relativeFloorStatus:find("baseline atual do PoB", 1, true), relativeFloorStatus)
		assert.is_truthy(relativeFloorStatus:find("10%", 1, true), relativeFloorStatus)
		assert.is_truthy(expanded.controls.routePlannerConversionRoute, "an exact conversion gate belongs in advanced settings")
		assert.is_truthy(expanded.controls.routePlannerConversionMinimum)
		assert.is_truthy(expanded.controls.routePlannerScenario)
		assert.is_truthy(expanded.controls.useImportedRoutes, "compatible archived trees should remain optional guidance")
		assert.is_true(expanded.controls.useImportedRoutes.state)
		assert.is_truthy(expanded.controls.useImportedRoutes.tooltipText:find("propostas locais", 1, true))
		assert.is_truthy(expanded.controls.useNodePower, "Show Node Power should remain an advanced ordering hint")
		assert.is_truthy(expanded.controls.selectTarget, "direct passive target selection should remain available")
		tab.textValues.routePlannerModelPackageId = "stale-model-for-old-scenario"
		expanded.controls.routePlannerScenario:SetSel(2)
		assert.are.equal("", tab.textValues.routePlannerModelPackageId,
			"changing the scenario must clear a package that has not been checked for the new compatibility key")
		expanded.controls.rankingPriority:SetSel(2)
		expanded.controls.routePlannerConversionRoute:SetSel(2)
		expanded.controls.routePlannerConversionMinimum:SetSel(2)
		assert.are.equal("DefenseFirst", tab.textValues.rankingPriority)
		assert.are.equal("PHYSICAL_TO_FIRE", tab.textValues.routePlannerConversionRoute)
		assert.are.equal("75", tab.textValues.routePlannerConversionMinimum)
		expanded.controls.useImportedRoutes.state = false
		expanded.controls.useImportedRoutes.changeFunc(false)
		assert.are.equal("false", tab.textValues.useImportedRouteMemory)
		assert.is_true(expanded.controls.run.enabled(), "socket warnings must not disable the native generator")
		main:ClosePopup()
		newBuild()
	end)

	it("keeps the exact budget on the primary screen and groups detailed gates in advanced settings", function()
		newBuild()
		local tab = build.optimizerTab
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_truthy(popup.controls.routePlannerExactEvaluationBudget)
		assert.are.equal("5000", popup.controls.routePlannerExactEvaluationBudget:GetSelValue().val,
			"the first view should use the expanded exact-search budget")
		assert.is_truthy(popup.controls.budgetNote:GetProperty("label"):find("até 5,000 recálculos exatos", 1, true),
			"the primary screen should state the new default exact-search quota")
		popup.controls.routePlannerExactEvaluationBudget:SetSel(2)
		assert.are.equal("500", tab.textValues.routePlannerExactEvaluationBudget,
			"the selector must persist its categorical budget")
		assert.is_truthy(popup.controls.budgetNote:GetProperty("label"):find("500 recálculos exatos", 1, true))
		assert.is_truthy(popup.controls.routePlannerExactEvaluationBudget.tooltipText:find("prazo dessa fase", 1, true))
		popup.controls.routePlannerExactEvaluationBudget:SetSel(5)
		assert.are.equal("5000", tab.textValues.routePlannerExactEvaluationBudget)
		assert.is_truthy(popup.controls.budgetNote:GetProperty("label"):find("5,000 recálculos exatos / 30 min", 1, true))
		popup.controls.routePlannerExactEvaluationBudget:SetSel(6)
		assert.are.equal("10000", tab.textValues.routePlannerExactEvaluationBudget)
		assert.is_truthy(popup.controls.budgetNote:GetProperty("label"):find("10,000 recálculos exatos / 60 min", 1, true))
		assert.is_nil(popup.controls.routePlannerPhysicalHitTier)
		popup.controls.advanced:Click()
		local expanded = assert(main.popups[1], "expanding options should reopen the planner")
		assert.is_truthy(expanded.controls.routePlannerPhysicalHitTier)
		assert.is_truthy(expanded.controls.routePlannerElementalResists)
		main:ClosePopup()
		newBuild()
	end)

	it("keeps route generation active when a native item rework can repair the selected skill sockets", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		local item = new("Item"):Item("Rarity: Rare\nSocket Repair Seed\nVaal Regalia\nSockets: R\n--------\n+80 to maximum Life")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = item.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		build.skillsTab.socketGroupList[1].slot = "Body Armour"
		build.skillsTab:ProcessSocketGroup(build.skillsTab.socketGroupList[1])
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		-- A wrong primary-gem color can leave PoB with no display skill entry even
		-- though the XML still contains one unambiguous active Main Skill gem.
		build.skillsTab.socketGroupList[1].displaySkillList = { }

		local tab = build.optimizerTab
		tab.RefreshOverviewDirectionControls(true)
		assert.is_true(tab.overviewSkillHasOptions,
			"the route-first overview should expose an unambiguous native gem when a legal socket repair exists")
		-- The loaded Main Skill is enough for the Route Planner. Clearing the
		-- independent Matrix optimizer target must not hide its entry point.
		tab.textValues.targetSkillGroupIndex = ""
		tab.textValues.targetSkillIndex = ""
		tab.textValues.targetSkillGemId = ""
		assert.is_false(tab.controls.overviewRun.enabled(),
			"the generic Matrix optimizer still requires its own target gem")
		assert.is_true(tab.controls.overviewRoutes.enabled(),
			"the overview route button must open the repairable combination flow independently of Matrix selections")
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_true(popup.controls.run.enabled(),
			"a wrong socket color should trigger replacement-item search instead of blocking the generator")
		assert.is_truthy(popup.controls.skill:GetProperty("label"):find("reparo nativo exigido", 1, true),
			"the loaded raw gem identity should show that PoB will repair sockets in a disposable candidate")
		assert.is_truthy(popup.controls.run.tooltipText:find("reparos necessários de sockets/links", 1, true))
		assert.is_nil(popup.controls.fixSkills, "a repairable socket-color mismatch should not require manual intervention")
		main:ClosePopup(popup)
		newBuild()
	end)

	it("explains and cancels an active optimizer job instead of silently disabling route generation", function()
		newBuild()
		local tab = build.optimizerTab
		local originalGetMainSkill = RoutePlanner.GetMainSkill
		RoutePlanner.GetMainSkill = function()
			return {
				effectId = "CycloneAltX",
				gemId = "Metadata/Items/Gems/SkillGemCycloneAltX",
				slot = "Body Armour",
				socketEvidence = { status = "linked", socketCount = 6 },
			}, nil, { baseline = { CombinedDPS = 12000000, TotalEHP = 60000 } }
		end
		local cancelReason
		tab.job = {
			status = "running",
			routePlannerRun = true,
			progress = { phase = "Exact calculations", processed = 12, total = 48 },
			Cancel = function(_, reason) cancelReason = reason end,
		}
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_false(popup.controls.run.enabled(), "a second native search must not overlap the active job")
		assert.is_true(popup.controls.activeSearchStatus:IsShown())
		assert.is_truthy(popup.controls.activeSearchStatus:GetProperty("label"):find("Recalculando combinações", 1, true))
		assert.is_truthy(popup.controls.activeSearchStatus:GetProperty("label"):find("12/48", 1, true))
		assert.is_true(popup.controls.cancelActiveSearch:IsShown())
		assert.is_true(popup.controls.cancelActiveSearch:IsEnabled())
		assert.is_false(popup.controls.advanced:IsShown(),
			"the active-search view should hide settings to keep progress and actions unobstructed")
		assert.is_false(popup.controls.routePlannerExactEvaluationBudget:IsShown(),
			"the exact-budget selector must not overlap live search counters")
		popup.controls.cancelActiveSearch:Click()
		assert.are.equal("user_cancelled", cancelReason, "the visible action should cancel the blocking job")
		tab.job = nil
		assert.is_false(popup.controls.activeSearchStatus:IsShown())
		assert.is_false(popup.controls.cancelActiveSearch:IsShown())
		assert.is_true(popup.controls.run.enabled(), "route generation must re-enable as soon as the active job ends")
		main:ClosePopup(popup)
		RoutePlanner.GetMainSkill = originalGetMainSkill
		newBuild()
	end)

	it("starts the route time budget only after structural generation reaches exact calculations", function()
		newBuild()
		local tab = build.optimizerTab
		local cancelReason
		local job = {
			status = "running",
			routePlannerRun = true,
			progress = { phase = "Pathfinding", processed = 25, total = 100 },
			Cancel = function(_, reason) cancelReason = reason end,
			Step = function() return "running" end,
		}
		tab.job = job
		tab.activeRunTimeoutSeconds = 120
		tab.activeRunDeadline = nil
		tab.routePlannerTimedOut = false

		tab:Tick()
		assert.is_nil(tab.activeRunDeadline, "path generation must not consume the exact-calculation budget")
		assert.is_nil(cancelReason, "a slow structural phase must not cancel before native calculations start")

		job.progress.phase = "Exact calculations"
		tab:Tick()
		assert.are.equal("number", type(tab.activeRunDeadline), "the deadline should start when exact calculations begin")
		assert.is_true(tab.activeRunDeadline > os.clock())
		assert.is_nil(cancelReason)

		tab.job = nil
		tab.activeRunDeadline = nil
		tab.activeRunTimeoutSeconds = nil
		newBuild()
	end)

	it("keeps Cyclone of Tumult active for a six-socket repair on a unique chest", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Duelist))
		build.characterLevel = 95
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nCyclone of Tumult 20/20 1\nAwakened Brutality 5/20 1\nAwakened Melee Physical Damage 5/20 1\nInfused Channelling 20/20 1\nLifetap 20/20 1\nMaim 20/20 1")
		build.mainSocketGroup = 1
		local item = new("Item"):Item("Rarity: Unique\nFoulborn Gruthkul's Pelt\nWyrmscale Doublet\nSockets: R-R-B-G-R-R")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = item.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		local group = build.skillsTab.socketGroupList[1]
		group.slot = "Body Armour"
		build.skillsTab:ProcessSocketGroup(group)
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		group.displaySkillList = { }
		-- Stale empty groups can remain in imported PoB state. They consume no
		-- sockets and must not make a valid six-socket repair plan disappear.
		build.skillsTab.socketGroupList[#build.skillsTab.socketGroupList + 1] = {
			slot = "Body Armour", gemList = { }, enabled = true, slotEnabled = true,
		}
		-- Disabled saved groups do not consume sockets in the active PoB
		-- calculation. They must not make a legal six-socket repair disappear.
		build.skillsTab.socketGroupList[#build.skillsTab.socketGroupList + 1] = {
			slot = "Body Armour", gemList = { group.gemList[1] }, enabled = false, slotEnabled = true,
		}

		local skill, skillError, context = RoutePlanner.GetMainSkill(build)
		assert.is_table(context and context.socketRepair,
			"the six-gem Cyclone group should produce a legal disposable socket plan: " .. tostring(skillError))
		assert.are.equal("G", context.socketRepair.colors[1], "Cyclone of Tumult requires a green first socket")
		assert.are.equal(6, context.socketRepair.socketCount, "the repair must preserve the complete six-gem link")
		assert.is_table(skill, "a repairable Main Skill remains available to the planner without editing the source build")
		assert.is_false(context.socketEvidence.valid, "the loaded source item remains physically invalid until a candidate is recalculated")

		local tab = build.optimizerTab
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_true(popup.controls.run.enabled(), "a unique chest must not block native item-rework proposals")
		assert.is_true(popup.controls.run:IsEnabled(), "the rendered PoB button must be clickable when native socket repair is available")
		assert.is_truthy(popup.controls.skill:GetProperty("label"):find("reparo nativo exigido", 1, true))
		assert.is_truthy(popup.controls.run.tooltipText:find("reparos necessários de sockets/links", 1, true))
		tab.textValues.routePlannerModelPackageId = "not-yet-verified-package"
		tab.routePlannerModelCatalog = { status = "loading", models = { } }
		assert.is_true(popup.controls.run.enabled(),
			"an unresolved optional GNN model must not disable the native generator")
		assert.are.equal("not-yet-verified-package", tab.textValues.routePlannerModelPackageId,
			"the draw-time enabled predicate must not mutate saved selection state")
		local originalStartOptimizer = tab.StartOptimizer
		local startCaptured = false
		local runRoutePlannerCalled = false
		tab.StartOptimizer = function(self, values)
			startCaptured = true
			assert.are.equal("", values.routePlannerModelPackageId,
				"a model still loading must use the native deterministic fallback")
			assert.are.equal("deterministic_fallback", values.routePlannerModelMode)
			return true, { status = "running" }
		end
		local originalRunRoutePlanner = tab.RunRoutePlanner
		tab.RunRoutePlanner = function(self)
			runRoutePlannerCalled = true
			return originalRunRoutePlanner(self)
		end
		popup.controls.run:Click()
		tab.RunRoutePlanner = originalRunRoutePlanner
		tab.StartOptimizer = originalStartOptimizer
		assert.is_true(runRoutePlannerCalled, "clicking the rendered generator must enter the route-planner flow")
		assert.is_true(startCaptured, "the generator should reach the search startup")
		assert.are.equal("", tab.textValues.routePlannerModelPackageId)
		newBuild()
	end)

	it("keeps the generator active when a disabled support must be removed to fit native sockets", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Duelist))
		build.characterLevel = 95
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nCyclone of Tumult 20/20 1\nAwakened Brutality 5/20 1\nAwakened Melee Physical Damage 5/20 1\nInfused Channelling 20/20 1\nLifetap 20/20 1\nMaim 20/20 1")
		build.mainSocketGroup = 1
		local item = new("Item"):Item("Rarity: Rare\nSocket Repair Overflow Seed\nSacred Chainmail\nSockets: R-R-B-G-R-R")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = item.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		local group = build.skillsTab.socketGroupList[1]
		group.slot = "Body Armour"
		build.skillsTab:ProcessSocketGroup(group)
		local disabledSupport
		for _, gemData in pairs(build.data.gems or { }) do
			local effect = gemData.grantedEffect
			if effect and effect.support and not effect.unsupported then
				local alreadyPresent = false
				for _, gem in ipairs(group.gemList) do
					if gem.gemId == gemData.id then alreadyPresent = true; break end
				end
				if not alreadyPresent then disabledSupport = gemData; break end
			end
		end
		assert.is_truthy(disabledSupport, "the fixture needs a native support gem to mark as inactive")
		group.gemList[#group.gemList + 1] = {
			gemData = disabledSupport,
			gemId = disabledSupport.id,
			skillId = disabledSupport.grantedEffectId,
			nameSpec = disabledSupport.name,
			level = 1,
			quality = 0,
			enabled = false,
			enableGlobal1 = true,
			enableGlobal2 = true,
			count = 1,
		}
		build.skillsTab:ProcessSocketGroup(group)
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local skill, skillError, context = RoutePlanner.GetMainSkill(build)
		assert.is_table(skill, skillError)
		local repair = assert(context.socketRepair,
			"a six-socket item should be repairable by removing only the extra disabled support")
		assert.are.equal(6, repair.socketCount)
		assert.are.equal(1, #repair.gemRemovals)
		assert.are.equal("support_remove", repair.gemRemovals[1].kind)
		assert.are.equal(disabledSupport.id, repair.gemRemovals[1].gemId)
		assert.are.equal(#group.gemList, repair.socketCount + #repair.gemRemovals)

		local tab = build.optimizerTab
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_true(popup.controls.run:IsEnabled(),
			"a removable disabled support must not leave the generator stuck on a blocker")
		assert.is_truthy(popup.controls.skill:GetProperty("label"):find("removerá 1", 1, true))
		local runSpec, prepareError = RoutePlanner.Prepare(build, tab.textValues)
		assert.is_table(runSpec, prepareError)
		assert.are.equal(disabledSupport.id, runSpec.skill.socketRepair.gemRemovals[1].gemId,
			"the removal plan must reach the native exact-search RunSpec")
		newBuild()
	end)

	it("keeps the generator active and plans every active item socket repair together", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Duelist))
		build.characterLevel = 95
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nCyclone of Tumult 20/20 1\nAwakened Brutality 5/20 1\nAwakened Melee Physical Damage 5/20 1\nInfused Channelling 20/20 1\nLifetap 20/20 1\nMaim 20/20 1")
		build.mainSocketGroup = 1
		local chest = new("Item"):Item("Rarity: Unique\nFoulborn Gruthkul's Pelt\nWyrmscale Doublet\nSockets: R-R-B-G-R-R")
		build.itemsTab:AddItem(chest, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = chest.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(chest.id)
		build.itemsTab:PopulateSlots()
		local mainGroup = build.skillsTab.socketGroupList[1]
		mainGroup.slot = "Body Armour"
		build.skillsTab:ProcessSocketGroup(mainGroup)
		build.skillsTab:UpdateSocketGroups()
		build.skillsTab:PasteSocketGroup("Slot: Helmet\nVulnerability 20/0 1\nBlasphemy 20/0 1")
		local curseGroup = build.skillsTab.socketGroupList[#build.skillsTab.socketGroupList]
		curseGroup.slot = "Helmet"
		local helmet = new("Item"):Item("Rarity: Rare\nSocket Repair Helmet\nHubris Circlet\nSockets: B-B\n--------\n+70 to maximum Life")
		build.itemsTab:AddItem(helmet, true)
		build.itemsTab.activeItemSet.Helmet.selItemId = helmet.id
		build.itemsTab.slots.Helmet:SetSelItemId(helmet.id)
		build.itemsTab:PopulateSlots()
		build.skillsTab:ProcessSocketGroup(curseGroup)
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		mainGroup.displaySkillList = { }

		local allGroupsValid, activeProof = SkillCatalog.ValidateEnabledSocketGroups(build, build.itemsTab)
		assert.is_false(allGroupsValid, "the source build deliberately has two physical socket violations")
		assert.are.equal(2, #activeProof.violations,
			"the exact socket audit must include the non-Main Skill group even when it is not Full DPS")
		local skill, skillError, context = RoutePlanner.GetMainSkill(build)
		assert.is_table(skill, "the repairable Main Skill must keep the route planner usable: " .. tostring(skillError))
		assert.are.equal(2, #context.socketRepairs, "the route plan must contain one item rework per invalid slot")
		assert.are.equal("Body Armour", context.socketRepairs[1].slot)
		assert.are.equal("Helmet", context.socketRepairs[2].slot)
		assert.are.equal("G", context.socketRepairs[1].colors[1], "Cyclone requires a green first socket")
		assert.are.equal("R", context.socketRepairs[2].colors[1], "Vulnerability requires a red first socket")
		local runSpec = assert(RoutePlanner.Prepare(build, { }))
		assert.are.equal(2, #runSpec.skill.socketRepairs, "the RunSpec must carry both repair plans into search")

		build.optimizerTab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_true(popup.controls.run:IsEnabled(), "two repairable active groups must not gray out the generator")
		local status = popup.controls.skill:GetProperty("label")
		assert.is_truthy(status:find("Body Armour, Helmet", 1, true),
			"the UI should show both equipment slots that will be repaired in disposable candidates")
		main:ClosePopup(popup)

		local repairedChest = new("Item"):Item("Rarity: Rare\nSocket Proof Chest\nSimple Robe\nSockets: G-R-R-B-R-R\n--------\n+50 to maximum Life")
		local repairedHelmet = new("Item"):Item("Rarity: Rare\nSocket Proof Helmet\nIron Hat\nSockets: R-B\n--------\n+50 to maximum Life")
		build.itemsTab:AddItem(repairedChest, true)
		build.itemsTab:AddItem(repairedHelmet, true)
		local targetItemSet = { useSecondWeaponSet = build.itemsTab.activeItemSet.useSecondWeaponSet }
		for slotName, itemState in pairs(build.itemsTab.activeItemSet) do
			if type(itemState) == "table" then
				targetItemSet[slotName] = { selItemId = itemState.selItemId }
			end
		end
		targetItemSet["Body Armour"] = { selItemId = repairedChest.id }
		targetItemSet.Helmet = { selItemId = repairedHelmet.id }
		local allRepairedGroupsValid, exactRepairProof = SkillCatalog.ValidateEnabledSocketGroups(
			build, build.itemsTab, targetItemSet)
		assert.is_true(allRepairedGroupsValid, "the composed Body Armour + Helmet set must physically host every active group")
		assert.are.equal(0, #exactRepairProof.violations)
		local sourceSignature = Candidate.BuildSignature(build)
		local candidateForRepair = {
			feasible = true,
			sourceSignature = sourceSignature,
			generationPhase = "combined",
			nodeIds = { },
			removeNodeIds = { },
			gearVariant = { overrides = { ["Body Armour"] = repairedChest.id, Helmet = repairedHelmet.id },
				changedSlots = { "Body Armour", "Helmet" } },
			evaluation = { routePlannerSearchMode = runSpec.searchMode,
				routePlannerSocketProofs = { status = "pass", groups = { }, violations = { } } },
		}
		local projectedSpec, projectionError, projectedItems = Candidate.BuildPassiveSpec(
			build, { }, { }, { gearVariant = candidateForRepair.gearVariant })
		assert.is_truthy(projectedSpec, projectionError)
		local isolatedBuild = { spec = projectedSpec, itemsTab = projectedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local exactOutput = exactCalc({ spec = projectedSpec, returnEnv = true }, true)
		assert.is_truthy(exactOutput and type(exactOutput.CombinedDPS) == "number",
			"the fully repaired multi-slot route must reach PoB's exact native calculation")
		allRepairedGroupsValid, exactRepairProof = SkillCatalog.ValidateEnabledSocketGroups(isolatedBuild, projectedItems)
		assert.is_true(allRepairedGroupsValid, "all active groups must pass the native socket proof after exact calculation")
		for _, groupProof in ipairs(exactRepairProof.groups) do
			if groupProof.groupIndex ~= #build.skillsTab.socketGroupList then
				candidateForRepair.evaluation.routePlannerSocketProofs.groups[#candidateForRepair.evaluation.routePlannerSocketProofs.groups + 1] = groupProof
			end
		end
		local appliedWithoutHelmetProof, missingProofError = Candidate.Apply(build, candidateForRepair)
		assert.is_false(appliedWithoutHelmetProof,
			"a route missing exact proof for the non-Main Helmet group must not be applied")
		assert.is_truthy(tostring(missingProofError):find("every active skill group", 1, true), tostring(missingProofError))
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "rejecting an incomplete proof must leave the source build unchanged")
		candidateForRepair.evaluation.routePlannerSocketProofs.groups = exactRepairProof.groups
		local appliedWithAllProofs, applyError = Candidate.Apply(build, candidateForRepair)
		assert.is_true(appliedWithAllProofs, applyError)
		assert.is_true(SkillCatalog.ValidateEnabledSocketGroups(build, build.itemsTab))
		build.itemsTab:Undo()
		newBuild()
	end)

	it("keeps the generator active when imported items lack base metadata but retain native sockets", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Duelist))
		build.characterLevel = 95
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nCyclone of Tumult 20/20 1\nAwakened Brutality 5/20 1\nAwakened Melee Physical Damage 5/20 1\nInfused Channelling 20/20 1\nLifetap 20/20 1\nMaim 20/20 1")
		build.mainSocketGroup = 1
		local chest = new("Item"):Item("Rarity: Unique\nFoulborn Gruthkul's Pelt\nWyrmscale Doublet\nSockets: R-R-B-G-R-R")
		build.itemsTab:AddItem(chest, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = chest.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(chest.id)
		build.itemsTab:PopulateSlots()
		local mainGroup = build.skillsTab.socketGroupList[1]
		mainGroup.slot = "Body Armour"
		build.skillsTab:ProcessSocketGroup(mainGroup)
		build.skillsTab:UpdateSocketGroups()
		build.skillsTab:PasteSocketGroup("Slot: Helmet\nVulnerability 20/0 1\nBlasphemy 20/0 1")
		local curseGroup = build.skillsTab.socketGroupList[#build.skillsTab.socketGroupList]
		curseGroup.slot = "Helmet"
		local helmet = new("Item"):Item("Rarity: Rare\nSocket Repair Helmet\nHubris Circlet\nSockets: B-B\n--------\n+70 to maximum Life")
		build.itemsTab:AddItem(helmet, true)
		build.itemsTab.activeItemSet.Helmet.selItemId = helmet.id
		build.itemsTab.slots.Helmet:SetSelItemId(helmet.id)
		build.itemsTab:PopulateSlots()
		build.skillsTab:ProcessSocketGroup(curseGroup)
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		mainGroup.displaySkillList = { }

		-- Imported equipment can preserve its exact native socket layout while the
		-- active item instance has no base object. This must not hide a legal
		-- disposable item rework or disable route generation.
		chest.base = nil
		helmet.base = nil
		local skill, skillError, context = RoutePlanner.GetMainSkill(build)
		assert.is_table(skill, "the imported Main Skill must remain searchable: " .. tostring(skillError))
		assert.are.equal(2, #context.socketRepairs, "both invalid equipment links need planned repairs")
		assert.are.equal(0, #context.socketRepairAudit.blockers,
			"missing item base metadata must not be mistaken for an unrepairable socket group")
		local runSpec, prepareError = RoutePlanner.Prepare(build, { })
		assert.is_table(runSpec, "the native RunSpec should include the repairable build: " .. tostring(prepareError))
		assert.are.equal(2, #runSpec.skill.socketRepairs)

		build.optimizerTab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_true(popup.controls.run:IsEnabled(),
			"legal socket repairs must keep the combination generator enabled")
		main:ClosePopup(popup)
		newBuild()
	end)

	it("lists only locally approved models compatible with the current build context", function()
		newBuild()
		local tab = build.optimizerTab
		local originalGetMainSkill = RoutePlanner.GetMainSkill
		local originalConnect = GNNIPC.Connect
		local originalManifestFingerprint = launch.manifestFingerprint
		local originalManifestFingerprintStatus = launch.manifestFingerprintStatus
		local originalVersionBranch = launch.versionBranch
		launch.manifestFingerprint = string.rep("a", 64)
		launch.manifestFingerprintStatus = "available"
		-- The catalog correctly refuses to compare packages when the running
		-- PoB branch is unknown. Give this compatibility test a complete engine
		-- fingerprint instead of depending on the contract runner's launch mode.
		launch.versionBranch = "stable"
		restorePlannerCatalogStubs = function()
			RoutePlanner.GetMainSkill = originalGetMainSkill
			GNNIPC.Connect = originalConnect
			launch.manifestFingerprint = originalManifestFingerprint
			launch.manifestFingerprintStatus = originalManifestFingerprintStatus
			launch.versionBranch = originalVersionBranch
		end
		local skill = { effectId = "IceSpear", gemId = "Metadata/Items/Gems/SkillGemIceSpear",
			slot = "Body Armour", socketEvidence = { status = "linked", socketCount = 6 } }
		local scenario = { profile = "Current", enemyPreset = "Active" }
		local engine = Version.Snapshot(build)
		local compatible = { packageId = "ice-spear-current-v1", modelType = "hetero-gatv2-ensemble-v1",
			skill = { effectId = skill.effectId, gemId = skill.gemId }, scenario = scenario, engine = engine }
		local wrongSkill = { packageId = "wrong-skill-v1", modelType = compatible.modelType,
			skill = { effectId = "Fireball", gemId = "Metadata/Items/Gems/SkillGemFireball" }, scenario = scenario, engine = engine }
		local wrongPatch = { packageId = "wrong-patch-v1", modelType = compatible.modelType,
			skill = compatible.skill, scenario = scenario, engine = { pobVersion = "old" } }
		RoutePlanner.GetMainSkill = function()
			return skill, nil, { skill = skill, baseline = { CombinedDPS = 12000000, TotalEHP = 60000 } }
		end
		GNNIPC.Connect = function()
			return {
				Call = function(_, method, params)
					assert.are.equal("build_planner/list_models", method)
					assert.are.equal(skill.effectId, params.skill.effectId)
					assert.are.equal(scenario.profile, params.scenario.profile)
					return { models = { wrongSkill, wrongPatch, compatible } }
				end,
				Close = function() end,
			}
		end
		tab:OpenRoutePlanner()
		tab:Tick()
		local popup = assert(main.popups[1])
		popup.controls.advanced:Click()
		popup = assert(main.popups[1])
		local modelControl = popup.controls.routePlannerModelPackageId
		assert.are.equal(2, #modelControl.list,
			"only fallback and one exact-compatible approved package should appear; choices="
				.. tostring(#modelControl.list) .. "; catalog="
				.. tostring(tab.routePlannerModelCatalog and tab.routePlannerModelCatalog.status)
				.. "; error=" .. tostring(tab.routePlannerModelCatalog and tab.routePlannerModelCatalog.error)
				.. "; models=" .. tostring(tab.routePlannerModelCatalog and #(tab.routePlannerModelCatalog.models or { }))
				.. "; label=" .. tostring(popup.controls.modelStatus:GetProperty("label")))
		assert.are.equal("", modelControl.list[1].val)
		assert.are.equal("ice-spear-current-v1", modelControl.list[2].val)
		assert.is_truthy(popup.controls.modelStatus:GetProperty("label"):find("1 modelo(s)", 1, true))
		modelControl:SetSel(2)
		assert.are.equal("ice-spear-current-v1", tab.textValues.routePlannerModelPackageId)
		assert.are.equal("approved_gnn", tab.textValues.routePlannerModelMode)
		assert.is_true(popup.controls.run.enabled(), "a compatible package may be selected for route ranking")
		main:ClosePopup(popup)
		restorePlannerCatalogStubs()
		restorePlannerCatalogStubs = nil
		newBuild()
	end)

	it("keeps native route generation available when a saved GNN package is no longer compatible", function()
		newBuild()
		local tab = build.optimizerTab
		local originalGetMainSkill = RoutePlanner.GetMainSkill
		local originalRefreshCatalog = tab.RefreshRoutePlannerModelCatalog
		restorePlannerCatalogStubs = function()
			RoutePlanner.GetMainSkill = originalGetMainSkill
			tab.RefreshRoutePlannerModelCatalog = originalRefreshCatalog
		end
		local skill = { effectId = "Cyclone", gemId = "Metadata/Items/Gems/SkillGemCyclone",
			slot = "Body Armour", socketEvidence = { status = "linked", socketCount = 6 } }
		RoutePlanner.GetMainSkill = function()
			return skill, nil, { skill = skill, baseline = { CombinedDPS = 12000000, TotalEHP = 60000 } }
		end
		-- Simulate an unavailable resolved catalog while the old package ID remains
		-- in persisted state, even though the dropdown is showing native fallback.
		tab.routePlannerModelCatalog = { status = "unavailable", models = { } }
		tab.textValues.routePlannerModelPackageId = "retired-model-v1"
		tab.textValues.routePlannerModelMode = "approved_gnn"
		tab.RefreshRoutePlannerModelCatalog = function() return false end
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_true(popup.controls.run.enabled(), "a missing optional GNN package must not block native PoB search")
		assert.are.equal("", tab.textValues.routePlannerModelPackageId)
		assert.are.equal("deterministic_fallback", tab.textValues.routePlannerModelMode)
		popup.controls.advanced:Click()
		popup = assert(main.popups[1])
		assert.are.equal("", popup.controls.routePlannerModelPackageId:GetSelValue().val)
		main:ClosePopup(popup)
		restorePlannerCatalogStubs()
		restorePlannerCatalogStubs = nil
		newBuild()
	end)

	it("keeps native route generation available while the approved-model catalog is loading", function()
		newBuild()
		local tab = build.optimizerTab
		local originalGetMainSkill = RoutePlanner.GetMainSkill
		local originalRefreshCatalog = tab.RefreshRoutePlannerModelCatalog
		restorePlannerCatalogStubs = function()
			RoutePlanner.GetMainSkill = originalGetMainSkill
			tab.RefreshRoutePlannerModelCatalog = originalRefreshCatalog
		end
		local skill = { effectId = "Cyclone", gemId = "Metadata/Items/Gems/SkillGemCyclone",
			slot = "Body Armour", socketEvidence = { status = "linked", socketCount = 6 } }
		RoutePlanner.GetMainSkill = function()
			return skill, nil, { skill = skill, baseline = { CombinedDPS = 12000000, TotalEHP = 60000 } }
		end
		tab.routePlannerModelCatalog = { status = "loading", models = { } }
		tab.textValues.routePlannerModelPackageId = "pending-model-v1"
		tab.textValues.routePlannerModelMode = "approved_gnn"
		tab.RefreshRoutePlannerModelCatalog = function() return true end
		tab:OpenRoutePlanner()

		local popup = assert(main.popups[1])
		assert.is_true(popup.controls.run.enabled(),
			"the optional model catalog must not lock native route generation while it is loading")
		assert.are.equal("", tab.textValues.routePlannerModelPackageId,
			"an unverified saved model must be cleared before the native fallback runs")
		assert.are.equal("deterministic_fallback", tab.textValues.routePlannerModelMode)
		popup.controls.advanced:Click()
		popup = assert(main.popups[1])
		assert.are.equal("", popup.controls.routePlannerModelPackageId:GetSelValue().val,
			"the visible model dropdown must agree with the native fallback")
		main:ClosePopup(popup)
		restorePlannerCatalogStubs()
		restorePlannerCatalogStubs = nil
		newBuild()
	end)

	it("keeps completed exact routes and the timeout count visible after the search deadline", function()
		newBuild()
		local tab = build.optimizerTab
		local evaluation = { feasible = true, objective = "CombinedDPS", objectiveValue = 12000000,
			metrics = { CombinedDPS = 12000000 }, scenarioProfile = "Current", passivePointsUsed = 100,
			strictPointCap = 130 }
		local route = { feasible = true, sourceSignature = "source-signature", evaluation = evaluation,
			gearVariant = { overrides = { ["Ring 1"] = 123 } } }
		local sameMetricsRoute = { feasible = true, sourceSignature = "source-signature",
			label = "Different exact route with the same metrics",
			gearVariant = { overrides = { ["Ring 1"] = 124 } },
			evaluation = { feasible = true, objective = "CombinedDPS", objectiveValue = 12000000,
				metrics = { CombinedDPS = 12000000 }, scenarioProfile = "Current", passivePointsUsed = 100,
				strictPointCap = 130 } }
		local result = { status = "feasible", candidate = route, evaluation = evaluation,
			paretoFront = { route, sameMetricsRoute }, evaluations = 765, searchInterrupted = true, searchTimedOut = true,
			generationPhase = "combined", searchCoverage = { phase = { exactEvaluations = 765 } } }
		tab.job = {
			status = "running", routePlannerRun = true, sourceSignature = "source-signature", inputSignature = "input-signature",
			Cancel = function(self, reason) self.cancelReason = reason end,
			Step = function() return "feasible", result end,
		}
		tab.activeRunDeadline = 0
		tab:Tick()
		assert.is_nil(tab.job)
		assert.are.equal(result, tab.result)
		assert.is_true(result.routePlanner)
		assert.are.equal("source-signature", result.sourceSignature)
		assert.are.equal("input-signature", result.inputSignature)
		assert.is_truthy(tab.statusMessage:find("2 rotas exatas aprovadas (1 perfil métrico)", 1, true), tab.statusMessage)
		assert.is_truthy(tab.statusMessage:find("765 recálculos exatos concluídos", 1, true), tab.statusMessage)
		assert.is_truthy(tab.statusMessage:find("só candidatas já recalculadas pelo PoB", 1, true), tab.statusMessage)
		newBuild()
	end)

	it("selects a legal route target from the passive tree without allocating it", function()
		newBuild()
		local tab = build.optimizerTab
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		popup.controls.selectTarget:Click()
		assert.is_true(tab.routePlannerTargetSelectMode)
		assert.are.equal("TREE", build.viewMode)
		assert.is_nil(main.popups[1], "target selection should happen directly on the passive tree")

		local targetNode = { id = 9001, type = "Notable", dn = "Target Notable", alloc = false }
		local targetBuild = { optimizerTab = tab, spec = {
			treeVersion = "3_29", nodes = { [9001] = targetNode }, tree = { nodes = { [9001] = { id = 9001 } } },
		} }
		local handled, selected = build.treeTab.viewer:CaptureRoutePlannerTarget(targetBuild, targetNode)
		assert.is_true(handled)
		assert.is_true(selected)
		assert.are.equal("9001", tab.textValues.routePlannerTargetNodeId)
		assert.are.equal("Target Notable", tab.textValues.routePlannerTargetNodeName)
		assert.are.equal("3_29", tab.textValues.routePlannerTargetTreeVersion)
		assert.is_false(tab.routePlannerTargetSelectMode)
		assert.is_false(targetNode.alloc, "selecting a route target must not allocate it in the active build")

		tab.textValues.routePlannerTargetNodeId = ""
		tab.routePlannerTargetSelectMode = true
		local allocatedNode = { id = 9002, type = "Notable", dn = "Allocated Notable", alloc = true }
		targetBuild.spec.nodes[9002] = allocatedNode
		targetBuild.spec.tree.nodes[9002] = { id = 9002 }
		local rejected, wasSelected = build.treeTab.viewer:CaptureRoutePlannerTarget(targetBuild, allocatedNode)
		assert.is_true(rejected)
		assert.is_false(wasSelected)
		assert.is_true(tab.routePlannerTargetSelectMode, "an invalid click must leave target-selection mode active")
		assert.are.equal("", tab.textValues.routePlannerTargetNodeId)
		assert.is_truthy(tab.statusMessage:find("não aceita roteamento direto", 1, true))
		newBuild()
	end)

	it("keeps the overview focused on build setup and route generation", function()
		newBuild()
		local tab = build.optimizerTab
		assert.is_false(tab.controls.overviewImport:IsShown(), "native PoB already has a dedicated Import/Export entry")
		assert.is_false(tab.controls.overviewAI:IsShown(), "Ask AI is a separate surface from route generation")
		assert.is_false(tab.controls.overviewRun:IsShown(), "the generic Optimize action duplicates the Matrix workflow")
		assert.is_false(tab.controls.overviewAdvanced:IsShown(), "advanced settings are available from the route setup and Matrix pages")
		assert.is_false(tab.controls.overviewRefresh:IsShown(), "the readiness report refreshes from the current PoB state automatically")
		assert.are.equal("Gerar rotas", tab.controls.overviewRoutes:GetProperty("label"))
		assert.is_false(tab.controls.overviewResult:IsShown(), "result navigation should appear only after a search completes")
		assert.is_false(tab.controls.overviewCancel:IsShown(), "cancel should appear only while a search is running")
		tab.result = { status = "no_feasible_candidate" }
		assert.is_true(tab.controls.overviewResult:IsShown(), "completed results must expose a direct result action")
		tab.result = nil
		tab.job = { status = "running" }
		assert.is_true(tab.controls.overviewCancel:IsShown(), "running searches must expose cancellation")
		newBuild()
	end)

	it("does not show a blocked-skill warning when the native Main Skill is valid", function()
		newBuild()
		local originalGetMainSkill = RoutePlanner.GetMainSkill
		RoutePlanner.GetMainSkill = function()
			local skill = { effectId = "Metadata/Items/Gems/SkillGemCyclone", gemId = "Metadata/Items/Gems/SkillGemCyclone",
				slot = "Body Armour", socketEvidence = { status = "linked", socketCount = 6 } }
			local context = { baseline = { CombinedDPS = 12000000, TotalEHP = 60000,
				PhysicalMaximumHitTaken = 12000, FireMaximumHitTaken = 15000,
				ColdMaximumHitTaken = 14000, LightningMaximumHitTaken = 13000 } }
			return skill, nil, context
		end
		local tab = build.optimizerTab
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_nil(popup.controls.blockingReason,
			"a valid Main Skill must not produce the fallback blocking reason")
		assert.is_nil(popup.controls.fixSkills,
			"the repair button belongs only to a genuinely blocked skill/socket state")
		assert.is_true(popup.controls.run.enabled(), "a valid exact Main Skill should enable the native search")
		assert.are.equal("AI Planner — Combinações", popup.title)
		main:ClosePopup(popup)
		RoutePlanner.GetMainSkill = originalGetMainSkill
		newBuild()
	end)

	it("keeps generation active when another socket group has no legal repair and marks the limitation", function()
		newBuild()
		local originalGetMainSkill = RoutePlanner.GetMainSkill
		local mainSkill = {
			effectId = "Metadata/Items/Gems/SkillGemCyclone",
			gemId = "Metadata/Items/Gems/SkillGemCyclone",
			groupIndex = 1,
			slot = "Body Armour",
			socketEvidence = { valid = false, status = "invalid", slot = "Body Armour", reason = "Cyclone needs G" },
		}
		local context = {
			skill = mainSkill,
			socketEvidence = mainSkill.socketEvidence,
			socketRepair = { slot = "Body Armour", groupIndices = { 1 } },
			socketRepairs = { { slot = "Body Armour", groupIndices = { 1 } } },
			socketRepairAudit = { blockers = {
				{ groupIndex = 2, group = "2", reason = "no legal native equipment repair" },
			} },
			socketWarnings = {
				{ groupIndex = 2, group = "2", reason = "no legal native equipment repair" },
			},
			baseline = { CombinedDPS = 12000000, TotalEHP = 60000,
				PhysicalMaximumHitTaken = 12000, FireMaximumHitTaken = 15000,
				ColdMaximumHitTaken = 14000, LightningMaximumHitTaken = 13000 },
		}
		RoutePlanner.GetMainSkill = function()
			return mainSkill, nil, context
		end
		restorePlannerCatalogStubs = function()
			RoutePlanner.GetMainSkill = originalGetMainSkill
		end

		build.optimizerTab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_true(popup.controls.run.enabled(),
			"socket validation belongs to exact candidate gates and must not disable structural search")
		assert.is_truthy(popup.controls.socketWarning:GetProperty("label"):find("grupo(s) secundário(s) já têm socket/link inválido", 1, true),
			"the UI must explain that pre-existing secondary socket issues do not block Single Skill search")
		main:ClosePopup(popup)
		RoutePlanner.GetMainSkill = originalGetMainSkill
		restorePlannerCatalogStubs = nil
		newBuild()
	end)

	it("keeps the generator active when the selected Main Skill is identified but its socket repair is unresolved", function()
		newBuild()
		local originalGetMainSkill = RoutePlanner.GetMainSkill
		local mainSkill = {
			effectId = "CycloneAltX",
			gemId = "Metadata/Items/Gems/SkillGemCycloneAltX",
			groupIndex = 1,
			slot = "Body Armour",
			socketEvidence = { valid = false, status = "invalid", slot = "Body Armour",
				reason = "Gem Cyclone of Tumult needs a G socket but PoB item slot Body Armour has R at position 1" },
		}
		local socketReason = mainSkill.socketEvidence.reason
		local context = {
			skill = mainSkill,
			socketEvidence = mainSkill.socketEvidence,
			socketRepair = nil,
			socketRepairs = { },
			socketRepairAudit = { blockers = {
				{ groupIndex = 1, group = "Cyclone of Tumult", slot = "Body Armour", reason = socketReason },
			} },
			socketWarnings = {
				{ groupIndex = 1, group = "Cyclone of Tumult", slot = "Body Armour", reason = socketReason },
			},
			baseline = { CombinedDPS = 17414139.388218, TotalEHP = 188174.088538,
				PhysicalMaximumHitTaken = 18778, FireMaximumHitTaken = 49900,
				ColdMaximumHitTaken = 48118, LightningMaximumHitTaken = 48118 },
		}
		RoutePlanner.GetMainSkill = function()
			-- Simulate strict socket validation returning no playable skill while
			-- preserving the already-resolved native Main Skill in its context.
			return nil, "The selected Main Skill is not bound to a valid native PoB item socket/link: " .. socketReason, context
		end
		restorePlannerCatalogStubs = function()
			RoutePlanner.GetMainSkill = originalGetMainSkill
		end

		local tab = build.optimizerTab
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.is_true(popup.controls.run:IsEnabled(),
			"an identified Main Skill must remain searchable even if no socket repair was precomputed")
		local skillLabel = popup.controls.skill:GetProperty("label")
		assert.is_truthy(skillLabel:find("Main Skill identificada; vínculo físico pendente", 1, true),
			"the UI should report a socket blocker without labelling the selected skill as missing")
		assert.is_nil(skillLabel:find("Main Skill bloqueada", 1, true))
		assert.is_truthy(popup.controls.socketWarning:GetProperty("label"):find("Busca habilitada", 1, true))
		assert.is_nil(popup.controls.fixSkills,
			"a physical socket blocker should not replace the route-generation action with a repair-only screen")

		local startCalled = false
		local originalStartOptimizer = tab.StartOptimizer
		restorePlannerCatalogStubs = function()
			RoutePlanner.GetMainSkill = originalGetMainSkill
			tab.StartOptimizer = originalStartOptimizer
		end
		tab.StartOptimizer = function(_, _, _, options)
			startCalled = options and options.routePlanner == true
			return true, { status = "running" }
		end
		popup.controls.run:Click()
		tab.StartOptimizer = originalStartOptimizer
		assert.is_true(startCalled, "clicking the enabled control must reach route-planner startup")
		RoutePlanner.GetMainSkill = originalGetMainSkill
		restorePlannerCatalogStubs = nil
		newBuild()
	end)

	it("uses PoB Full DPS for a selected Main Skill that creates minions", function()
		newBuild()
		local gemId = "Metadata/Items/Gems/SkillGemRaiseSpectre"
		local grantedEffect = { id = gemId, minionList = { } }
		local activeEffect = { grantedEffect = grantedEffect }
		local skill = {
			activeEffect = activeEffect,
			effectList = { activeEffect },
			skillFlags = { haveMinion = true },
		}
		local gemData = { id = gemId, grantedEffect = grantedEffect }
		local group = {
			enabled = true,
			slotEnabled = true,
			slot = "Body Armour",
			mainActiveSkill = 1,
			displaySkillList = { skill },
			gemList = { { gemId = gemId, gemData = gemData } },
		}
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList = { group }
		build.data.gems[gemId] = gemData
		build.calcsTab.mainOutput = { CombinedDPS = 0, FullDPS = 20519076.632921,
			TotalEHP = 258198.915418, PhysicalMaximumHitTaken = 12000,
			FireMaximumHitTaken = 18000, ColdMaximumHitTaken = 18000, LightningMaximumHitTaken = 18000 }

		local originalMethods = { }
		for _, name in ipairs({ "CurrentMainGemId", "SocketGroupEvidence", "PlanEnabledSocketRepairs",
			"ValidateFullDPSSocketGroups" }) do
			originalMethods[name] = SkillCatalog[name]
		end
		SkillCatalog.CurrentMainGemId = function() return gemId end
		SkillCatalog.SocketGroupEvidence = function()
			return { valid = true, status = "linked", slot = "Body Armour", socketCount = 1 }
		end
		SkillCatalog.PlanEnabledSocketRepairs = function()
			return { status = "pass", repairs = { }, blockers = { } }
		end
		SkillCatalog.ValidateFullDPSSocketGroups = function()
			return true, { status = "pass", groups = { }, violations = { } }
		end
		restorePlannerCatalogStubs = function()
			for name, method in pairs(originalMethods) do SkillCatalog[name] = method end
		end

		local runSpec, floors = RoutePlanner.Prepare(build, {
			damageFocus = "Minions",
			routePlannerDpsGain = "GAIN_10_PERCENT",
			routePlannerUseNodePower = "false",
		})
		assert.is_table(runSpec)
		assert.is_table(floors)
		assert.is_true(runSpec.skill.isMinion, "the selected native minion effect must be identified")
		assert.are.equal("FullDPS", runSpec.objectiveMetric)
		assert.is_true(math.abs(floors.FullDPS - 22570984.2962131) < 0.00001,
			"the relative floor must use 110% of the exact selected-minion Full DPS baseline")
		assert.are.equal("GAIN_10_PERCENT", runSpec.targets.dpsGain)
		assert.are.equal(20519076.632921, runSpec.targets.dpsBaseline)
		assert.is_nil(floors.CombinedDPS,
			"the zero player Combined DPS must not block a valid minion build")
		local savedFullDps = build.calcsTab.mainOutput.FullDPS
		build.calcsTab.mainOutput.FullDPS = nil
		local noLossSpec, noLossError = RoutePlanner.Prepare(build, {
			damageFocus = "Minions", routePlannerDpsGain = "NO_LOSS",
			routePlannerUseNodePower = "false",
		})
		assert.is_nil(noLossSpec, "a relative requirement must not use a missing or stale baseline")
		assert.is_truthy(tostring(noLossError):find("exact, positive current PoB baseline", 1, true))
		build.calcsTab.mainOutput.FullDPS = savedFullDps

		grantedEffect.minionList = nil
		skill.skillFlags = { }
		local regularSkillSpec = assert(RoutePlanner.Prepare(build, {
			damageFocus = "Minions",
			routePlannerDpsGain = "NONE",
			routePlannerUseNodePower = "false",
		}))
		assert.is_false(regularSkillSpec.skill.isMinion,
			"a Minions ranking preference alone must not change a non-minion skill's metric")
		assert.are.equal("CombinedDPS", regularSkillSpec.objectiveMetric)
		newBuild()
	end)

	it("forces deterministic Single Skill search and clears stale Matrix roots and filters", function()
		newBuild()
		local tab = build.optimizerTab
		local routeTarget
		for nodeId, node in pairs(build.spec.nodes) do
			if node and not node.alloc and not node.ascendancyName and not node.isProxy
				and (node.type == "Normal" or node.type == "Notable" or node.type == "Keystone")
				and build.spec.tree.nodes[nodeId] then
				routeTarget = node
				break
			end
		end
		assert.is_truthy(routeTarget, "the fixture tree must have an unallocated legal route target")
		tab.textValues.routePlannerModelMode = "approved_gnn"
		tab.textValues.routePlannerModelPackageId = ""
		tab.textValues.routePlannerSearchMode = "CROSS_SKILL_COMBINATION"
		tab.textValues.routePlannerCrossSkillMode = "ALLOW_COC_AND_CWC"
		tab.textValues.baseClassId = "0"
		tab.textValues.ascendancyId = "4"
		tab.textValues.requiredNodeIds = "123"
		tab.textValues.allowedRegions = "NW"
		tab.textValues.searchAllClasses = "true"
		tab.textValues.nodePotentialAnalysis = "true"
		tab.textValues.useImportedRouteMemory = "true"
		tab.textValues.damageFocus = "Fire"
		tab.textValues.defenseProfile = "EnergyShield"
		tab.textValues.rankingPriority = "DefenseFirst"
		tab.textValues.routePlannerProposalLimit = "100000"
		tab.textValues.routePlannerExactEvaluationBudget = "500"
		tab.textValues.routePlannerConversionRoute = "PHYSICAL_TO_FIRE"
		tab.textValues.routePlannerConversionMinimum = "75"
		tab.textValues.routePlannerUseNodePower = "true"
		tab.textValues.routePlannerTargetNodeId = tostring(routeTarget.id)
		tab.textValues.routePlannerTargetNodeName = tostring(routeTarget.dn or routeTarget.name)
		tab.textValues.routePlannerTargetTreeVersion = tostring(build.spec.treeVersion)
		local captured
		tab.StartOptimizer = function(self, values, matrix, options)
			captured = { values = values, matrix = matrix, options = options }
			return true, { status = "running" }
		end
		local started = tab:RunRoutePlanner()
		assert.is_true(started)
		assert.are.equal("deterministic_fallback", captured.values.routePlannerModelMode)
		assert.are.equal("SINGLE_SKILL_ONLY", captured.values.routePlannerSearchMode)
		assert.are.equal("SINGLE_SKILL_ONLY", captured.values.routePlannerCrossSkillMode)
		assert.are.equal("combined", captured.values.generationPhase,
			"AI Analyzer must explore tree, skills and equipment together")
		assert.are.equal("true", captured.values.searchSyntheticGear,
			"AI Analyzer should include bounded, native-registry-validated rare reworks")
		assert.are.equal("", captured.values.baseClassId, "search must keep the currently loaded class and allocated tree")
		assert.are.equal("", captured.values.ascendancyId, "search must keep the loaded ascendancy instead of rebuilding a class root")
		assert.are.equal("", captured.values.requiredNodeIds)
		assert.are.equal("", captured.values.allowedRegions)
		assert.are.equal("false", captured.values.searchAllClasses)
		assert.are.equal("false", captured.values.nodePotentialAnalysis)
		assert.are.equal("true", captured.values.useImportedRouteMemory,
			"the route planner should pass compatible archive evidence into bounded candidate generation")
		assert.are.equal("Fire", captured.values.damageFocus)
		assert.are.equal("EnergyShield", captured.values.defenseProfile)
		assert.are.equal("DefenseFirst", captured.values.rankingPriority)
		assert.are.equal("100000", captured.values.routePlannerProposalLimit)
		assert.are.equal("500", captured.values.routePlannerExactEvaluationBudget)
		assert.are.equal("true", captured.values.routePlannerUseNodePower)
		assert.are.equal("PHYSICAL_TO_FIRE", captured.values.routePlannerConversionRoute)
		assert.are.equal("75", captured.values.routePlannerConversionMinimum)
		assert.are.equal(tostring(routeTarget.id), captured.values.targetNodeIds,
			"an explicitly chosen tree target must survive planner setup and constrain route generation")
		assert.is_nil(captured.options.trainingAuthorization)
		captured = nil
		tab.textValues.routePlannerModelPackageId = "v1.2.0_IceSpear_PinnacleBoss"
		tab.routePlannerModelCatalog = { status = "ready", models = {
			{ packageId = "v1.2.0_IceSpear_PinnacleBoss" },
		} }
		assert.is_true(tab:RunRoutePlanner())
		assert.are.equal("approved_gnn", captured.values.routePlannerModelMode)
		assert.are.equal("v1.2.0_IceSpear_PinnacleBoss", captured.values.routePlannerModelPackageId)
		captured = nil
		tab.textValues.routePlannerTargetTreeVersion = "stale-tree-version"
		local staleStarted, staleError = tab:RunRoutePlanner()
		assert.is_false(staleStarted, "a node ID from another tree version must not silently target a different passive")
		assert.is_truthy(tostring(staleError):find("identidade do nó-alvo mudou", 1, true))
		assert.is_nil(captured, "stale target rejection must happen before starting a search")
		newBuild()
	end)

	it("suppresses flask-slot alternatives without hiding equipment affixes that mention flasks", function()
		newBuild()
		local tab = build.optimizerTab
		tab.nodeEvidence = { status = "ready", compatibleBuildCount = 2, routePatternCount = 3 }
		local flaskNearMiss = { exact = true, feasible = false, label = "Staff + flask", normalizedDeficit = 0.25,
			metrics = { CombinedDPS = 140, FullDPS = 160, TotalEHP = 25000, ChaosResist = -5 },
			changes = { "Weapon 1 → Maelstrom Staff", "Flask 5 → Progenesis" },
			violations = { { key = "ChaosResist", label = "Chaos resistance", actual = -5, required = 0,
				reason = "Below strict minimum" } } }
		local gearNearMiss = { exact = true, feasible = false, label = "Belt rework", normalizedDeficit = 0.2,
			metrics = { CombinedDPS = 150, FullDPS = 170, TotalEHP = 26000, ChaosResist = -5 },
			changes = { "Belt → Studded Belt", "Afixo em Belt → 20% increased Flask Effect Duration",
				"Belt affix → Magic Utility Flasks cannot be Used" },
			violations = { { key = "ChaosResist", label = "Chaos resistance", actual = -5, required = 0,
				reason = "Below strict minimum" } } }
		tab.result = {
			status = "no_feasible_candidate", routePlanner = true, evaluations = 3,
			generationPhase = "combined", scenarioProfile = "Current", failureEvidence = "exact_calculation",
			objectiveMetric = "CombinedDPS", sourceSignature = Candidate.BuildSignature(build),
			inputSignature = assert(OptimizerTab.ComputeInputSignature(tab.textValues)),
			searchBaseline = { exact = true, label = "Current build", feasible = false, violationCount = 1,
				metrics = { CombinedDPS = 100, FullDPS = 120, TotalEHP = 20000, ChaosResist = -30 } },
			bestObservedIdentity = { candidateLabel = "Belt rework", baseClass = "Witch", ascendancy = "None" },
			bestObservedMetrics = { CombinedDPS = 130, FullDPS = 150, TotalEHP = 24000, ChaosResist = -5 },
			bestObservedViolations = { { key = "ChaosResist", label = "Chaos resistance", actual = -5, required = 0,
				reason = "Below strict minimum" } },
			nearMisses = { flaskNearMiss, gearNearMiss },
			searchCoverage = { phase = { archivedRoutePatterns = { availablePatterns = 3,
				generatedCandidates = 1, exactEvaluations = 1, exactFeasible = 0 } } },
		}
		local rows = OptimizerTab.FormatResultDetails(tab, 900)
		local lines = { }
		for _, row in ipairs(rows) do lines[#lines + 1] = row[1] or "" end
		local report = table.concat(lines, "\n")
		assert.is_truthy(report:find("Belt → Studded Belt", 1, true), report)
		assert.is_truthy(report:find("Flask Effect Duration", 1, true), report)
		assert.is_truthy(report:find("Magic Utility Flasks cannot be Used", 1, true), report)
		assert.is_truthy(report:find("Combined DPS: 150", 1, true), report)
		assert.is_nil(report:find("Flask 5 → Progenesis", 1, true), report)
		local popup = tab:OpenResultDetails()
		assert.are.equal("AI Planner — Propostas exatas não aprovadas", popup.title)
		assert.is_nil(popup.controls.routeSelect, "near misses must not be selectable as approved routes")
		assert.is_nil(popup.controls.applyRoute, "near misses must not be applicable from this screen")
		main:ClosePopup(popup)
		newBuild()
	end)

	it("shows exact passive near-misses beside approved routes without making them selectable", function()
		newBuild()
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		local approved = {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { 101 },
			label = "Exact gear route",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Exact gear route",
				metrics = { CombinedDPS = 50000000, TotalEHP = 100000 } },
		}
		local nearMiss = { exact = true, feasible = false, label = "Progressive passive routes; replace 4 leaf points",
			normalizedDeficit = 0.12,
			changes = { "Add 4 passive points; remove 4 low-value leaf points" },
			metrics = { CombinedDPS = 35000000, TotalEHP = 95000, ChaosResist = -5 },
			violations = { { key = "ChaosResist", label = "Chaos resistance", actual = -5, required = 0,
				reason = "Below strict minimum" } } }
		local archiveNearMiss = { exact = true, feasible = false,
			label = "Compatible archive pattern 2 (8 observed routes, 5 added points)", archiveDerivedPassiveRoute = true,
			normalizedDeficit = 0.2, changes = { "Add Heart of Ice" },
			metrics = { CombinedDPS = 30000000, TotalEHP = 90000, ChaosResist = -10 },
			violations = { { key = "ChaosResist", label = "Chaos resistance", actual = -10, required = 0,
				reason = "Below strict minimum" } } }
		tab.result = {
			status = "feasible", routePlanner = true, evaluations = 250,
			objectiveMetric = "CombinedDPS", scenarioProfile = "Current",
			candidate = approved, paretoFront = { approved }, sourceSignature = sourceSignature,
			inputSignature = assert(OptimizerTab.ComputeInputSignature(tab.textValues)),
			nearMisses = { nearMiss, archiveNearMiss },
		}
		local rows = OptimizerTab.FormatResultDetails(tab, 900)
		local lines = { }
		for _, row in ipairs(rows) do lines[#lines + 1] = row[1] or "" end
		local report = table.concat(lines, "\n")
		assert.is_truthy(report:find("Combinações exatas adicionais — não aprovadas", 1, true), report)
		assert.is_truthy(report:find("A rota aprovada acima passou por todos os gates", 1, true), report)
		assert.is_truthy(report:find("Progressive passive routes; replace 4 leaf points", 1, true), report)
		assert.is_truthy(report:find("Compatible archive pattern 2", 1, true), report)
		assert.is_truthy(report:find("padrão passivo observado em builds arquivadas", 1, true), report)
		assert.is_truthy(report:find("recalculadas pelo motor nativo do PoB", 1, true), report)
		assert.is_truthy(report:find("Chaos resistance", 1, true), report)
		local popup = tab:OpenResultDetails()
		assert.are.equal("AI Planner — Rotas e propostas exatas", popup.title)
		assert.are.equal(1, #popup.controls.routeSelect.list, "only the approved route belongs in the route selector")
		assert.are.equal(approved, popup.controls.routeSelect:GetSelValue().candidate)
		main:ClosePopup(popup)
		newBuild()
	end)

	it("lists up to 25 distinct exact Pareto routes in the route selector", function()
		newBuild()
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		local baselineMetrics = { CombinedDPS = 17414139.388218, TotalEHP = 188174.08853846 }
		local routes = { }
		for index = 1, 30 do
			routes[index] = {
				feasible = true,
				sourceSignature = sourceSignature,
				nodeIds = { 200000 + index },
				label = "Exact route " .. tostring(index),
				evaluation = {
					feasible = true,
					objective = "CombinedDPS",
					candidateLabel = "Exact route " .. tostring(index),
					metrics = { CombinedDPS = baselineMetrics.CombinedDPS + index * 100000,
						TotalEHP = baselineMetrics.TotalEHP + index * 1000 },
				},
			}
		end
		tab.result = {
			status = "feasible",
			routePlanner = true,
			evaluations = 1000,
			objectiveMetric = "CombinedDPS",
			sourceSignature = sourceSignature,
			sourceBuildBaseline = { comparisonOnly = true, metrics = baselineMetrics },
			candidate = routes[1],
			paretoFront = routes,
			inputSignature = assert(OptimizerTab.ComputeInputSignature(tab.textValues)),
		}

		local popup = tab:OpenResultDetails()
		local choices = assert(popup.controls.routeSelect).list
		assert.are.equal(25, #choices, "the selector should expose the 25-route UI cap")
		assert.are.equal(routes[1], choices[1].candidate)
		assert.are.equal(routes[25], choices[25].candidate,
			"the 25th distinct exact route must remain selectable")
		assert.is_truthy(choices[1].label:find("Exact route 1", 1, true))
		assert.is_truthy(choices[25].label:find("Exact route 25", 1, true))
		main:ClosePopup(popup)
		newBuild()
	end)

	it("keeps route application feedback visible and dispatches the selected second route", function()
		newBuild()
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		local routeOne = {
			feasible = true, sourceSignature = sourceSignature, nodeIds = { 501 }, label = "Route one",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Route one",
				metrics = { CombinedDPS = 12000000, TotalEHP = 60000 } },
		}
		local routeTwo = {
			feasible = true, sourceSignature = sourceSignature, nodeIds = { 502 }, label = "Route two",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Route two",
				metrics = { CombinedDPS = 13000000, TotalEHP = 61000 } },
		}
		tab.result = {
			status = "feasible", routePlanner = true, generationPhase = "combined", evaluations = 2,
			objectiveMetric = "CombinedDPS", sourceSignature = sourceSignature,
			inputSignature = assert(OptimizerTab.ComputeInputSignature(tab.textValues)),
			candidate = routeOne, paretoFront = { routeOne, routeTwo },
		}
		local originalRefreshFreshness = OptimizerTab.RefreshResultFreshness
		local originalApplyCandidate = tab.ApplyCandidate
		local appliedCandidate
		OptimizerTab.RefreshResultFreshness = function() return "current" end
		tab.ApplyCandidate = function(_, candidate)
			appliedCandidate = candidate
			return false, "exact native variation was rejected"
		end
		restorePlannerCatalogStubs = function()
			OptimizerTab.RefreshResultFreshness = originalRefreshFreshness
			tab.ApplyCandidate = originalApplyCandidate
		end

		local popup = tab:OpenResultDetails()
		popup.controls.routeSelect:SetSel(2)
		assert.are.equal(routeTwo, tab.selectedRouteCandidate,
			"the selection must track the second candidate rather than the default winner")
		popup.controls.applyRoute:Click()
		assert.are.equal(routeTwo, appliedCandidate, "Apply must receive the route selected in the dropdown")
		assert.are.equal(popup, main.popups[1], "a failed apply must keep the result dialog open")
		local failure = popup.controls.applyFeedback:GetProperty("label")
		assert.is_truthy(failure:find("Rota não aplicada", 1, true), failure)
		assert.is_truthy(failure:find("exact native variation was rejected", 1, true), failure)

		tab.ApplyCandidate = function(self, candidate)
			appliedCandidate = candidate
			self.result = nil
			return true
		end
		popup.controls.applyRoute:Click()
		assert.are.equal(routeTwo, appliedCandidate)
		assert.are.equal(popup, main.popups[1], "successful application feedback should remain visible until the user closes it")
		local success = popup.controls.applyFeedback:GetProperty("label")
		assert.is_truthy(success:find("Rota 2 aplicada como variação reversível", 1, true), success)
		assert.is_false(popup.controls.applyRoute:IsEnabled(), "an already applied route cannot be applied twice")
		main:ClosePopup(popup)
		restorePlannerCatalogStubs()
		restorePlannerCatalogStubs = nil
		newBuild()
	end)
end)
