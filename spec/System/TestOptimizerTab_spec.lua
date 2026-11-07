local Inputs = require("Modules.Optimizer.Inputs")
local Activity = require("Modules.Optimizer.Activity")
local Candidate = require("Modules.Optimizer.Candidate")
local OptimizerTab = require("Classes.OptimizerTab")
local BuildReviewPair = require("Modules.Optimizer.BuildReviewPair")
local StudyRecords = require("Modules.Optimizer.StudyRecords")
local Version = require("Modules.Optimizer.Version")
local SpatialZones = require("Modules.Optimizer.SpatialZones")
local DisplayText = require("Modules.Optimizer.DisplayText")
local BuildReadiness = require("Modules.Optimizer.BuildReadiness")
local TestSupport = require("OptimizerTestSupport")

local function stampOptimizerResult(tab)
	assert.is_table(tab.result)
	tab.result.sourceSignature = Candidate.BuildSignature(tab.build)
	tab.result.inputSignature = assert(OptimizerTab.ComputeInputSignature(tab.textValues))
end

local function selectCheckChoice(controls, prefix, value)
	for key, control in pairs(controls or { }) do
		if key:sub(1, #prefix + 1) == prefix .. "_" and control.choiceValue == tostring(value) then
			control.changeFunc(true)
			return control
		end
	end
	error("Missing " .. prefix .. " checkbox choice " .. tostring(value))
end

local function selectRadioChoice(group, value)
	for _, option in ipairs(group and group.options or { }) do
		if option.value == tostring(value) then
			option.control.changeFunc(true)
			return option.control
		end
	end
	error("Missing radio choice " .. tostring(value))
end

local ffi = require("ffi")
pcall(ffi.cdef, [[
	int _mkdir(const char *dirname);
	int _rmdir(const char *dirname);
	int _access(const char *filename, int mode);
]])
local crt = ffi.load("msvcr100")

local function createTestDirectory(path)
	path = path:gsub("[/\\]+$", "")
	if crt._mkdir(path) == 0 then return true end
	if crt._access(path, 0) == 0 then return nil, "No error" end
	return nil, "could not create isolated test directory"
end

describe("AI Planner guided overview flow", function()
	it("puts the essential build direction on the overview and persists it without changing the loaded build", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local tab = build.optimizerTab
		tab.RefreshOverviewDirectionControls(true)
		local loadedSignature = Candidate.BuildSignature(build)
		assert.is_true(tab.controls.overviewRun.enabled(), "the active Main Skill should bind automatically on the loaded build")
		assert.are.equal("1:1", tab.controls.overviewSkill:GetSelValue().val)
		assert.are.equal("Metadata/Items/Gems/SkillGemFireball", tab.controls.overviewGem:GetSelValue().val)
		local function selectValue(control, value)
			for index, option in ipairs(control.list) do
				if option.val == value then control:SetSel(index); return true end
			end
			return false
		end
		tab.nodeEvidence = { status = "ready" }
		tab.textValues.targetSkillGroupIndex = "99"
		tab.textValues.targetSkillIndex = "99"
		tab.textValues.targetSkillGemId = "Metadata/Items/Gems/SkillGemArc"
		tab.RefreshOverviewDirectionControls(true)
		assert.is_nil(tab.nodeEvidence, "rebinding an invalid slot must clear stale imported evidence")
		assert.is_true(tab.controls.overviewRun.enabled(), "active Main Skill plus a valid planning gem should enable Run")
		assert.are.equal("1:1", tab.controls.overviewSkill:GetSelValue().val)
		assert.are.equal("Metadata/Items/Gems/SkillGemFireball", tab.controls.overviewGem:GetSelValue().val)

		local rangerId = tostring(build.spec.tree.classNameMap.Ranger)
		tab.nodeEvidence = { status = "ready" }
		selectCheckChoice(tab.controls, "overviewClass", rangerId)
		assert.is_nil(tab.nodeEvidence, "changing the planner class must clear stale imported evidence")
		assert.are.equal(rangerId, tab.textValues.baseClassId)
		assert.are.equal("", tab.textValues.ascendancyId, "class direction must leave ascendancy selection on Auto")
		assert.is_true(tab.controls["overviewClass_" .. rangerId].state)
		assert.is_false(tab.controls["overviewClass_" .. tostring(build.spec.tree.classNameMap.Witch)].state,
			"overview class choices must be mutually exclusive")
		assert.are.equal(build.spec.tree.classNameMap.Witch, build.spec.curClassId,
			"planner class direction must not mutate the loaded PoB character")
		assert.is_truthy(tab.controls.overviewAscendancy.label:find("Auto", 1, true))

		local damageImpale = selectRadioChoice(tab.overviewDamageGroup, "PhysicalImpale")
		assert.are.equal("PhysicalImpale", tab.textValues.damageFocus,
			"physical hit plus Impale must remain an explicit route separate from elemental conversion")
		assert.is_true(damageImpale.state)
		assert.is_false(tab.controls.overviewDamage_Auto.state, "damage-route checkboxes must remain mutually exclusive")
		local defenseEnergyShield = selectRadioChoice(tab.overviewDefenseGroup, "EnergyShield")
		assert.are.equal("EnergyShield", tab.textValues.defenseProfile)
		assert.is_true(defenseEnergyShield.state)
		assert.is_false(tab.controls.overviewDefense_Life.state, "defense checkboxes must remain mutually exclusive")
		local plannerInputs = assert(Inputs.Parse(tab.textValues))
		assert.are.equal("PhysicalImpale", plannerInputs.preferences.damageFocus)
		assert.are.equal("EnergyShield", plannerInputs.preferences.defenseProfile)
		tab.nodeEvidence = { status = "ready" }
		assert.is_true(selectValue(tab.controls.overviewGem, "Metadata/Items/Gems/SkillGemArc"))
		assert.is_nil(tab.nodeEvidence, "changing the planner gem must clear stale imported evidence")
		assert.are.equal("Metadata/Items/Gems/SkillGemArc", tab.textValues.targetSkillGemId,
			"planning gem selection must reach the existing exact candidate input")
		local defenseFirst = selectRadioChoice(tab.overviewPriorityGroup, "DefenseFirst")
		assert.are.equal("DefenseFirst", tab.textValues.rankingPriority)
		assert.is_true(defenseFirst.state)
		assert.is_false(tab.controls.overviewPriority_ObjectiveFirst.state,
			"the visible search priority must be a single choice")
		local importedRoutesQuick = tab.controls.overviewUseImportedRoutes
		assert.is_truthy(importedRoutesQuick, "the primary overview should expose the graph-pattern preference")
		assert.is_true(importedRoutesQuick.state, "compatible imported-route guidance should default on")
		importedRoutesQuick.state = false
		importedRoutesQuick.changeFunc(false)
		assert.are.equal("false", tab.textValues.useImportedRouteMemory,
			"the overview graph-pattern checkbox must drive the same solver input as Build Direction")
		tab:OpenBuildDirection()
		local importedRoutes = main.popups[1].controls.useImportedRoutes
		assert.is_false(importedRoutes.state)
		main:ClosePopup()
		assert.are.equal("1", tab.textValues.targetSkillGroupIndex)
		assert.are.equal("1", tab.textValues.targetSkillIndex)
		assert.are.equal(loadedSignature, Candidate.BuildSignature(build), "overview choices must be planner-only until Apply")

		for _, width in ipairs({ 556, 1026, 520 }) do
			tab:Layout({ width = width, height = 520 })
			for _, option in ipairs(tab.overviewClassGroup.options) do
				local x, y = option.control:GetPos()
				local controlWidth = option.control:GetSize()
				assert.is_true(x >= 0 and x + controlWidth + option.control.labelWidth <= width,
					"class option label must stay inside overview at width " .. width)
			end
			for _, key in ipairs({ "overviewSkill", "overviewGem" }) do
				local control = tab.controls[key]
				local x = control:GetPos()
				local controlWidth = control:GetSize()
				assert.is_true(x >= 0 and x + controlWidth <= width, key .. " must fit at width " .. width)
			end
			for _, group in ipairs({ tab.overviewDamageGroup, tab.overviewDefenseGroup }) do
				for _, option in ipairs(group.options) do
					local x, y = option.control:GetPos()
					local controlWidth, controlHeight = option.control:GetSize()
					assert.is_true(x >= 0 and x + controlWidth + option.control.labelWidth <= width,
						"preference checkbox and label must fit at width " .. width)
					assert.is_true(y >= 0 and y + controlHeight <= 520,
						"preference checkbox must fit vertically at width " .. width)
				end
			end
			for _, option in ipairs(tab.overviewPriorityGroup.options) do
				local x = option.control:GetPos()
				local controlWidth = option.control:GetSize()
				assert.is_true(x >= 0 and x + controlWidth + option.control.labelWidth + 5 <= width,
					"priority option label must stay inside overview at width " .. width)
			end
			local graphControl = tab.controls.overviewUseImportedRoutes
			local graphX = graphControl:GetPos()
			local graphWidth = graphControl:GetSize()
			assert.is_true(graphX >= 0 and graphX + graphWidth + graphControl.labelWidth <= width,
				"graph-pattern preference must stay visible at width " .. width)
			local reportX, reportY = tab.controls.overviewReport:GetPos()
			local _, reportHeight = tab.controls.overviewReport:GetSize()
			assert.is_true(reportX >= 0 and reportY + reportHeight <= 520,
				"readiness report must fit under the choices at width " .. width)
		end

		local saved = { }
		tab:Save(saved)
		tab.textValues.baseClassId = tostring(build.spec.tree.classNameMap.Witch)
		tab.textValues.damageFocus = "Auto"
		tab.textValues.defenseProfile = "Auto"
		tab.textValues.targetSkillGemId = "Metadata/Items/Gems/SkillGemFireball"
		tab.textValues.rankingPriority = "ObjectiveFirst"
		tab.textValues.useImportedRouteMemory = "true"
		tab:Load(saved)
		assert.are.equal(rangerId, tab.textValues.baseClassId)
		assert.is_true(tab.controls["overviewClass_" .. rangerId].state)
		assert.are.equal("PhysicalImpale", tab.overviewDamageGroup.selectedValue)
		assert.are.equal("EnergyShield", tab.overviewDefenseGroup.selectedValue)
		assert.is_true(tab.controls.overviewDamage_PhysicalImpale.state)
		assert.is_true(tab.controls.overviewDefense_EnergyShield.state)
		assert.are.equal("Metadata/Items/Gems/SkillGemArc", tab.controls.overviewGem:GetSelValue().val)
		assert.are.equal("DefenseFirst", tab.textValues.rankingPriority)
		assert.is_true(tab.controls.overviewPriority_DefenseFirst.state)
		assert.is_false(tab.controls.overviewPriority_ObjectiveFirst.state)
		assert.are.equal("false", tab.textValues.useImportedRouteMemory)
		assert.is_false(tab.controls.overviewUseImportedRoutes.state,
			"the primary graph-pattern checkbox must restore the saved preference")
		tab:OpenBuildDirection()
		assert.is_false(main.popups[1].controls.useImportedRoutes.state)
		main:ClosePopup()
		assert.are.equal(loadedSignature, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("keeps Run disabled without an active slot and binds it when the loaded build gains a Main Skill", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		local tab = build.optimizerTab
		tab.RefreshOverviewDirectionControls(true)
		assert.is_false(tab.controls.overviewRun.enabled(), "a gem alone must not imply a linked Main Skill slot")
		assert.is_true(tab.controls.overviewRoutes.enabled(),
			"the route entry point must remain available so its native preflight can explain the missing Main Skill")
		local missingSkill = table.concat(OptimizerTab.FormatGuidedWorkflow(tab, BuildReadiness.Evaluate(build)), "\n")
		assert.is_truthy(missingSkill:find("Selecione uma Main Skill", 1, true), missingSkill)
		assert.is_nil(missingSkill:find("Pronto para gerar", 1, true), missingSkill)
		tab:OpenRoutePlanner()
		assert.is_false(main.popups[1].controls.run.enabled(),
			"the route action itself must stay disabled when PoB has no resolvable active skill")
		assert.is_truthy(main.popups[1].controls.skill:GetProperty("label"):find("Main Skill bloqueada", 1, true))
		main:ClosePopup()
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		tab.RefreshOverviewDirectionControls(true)
		assert.is_true(tab.controls.overviewRun.enabled(), string.format("a native active skill and valid planning gem must satisfy the overview gate (slot=%s, gem=%s, skillOptions=%s, gemOptions=%s, selected=%s)",
			tostring(tab.textValues.targetSkillGroupIndex), tostring(tab.textValues.targetSkillGemId), tostring(tab.overviewSkillHasOptions),
			tostring(tab.overviewGemHasOptions), tostring(tab.controls.overviewSkill:GetSelValue() and tab.controls.overviewSkill:GetSelValue().val)))
		assert.is_true(tab.controls.overviewRoutes.enabled(), "route generation should enable with a linked Main Skill and valid target gem")
		assert.are.equal("1:1", tab.controls.overviewSkill:GetSelValue().val,
			"the Main Skill added to the loaded build should be selected without manual re-entry")
		newBuild()
	end)

	it("rebinds in-memory selectors when a different build is loaded without saved Optimizer inputs", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local tab = build.optimizerTab
		local witchId = build.spec.curClassId
		local groupIndex = build.mainSocketGroup
		local group = build.skillsTab.socketGroupList[groupIndex]
		local skillIndex = group.mainActiveSkill or 1
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		assert.are.equal(fireballId, require("Modules.Optimizer.SkillCatalog").CurrentMainGemId(build, groupIndex, skillIndex))
		tab.textValues.baseClassId = "0"
		tab.textValues.targetSkillGroupIndex = "99"
		tab.textValues.targetSkillIndex = "99"
		tab.textValues.targetSkillGemId = "Metadata/Items/Gems/SkillGemArc"
		tab.textValues.ascendancyId = "4"
		tab.textValues.allowedRegions = "Scion"
		tab.hasPersistedOptimizerInputs = false
		tab.loadedOptimizerContext = nil
		tab.contextAnchor = { classId = witchId + 20, ascendancyId = 4, treeVersion = "old-tree",
			groupIndex = 99, skillIndex = 99, gemId = "Metadata/Items/Gems/SkillGemArc" }
		tab:FinalizeBuildContext()
		assert.are.equal(tostring(witchId), tab.textValues.baseClassId)
		assert.are.equal(tostring(groupIndex), tab.textValues.targetSkillGroupIndex)
		assert.are.equal(tostring(skillIndex), tab.textValues.targetSkillIndex)
		assert.are.equal(fireballId, tab.textValues.targetSkillGemId)
		assert.are.equal("1:1", tab.controls.overviewSkill:GetSelValue().val)
		assert.are.equal("", tab.textValues.ascendancyId)
		assert.are.equal("", tab.textValues.allowedRegions)
		assert.is_truthy(tab.statusMessage:find("Witch/Fireball", 1, true))
		newBuild()
	end)

	it("opens the short setup directly and preserves exact Matrix floors without mutating the build", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.characterLevel, build.characterLevelAutoMode = 90, false
		build.calcsTab:BuildOutput()
		local tab = build.optimizerTab
		assert.is_truthy(tab.controls.metric_Str, "Matrix must expose an exact Strength floor")
		assert.is_truthy(tab.controls.metric_Dex, "Matrix must expose an exact Dexterity floor")
		assert.is_truthy(tab.controls.metric_Int, "Matrix must expose an exact Intelligence floor")
		tab.controls.metric_Int:SetText("155", true)
		assert.are.equal("155", tab.textValues.Int)
		assert.are.equal(155, assert(Inputs.Parse(tab.textValues)).hard.Int.value)
		tab.controls.metric_Int:SetText("", true)
		local sourceSignature = Candidate.BuildSignature(build)
		local witchId = build.spec.tree.classNameMap.Witch
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		tab.textValues.TotalEHP = "5000"
		tab.textValues.CombinedDPS = "10000000"
		tab.textValues.LifeUnreserved = "4000"
		tab.textValues.SpellSuppressionChance = "100"
		tab.textValues.objectiveMetric = "TotalEHP"
		tab.textValues.targetSkillGroupIndex = "1"
		tab.textValues.targetSkillIndex = "1"
		tab.textValues.targetSkillGemId = fireballId
		for index, option in ipairs(tab.controls.text_objectiveMetric.list) do
			if option.val == "TotalEHP" then tab.controls.text_objectiveMetric:SetSel(index); break end
		end
		tab.controls.overviewDirection:Click()
		local page = main.popups[1]
		assert.are.equal("AI Planner — Beginner setup", page.title,
			"Configurar build must open the guided choices without a profile-picker click")
		assert.are.equal("Step 1 of 4 — Choose class and planning stage", page.controls.step:GetProperty("label"))
		assert.are.equal("close", page.escapeControl)
		assert.are.equal("level", page.controls.treeBudget:GetSelValue().val)
		local nativePointLimit = build:GetPassivePointLimitForLevel(build.characterLevel,
			build.calcsTab.mainOutput.ExtraPoints or 0)
		assert.are.equal(tostring(math.min(nativePointLimit, tonumber(tab.textValues.maxTotalPoints) or 120)), tab.textValues.maxAddedPoints,
			"recommended fresh-tree scope must use PoB's native manual-level point allowance")
		for index, option in ipairs(page.controls.treeBudget.list) do
			if option.val == "local" then page.controls.treeBudget:SetSel(index); break end
		end
		assert.are.equal("5", tab.textValues.maxAddedPoints)
		for index, option in ipairs(page.controls.treeBudget.list) do
			if option.val == "level" then page.controls.treeBudget:SetSel(index); break end
		end
		assert.are.equal(tostring(nativePointLimit), tab.textValues.maxAddedPoints)
		for index, option in ipairs(page.controls.treeBudget.list) do
			if option.val == "custom" then page.controls.treeBudget:SetSel(index); break end
		end
		assert.are.equal(tostring(nativePointLimit), tab.textValues.maxAddedPoints,
			"Custom must preserve the existing Matrix budget")
		local scionId = build.spec.tree.classNameMap.Scion
		selectCheckChoice(page.controls, "class", scionId)
		assert.are.equal(tostring(scionId), tab.textValues.baseClassId)
		selectCheckChoice(page.controls, "class", witchId)
		assert.is_true(page.controls["class_" .. tostring(witchId)].state)
		assert.is_false(page.controls["class_" .. tostring(scionId)].state,
			"the native class boxes must select one legal PoB class root at a time")
		page.controls.next:Click()
		page = main.popups[1]
		assert.is_truthy(page.controls.gem)
		for index, option in ipairs(page.controls.gem.list) do
			if option.val == fireballId then page.controls.gem:SetSel(index); break end
		end
		page.controls.next:Click()
		page = main.popups[1]
		assert.are.equal("Step 3 of 4 — Set damage, defense, and scenario preferences", page.controls.step:GetProperty("label"))
		local function selectChoice(control, value)
			for index, option in ipairs(control.list) do
				if option.val == value then control:SetSel(index); return true end
			end
			return false
		end
		assert.is_true(selectChoice(page.controls.damageFocus, "PhysicalImpale"))
		assert.are.equal("PhysicalImpale", tab.textValues.damageFocus)
		assert.is_true(selectChoice(page.controls.defenseProfile, "EnergyShield"))
		assert.are.equal("EnergyShield", tab.textValues.defenseProfile)
		assert.is_true(selectChoice(page.controls.rankingPriority, "DefenseFirst"))
		assert.is_true(selectChoice(page.controls.scenario, "PinnacleUnbuffed"))
		assert.is_true(selectChoice(page.controls.enemy, "Pinnacle"))
		assert.are.equal("PinnacleUnbuffed", tab.textValues.scenarioProfile)
		assert.are.equal("Pinnacle", tab.textValues.scenarioEnemyPreset)
		assert.is_truthy(page.controls.matrix, "strict floors remain one click away in Matrix")
		page.controls.next:Click()
		page = main.popups[1]
		assert.are.equal("Step 4 of 4 — Review before calculation", page.controls.step:GetProperty("label"))
		local summary = page.controls.summary:GetProperty("label")
		assert.is_truthy(summary:find("Hard constraints:", 1, true), summary)
		assert.is_truthy(summary:find("Minimum EHP >= 5000", 1, true), summary)
		assert.is_truthy(summary:find("Minimum selected-skill DPS >= 10000000", 1, true), summary)
		assert.is_truthy(summary:find("Unreserved life >= 4000", 1, true), summary)
		assert.is_truthy(summary:find("Spell suppression >= 100 %", 1, true), summary)
		assert.is_truthy(summary:find("exact-evaluation budget is compute, not currency", 1, true), summary)
		assert.is_true(page.controls.run.enabled)
		assert.are.equal(tostring(witchId), tab.textValues.baseClassId)
		assert.are.equal(fireballId, tab.textValues.targetSkillGemId)
		assert.are.equal("PhysicalImpale", tab.textValues.damageFocus)
		assert.are.equal("TotalEHP", tab.textValues.objectiveMetric)
		assert.are.equal("EnergyShield", tab.textValues.defenseProfile)
		assert.are.equal("DefenseFirst", tab.textValues.rankingPriority)
		assert.are.equal("PinnacleUnbuffed", tab.textValues.scenarioProfile)
		assert.are.equal("5000", tab.textValues.TotalEHP)
		assert.are.equal("10000000", tab.textValues.CombinedDPS)
		assert.are.equal("4000", tab.textValues.LifeUnreserved)
		assert.are.equal("100", tab.textValues.SpellSuppressionChance)
		local parsedInputs, parseError = Inputs.Parse(tab.textValues)
		assert.is_truthy(parsedInputs, parseError)
		assert.are.equal(10000000, parsedInputs.hard.CombinedDPS.value)
		assert.are.equal(5000, parsedInputs.hard.TotalEHP.value)
		assert.are.equal(4000, parsedInputs.hard.LifeUnreserved.value)
		assert.are.equal(100, parsedInputs.hard.SpellSuppressionChance.value)
		assert.are.equal("TotalEHP", tab.controls.text_objectiveMetric:GetSelValue().val,
			"the Matrix objective remains the same solver input")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "setup must not edit the active PoB build")
		local popupX, popupY = page:GetPos()
		for _, key in ipairs({ "matrix", "back", "run", "close" }) do
			local control = page.controls[key]
			local x, y = control:GetPos()
			local width, height = control:GetSize()
			assert.is_true(x >= popupX and x + width <= popupX + 720, key .. " must stay inside the guided popup")
			assert.is_true(y >= popupY and y + height <= popupY + 400, key .. " must stay inside the guided popup")
		end
		local saved = { }
		tab:Save(saved)
		tab.textValues.guidedProfile = "advanced"
		tab:Load(saved)
		assert.are.equal("beginner", tab.textValues.guidedProfile)
		assert.are.equal("5000", tab.textValues.TotalEHP)
		tab.textValues.evaluationBudget = "1"
		page.controls.run:Click()
		assert.is_nil(main.popups[1], "Run must close the guided review before starting the native optimizer; open popup="
			.. tostring(main.popups[1] and main.popups[1].title) .. ", button shown="
			.. tostring(page.controls.run:IsShown()) .. ", enabled=" .. tostring(page.controls.run:IsEnabled()))
		assert.are.equal("matrix", tab.innerView)
		assert.is_truthy(tab.job, tab.statusMessage)
		assert.are.equal("running", tab.job.status, "the guided action must create the normal exact-calculation job")
		tab.job:Cancel()
		assert.are.equal("cancelled", tab.job:Step())
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "starting and cancelling from review must preserve the source build")
		newBuild()
	end)

	it("creates a selected active gem as an explicit reversible PoB skill-set seed", function()
		newBuild()
		local tab = build.optimizerTab
		local originalSetId = build.skillsTab.activeSkillSetId
		local originalSetCount = #build.skillsTab.skillSetOrderList
		tab.controls.overviewDirection:Click()
		main.popups[1].controls.next:Click()
		local skillPage = main.popups[1]
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		for index, option in ipairs(skillPage.controls.gem.list) do
			if option.val == fireballId then skillPage.controls.gem:SetSel(index); break end
		end
		assert.is_false(skillPage.controls.next.enabled,
			"a new gem without a native Main Skill slot must be seeded before optimization")
		assert.is_true(skillPage.controls.createSeed:IsEnabled())
		assert.are.equal(originalSetId, build.skillsTab.activeSkillSetId,
			"selecting a gem alone must not mutate the active skill set")
		skillPage.controls.createSeed:Click()
		assert.are.equal(originalSetCount + 1, #build.skillsTab.skillSetOrderList)
		assert.is_false(originalSetId == build.skillsTab.activeSkillSetId)
		assert.are.equal(fireballId, tab.textValues.targetSkillGemId)
		assert.are.equal("tree", tab.textValues.generationPhase)
		assert.are.equal("AI Planner — Beginner setup", main.popups[1].title)
		assert.are.equal("Step 3 of 4 — Set damage, defense, and scenario preferences", main.popups[1].controls.step:GetProperty("label"))
		assert.is_truthy(tab.statusMessage:find("new reversible PoB skill set", 1, true))
		main:ClosePopup()
		newBuild()
	end)

	it("adds intermediate conversion and compute limits while routing advanced users to native controls", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local tab = build.optimizerTab
		tab.textValues.targetSkillGroupIndex = "1"
		tab.textValues.targetSkillIndex = "1"
		tab.textValues.targetSkillGemId = "Metadata/Items/Gems/SkillGemFireball"
		tab:OpenGuidedSetup("intermediate", 1)
		local page = main.popups[1]
		assert.are.equal("Step 1 of 5 — Choose class and planning stage", page.controls.step:GetProperty("label"))
	for _ = 1, 3 do page.controls.next:Click(); page = main.popups[1] end
		assert.is_truthy(page.controls.conversion_Physical_Cold)
		selectCheckChoice(page.controls, "conversion", "Physical>Cold")
		assert.is_true(page.controls.conversion_Physical_Cold.state)
		assert.is_false(page.controls.conversion_None.state,
			"the exact conversion route must replace the no-route choice")
		page.controls.maxTotalPoints:SetText("90", true)
		page.controls.evaluationBudget:SetText("320", true)
		assert.are.equal("Physical>Cold", tab.textValues.conversionRoute)
		assert.are.equal("100", tab.textValues.conversionMin)
		assert.are.equal("90", tab.textValues.maxTotalPoints)
		assert.are.equal("320", tab.textValues.evaluationBudget)
		page.controls.next:Click()
		page = main.popups[1]
		assert.are.equal("Step 5 of 5 — Review before calculation", page.controls.step:GetProperty("label"))
		local summary = page.controls.summary:GetProperty("label")
		assert.is_truthy(summary:find("Conversion: Physical → Cold · each edge >= 100%", 1, true), summary)
		assert.is_truthy(summary:find("No strict metric floors", 1, true), summary)
		assert.is_truthy(summary:find("no market currency cap", 1, true), summary)
		assert.is_true(page.controls.run.enabled, "valid intermediate inputs should remain eligible for the native Run gate")
		main:ClosePopup(page)

		tab:OpenGuidedSetup("advanced", 1)
		assert.are.equal("AI Planner — Build Direction", main.popups[1].title,
			"advanced setup must route to the existing complete native dialog")
		assert.is_truthy(main.popups[1].controls.ascendancy)
		assert.are.equal("advanced", tab.textValues.guidedProfile)
		assert.are.equal("Physical>Cold", tab.textValues.conversionRoute)
		assert.are.equal("90", tab.textValues.maxTotalPoints)
		assert.are.equal("320", tab.textValues.evaluationBudget,
			"switching experience profiles must preserve the same Matrix values")
		main:ClosePopup()
		newBuild()
	end)

	it("shows all six stages and separates current diagnosis from the planned objective", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.buildName = "Download information not found"
		build.calcsTab:BuildOutput()
		build.buildFlag = false

		local tab = build.optimizerTab
		tab.textValues.targetSkillGemId = "Metadata/Items/Gems/SkillGemArc"
		tab.textValues.targetSkillGroupIndex = "1"
		tab.textValues.targetSkillIndex = "1"
		local report = BuildReadiness.Evaluate(build)
		local lines = OptimizerTab.FormatGuidedWorkflowDiagnostics(tab, report)
		assert.are.equal(6, #lines)
		assert.is_truthy(lines[1]:find("A. Build carregada — Parcial", 1, true))
		assert.is_truthy(lines[1]:find("Integridade estrutural ativa: partial", 1, true))
		assert.is_truthy(lines[1]:find("Witch", 1, true))
		assert.is_truthy(lines[1]:find("PoB " .. tostring(launch.versionNumber), 1, true))
		assert.is_truthy(lines[1]:find("dados " .. tostring(report.identity.engine.dataVersion), 1, true))
		assert.is_truthy(lines[1]:find("liga na origem não registrada", 1, true))
		assert.is_truthy(lines[1]:find("modo/plataforma não confirmados", 1, true))
		assert.is_truthy(lines[2]:find("Main Skill Arc", 1, true))
		assert.is_truthy(lines[2]:find("skill carregada Fireball", 1, true))
		assert.is_truthy(lines[3]:find("nenhum piso métrico rígido", 1, true))
		assert.is_truthy(lines[4]:find("Current", 1, true))
		assert.is_truthy(lines[5]:find("por iniciar", 1, true))
		assert.is_truthy(lines[6]:find("a build ativa permanece intacta", 1, true))
		assert.is_false(report.capabilities.physicalSkillSetup)
	end)

	it("explains when class-specific imported routes are suspended during all-class comparison", function()
		newBuild()
		local tab = build.optimizerTab
		tab.nodeEvidence = { status = "disabled", reason = "class_specific_prior_disabled_for_all_class_comparison", readOnly = true }
		local report = BuildReadiness.Evaluate(build)
		local workflow = table.concat(OptimizerTab.FormatGuidedWorkflowDiagnostics(tab, report), "\n")
		assert.is_truthy(workflow:find("suspensa na comparação das classes", 1, true))
		assert.is_truthy(workflow:find("usa propostas sem essa preferência", 1, true))
	end)

	it("exposes strict failure and feasible review states without offering fallback", function()
		newBuild()
		local tab = build.optimizerTab
		local report = BuildReadiness.Evaluate(build)
		tab.result = { status = "no_feasible_candidate" }
		local failed = table.concat(OptimizerTab.FormatGuidedWorkflowDiagnostics(tab, report), "\n")
		assert.is_truthy(failed:find("nenhuma solução viável dentro do orçamento", 1, true))
		assert.is_truthy(failed:find("Não há fallback entregável", 1, true))

		tab.result = { status = "feasible" }
		local feasible = table.concat(OptimizerTab.FormatGuidedWorkflowDiagnostics(tab, report), "\n")
		assert.is_truthy(feasible:find("passou os hard gates no cálculo exato do PoB", 1, true))
		assert.is_truthy(feasible:find("ação explícita em Apply", 1, true))

		tab.result, tab.job = nil, { status = "running", progress = { processed = 3, total = 9 } }
		local running = table.concat(OptimizerTab.FormatGuidedWorkflowDiagnostics(tab, report), "\n")
		assert.is_truthy(running:find("3 de 9 avaliações concluídas", 1, true))
		assert.is_truthy(running:find("aguardando", 1, true))

		tab.job = nil
		tab.textValues.TotalEHP = "invalid"
		local invalid = table.concat(OptimizerTab.FormatGuidedWorkflowDiagnostics(tab, report), "\n")
		assert.is_truthy(invalid:find("C. Restrições — corrigir Matrix", 1, true))
		assert.is_truthy(invalid:find("Minimum EHP must be a number", 1, true))
	end)

	it("refreshes objective, constraint, search, and result steps without a resize", function()
		newBuild()
		build.calcsTab:BuildOutput()
		build.buildFlag = false
		local tab = build.optimizerTab
		tab.width = 556
		tab:RefreshReadiness(true)
		local function overview()
			local rows = { }
			for _, row in ipairs(tab.controls.overviewReport.list or { }) do rows[#rows + 1] = row[1] end
			return table.concat(rows, "\n")
		end
		assert.is_truthy(overview():find("Selecione uma Main Skill", 1, true))
		assert.is_nil(overview():find("E. Busca", 1, true))
		assert.is_nil(overview():find("F. Resultado", 1, true))
		assert.is_nil(overview():find("G. Memória de builds", 1, true))
		assert.is_nil(overview():find("Integridade estrutural", 1, true))

		tab.textValues.TotalEHP = "12345"
		tab.job = { status = "running", progress = {
			processed = 2, total = 5, phase = "Exact calculations", current = "Cyclone route",
			generatedProposals = 40000, uniqueProposals = 39000, retainedProposals = 39000,
			paretoRoutes = 1, exactFeasibleMutations = 4,
			bestExactRoute = {
				label = "Fire route", objectiveKey = "CombinedDPS", objectiveValue = 12345,
				objectiveBaseline = 10000, focusMetricKey = "FireHitAverage", focusMetricValue = 2500,
				focusMetricBaseline = 2000, defenseMetricKey = "EnergyShield", defenseMetricValue = 4567,
				defenseMetricBaseline = 4000,
			},
		} }
		tab:RefreshReadiness()
		assert.is_truthy(overview():find("Gerando combinações e rotas", 1, true))
		assert.is_truthy(overview():find("2/5 recálculos", 1, true))
		assert.is_truthy(overview():find("40,000 propostas", 1, true))
		assert.is_truthy(overview():find("39,000 únicas", 1, true))
		assert.is_truthy(overview():find("Fronteira Pareto atual: 1 rota", 1, true))
		assert.is_truthy(overview():find("Combinações exatas aprovadas: 4", 1, true))
		assert.is_truthy(overview():find("Melhor rota aprovada até agora: Fire route", 1, true))
		assert.is_truthy(overview():find("Combined DPS: 12,345 (Δ +2,345)", 1, true))
		assert.is_truthy(overview():find("Fire average hit: 2,500 (Δ +500)", 1, true))
		assert.is_truthy(overview():find("Energy shield: 4,567 (Δ +567)", 1, true))
		assert.is_nil(overview():find("pisos métricos rígidos", 1, true))
		tab.readinessDetailsExpanded = true
		tab.readinessLayoutWidth = nil
		tab:RefreshReadiness()
		assert.is_truthy(overview():find("Gerando combinações e rotas", 1, true))
		assert.is_nil(overview():find("pisos métricos rígidos", 1, true), "the Analyzer overview stays focused on routes")
		assert.is_nil(overview():find("G. Memória de builds", 1, true), "archive diagnostics stay out of the Analyzer overview")
		tab.readinessDetailsExpanded = false
		tab.readinessLayoutWidth = nil
		tab.job = { status = "running", progress = { processed = 1314, total = 644, counterValid = false, phase = "Path search", current = "plan 2/8; NorthWest" } }
		tab:RefreshReadiness()
		assert.is_truthy(overview():find("progresso em reconciliação", 1, true))
		assert.is_nil(overview():find("1314/644", 1, true), "inconsistent counters are not presented as valid progress")

		tab.job = nil
		tab.result = { status = "no_feasible_candidate" }
		tab:RefreshReadiness()
		assert.is_truthy(overview():find("0 rotas exatas aprovadas", 1, true))
		tab.result = nil
		tab.controls.overviewRoutes.enabled = function() return true end
		local blocked = table.concat(OptimizerTab.FormatGuidedWorkflow(tab,
			{ label = "Blocked", skill = { status = "resolved", name = "Cyclone" } }), "\n")
		assert.is_truthy(blocked:find("Não foi possível iniciar a geração de rotas", 1, true), blocked)
		assert.is_nil(blocked:find("Detalhes", 1, true), blocked)
	end)

	it("shows exact configured gains for the currently selected Pareto route", function()
		newBuild()
		local tab = build.optimizerTab
		tab.textValues.objectiveMetric = "CombinedDPS"
		tab.textValues.defenseProfile = "EnergyShield"
		local route = {
			feasible = true, sourceSignature = "overview-route-source", nodeIds = { 101 }, label = "Fire conversion route",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Fire conversion route",
				metrics = { CombinedDPS = 12345.25, EnergyShield = 4567 } },
		}
		tab.result = {
			status = "feasible", routePlanner = true, sourceSignature = "overview-route-source", objectiveMetric = "CombinedDPS",
			candidate = route, evaluation = route.evaluation, paretoFront = { route }, evaluations = 37,
			searchBaseline = { exact = true, metrics = { CombinedDPS = 10000.125, EnergyShield = 4000 } },
		}
		tab.selectedRouteResult, tab.selectedRouteCandidate = tab.result, route
		local overview = table.concat(OptimizerTab.FormatGuidedWorkflow(tab, BuildReadiness.Evaluate(build)), "\n")
		assert.is_truthy(overview:find("1 rotas exatas aprovadas", 1, true), overview)
		assert.is_truthy(overview:find("37 recálculos nativos", 1, true), overview)
		assert.is_truthy(overview:find("Combined DPS: 12,345.25 (Δ +2,345.125)", 1, true), overview)
		assert.is_truthy(overview:find("Energy shield: 4,567 (Δ +567)", 1, true), overview)
		assert.is_nil(overview:find("e+", 1, true), overview)
		local diagnostics = table.concat(OptimizerTab.FormatGuidedWorkflowDiagnostics(tab, BuildReadiness.Evaluate(build)), "\n")
		assert.is_truthy(diagnostics:find("Combined DPS: 12,345.25 (Δ +2,345.125)", 1, true), diagnostics)
		assert.is_nil(diagnostics:find("E. Busca", 1, true), diagnostics)
		assert.is_nil(diagnostics:find("G. Memória de builds", 1, true), diagnostics)
	end)

	it("shows exact near-miss gains without presenting them as applicable routes", function()
		newBuild()
		local tab = build.optimizerTab
		tab.textValues.objectiveMetric = "CombinedDPS"
		tab.textValues.damageFocus = "Fire"
		tab.textValues.defenseProfile = "EnergyShield"
		tab.result = {
			status = "no_feasible_candidate", routePlanner = true, evaluations = 250, objectiveMetric = "CombinedDPS",
			searchBaseline = { exact = true, metrics = { CombinedDPS = 10000.125, FireHitAverage = 400, EnergyShield = 4000 } },
			nearMisses = { { exact = true, feasible = false, label = "Fire and energy shield route",
				metrics = { CombinedDPS = 12345.25, FireHitAverage = 500, EnergyShield = 4567 },
				violations = { { key = "TotalEHP" } } } },
		}
		local overview = table.concat(OptimizerTab.FormatGuidedWorkflow(tab, BuildReadiness.Evaluate(build)), "\n")
		assert.is_truthy(overview:find("0 rotas aprovadas; 1 quase-rotas recalculadas pelo PoB", 1, true), overview)
		assert.is_truthy(overview:find("Melhor quase-rota: Fire and energy shield route — não aplicável", 1, true), overview)
		assert.is_truthy(overview:find("Combined DPS: 12,345.25 (Δ +2,345.125)", 1, true), overview)
		assert.is_truthy(overview:find("Fire average hit: 500 (Δ +100)", 1, true), overview)
		assert.is_truthy(overview:find("Energy shield: 4,567 (Δ +567)", 1, true), overview)
		assert.is_truthy(overview:find("Não pode ser aplicada", 1, true), overview)
		assert.is_nil(overview:find("e+", 1, true), overview)
	end)

	it("uses a renderer-safe details label in the compact overview", function()
		newBuild()
		local control = build.optimizerTab.controls.overviewDetails
		assert.are.equal("Detalhes", control:GetProperty("label"))
		assert.is_false(control.shown, "the overview must not expose the technical A–G diagnostic toggle")
		newBuild()
	end)

	it("refreshes live route progress while keeping technical diagnostics out of the overview", function()
		newBuild()
		local tab = build.optimizerTab
		tab.width = 556
		tab:RefreshReadiness(true)
		tab.job = { status = "running", progress = { processed = 1, total = 10, phase = "Exact calculations",
			archiveCompatibleLineages = 2, archivePatternsAvailable = 3,
			archiveRoutesGenerated = 2, archiveCompositionsGenerated = 6, archiveDirectExact = 1,
			archiveCompositionsExact = 0 } }
		tab:RefreshReadiness()
		local function overview()
			local rows = { }
			for _, row in ipairs(tab.controls.overviewReport.list or { }) do rows[#rows + 1] = row[1] end
			return table.concat(rows, "\n")
		end
		assert.is_truthy(overview():find("1/10 recálculos", 1, true), overview())
		assert.is_truthy(overview():find("Memória de builds: 2 linhagens / 3 padrões · 2 rotas diretas · 6 combinações compostas", 1, true), overview())
		assert.is_truthy(overview():find("recálculos nativos: 1 diretas / 0 compostas", 1, true), overview())
		tab.job.progress.processed = 2
		tab.job.progress.archiveCompositionsExact = 1
		tab:RefreshReadiness()
		assert.is_truthy(overview():find("2/10 recálculos", 1, true))
		assert.is_truthy(overview():find("recálculos nativos: 1 diretas / 1 compostas", 1, true), overview())
		assert.is_nil(overview():find("E. Busca", 1, true))
		assert.is_nil(overview():find("G. Memória de builds", 1, true))
	end)

	it("shows planned and completed exact-evaluation families in live route progress", function()
		newBuild()
		local Progress = require("Modules.Optimizer.RoutePlannerProgress")
		local tab = build.optimizerTab
		tab.width = 556
		tab:RefreshReadiness(true)
		local job = { status = "running", routePlannerRun = true }
		local phaseCoverage = {
			exactEvaluationPlan = {
				status = "round_robin_by_mutation_family", windowSize = 12, windowFamilyDiversity = 5,
				familyOrder = { "equipment", "skills", "combined", "tree", "configuration" },
				windowFamilyCounts = { equipment = 3, skills = 2, combined = 2, tree = 3, configuration = 2 },
			},
			exactEvaluationsByFamily = { baseline = 1, equipment = 2, skills = 1 },
		}
		Progress.Merge(job, { phase = "Exact calculations", processed = 4, total = 12 }, phaseCoverage)
		tab.job = job
		tab:RefreshReadiness()
		local function overview()
			local rows = { }
			for _, row in ipairs(tab.controls.overviewReport.list or { }) do rows[#rows + 1] = row[1] end
			return table.concat(rows, "\n")
		end
		assert.is_truthy(overview():find("Fila exata planejada (12): equipamentos 3, gemas/suportes 2", 1, true), overview())
		assert.is_truthy(overview():find("rotas combinadas 2, passivas 3, configuração 2", 1, true), overview())
		assert.is_truthy(overview():find("Recálculos exatos por família: base 1, equipamentos 2", 1, true), overview())
		assert.is_truthy(overview():find("gemas/suportes 1", 1, true), overview())
		phaseCoverage.exactEvaluationsByFamily.equipment = 4
		Progress.Merge(job, { phase = "Exact calculations", processed = 6, total = 12 }, phaseCoverage)
		tab:RefreshReadiness()
		assert.is_truthy(overview():find("Recálculos exatos por família: base 1, equipamentos 4", 1, true), overview())
		assert.is_truthy(overview():find("gemas/suportes 1", 1, true), overview())
		newBuild()
	end)
end)

describe("Optimizer Matrix responsive layout", function()
	it("refreshes readiness identity when the PoB level changes with a reused calculator environment", function()
		newBuild()
		build.calcsTab:BuildOutput()
		build.buildFlag = false
		local tab = build.optimizerTab
		local originalEnvironment = build.calcsTab.mainEnv
		tab:RefreshReadiness(true)
		assert.are.equal(build.characterLevel, tab.readinessReport.identity.level)

		-- The readiness report includes identity even if the calculator environment
		-- has not yet been replaced. Level must therefore be part of its cache key.
		build.characterLevel = 90
		build.buildFlag = false
		assert.are.equal(originalEnvironment, build.calcsTab.mainEnv)
		tab:RefreshReadiness()
		assert.are.equal(90, tab.readinessReport.identity.level)
		assert.is_truthy(table.concat(require("Modules.Optimizer.BuildReadiness").Describe(tab.readinessReport), "\n")
			:find("Nível: 90", 1, true))
	end)

	it("rebases legacy Matrix class and skill selectors to the loaded PoB build", function()
		newBuild()
		local tab = build.optimizerTab
		local witchId = assert(build.spec.tree.classNameMap.Witch)
		local scionId = assert(build.spec.tree.classNameMap.Scion)
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local arcId = "Metadata/Items/Gems/SkillGemArc"
		build.spec:SelectClass(witchId)
		assert(require("Modules.Optimizer.SkillSeed").Create(build, fireballId))
		local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
		local skillIndex = group.mainActiveSkill or 1
		local originalDisplaySkill = group.displaySkillList[skillIndex]

		-- Legacy Optimizer sections have no source-build context. This one contains
		-- the stale Scion/Arc direction observed in the live Witch/Fireball seed.
		tab:Load({
			{ elem = "Input", attrib = { name = "baseClassId", value = tostring(scionId) } },
			{ elem = "Input", attrib = { name = "ascendancyId", value = "1" } },
			{ elem = "Input", attrib = { name = "targetSkillGroupIndex", value = tostring(build.mainSocketGroup) } },
			{ elem = "Input", attrib = { name = "targetSkillIndex", value = tostring(skillIndex) } },
			{ elem = "Input", attrib = { name = "targetSkillGemId", value = arcId } },
			{ elem = "Input", attrib = { name = "allowedRegions", value = "Scion" } },
			{ elem = "Input", attrib = { name = "objectiveMetric", value = "CombinedDPS" } },
			{ elem = "Input", attrib = { name = "conversionRoute", value = "Physical>Cold" } },
			{ elem = "Input", attrib = { name = "damageFocus", value = "Cold" } },
		})
		-- The native display skill may not expose a resolved name while socket
		-- groups are rebuilding; keep the independent source gem identity intact.
		group.displaySkillList[skillIndex] = { }
		local finalized, finalizeError = pcall(function() tab:FinalizeBuildContext() end)
		group.displaySkillList[skillIndex] = originalDisplaySkill
		assert.is_true(finalized, tostring(finalizeError))
		assert.are.equal(tostring(witchId), tab.textValues.baseClassId)
		assert.are.equal(tostring(build.mainSocketGroup), tab.textValues.targetSkillGroupIndex)
		assert.are.equal(tostring(skillIndex), tab.textValues.targetSkillIndex)
		assert.are.equal(fireballId, tab.textValues.targetSkillGemId)
		assert.are.equal("", tab.textValues.ascendancyId)
		assert.are.equal("", tab.textValues.allowedRegions)
		assert.are.equal("CombinedDPS", tab.textValues.objectiveMetric, "hard objective selection must be preserved")
		assert.are.equal("Physical>Cold", tab.textValues.conversionRoute, "explicit conversion preference must be preserved for review")
		assert.are.equal("Cold", tab.textValues.damageFocus)
		assert.is_truthy(tab.statusMessage:find("Witch/Fireball", 1, true))
		assert.is_true(tab.modFlag, "a one-time migration must be saveable with its new context marker")

		-- Deliberate alternate class/gem choices survive a round-trip while the
		-- saved native build context remains unchanged.
		tab.textValues.baseClassId = tostring(scionId)
		tab.textValues.targetSkillGemId = arcId
		local saved = { }
		tab:Save(saved)
		local context
		for _, child in ipairs(saved) do
			if child.elem == "Context" then context = child.attrib break end
		end
		assert.is_truthy(context)
		assert.are.equal("1", context.version)
		tab:Load(saved)
		tab:FinalizeBuildContext()
		assert.are.equal(tostring(scionId), tab.textValues.baseClassId)
		assert.are.equal(arcId, tab.textValues.targetSkillGemId)

		-- A later native class change invalidates the saved target context and
		-- safely reanchors the selector to the build that is actually open.
		build.spec:SelectClass(scionId)
		tab:Load(saved)
		tab:FinalizeBuildContext()
		assert.are.equal(tostring(scionId), tab.textValues.baseClassId)
		assert.are.equal(fireballId, tab.textValues.targetSkillGemId)
		assert.is_truthy(tab.statusMessage:find("context refreshed", 1, true))
		newBuild()
	end)

	it("keeps Build Direction classes, skill-gem direction, conversion controls, and Close inside the popup", function()
		newBuild()
		local tab = build.optimizerTab
		tab:OpenBuildDirection()
		local popup = main.popups[1]
		assert.are.equal(DisplayText.Native("AI Planner — Build Direction"), popup.title)
		assert.is_nil(popup.scrollBarFunc, "Build Direction must not pass its Close control as a scrollbar callback")
		assert.are.equal("close", popup.escapeControl, "Escape must target the popup's Close action")
		for key, control in pairs(popup.controls) do
			if key == "intro" or key == "skillLabel" or key == "skill" or key == "gemLabel" or key == "targetGem" or key == "ascendancyLabel" or key == "ascendancy" or key == "conversionLabel"
				or key == "conversionPreview" or key == "conversionHint" or key == "notes" or key == "close"
				or key == "allClasses" or key == "phaseLabel" or key == "phase"
				or key == "damageFocusLabel" or key == "damageFocus" or key == "defenseProfileLabel" or key == "defenseProfile" or key == "preferenceHint"
				or key == "objectiveLabel" or key == "objectiveMetric" or key == "scenarioLabel" or key == "scenarioProfile"
				or key == "enemyLabel" or key == "enemyPreset" or key == "enemyLevel"
				or key == "ascendancyBudgetLabel" or key == "ascendancyBudget" or key == "ascendancyBudgetHint"
				or key:match("^class_") or key:match("^conversion_") then
				assert.are.equal("TOPLEFT", control.anchor.point, key .. " must use the popup's top-left origin")
				assert.are.equal(popup, control.anchor.other, key .. " must be parented to the popup")
			end
		end
		local popupX, popupY = popup:GetPos()
		local closeX, closeY = popup.controls.close:GetPos()
		local closeWidth, closeHeight = popup.controls.close:GetSize()
		assert.is_true(closeX >= popupX)
		assert.is_true(closeX + closeWidth <= popupX + 720)
		assert.is_true(closeY >= popupY)
		assert.is_true(closeY + closeHeight <= popupY + 480)
		local previousRight = popupX
		for _, key in ipairs({ "objectiveMetric", "scenarioProfile", "enemyPreset" }) do
			local x, y = popup.controls[key]:GetPos()
			local width, height = popup.controls[key]:GetSize()
			assert.is_true(x >= previousRight, key .. " must not overlap the preceding guided selector")
			assert.is_true(x + width <= popupX + 720, key .. " must remain inside the popup")
			assert.is_true(y >= popupY and y + height <= popupY + 480, key .. " must remain vertically inside the popup")
			previousRight = x + width
		end
		for key, control in pairs(popup.controls) do
			if key:match("^class_") then
				local x, y = control:GetPos()
				assert.is_true(x >= popupX and x + 154 <= popupX + 720, key .. " class label must fit")
				assert.is_true(y >= popupY and y + 18 <= popupY + 386, key .. " class option must fit")
			end
		end
		assert.is_function(popup.controls.intro.Draw)
		assert.is_truthy(popup.controls.allClasses)
		assert.are.equal("TOPLEFT", popup.controls.allClasses.anchor.point)
		assert.is_true(select(1, popup.controls.allClasses:GetPos()) + 440 <= popupX + 720)
		assert.is_function(popup.controls.conversionHint.Draw)
		assert.is_truthy(popup.controls.damageFocus)
		assert.is_truthy(popup.controls.defenseProfile)
		assert.is_truthy(popup.controls.rankingPriority)
		assert.is_truthy(popup.controls.preferenceHint)
		assert.are.equal("Auto", tab.textValues.damageFocus)
		assert.are.equal("Auto", tab.textValues.defenseProfile)
		assert.are.equal("ObjectiveFirst", tab.textValues.rankingPriority)
		assert.is_truthy(popup.controls.objectiveMetric)
		assert.is_truthy(popup.controls.scenarioProfile)
		assert.is_truthy(popup.controls.enemyPreset)
		assert.is_truthy(popup.controls.enemyLevel)
		assert.are.equal("CombinedDPS", tab.textValues.objectiveMetric)
		assert.are.equal("Current", tab.textValues.scenarioProfile)
		assert.are.equal("Active", tab.textValues.scenarioEnemyPreset)
		for _, choice in ipairs(popup.controls.objectiveMetric.list) do
			assert.are.equal(choice.val, Inputs.objectives[choice.val], "guided objective must be accepted by the exact input parser")
		end
		for _, choice in ipairs(popup.controls.scenarioProfile.list) do
			assert.are.equal(choice.val, Inputs.scenarioProfiles[choice.val], "guided scenario must be accepted by the exact input parser")
		end
		for _, choice in ipairs(popup.controls.enemyPreset.list) do
			assert.are.equal(choice.val, Inputs.scenarioEnemyPresets[choice.val], "guided enemy tier must use native PoB ConfigOptions")
		end
		local function choiceIndex(control, value)
			for index, choice in ipairs(control.list) do
				if choice.val == value then return index end
			end
		end
		popup.controls.objectiveMetric:SetSel(assert(choiceIndex(popup.controls.objectiveMetric, "FullDotDPS")))
		popup.controls.rankingPriority:SetSel(assert(choiceIndex(popup.controls.rankingPriority, "DefenseFirst")))
		popup.controls.scenarioProfile:SetSel(assert(choiceIndex(popup.controls.scenarioProfile, "PinnacleChassis")))
		assert.is_nil(choiceIndex(popup.controls.enemyPreset, "Boss"), "Pinnacle profiles must not offer a standard-boss override")
		popup.controls.enemyPreset:SetSel(assert(choiceIndex(popup.controls.enemyPreset, "Uber")))
		popup.controls.enemyLevel:SetText("72", true)
		assert.are.equal("FullDotDPS", tab.textValues.objectiveMetric)
		assert.are.equal("PinnacleChassis", tab.textValues.scenarioProfile)
		assert.are.equal("Uber", tab.textValues.scenarioEnemyPreset)
		assert.are.equal("72", tab.textValues.scenarioEnemyLevel)
		assert.are.equal("FullDotDPS", tab.controls.text_objectiveMetric:GetSelValue().val,
			"the guided objective must immediately mirror the native Matrix selector")
		assert.are.equal("PinnacleChassis", tab.controls.text_scenarioProfile:GetSelValue().val,
			"the guided scenario must immediately mirror the native Matrix selector")
		local parsedDirection = assert(Inputs.Parse(tab.textValues))
		assert.are.equal("FullDotDPS", parsedDirection.objective)
		assert.are.equal("DefenseFirst", parsedDirection.preferences.rankingPriority)
		assert.are.equal("PinnacleChassis", parsedDirection.scenarioProfile,
			"the selected scenario must reach the same typed input consumed by the solver")
		assert.are.equal("Uber", parsedDirection.scenarioEnemyPreset,
			"the guided enemy tier must reach the same typed input consumed by the solver")
		assert.are.equal(72, parsedDirection.scenarioEnemyLevel,
			"the enemy level must reach the typed native scenario consumed by the solver")
		local savedInputs = { }
		tab:Save(savedInputs)
		tab.textValues.objectiveMetric = "CombinedDPS"
		tab.textValues.rankingPriority = "ObjectiveFirst"
		tab.textValues.scenarioProfile = "Current"
		tab:Load(savedInputs)
		tab:FinalizeBuildContext()
		assert.are.equal("FullDotDPS", tab.textValues.objectiveMetric,
			"the exact ranking objective must survive PoB build save/load")
		assert.are.equal("DefenseFirst", tab.textValues.rankingPriority,
			"the exact winner-ranking priority must survive PoB build save/load")
		assert.are.equal("PinnacleChassis", tab.textValues.scenarioProfile,
			"the exact calculation scenario must survive PoB build save/load")
		assert.are.equal("Uber", tab.textValues.scenarioEnemyPreset,
			"the exact native enemy tier must survive PoB build save/load")
		assert.are.equal("72", tab.textValues.scenarioEnemyLevel,
			"the native enemy-level override must survive PoB build save/load")
		assert.is_truthy(popup.controls.targetGem)
		assert.is_true(#popup.controls.targetGem.list > 0, "native active-skill database should populate the gem direction selector")
		assert.is_truthy(popup.controls.ascendancy)
		assert.are.equal(DisplayText.Native("Auto — compare legal ascendancies"), popup.controls.ascendancy.list[1].label)
		assert.is_truthy(popup.controls.ascendancyBudget)
		assert.are.equal("auto", tab.textValues.ascendancyPointBudget)
		assert.are.equal(DisplayText.Native("Auto — up to 0 per ascendancy"), popup.controls.ascendancyBudget.list[1].label)
		local witchId = build.spec.tree.classNameMap.Witch
		tab.directionClassControls[witchId].changeFunc()
		local elementalistIndex
		for index, option in ipairs(popup.controls.ascendancy.list) do
			if option.label == "Elementalist" then elementalistIndex = index break end
		end
		assert.is_truthy(elementalistIndex, "changing to Witch must load its native ascendancy choices")
		popup.controls.ascendancy:SetSel(elementalistIndex)
		assert.are.equal(popup.controls.ascendancy.list[elementalistIndex].val, tab.textValues.ascendancyId)
		local selectedGem = popup.controls.targetGem:GetSelValue()
		assert.is_truthy(selectedGem.val)
		local nextGemIndex = 1
		for index, option in ipairs(popup.controls.targetGem.list) do
			if option.val ~= selectedGem.val then nextGemIndex = index break end
		end
		local nextGem = popup.controls.targetGem.list[nextGemIndex]
		popup.controls.targetGem:SetSel(nextGemIndex)
		assert.are.equal(nextGem.val, tab.textValues.targetSkillGemId)
		for key, expectedWidth in pairs({ intro = 410, conversionLabel = 640, conversionPreview = 650, conversionHint = 660 }) do
			local width = popup.controls[key]:GetSize()
			assert.are.equal(expectedWidth, width, key .. " must use its intended popup clip width")
		end
		local _, hintY = popup.controls.conversionHint:GetPos()
		local _, hintHeight = popup.controls.conversionHint:GetSize()
		local _, notesY = popup.controls.notes:GetPos()
		assert.is_true(hintHeight >= 26, "conversion hint must have room for wrapped lines")
		assert.is_true(hintY + hintHeight <= notesY, "conversion hint must not overlap the notes action")
		local closeX, closeY = popup.controls.close:GetPos()
		local closeWidth, closeHeight = popup.controls.close:GetSize()
		local originalGetCursorPos = GetCursorPos
		local clickOk, clickError = pcall(function()
			GetCursorPos = function() return closeX + closeWidth / 2, closeY + closeHeight / 2 end
			popup:ProcessInput({ { type = "KeyDown", key = "LEFTBUTTON" } }, main.viewPort)
			popup:ProcessInput({ { type = "KeyUp", key = "LEFTBUTTON" } }, main.viewPort)
		end)
		GetCursorPos = originalGetCursorPos
		assert.is_truthy(clickOk, clickError)
		assert.is_false(main.popups[1] == popup, "one click must dismiss Build Direction even when its skill dropdown starts focused")
		tab:OpenBuildDirection()
		local escapePopup = main.popups[1]
		assert.are.equal("FullDotDPS", escapePopup.controls.objectiveMetric:GetSelValue().val,
			"guided objective selection must persist when the direction dialog is reopened")
		assert.are.equal("PinnacleChassis", escapePopup.controls.scenarioProfile:GetSelValue().val,
			"guided scenario selection must persist when the direction dialog is reopened")
		assert.are.equal("Uber", escapePopup.controls.enemyPreset:GetSelValue().val,
			"guided enemy tier selection must persist when the direction dialog is reopened")
		escapePopup:ProcessInput({ { type = "KeyDown", key = "ESCAPE" } }, main.viewPort)
		assert.is_false(main.popups[1] == escapePopup, "Escape must dismiss Build Direction without invoking a non-function callback")
		newBuild()
	end)

	it("keeps the native enemy-level override in advanced controls", function()
		newBuild()
		local tab = build.optimizerTab
		tab:OpenBuildDirection()
		local popup = main.popups[1]
		assert.is_truthy(popup.controls.enemyLevel)
		popup.controls.enemyLevel:SetText("68", true)
		assert.are.equal("68", tab.textValues.scenarioEnemyLevel)
		assert.are.equal(68, assert(Inputs.Parse(tab.textValues)).scenarioEnemyLevel)
		main:ClosePopup(popup)
		newBuild()
	end)

	it("adapts Build Direction punctuation for the native renderer without changing solver IDs", function()
		local originalUnicode, originalWidth = main.unicode, DrawStringWidth
		local ok, failure = pcall(function()
			main.unicode = true
			DrawStringWidth = function(_, _, text)
				if text == "—" then return 80 end
				return 20
			end
			newBuild()
			local tab = build.optimizerTab
			local originalGemId = tab.textValues.targetSkillGemId
			tab:OpenBuildDirection()
			local popup = main.popups[1]
			assert.are.equal("AI Planner - Build Direction", popup.title)
			assert.are.equal("1 - Tree foundation", popup.controls.phase.list[1].label)
			assert.are.equal("Auto - compare legal ascendancies", popup.controls.ascendancy.list[1].label)
			assert.are.equal("Auto - up to 0 per ascendancy", popup.controls.ascendancyBudget.list[1].label)
			assert.is_truthy(popup.controls.conversionLabel:GetProperty("label"):find("Conversion path - check", 1, true))
			assert.are.equal(originalGemId, tab.textValues.targetSkillGemId,
				"presentation fallback must not rewrite the stable Main Skill gem ID")
			for _, key in ipairs({ "phase", "skill", "targetGem", "ascendancy", "ascendancyBudget", "objectiveMetric", "scenarioProfile", "enemyPreset", "damageFocus", "defenseProfile" }) do
				for _, choice in ipairs(popup.controls[key].list or { }) do
					local label = type(choice) == "table" and choice.label or choice
					if type(label) == "string" then
						assert.is_nil(label:find("[\128-\255]"), key .. " label must not contain escaped UTF-8 glyphs")
					end
				end
			end
			local parsed = assert(Inputs.Parse(tab.textValues))
			assert.are.equal(Inputs.objectives[tab.textValues.objectiveMetric], parsed.objective)
			main:ClosePopup()
		end)
		if main.popups[1] then main:ClosePopup() end
		main.unicode, DrawStringWidth = originalUnicode, originalWidth
		if not ok then error(failure) end
	end)

	it("defaults to tree foundation and keeps later phases isolated from class-root search", function()
		newBuild()
		local tab = build.optimizerTab
		assert.are.equal("tree", tab.textValues.generationPhase)
		tab:OpenBuildDirection()
		local controls = main.popups[1].controls
		assert.are.equal("tree", controls.phase:GetSelValue().val)
		assert.is_true(tab.directionClassControls[build.spec.curClassId].enabled())
		controls.phase:SetSel(2)
		assert.are.equal("skills", tab.textValues.generationPhase)
		assert.is_false(tab.textValues.searchAllClasses)
		assert.is_false(tab.directionClassControls[build.spec.curClassId].enabled())
		assert.are.equal(tostring(build.spec.curClassId), tab.textValues.baseClassId)
		controls.phase:SetSel(3)
		assert.are.equal("equipment", tab.textValues.generationPhase)
		controls.phase:SetSel(1)
		assert.are.equal("tree", tab.textValues.generationPhase)
		assert.is_true(tab.directionClassControls[build.spec.curClassId].enabled())
		main:ClosePopup()
		newBuild()
	end)

	it("routes a different gem from an unlinked seed through Skills before preparing socketed gear", function()
		newBuild()
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local arcId = "Metadata/Items/Gems/SkillGemArc"
		local seed, seedError = require("Modules.Optimizer.SkillSeed").Create(build, fireballId)
		assert.is_truthy(seed, seedError)
		assert.is_false(seed.linked)
		local tab = build.optimizerTab
		tab.textValues.targetSkillGroupIndex = tostring(seed.groupIndex)
		tab.textValues.targetSkillIndex = tostring(seed.skillIndex)
		tab.textValues.targetSkillGemId = arcId
		local sourceSignature = Candidate.BuildSignature(build)

		tab:OpenEquipmentChoices()
		local firstPopup = main.popups[1]
		assert.is_truthy(firstPopup.controls.prepareGear)
		firstPopup.controls.prepareGear:Click()
		assert.are.equal("skills", tab.textValues.generationPhase,
			"gear preparation must route an unapplied different gem through its exact Skills checkpoint")
		assert.is_false(tostring(tab.textValues.searchSyntheticGear):lower() == "true",
			"the planner must not enable or run an item search for a gem that is not installed yet")
		assert.is_truthy(tab.statusMessage:find("First run and apply the selected Main Skill in the Skills phase", 1, true))
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "setup guidance must not mutate the active build")
		assert.is_nil(main.popups[1], "the routed next step should return focus to the Matrix")

		tab.textValues.targetSkillGemId = fireballId
		tab:OpenEquipmentChoices()
		local secondPopup = main.popups[1]
		secondPopup.controls.prepareGear:Click()
		assert.are.equal("equipment", tab.textValues.generationPhase)
		assert.is_true(tab.textValues.searchSyntheticGear)
		assert.is_true(secondPopup.controls.searchSyntheticGear.state,
			"the Matrix setting and visible native checkbox must stay in sync")
		assert.is_truthy(tab.statusMessage:find("nothing is applied until Apply as variation", 1, true))
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "gear preparation must be a reversible-search setup only")
		main:ClosePopup()
		newBuild()
	end)

	it("saves phase checkpoints and asks before advancing Skills to Equipment", function()
		newBuild()
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		local function applyPhase(phase, expectedPhase)
			tab.textValues.generationPhase = phase
			local candidate = {
				feasible = true,
				generationPhase = phase,
				sourceSignature = sourceSignature,
				evaluation = { objective = "CombinedDPS", metrics = {
					CombinedDPS = 123, Life = 100, EnergyShield = 50, Ward = 10,
					Armour = 2500, Evasion = 1800, BlockChance = 35, SpellBlockChance = 25,
					SpellSuppressionChance = 100,
				} },
			}
			local applied, message = tab:ApplyCandidate(candidate)
			assert.is_true(applied, message)
			assert.are.equal(expectedPhase, tab.textValues.generationPhase)
			assert.is_true(tab.modFlag, "the advanced phase must be saved with the optimizer Matrix")
			return candidate
		end
		applyPhase("tree", "skills")
		local treeCheckpoint = require("Modules.Optimizer.Checkpoints").Decode(tab.textValues.phaseCheckpointsJson).phases.tree
		assert.are.equal("applied_exact_variation", treeCheckpoint.status)
		for key, expected in pairs({ Armour = 2500, Evasion = 1800, BlockChance = 35,
			SpellBlockChance = 25, SpellSuppressionChance = 100 }) do
			assert.are.equal(expected, treeCheckpoint.metrics[key], "exact defensive checkpoint metric missing: " .. key)
		end
		applyPhase("skills", "skills")
		assert.are.equal("applied_exact_variation", require("Modules.Optimizer.Checkpoints").Decode(tab.textValues.phaseCheckpointsJson).phases.skills.status)
		local prompt = main.popups[1]
		assert.are.equal("AI Planner — Skills checkpoint", prompt.title)
		prompt.controls.later:Click()
		assert.are.equal("skills", tab.textValues.generationPhase, "Later must retain the Skills checkpoint and phase")
		applyPhase("skills", "skills")
		local yesPrompt = main.popups[1]
		yesPrompt.controls.yes:Click()
		assert.are.equal("equipment", tab.textValues.generationPhase, "Yes selects Equipment without starting a search")
		assert.is_nil(tab.job)
		applyPhase("equipment", "equipment")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "no-op stage transitions must leave the build state unchanged")
		newBuild()
	end)

	it("shows exact-added-support coverage and marks an unlinked package as provisional", function()
		newBuild()
		local tab = build.optimizerTab
		tab.textValues.generationPhase = "skills"
		local result = {
			status = "feasible",
			generationPhase = "skills",
			evaluations = 2,
			candidate = {
				feasible = true,
				unlinkedSupportPlan = true,
				gemVariant = { kind = "support_add" },
			},
			evaluation = {
				objective = "CombinedDPS",
				metrics = { CombinedDPS = 123 },
				passivePointsUsed = 0,
				strictPointCap = 120,
				scenarioProfile = "Current",
			},
			searchCoverage = {
				phase = {
					exactSupportAddEvaluations = 2,
					compatibleSupportAddEvaluations = 1,
					supportPackages = {
						additions = { { arity = 1, exact = 2, compatible = 1 } },
						swaps = { },
					},
				},
			},
		}
		tab.job = {
			status = "running",
			Step = function()
				return "complete", result
			end,
		}
		tab:Tick()
		assert.is_truthy(tab.statusMessage:find("Support arities exact/compatible (2/1): add 1: 2/1", 1, true))
		assert.is_truthy(tab.statusMessage:find("not playable until assigned", 1, true))
		newBuild()
	end)

	it("refuses a feasible result from a phase that is no longer selected", function()
		newBuild()
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		tab.textValues.generationPhase = "skills"
		local applied, message = tab:ApplyCandidate({
			feasible = true, generationPhase = "tree", sourceSignature = sourceSignature,
		})
		assert.is_false(applied)
		assert.is_truthy(message:find("phase changed", 1, true))
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
		assert.are.equal("skills", tab.textValues.generationPhase)
		newBuild()
	end)

	it("opens the isolated local study review dialog and closes it without touching the active build", function()
		newBuild()
		local tab = build.optimizerTab
		tab.controls.pageMatrix:Click()
		local originalUserPath = main.userPath
		local ok, failure = xpcall(function()
			-- Point the read-only empty-state check at an isolated path; this must
			-- not inspect or write the user's actual study store.
			local emptyUserPath = os.tmpname()
			os.remove(emptyUserPath)
			main.userPath = emptyUserPath .. "_optimizer_study_ui"
			tab.controls.studyRecords:Click()
			local popup = main.popups[1]
			assert.are.equal("AI Planner — Study records and review", popup.title)
			for key, control in pairs(popup.controls) do
				assert.are.equal("TOPLEFT", control.anchor.point, key .. " must use the popup origin")
				assert.are.equal(popup, control.anchor.other, key .. " must belong to the popup")
			end
			for _, key in ipairs({ "exactPair", "scenario", "activity", "lookupTables", "localTrainingConsent", "sourceRightsVerified" }) do
				assert.is_truthy(popup.controls["attest_" .. key], "missing explicit human attestation " .. key)
			end
			assert.is_truthy(popup.controls.rightsBasis, "a structured source-use basis must be required")
			assert.is_truthy(popup.controls.licenseId, "open-license metadata must be captured locally")
			assert.is_truthy(popup.controls.licenseUrl, "open-license URL must be captured locally")
			assert.is_truthy(popup.controls.permissionReference, "creator permission must use a non-personal evidence reference")
			assert.is_truthy(popup.controls.sourceLine, "the source origin must be visible before rights attestation")
			assert.is_false(popup.controls.approve.enabled(), "approval must stay disabled without a selected local record")
			local popupX, popupY = popup:GetPos()
			local closeX, closeY = popup.controls.close:GetPos()
			local closeWidth, closeHeight = popup.controls.close:GetSize()
			assert.is_true(closeX >= popupX and closeX + closeWidth <= popupX + 760)
			assert.is_true(closeY >= popupY and closeY + closeHeight <= popupY + 650)
			popup.controls.close:Click()
			assert.is_false(main.popups[1] == popup, "Close must dismiss the study dialog")
		end, debug.traceback)
		main.userPath = originalUserPath
		newBuild()
		if not ok then error(failure) end
	end)

	it("shows exact-test and untested-hypothesis counts from the A/B summary", function()
		newBuild()
		local tab = build.optimizerTab
		local originalUserPath = main.userPath
		local tempFile = os.tmpname()
		os.remove(tempFile)
		local isolatedUserPath = tempFile .. "_optimizer_review_counts"
		local originalSummary = BuildReviewPair.Summary
		local ok, failure = xpcall(function()
			assert.is_truthy(createTestDirectory(isolatedUserPath))
			main.userPath = isolatedUserPath
			BuildReviewPair.Summary = function()
				return { storage = { reviewedLineages = 1 }, counts = {
					scoutProposed = 3, scoutCandidates = 5, scoutUnreviewedCandidates = 2,
					criticIndependentIdeas = 4, criticCandidates = 6, criticUnreviewedCandidates = 2,
					critiquesAndQuestions = 7, responses = 8, exactTests = 2, pendingExactTests = 17,
				} }
			end
			tab:OpenBuildReviewDashboard()
			local popup = main.popups[1]
			assert.are.equal("AI Planner — Caderno A/B e hipóteses", popup.title)
			local counts = popup.controls.counts:GetProperty("label")
			assert.is_truthy(counts:find("registros com teste exato: 2", 1, true))
			assert.is_truthy(counts:find("hipóteses por testar: 17", 1, true))
			assert.is_nil(counts:find("factorial skill×skill: 0", 1, true))
			popup.controls.close:Click()
		end, debug.traceback)
		BuildReviewPair.Summary = originalSummary
		main.userPath = originalUserPath
		newBuild()
		if not ok then error(failure) end
	end)

	it("opens the paginated Scout/Critic public-build review history with bounded popup controls", function()
		newBuild()
		local tab = build.optimizerTab
		local originalUserPath = main.userPath
		local tempFile = os.tmpname()
		os.remove(tempFile)
		local isolatedUserPath = tempFile .. "_optimizer_public_review_history"
		local ok, failure = xpcall(function()
			assert.is_truthy(createTestDirectory(isolatedUserPath))
			main.userPath = isolatedUserPath
			tab:OpenPublicBuildReviewHistory()
			local popup = main.popups[1]
			assert.are.equal("AI Planner — histórico de revisões públicas", popup.title)
			assert.is_truthy(popup.controls.patch)
			assert.is_truthy(popup.controls.category)
			assert.is_truthy(popup.controls.skill)
			assert.is_truthy(popup.controls.history1)
			assert.is_truthy(popup.controls.detail1)
			assert.is_truthy(popup.controls.live:GetProperty("label"):find("histórico de revisões não encontrado", 1, true))
			assert.is_false(popup.controls.detail1.enabled(), "details must stay disabled when no paired result exists")
			local popupX, popupY = popup:GetPos()
			for key, control in pairs(popup.controls) do
				assert.are.equal("TOPLEFT", control.anchor.point, key .. " must use the popup origin")
				assert.are.equal(popup, control.anchor.other, key .. " must belong to the popup")
				local x, y = control:GetPos()
				local width, height = control:GetSize()
				assert.is_true(x >= popupX and x + width <= popupX + 840, key .. " must remain within the history popup width")
				assert.is_true(y >= popupY and y + height <= popupY + 700, key .. " must remain within the history popup height")
			end
			popup.controls.close:Click()
			assert.is_false(main.popups[1] == popup, "Close must dismiss the public review history")
		end, debug.traceback)
		main.userPath = originalUserPath
		newBuild()
		if not ok then error(failure) end
	end)

	it("renders a paired public-build review and exposes its skill filter in the history dashboard", function()
		newBuild()
		local tab = build.optimizerTab
		local originalUserPath = main.userPath
		local tempFile = os.tmpname()
		os.remove(tempFile)
		local isolatedUserPath = tempFile .. "_optimizer_public_review_history_data"
		local ok, failure = xpcall(function()
			assert.is_truthy(createTestDirectory(isolatedUserPath))
			local studiesPath = isolatedUserPath .. "/OptimizerStudies"
			local ingestionPath = studiesPath .. "/BuildIngestion"
			assert.is_truthy(createTestDirectory(studiesPath))
			assert.is_truthy(createTestDirectory(ingestionPath))
			local file = assert(io.open(ingestionPath .. "/latest-results.jsonl", "wb"))
			local json = require("dkjson")
			assert.is_truthy(file:write(assert(json.encode({
				schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
				id = "ui_reviewed_arc", status = "reviewed", patch = "3.29", skill = "Arc",
				category = "normal", ascendancy = "Elementalist", reviewAudit = {
					pairedReviewCompleted = true, sourceStatus = "archived", reviewers = { "Scout", "Critic" },
					summary = "Main sockets confirmed by both reviewers", validationScope = "main_skill_group_only",
					mainSkillCoverageEligible = true, fullBuildStatus = "reviewed_valid", trainingEligible = false,
					ideas = { { title = "Arc + Frost Shield", status = "untested",
						linkedSkills = { "Arc", "Frost Shield" }, testPlan = "Fix the target and compare four cells." } },
					reportPath = "docs/optimizer/QA_PUBLIC_BUILD_CROSS_REVIEW_ROUND23_2026-10-25.md",
				},
			})), "\n"))
			file:close()
			main.userPath = isolatedUserPath
			tab:OpenPublicBuildReviewHistory()
			local popup = main.popups[1]
			assert.are.equal("AI Planner — histórico de revisões públicas", popup.title)
			assert.is_truthy(popup.controls.live:GetProperty("label"):find("1 revisões A/B no arquivo", 1, true))
			assert.is_truthy(popup.controls.page:GetProperty("label"):find("1 revisões nesta seleção", 1, true))
			local row = popup.controls.history1:GetProperty("label")
			assert.is_truthy(row:find("3.29 Arc [normal] / Elementalist", 1, true))
			assert.is_truthy(row:find("Ideia untested: Arc + Frost Shield", 1, true))
			assert.is_true(popup.controls.detail1.enabled())
			popup.controls.close:Click()
		end, debug.traceback)
		main.userPath = originalUserPath
		newBuild()
		if not ok then error(failure) end
	end)

	it("approves a ready exact pair only after all six technical, consent, and rights attestations", function()
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		local tab = build.optimizerTab
		local originalUserPath = main.userPath
		local originalMakeDir = MakeDir
		local root, storePath, storeDirectory, reviewPath
		local ok, failure = xpcall(function()
			local tempFile = os.tmpname()
			os.remove(tempFile)
			root = tempFile .. "_optimizer_study_review_ui"
			assert.is_truthy(createTestDirectory(root))
			storePath, storeDirectory = StudyRecords.GetStorePath(root)
			reviewPath = StudyRecords.GetReviewPath(root)
			main.userPath = root
			MakeDir = createTestDirectory
			local dataVersion = Version.Data(build)
			local exactRecord = {
				kind = "passive_node_pair",
				engine = { pobVersion = launch.versionNumber, pobBranch = Version.Branch(),
					dataVersion = dataVersion, treeVersion = build.spec.treeVersion,
					manifestFingerprint = launch.manifestFingerprint, lookupTableStatus = "not_audited" },
				buildState = {
					characterLevel = 90,
					class = { classId = 2, class = "Witch", ascendancyId = 5, ascendancy = "Elementalist" },
					allocatedNodeIds = { 101, 102, 103 },
					masterySelections = { },
					mainSkill = "Fireball",
					configuration = { activeConfigSetId = 1, title = "Pinnacle", values = { enemyIsBoss = true }, customModifiers = { } },
				},
				experiment = { unit = "one_passive_node", addedNodeIds = { 205 }, removedNodeIds = { } },
				baseline = { metrics = { CombinedDPS = 100 }, requirements = { feasible = true }, activitySustain = { status = "pass" } },
				candidate = { metrics = { CombinedDPS = 110 }, requirements = { feasible = true }, activitySustain = { status = "pass" } },
				metricDelta = { CombinedDPS = 10 },
				admission = { exactCalculated = true, useRequirementsFeasible = true, activityRatesFeasible = true, activityStatus = "pass" },
			}
			local stored = assert(StudyRecords.Append(exactRecord, root, createTestDirectory))
			local preflight = assert(StudyRecords.ReadById(storePath, stored.recordId, dataVersion, build.spec.treeVersion,
				launch.versionNumber, Version.Branch(), launch.manifestFingerprint))
			assert.is_true(preflight.reviewAssessment.canApprove,
				"fixture review preflight blocked: " .. table.concat(preflight.reviewAssessment.blockers, ", "))
			tab:OpenStudyRecords()
			local popup = main.popups[1]
			assert.are.equal("AI Planner — Study records and review", popup.title)
			assert.is_false(popup.controls.approve.enabled(), "the human attestations must be required")
			for _, key in ipairs({ "exactPair", "scenario", "activity", "lookupTables" }) do
				popup.controls["attest_" .. key].state = true
			end
			assert.is_false(popup.controls.approve.enabled(), "technical review alone must not grant training consent")
			popup.controls.attest_localTrainingConsent.state = true
			assert.is_false(popup.controls.approve.enabled(), "training consent alone must not attest source rights")
			popup.controls.attest_sourceRightsVerified.state = true
			assert.is_false(popup.controls.approve.enabled(), "a rights checkbox without a structured basis must not enable approval")
			local licenseOption
			for index, option in ipairs(popup.controls.rightsBasis.list) do
				if option.val == "open_license" then licenseOption = index break end
			end
			assert.is_truthy(licenseOption)
			popup.controls.rightsBasis:SetSel(licenseOption)
			popup.controls.licenseId:SetText("CC-BY-4.0")
			popup.controls.licenseUrl:SetText("https://creativecommons.org/licenses/by/4.0/")
			assert.is_true(popup.controls.approve.enabled(), "all attestations and valid rights evidence should enable approval")
			popup.controls.approve:Click()
			local reviewed = assert(StudyRecords.ReadById(storePath, stored.recordId, dataVersion, build.spec.treeVersion,
				launch.versionNumber, Version.Branch(), launch.manifestFingerprint))
			assert.is_true(reviewed.trainingEligible)
			assert.are.equal("approved", reviewed.reviewStatus)
			assert.are.equal("open_license", reviewed.certification.sourceRights.basis)
			assert.is_nil(reviewed.certification.sourceRights.licenseUrl, "the public record summary must not expose the raw URL")
			popup.controls.close:Click()
		end, debug.traceback)
		main.userPath = originalUserPath
		MakeDir = originalMakeDir
		if reviewPath then os.remove(reviewPath) end
		if storePath then os.remove(storePath) end
		if storeDirectory then crt._rmdir(storeDirectory) end
		if root then crt._rmdir(root) end
		newBuild()
		if not ok then error(failure) end
	end)

	it("switches the direction selector cleanly between one class and all seven", function()
		newBuild()
		local tab = build.optimizerTab
		tab:OpenBuildDirection()
		local controls = main.popups[1].controls
		local selectedClassId = tonumber(tab.textValues.baseClassId)
		controls.allClasses.state = true
		controls.allClasses.changeFunc(true)
		assert.is_true(tab.textValues.searchAllClasses)
		assert.are.equal("", tab.textValues.baseClassId)
		for _, option in pairs(tab.directionClassControls) do assert.is_false(option.state) end

		local otherClassId
		for classId in pairs(tab.directionClassControls) do
			if classId ~= selectedClassId then otherClassId = classId break end
		end
		assert.is_truthy(otherClassId)
		tab.directionClassControls[otherClassId].changeFunc()
		assert.is_false(tab.textValues.searchAllClasses)
		assert.are.equal(tostring(otherClassId), tab.textValues.baseClassId)
		assert.is_false(controls.allClasses.state)
		assert.is_true(tab.directionClassControls[otherClassId].state)
		main:ClosePopup()
		newBuild()
	end)

	it("preserves structural passive-tree failure reasons instead of inventing missing metrics", function()
		local text = OptimizerTab.FormatViolation({
			key = "branch_or_point_limit",
			label = "Passive tree constraint",
			reason = "Candidate must contain exactly the selected class start node",
		})
		assert.are.equal("Passive tree constraint: Candidate must contain exactly the selected class start node", text)
		assert.is_nil(text:find("not provided", 1, true))
		assert.is_nil(text:find("strict requirement", 1, true))
	end)

	it("formats exact zonal gains and best deficits for the result status", function()
		local zones = {
			exactEvaluations = 7,
			exactCombinedEvaluations = 2,
			zoneResults = {
				Hub = { bestObjectiveDeltaFromBaseline = 100, bestNormalizedDeficit = 0.02 },
				NorthWest = { bestObjectiveDeltaFromBaseline = -0.25, bestNormalizedDeficit = 0.15 },
				SouthEast = { bestNormalizedDeficit = 0.08 },
			},
		}
		assert.are.equal("Zone delta: Hub +100 NW -0.25 (7 exact/2 combined)", OptimizerTab.FormatZoneOutcomeSummary(zones, true))
		assert.are.equal("Best zone deficit: Hub 0.02 NW 0.15 SE 0.08 (7 exact/2 combined)", OptimizerTab.FormatZoneOutcomeSummary(zones, false))
		assert.is_nil(OptimizerTab.FormatZoneOutcomeSummary({ zoneResults = { } }, true))
	end)

	it("shows exact support-package evaluation and compatibility by arity", function()
		assert.are.equal("Support arities exact/compatible (6/4): add 2: 3/2, add 3: 2/1, replace 2: 1/1",
			OptimizerTab.FormatSupportPackageSummary({ supportPackages = {
				additions = {
					{ arity = 1, exact = 0, compatible = 0 },
					{ arity = 2, exact = 3, compatible = 2 },
					{ arity = 3, exact = 2, compatible = 1 },
					{ arity = 4, exact = 0, compatible = 0 },
					{ arity = 5, exact = 0, compatible = 0 },
				},
				swaps = {
					{ arity = 1, exact = 0, compatible = 0 },
					{ arity = 2, exact = 1, compatible = 1 },
					{ arity = 3, exact = 0, compatible = 0 },
					{ arity = 4, exact = 0, compatible = 0 },
					{ arity = 5, exact = 0, compatible = 0 },
				},
			} }))
		assert.is_nil(OptimizerTab.FormatSupportPackageSummary({ supportPackages = { additions = { }, swaps = { } } }))
	end)

	it("shows exact local gear-repair coverage only when the baseline has target deficits", function()
		assert.are.equal("Local gear repair: 3 exact/8 proposals, 2 improved, 1 target deficit cleared",
			OptimizerTab.FormatRequirementRepairSummary({ active = true, exactCandidateEvaluations = 3,
				scheduledCandidates = 8, improvedExactEvaluations = 2, fullyRepairedExactEvaluations = 1 }))
		assert.is_nil(OptimizerTab.FormatRequirementRepairSummary({ active = false }))
		assert.are.equal("Catalyst repairs: 2 exact/3 proposals; 1 strict-budget price gap(s)",
			OptimizerTab.FormatCatalystSearchSummary({ generatedCandidates = 3, exactEvaluations = 2, unpricedCandidates = 1 }))
		assert.is_nil(OptimizerTab.FormatCatalystSearchSummary({ generatedCandidates = 0 }))
		assert.are.equal("Synthetic gear: 3 singles/2 pairs/0 triples; 4 exact (1 pairs/0 triples)",
			OptimizerTab.FormatSyntheticGearSummary({ generatedCandidates = 5, generatedSingleCandidates = 3,
				generatedPairedCandidates = 2, exactEvaluations = 4, exactPairedEvaluations = 1 }))
		assert.are.equal("Synthetic gear: 1 singles/0 pairs/0 triples; 1 exact (0 pairs/0 triples); 1 linked-skill proposal(s), 1 exact; last exact blocker: attribute_requirement_Str — Base requires Strength",
			OptimizerTab.FormatSyntheticGearSummary({ generatedCandidates = 1, generatedSingleCandidates = 1,
				exactEvaluations = 1, socketBoundCandidates = 1, exactSocketBoundEvaluations = 1,
				lastExactEvaluation = { feasible = false, violations = {
					{ key = "attribute_requirement_Str", reason = "Base requires Strength" },
				} } }))
		assert.is_nil(OptimizerTab.FormatSyntheticGearSummary({ generatedCandidates = 0 }))
		assert.are.equal("native permanent utility flasks 2; Pathfinder flasks off (uptime unsupported)",
			OptimizerTab.FormatFlaskExceptionSummary({
				magebloodPermanentCount = 2,
				pathfinderPolicy = "disabled_without_exact_uptime_model",
			}))
		assert.are.equal("Pinnacle flask audit failed",
			OptimizerTab.FormatFlaskExceptionSummary({ certified = false }))
		assert.is_nil(OptimizerTab.FormatFlaskExceptionSummary({ status = "all_flasks_disabled", certified = true }))
		assert.are.equal("PoB charges P 3/3 F 3/3 E 0/3; config useFrenzyCharges=true; gain/spend/uptime unverified | Shock PoB 65% (conditionEnemyShocked=true, conditionShockEffect=65); application/uptime unverified | Preserved configured conditions (uptime unverified): conditionEnemyCursed=true",
			OptimizerTab.FormatScenarioAssumptionSummary({
				chargeAudit = { countsAreExactPoBOutput = true, generationConsumptionSimulated = false, uptimeCertified = false,
					charges = {
						{ key = "Power", current = 3, minimum = 0, maximum = 3 },
						{ key = "Frenzy", current = 3, minimum = 0, maximum = 3 },
						{ key = "Endurance", current = 0, minimum = 0, maximum = 3 },
					}, configuredFields = { { key = "useFrenzyCharges", value = true, source = "input" } } },
				shockAudit = { effectivePoBOutput = 65, uptimeCertified = false, configuredAssumptions = {
					{ key = "conditionEnemyShocked", value = true },
					{ key = "conditionShockEffect", value = 65 },
				} },
				preservedConditionalAssumptions = {
					{ key = "conditionEnemyShocked", category = "enemy_ailment" },
					{ key = "useFrenzyCharges", category = "charges" },
					{ key = "conditionEnemyCursed", category = "condition", value = true },
				},
			}))
		assert.are.equal("Shock PoB 0% (conditionShockedEnemyRecently=true); application/uptime unverified | Preserved configured conditions (uptime unverified): conditionBlockedAttackRecently=true, frostShieldStages=4, multiplierWitheredStackCount=15 (+1 more)",
			OptimizerTab.FormatScenarioAssumptionSummary({
				shockAudit = { effectivePoBOutput = 0, uptimeCertified = false, configuredAssumptions = {
					{ key = "conditionShockedEnemyRecently", value = true },
				} },
				preservedConditionalAssumptions = {
					{ key = "conditionShockedEnemyRecently", category = "enemy_ailment", value = true },
					{ key = "conditionBlockedAttackRecently", category = "condition", value = true },
					{ key = "frostShieldStages", category = "stacks", value = 4 },
					{ key = "multiplierWitheredStackCount", category = "stacks", value = 15 },
					{ key = "conditionEnemyCursed", category = "condition", value = true },
				},
			}))
		assert.are.equal("PoB charge counts 0 | Shock PoB 0%",
			OptimizerTab.FormatScenarioAssumptionSummary({
				chargeAudit = { countsAreExactPoBOutput = true, uptimeCertified = true, charges = { }, alternateCharges = { } },
				shockAudit = { effectivePoBOutput = 0, uptimeCertified = true },
			}))
		assert.are.equal("PoB charge counts 0; Pinnacle charge policy: useFrenzyCharges cleared, overrideInspirationCharges=0 | Shock PoB 0%",
			OptimizerTab.FormatScenarioAssumptionSummary({
				chargeAudit = { countsAreExactPoBOutput = true, uptimeCertified = true, charges = { }, alternateCharges = { },
					clearedConfiguredFields = {
						{ key = "useFrenzyCharges", policy = "cleared" },
						{ key = "overrideInspirationCharges", policy = "forced_zero" },
					} },
				shockAudit = { effectivePoBOutput = 0, uptimeCertified = true },
			}))
		assert.are.equal("Enemy Uber pinnacle", OptimizerTab.FormatScenarioAssumptionSummary({ enemyIsBoss = "Uber" }))
		assert.are.equal("Enemy Uber pinnacle | PoB enemy level 72 (explicit; no area-specific stats)",
			OptimizerTab.FormatScenarioAssumptionSummary({ enemyIsBoss = "Uber", enemyLevelOverride = 72, resolvedEnemyLevel = 72 }))
		assert.is_nil(OptimizerTab.FormatScenarioAssumptionSummary({ }))
	end)

	it("explains whether the learned ranker is active, out of domain, stale, or absent", function()
		assert.are.equal("Learned ranker active; exact PoB gates remain authoritative",
			OptimizerTab.FormatLearningRankerSummary({ active = true, status = "ranked" }))
		assert.are.equal("Learned ranker off: no in-domain passive proposals",
			OptimizerTab.FormatLearningRankerSummary({ status = "outside_model_domain" }))
		assert.are.equal("Learned ranker off: PoB or tree version mismatch",
			OptimizerTab.FormatLearningRankerSummary({ status = "engine_version_mismatch:treeVersion" }))
		assert.are.equal("Learned ranker off: no validated model available",
			OptimizerTab.FormatLearningRankerSummary({ status = "disabled", loadStatus = "artifact_missing" }))
	end)

	it("summarizes contextual path evidence and reports when evidence is still being collected", function()
		assert.are.equal("Path learning: collecting exact baseline and route evidence",
			OptimizerTab.FormatPathExperienceSummary({ compatibleRecords = 0, storedThisRun = 0, contextStatus = "ready" }))
		assert.are.equal("Path learning: 12 exact records, 4 motifs; 3 reordered, 7 exploration routes kept, 2 promoted early; 2 saved",
			OptimizerTab.FormatPathExperienceSummary({ compatibleRecords = 12, patternCount = 4,
				reorderedCandidates = 3, preservedExploration = 7, promotedExploration = 2,
				storedThisRun = 2, contextStatus = "ready" }))
		assert.are.equal("Path learning off: optimizer context is incomplete",
			OptimizerTab.FormatPathExperienceSummary({ contextStatus = "optimizer_context_incomplete" }))
		assert.are.equal("Path learning paused: local history failed integrity checks",
			OptimizerTab.FormatPathExperienceSummary({ contextStatus = "ready", storageStatus = "corrupt" }))
	end)

	it("formats privacy-safe learning coverage without implying all skill combinations were evaluated", function()
		local coverage = {
			exactPairRows = 12,
			unverifiedPairRows = 2,
			versionRows = { current = 10, mismatch = 1, unverified = 1 },
			experimentFamilies = { passiveNodePairs = 3, gemVariantPairs = 4, masteryEffectPairs = 5, itemSlotPairs = 2,
				passiveFactorialInteractions = 1, skillSupportFactorialInteractions = 2,
				skillItemFactorialInteractions = 1, passiveItemFactorialInteractions = 1, otherFactorialInteractions = 0 },
			contextDiversity = { sourceBuildStatesObserved = 4, classStartsObserved = 3,
				mainSkillContextsObserved = 8, scenarioContextsObserved = 2 },
			combinationCoverage = "not_measured", graphRole = "report_only", modelTrainingEnabled = false,
		}
		assert.are.equal("Exact pairs 12 | unverified rows 2 | engine current 10, stale 1, unknown 1.",
			OptimizerTab.FormatLearningCoverage(coverage))
		assert.are.equal("Studies P3/G4/M5/I2/F5 | contexts 4 source, 3/7 classes, 8 skills, 2 scenarios.",
			OptimizerTab.FormatLearningCoverageContext(coverage))
		assert.are.equal("Combination coverage not_measured; graph report_only; neural model disabled.",
			OptimizerTab.FormatLearningCoverageSafety(coverage))
		assert.are.equal("Skill-combination coverage not measured; graph report-only; neural model disabled.",
			OptimizerTab.FormatLearningCoverageSafety(nil))
	end)

	it("keeps the passive-point slider within the 1–130 solver ceiling", function()
		local tab = { fieldLabels = { }, textFieldLabels = { }, controls = { pointCapSlider = { } } }
		for _, definition in ipairs(Inputs.metricDefinitions) do
			tab.fieldLabels[#tab.fieldLabels + 1] = { }
			tab.controls["metric_" .. definition.key] = { }
		end
		for _, definition in ipairs({
			{ key = "maxManualButtons" }, { key = "conversionMin" }, { key = "allowedRegions" }, { key = "requiredRegions" }, { key = "forbiddenRegions" },
			{ key = "maxAddedPoints" }, { key = "maxTotalPoints", compactLabel = "Point cap" },
			{ key = "evaluationBudget" }, { key = "objectiveMetric" }, { key = "seed" }, { key = "targetNodeIds" },
			{ key = "addNodeIds" }, { key = "removeNodeIds" }, { key = "requiredNodeIds" }, { key = "forbiddenNodeIds" },
			{ key = "scenarioProfile" },
		}) do
			tab.textFieldLabels[definition.key] = { }
			tab.controls["text_" .. definition.key] = { }
		end
		for _, key in ipairs({ "run", "cancel", "apply", "direction", "aiRequest", "mcpRequest", "compareRoots", "activitySchedule", "equipment", "classResults", "marketBudget", "studyRecords", "resultDetails", "pageMatrix", "pageNodePotential", "nodeAnalyze", "nodeCancel" }) do
			tab.controls[key] = { width = key == "activitySchedule" and 112 or key == "equipment" and 150 or key == "classResults" and 142 or key == "marketBudget" and 122 or key == "studyRecords" and 90 or key == "resultDetails" and 92 or 118, SetAnchor = function(self, point, other, otherPoint, x, y) self.x, self.y = x, y end }
		end
		OptimizerTab.Layout(tab, { width = 556 })
		assert.is_true(tab.controls.pointCapSlider.x >= tab.controls.text_maxTotalPoints.x + tab.controls.text_maxTotalPoints.width)
		assert.is_true(tab.controls.pointCapSlider.x + tab.controls.pointCapSlider.width <= 544)
		assert.are.equal(420, tab.controls.marketBudget.x)
		assert.are.equal(494, tab.controls.marketBudget.y)
		assert.is_true(tab.controls.marketBudget.x + tab.controls.marketBudget.width <= 544,
			"the compact currency-budget button must remain inside the usable panel width")
		assert.are.equal(480, tab.controls.studyRecords.x)
		assert.are.equal(520, tab.controls.studyRecords.y)
		assert.are.equal(72, tab.controls.studyRecords.width)
		assert.is_true(tab.controls.studyRecords.x + tab.controls.studyRecords.width <= 556,
			"the compact study button must remain inside the viewport")
		assert.are.equal(334, tab.controls.resultDetails.x)
		assert.are.equal(520, tab.controls.resultDetails.y)
		OptimizerTab.Layout(tab, { width = 800 })
		assert.are.equal(192, tab.controls.pointCapSlider.x)
		assert.are.equal(136, tab.controls.pointCapSlider.width)
		assert.are.equal(570, tab.controls.marketBudget.x)
		assert.are.equal(704, tab.controls.studyRecords.x)
		assert.are.equal(494, tab.controls.studyRecords.y)
		assert.are.equal(12, tab.controls.resultDetails.x)
		assert.are.equal(520, tab.controls.resultDetails.y)
		for _, width in ipairs({ 556, 740, 800, 1026 }) do
			OptimizerTab.Layout(tab, { width = width })
			for index, definition in ipairs(Inputs.metricDefinitions) do
				local label = tab.fieldLabels[index]
				local control = tab.controls["metric_" .. definition.key]
				local labelWidth = control.x - label.x - 8
				assert.is_truthy(label.text and label.text ~= "", definition.key .. " label must remain visible at " .. width .. "px")
				assert.is_nil(label.text:find("...", 1, true), definition.key .. " label is truncated at " .. width .. "px")
				assert.is_true(#label.text * label.fontSize * 0.5 <= labelWidth,
					definition.key .. " label exceeds its measured Matrix column at " .. width .. "px")
				if width == 1026 and definition.key == "FireResist" then
					assert.are.equal("Fire resistance (%)", label.text,
						"the wide Matrix must use the complete readable resistance name")
				elseif width == 1026 and definition.key == "LightningMaximumHitTaken" then
					assert.are.equal("Lightning max hit", label.text,
						"the wide Matrix must spell out Lightning rather than use a compact abbreviation")
				elseif width == 1026 and definition.key == "ManaSustainMargin" then
					assert.are.equal("Mana/ES regen margin (/s)", label.text,
						"the long sustain metric must use an explicit readable fallback")
				end
			end
		end
	end)

	it("keeps compact Matrix labels readable without splitting words", function()
		newBuild()
		local tab = build.optimizerTab
		local function labelFor(key)
			for index, definition in ipairs(Inputs.metricDefinitions) do
				if definition.key == key then return tab.fieldLabels[index].text end
			end
			error("missing metric label " .. key)
		end

		OptimizerTab.Layout(tab, { width = 740 })
		assert.are.equal("Life reserved", labelFor("LifeReserved"))
		assert.are.equal("Mana/ES regen (/s)", labelFor("ManaSustainMargin"))
		assert.are.equal("Lightning resist (%)", labelFor("LightningResist"))
		assert.are.equal("Spell suppression (%)", labelFor("SpellSuppressionChance"))
		assert.are.equal("Min Omniscience", labelFor("Omni"))

		OptimizerTab.Layout(tab, { width = 556 })
		for index, definition in ipairs(Inputs.metricDefinitions) do
			local label = tab.fieldLabels[index]
			local control = tab.controls["metric_" .. definition.key]
			local labelWidth = control.x - label.x - 8
			assert.is_nil(label.text:find("...", 1, true), definition.key .. " must not be visually clipped")
			assert.is_true(#label.text * label.fontSize * 0.5 <= labelWidth,
				definition.key .. " narrow alias exceeds its column")
		end
		assert.are.equal("Mana/ES net /s", labelFor("ManaSustainMargin"))
		assert.are.equal("Trigger /s", labelFor("SkillTriggerRate"))
		assert.are.equal("Min Omni", labelFor("Omni"))
	end)

	it("keeps each full exact metric name in its native input tooltip", function()
		newBuild()
		local tab = build.optimizerTab
		for _, definition in ipairs(Inputs.metricDefinitions) do
			local control = assert(tab.controls["metric_" .. definition.key])
			assert.is_truthy(control.tooltipText:find(definition.label, 1, true),
				definition.key .. " input must retain the full exact metric name in its tooltip")
		end
	end)

	it("saves, reports, and clears strict trade or SSF currency-budget settings", function()
		newBuild()
		local tab = build.optimizerTab
		tab.textValues.marketQuotesJson = '{"source":"poe.ninja","provider":"test economy snapshot","league":{"id":"poe1-test"},"quotes":{"101":{},"102":{}}}'
		tab:OpenMarketBudget()
		local popup = main.popups[1]
		assert.are.equal("AI Planner — Currency budget", popup.title)
		assert.are.equal("SSF", popup.controls.mode.optimizerChoices[2].val)
		assert.is_truthy(popup.controls.guidance:GetProperty("label"):find("direct UI runs use only a loaded quote snapshot", 1, true))
		assert.is_truthy(popup.controls.priceStatus:GetProperty("label"):find("Loaded quotes: 2 item IDs", 1, true))
		popup.controls.amount.buf = "12"
		popup.controls.unit.selIndex = 2
		popup.controls.mode.selIndex = 2
		popup.controls.league.buf = "SSF"
		popup.controls.rate.buf = "200"
		popup.controls.save:Click()
		assert.are.equal("12", tab.textValues.currencyBudgetAmount)
		assert.are.equal("Divine", tab.textValues.currencyBudgetUnit)
		assert.are.equal("SSF", tab.textValues.currencyBudgetMode)
		assert.are.equal("SSF", tab.textValues.currencyBudgetLeague)
		assert.are.equal("200", tab.textValues.currencyBudgetDivineChaosRate)
		assert.is_true(tab.modFlag)
		assert.is_truthy(tab.statusMessage:find("Currency budget saved", 1, true))
		tab:OpenMarketBudget()
		main.popups[1].controls.clear:Click()
		assert.are.equal("", tab.textValues.currencyBudgetAmount)
		assert.are.equal("{}", tab.textValues.marketQuotesJson)
		assert.are.equal("{}", tab.textValues.manualItemPricesJson)
		newBuild()
	end)

	it("explains overcap hard floors as percentage points above native PoB resistance maxima", function()
		newBuild()
		for _, key in ipairs({ "FireResistOverCap", "ColdResistOverCap", "LightningResistOverCap", "ChaosResistOverCap" }) do
			local tooltip = build.optimizerTab.controls["metric_" .. key].tooltipText
			assert.is_truthy(tooltip:find("exact PoB " .. key, 1, true), key .. " must identify the native output")
			assert.is_truthy(tooltip:find("percentage points above the current PoB maximum resistance", 1, true), key .. " must define overcap units")
		end
	end)

	it("shows PoB's exact legal passive limit and zero ExtraPoints in a feasible result", function()
		newBuild()
		local tab = build.optimizerTab
		tab.controls.pageMatrix:Click()
		tab.statusMessage = "Feasible candidate"
		tab.result = {
			status = "feasible",
			candidate = { label = "Native Bandit and Pantheon choices" },
			evaluation = {
				metrics = { TotalEHP = 1000, Life = 500, Mana = 100 },
				selectedBaseClassName = "Scion",
				selectedAscendancyName = "Pathfinder",
				passivePointsUsed = 46,
				strictPointCap = 120,
				passivePointLimit = 46,
				extraPassivePoints = 0,
				ascendancyPointsUsed = 0,
				activitySustain = { status = "not_required" },
			},
		}
		stampOptimizerResult(tab)
		tab.DrawControls = function() end
		tab.ProcessControlsInput = function() end
		local lines = { }
		local originalDrawString = DrawString
		DrawString = function(x, y, align, size, font, text)
			lines[#lines + 1] = tostring(text)
		end
		local ok, drawError = pcall(function()
			tab:Draw({ x = 0, y = 0, width = 1024, height = 600 }, { })
		end)
		DrawString = originalDrawString
		assert.is_true(ok, tostring(drawError))
		local resultLines = table.concat(lines, "\n")
		assert.is_truthy(resultLines:find("PoB legal 46 (Extra +0)", 1, true),
			"the result must display the exact native point budget and preserve ExtraPoints zero")
		newBuild()
	end)

	it("opens per-class results with exact candidate and Bloodline coverage details", function()
		newBuild()
		local tab = build.optimizerTab
		tab.result = {
			status = "feasible",
			evaluation = { objective = "CombinedDPS" },
			classSearch = {
				classCount = 1,
				results = {
					{
						class = "Witch", status = "feasible", quota = 16, evaluations = 14, objectiveValue = 1250000,
						bestCandidate = {
							mainAscendancy = "Occultist", bloodline = "Warden of the Maji", objectiveValue = 1250000,
							passivePointsUsed = 104, passivePointLimit = 120, mainAscendancyPoints = 6, bloodlinePoints = 4,
						},
						ascendancyCoverage = {
							status = "generated", representedMainAscendancies = 3, availableMainAscendancies = 3,
							representedBloodlines = 8, availableBloodlines = 12,
							representedBloodlineCombinations = 5, availableBloodlineCombinations = 36,
							exactBloodlineEvaluations = 6, exactCombinedEvaluations = 4, budgetLimited = true,
						},
					},
				},
			},
		}
		assert.is_true(tab.controls.classResults.enabled())
		assert.is_true(tab:OpenClassSearchResults())
		local popup = main.popups[1]
		assert.are.equal("AI Planner — per-class exact search results", popup.title)
		local candidateLine = popup.controls.class1:GetProperty("label")
		local coverageLine = popup.controls.coverage1:GetProperty("label")
		assert.is_truthy(candidateLine:find("Occultist 6 + Warden of the Maji 4", 1, true))
		assert.is_truthy(candidateLine:find("tree 104/120", 1, true))
		assert.is_truthy(coverageLine:find("Bloodlines 8/12", 1, true))
		assert.is_truthy(coverageLine:find("combined pairs 5/36", 1, true))
		assert.is_truthy(coverageLine:find("exact Bloodline 6, combined 4", 1, true))
		assert.is_truthy(coverageLine:find("quota limited", 1, true))
		popup.controls.close:Click()
		assert.is_false(main.popups[1] == popup)
		newBuild()
	end)

	it("reports local MCP health without claiming chat access while offline", function()
		local offline = {
			GetStatus = function() return "MCP offline: could not publish local endpoint" end,
			GetConnectionHealth = function() return { status = "offline" } end,
		}
		assert.are.equal("Local MCP offline: could not publish local endpoint",
			OptimizerTab.FormatMCPStatus(offline))
		local responding = {
			GetStatus = function() return "Ready on loopback port 54321" end,
			GetConnectionHealth = function() return { status = "fresh" } end,
		}
		assert.are.equal("Local MCP: online; UI loop responding",
			OptimizerTab.FormatMCPStatus(responding))
		assert.are.equal("Local MCP: bridge unavailable", OptimizerTab.FormatMCPStatus(nil))
		local unconfirmed = {
			GetStatus = function() return string.rep("starting", 8) end,
			GetConnectionHealth = function() return { status = "unknown" } end,
		}
		local message = OptimizerTab.FormatMCPStatus(unconfirmed)
		assert.are.equal(#("Local MCP: " .. string.rep("s", 35) .. "...; UI loop not confirmed"), #message,
			"long startup reasons must be clipped to keep the compact status line on screen")
		local longOffline = {
			GetStatus = function() return "MCP offline: " .. string.rep("x", 100) end,
			GetConnectionHealth = function() return { status = "offline" } end,
		}
		assert.is_true(#OptimizerTab.FormatMCPStatus(longOffline) <= #"Local MCP offline: " + 42,
			"offline diagnostics must stay within the compact status width")
	end)

	it("does not overlay compact status text over the Run and Study controls", function()
		newBuild()
		local tab = build.optimizerTab
		tab.statusMessage = "No feasible candidate: " .. string.rep("mana sustain deficit ", 20)
		assert.is_nil(tab.controls.run.tooltipText, "live diagnostics belong in the status line, not a hover overlay over controls")
		newBuild()
	end)

	it("wraps complete setup blockers in the Matrix viewport instead of clipping the Run error", function()
		newBuild()
		local tab = build.optimizerTab
		tab.controls.pageMatrix:Click()
		tab.statusMessage = "Cannot optimize: Apply the selected Main Skill in the Skills phase first; this unlinked seed needs a real socketed PoB item before Equipment can certify it"
			.. string.rep(" Additional native PoB setup context.", 3)
		tab.DrawControls = function() end
		tab.ProcessControlsInput = function() end
		local drawn = { }
		local originalDrawString = DrawString
		local originalDrawStringWidth = DrawStringWidth
		DrawString = function(x, y, align, size, font, text)
			drawn[#drawn + 1] = { y = y, text = tostring(text) }
		end
		-- HeadlessWrapper reports zero text width. Supply deterministic pixels
		-- so the real PoB WrapString path is exercised at a 1024 px viewport.
		DrawStringWidth = function(_, _, text) return #tostring(text) * 7 end
		local ok, drawError = pcall(function()
			tab:Draw({ x = 0, y = 0, width = 1024, height = 607 }, { })
		end)
		DrawString = originalDrawString
		DrawStringWidth = originalDrawStringWidth
		assert.is_true(ok, tostring(drawError))
		local statusLines = { }
		for _, row in ipairs(drawn) do
			if row.y >= tab.statusY and row.y < 607 then statusLines[#statusLines + 1] = row.text end
		end
		local rendered = table.concat(statusLines, "\n")
		local visibleStatus = rendered:gsub("%s+", " ")
		assert.is_truthy(visibleStatus:find("Apply the selected Main Skill in the Skills phase first", 1, true))
		assert.is_truthy(visibleStatus:find("before Equipment can", 1, true)
			and visibleStatus:find("certify it", 1, true),
			"the full next-step instruction must remain visible at the common 1024x607 viewport (statusY="
				.. tostring(tab.statusY) .. ", lines=" .. tostring(#statusLines) .. ", rendered=" .. rendered .. ")")
		assert.is_true(#statusLines >= 2, "long setup diagnostics should wrap across visible lines (" .. rendered .. ")")
		newBuild()
	end)

	it("keeps optimizer progress and exact hard-gate deficits visible in short viewports", function()
		local online = {
			GetStatus = function() return "Ready on loopback port 54321" end,
			GetConnectionHealth = function() return { status = "fresh" } end,
		}
		local idle = {
			statusMessage = "Exact PoB gates. FullDPS uses included groups. Existing Items-tab gear choices can be evaluated; no crafting.",
			textValues = { generationPhase = "tree" },
		}
		local idleLine, idleIsError = OptimizerTab.FormatVisibleStatus(idle, online, 708)
		assert.are.equal("Local MCP: online; UI loop responding", idleLine)
		assert.is_false(idleIsError)

		local running = {
			statusMessage = "Optimizer running...",
			textValues = { generationPhase = "tree" },
			job = { status = "running", progress = { phase = "Exact calculations", processed = 5, total = 12 } },
		}
		local progressLine = OptimizerTab.FormatVisibleStatus(running, online, 708)
		assert.is_truthy(progressLine:find("Searching Tree - Exact calculations 5/12 exact", 1, true))
		assert.is_truthy(progressLine:find("MCP online", 1, true))
		local routeRunning = {
			statusMessage = "Gerando combinações para AI Analyzer.",
			textValues = { generationPhase = "combined" },
			job = { status = "running", routePlannerRun = true,
				progress = { phase = "Pathfinding", processed = 14, total = 50 } },
		}
		local routeProgressLine = OptimizerTab.FormatVisibleStatus(routeRunning, online, 708)
		assert.is_truthy(routeProgressLine:find("Pathfinding 14/50", 1, true))
		assert.is_nil(routeProgressLine:find("MCP", 1, true), "route search progress must not show unrelated MCP status")
		local routeResult = {
			result = { status = "feasible", routePlanner = true,
				evaluation = { objective = "CombinedDPS", metrics = { CombinedDPS = 12345 }, passivePointsUsed = 90 } },
		}
		local routeResultLine = OptimizerTab.FormatVisibleStatus(routeResult, online, 708)
		assert.is_truthy(routeResultLine:find("Feasible:", 1, true))
		assert.is_nil(routeResultLine:find("MCP", 1, true), "route results must stay focused on exact PoB metrics")
		running.job.progress = { phase = "Pathfinding", processed = 60, total = 8032 }
		local pathLine = OptimizerTab.FormatVisibleStatus(running, online, 708)
		assert.is_truthy(pathLine:find("Pathfinding 60/8032", 1, true))
	assert.is_false(pathLine:find("exact", 1, true) ~= nil, "route progress must not be mislabeled as exact calculations")
		running.job.progress = { phase = "Pathfinding", processed = 1314, total = 644, counterValid = false,
			current = "plano 2/5 / NorthWest / node 443; 128 nodes expanded" }
		local inconsistentPathLine = OptimizerTab.FormatVisibleStatus(running, online, 708)
		assert.is_truthy(inconsistentPathLine:find("1314>644!", 1, true))
		assert.is_truthy(inconsistentPathLine:find("P2/5/NW/node 443", 1, true),
			"pathfinding progress should identify its active local search")

		local failed = {
			statusMessage = "Tree foundation: no feasible candidate within budget; best observed deficit is shown below.",
			result = {
				status = "no_feasible_candidate",
				evaluations = 5,
				bestObservedViolations = {
					{ key = "activity_sustain_mana", label = "Mana activity sustain",
						reason = "Exact PoB recovery 1.1/s is below recurring activity cost 6.66667/s" },
				},
			},
		}
		local failureLine, isError = OptimizerTab.FormatVisibleStatus(failed, online, 708)
		assert.is_true(isError)
		assert.is_truthy(failureLine:find("Mana activity sustain 1.1/s < 6.66667/s", 1, true))
		assert.is_truthy(failureLine:find("5 exact", 1, true))
		assert.is_truthy(failureLine:find("MCP online", 1, true))

		local narrowLine = OptimizerTab.FormatVisibleStatus({ statusMessage = string.rep("invalid matrix field ", 20) }, online, 300)
		assert.is_truthy(narrowLine:find("...", 1, true), "narrow viewports must clip long diagnostics")
		assert.is_truthy(narrowLine:find("MCP online", 1, true), "clipping must preserve the connection badge")
	end)

	it("marks results stale when the PoB build or Matrix changes and blocks their application", function()
		newBuild()
		local tab = build.optimizerTab
		local online = {
			GetStatus = function() return "Ready on loopback port 54321" end,
			GetConnectionHealth = function() return { status = "fresh" } end,
		}
		local sourceSignature = Candidate.BuildSignature(build)
		local inputSignature = assert(OptimizerTab.ComputeInputSignature(tab.textValues))
		tab.result = {
			status = "no_feasible_candidate", sourceSignature = sourceSignature, inputSignature = inputSignature,
			evaluations = 4, bestObservedViolations = { { key = "Int", label = "Minimum Intelligence", actual = 12, required = 104 } },
		}
		local currentLine = OptimizerTab.FormatVisibleStatus(tab, online, 708)
		assert.is_truthy(currentLine:find("Minimum Intelligence: 12 < 104", 1, true), currentLine)

		tab.textValues.objectiveMetric = "TotalEHP"
		local matrixStaleLine = OptimizerTab.FormatVisibleStatus(tab, online, 708)
		assert.is_truthy(matrixStaleLine:find("Optimizer result is stale", 1, true), matrixStaleLine)
		assert.is_false(matrixStaleLine:find("Minimum Intelligence 12 < 104", 1, true) ~= nil, matrixStaleLine)

		tab.textValues.objectiveMetric = "CombinedDPS"
		build.characterLevel = build.characterLevel - 1
		local buildStaleLine = OptimizerTab.FormatVisibleStatus(tab, online, 708)
		assert.is_truthy(buildStaleLine:find("Optimizer result is stale", 1, true), buildStaleLine)
		local staleDetails = OptimizerTab.FormatResultDetails(tab, 900)
		local staleText = table.concat((function()
			local rows = { }
			for _, row in ipairs(staleDetails) do rows[#rows + 1] = StripEscapes(row[1] or "") end
			return rows
		end)(), "\n")
		assert.is_truthy(staleText:find("previous metrics and deficits are hidden", 1, true), staleText)
		assert.is_false(staleText:find("Minimum Intelligence 12 < 104", 1, true) ~= nil, staleText)
		local buildSignatureBeforeApply = Candidate.BuildSignature(build)
		tab.result = {
			status = "feasible", sourceSignature = sourceSignature, inputSignature = inputSignature,
			candidate = { feasible = true, sourceSignature = sourceSignature, generationPhase = "tree" },
		}
		local applied = tab:ApplyResult()
		assert.is_false(applied)
		assert.is_truthy(tab.statusMessage:find("stale", 1, true), tab.statusMessage)
		assert.are.equal(buildSignatureBeforeApply, Candidate.BuildSignature(build), "a stale result must not mutate the build")

		tab.result = { status = "no_feasible_candidate", evaluations = 1, bestObservedViolations = { } }
		local unverifiedLine = OptimizerTab.FormatVisibleStatus(tab, online, 708)
		assert.is_truthy(unverifiedLine:find("not verified for the current build", 1, true), unverifiedLine)
		assert.is_false(unverifiedLine:find("No feasible:", 1, true) ~= nil, unverifiedLine)
		newBuild()
	end)

	it("opens a scrollable result report with every gate, exact metric and proof boundary", function()
		newBuild()
		local witchId = assert(build.spec.tree.classNameMap.Witch)
		local necromancerId
		for id, ascendancy in pairs(build.spec.tree.classes[witchId].classes) do
			if ascendancy.name == "Necromancer" then necromancerId = id end
		end
		assert.is_truthy(necromancerId)
		build.spec:SelectClass(witchId)
		build.spec:SelectAscendClass(necromancerId)
		local tab = build.optimizerTab
		tab.textValues.baseClassId = tostring(build.spec.curClassId)
		tab.textValues.targetSkillGemId = "Metadata/Items/Gems/SkillGemFireball"
		tab.textValues.targetSkillGroupIndex = "1"
		tab.textValues.targetSkillIndex = "1"
		tab.textValues.generationPhase = "tree"
		tab.textValues.evaluationBudget = "120"
		tab.textValues.conversionRoute = "Physical>Cold"
		tab.textValues.conversionMin = "100"
		tab.textValues.Life = "1000"
		local exactMetrics = { CombinedDPS = 13.9, Mana = 56 }
		for index = 1, 60 do exactMetrics["Metric" .. tostring(index)] = index end
		tab.result = {
			status = "no_feasible_candidate",
			evaluations = 3,
			bestObservedDeficit = 0.25,
			failureEvidence = "exact_calculation",
			scenarioProfile = "Current",
			bestObservedIdentity = {
				candidateLabel = "Current build",
				baseClass = "Witch",
				ascendancy = "Necromancer",
				secondaryAscendancy = "None",
				passivePointsUsed = 2,
				ascendancyPointsUsed = 0,
			},
			bestObservedViolations = {
				{ key = "conversion_route", label = "Conversion route", reason = "Physical to Cold 0% < 100%" },
				{ key = "activity_sustain_mana", label = "Mana activity sustain", actual = 1, required = 6.66667,
					reason = "Exact PoB recovery 1/s is below recurring activity cost 6.66667/s" },
			},
			searchBaseline = {
				exact = true, label = "Current build", feasible = false, violationCount = 1,
				metrics = { CombinedDPS = 10, Mana = 50 },
			},
			bestObservedMetrics = exactMetrics,
		}
		stampOptimizerResult(tab)

		local rows = OptimizerTab.FormatResultDetails(tab, 900)
		local textRows = { }
		local totalHeight = 0
		for _, row in ipairs(rows) do
			textRows[#textRows + 1] = StripEscapes(row[1] or "")
			totalHeight = totalHeight + (row.height or 0)
		end
		local report = table.concat(textRows, "\n")
		assert.is_truthy(report:find("does not prove a global optimum or infeasibility", 1, true))
		assert.is_truthy(report:find("Active PoB: Witch / Necromancer", 1, true))
		assert.is_truthy(report:find("Best observed candidate: Current build; Witch / Necromancer / None", 1, true))
		assert.is_truthy(report:find("Hard conversion route: Physical -> Cold", 1, true))
		assert.is_truthy(report:find("Minimum Life: minimum >= 1000", 1, true))
		assert.is_truthy(report:find("Conversion route: Physical to Cold 0% < 100%", 1, true))
		assert.is_truthy(report:find("Mana activity sustain", 1, true))
		assert.is_truthy(report:find("Compact comparison cards — exact PoB, same scenario", 1, true))
		assert.is_truthy(report:find("Baseline card — Current build — FAIL strict gates (1 violations).", 1, true))
		assert.is_truthy(report:find("Best observed card — Current build — NOT DELIVERABLE; 2 hard-gate violations.", 1, true))
		assert.is_truthy(report:find("Combined DPS: 13.9 (Δ +3.9)", 1, true))
		assert.is_truthy(report:find("Exact baseline-to-candidate comparison", 1, true))
		assert.is_truthy(report:find("Baseline: Current build — does not pass all current strict gates (1 violations).", 1, true))
		assert.is_truthy(report:find("Combined DPS: 10 -> 13.9 (Δ +3.9)", 1, true))
		assert.is_truthy(report:find("Mana: 50 -> 56 (Δ +6)", 1, true))
		assert.is_truthy(report:find("Combined DPS = 13.9", 1, true))
		assert.is_truthy(report:find("Mana = 56", 1, true))

		local popup = tab:OpenResultDetails()
		assert.are.equal("AI Planner — Result details", popup.title)
		assert.are.equal("close", popup.escapeControl)
		assert.is_truthy(popup.controls.details.controls.scrollBar, "the result report must use PoB's native scroll control")
		assert.is_true(totalHeight > select(2, popup.controls.details:GetSize()), "all report rows must extend beyond the visible panel for scrolling")
		assert.is_truthy(tab.controls.resultDetails.enabled())
		main:ClosePopup(popup)
		tab.innerView = "overview"
		assert.is_true(tab.controls.overviewResult.enabled())
		tab.controls.overviewResult:Click()
		local guidedPopup = main.popups[#main.popups]
		assert.are.equal("AI Planner — Result details", guidedPopup.title)
		main:ClosePopup(guidedPopup)
		newBuild()
	end)

	it("formats exact comparison cards for the baseline, winner, alternatives, and missing baseline", function()
		newBuild()
		local tab = build.optimizerTab
		tab.textValues.objectiveMetric = "CombinedDPS"
		tab.textValues.defenseProfile = "Hybrid"
		local winner = {
			label = "90 point route",
			evaluation = {
				candidateLabel = "90 point route",
				passivePointsUsed = 90,
				metrics = { CombinedDPS = 150, TotalEHP = 42000, Life = 3800, EnergyShield = 2000, SpellSuppressionChance = 100 },
			},
		}
		local alternative = {
			label = "Hybrid route",
			evaluation = {
				candidateLabel = "Hybrid route",
				passivePointsUsed = 94,
				metrics = { CombinedDPS = 125, TotalEHP = 51000, Life = 3200, EnergyShield = 3300, SpellSuppressionChance = 100 },
			},
		}
		tab.result = {
			status = "feasible",
			scenarioProfile = "PinnacleUnbuffed",
			evaluations = 18,
			candidate = winner,
			evaluation = winner.evaluation,
			paretoFront = { winner, alternative },
			searchBaseline = {
				exact = true,
				label = "Current build",
				feasible = true,
				violationCount = 0,
				metrics = { CombinedDPS = 100, TotalEHP = 30000, Life = 3500, EnergyShield = 1000, SpellSuppressionChance = 80 },
			},
		}
		stampOptimizerResult(tab)
		local function reportText()
			local rows = OptimizerTab.FormatResultDetails(tab, 900)
			local textRows = { }
			for _, row in ipairs(rows) do textRows[#textRows + 1] = StripEscapes(row[1] or "") end
			return table.concat(textRows, "\n")
		end
		local report = reportText()
		assert.is_truthy(report:find("Baseline card — Current build — PASS strict gates (0 violations).", 1, true))
		assert.is_truthy(report:find("Winner card — 90 point route — PASS all hard gates; not applied.", 1, true))
		assert.is_truthy(report:find("Combined DPS: 150 (Δ +50)", 1, true))
		assert.is_truthy(report:find("Life: 3,800 (Δ +300)", 1, true))
		assert.is_truthy(report:find("Pareto alternative #1 — Hybrid route — PASS hard gates; not applied.", 1, true))
		assert.is_truthy(report:find("Energy shield: 3,300 (Δ +2,300)", 1, true))
		assert.is_truthy(report:find("Passive points used: 94.", 1, true))

		tab.result.searchBaseline = nil
		report = reportText()
		assert.is_truthy(report:find("Baseline card — no exact same-run baseline; deltas are unavailable.", 1, true))
		assert.is_nil(report:find("Δ", 1, true), "the report must not invent deltas when the exact baseline is missing")
		newBuild()
	end)

	it("formats Route Planner metrics with readable labels, separators, and exact deltas", function()
		newBuild()
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		local winner = {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { 101 },
			label = "Exact route",
			archiveDerivedPassiveRoute = true,
			archivedRouteComposition = true,
			evaluation = {
				feasible = true,
				objective = "CombinedDPS",
				candidateLabel = "Exact route",
				metrics = {
					CombinedDPS = 50259480.125,
					FullDPS = 71071280.123456,
					FireHitAverage = 123456.789012,
					TotalEHP = 135385.75,
					PhysicalMaximumHitTaken = 16376.25,
					FireMaximumHitTaken = 57000,
					FireResist = 77,
					ChaosResist = 5,
				},
			},
		}
		tab.textValues.objectiveMetric = "CombinedDPS"
		tab.textValues.damageFocus = "Fire"
		tab.textValues.defenseProfile = "EnergyShield"
		tab.nodeEvidence = { status = "ready", compatibleBuildCount = 2, routePatternCount = 3,
			archiveSourceMode = "local_archive" }
		tab.result = {
			status = "feasible", routePlanner = true, objectiveMetric = "CombinedDPS",
			sourceSignature = sourceSignature, candidate = winner, evaluation = winner.evaluation,
			paretoFront = { winner },
			searchBaseline = {
				exact = true, label = "Current build", feasible = false, violationCount = 1,
				metrics = {
					CombinedDPS = 41740491.0625,
					FullDPS = 58825810.123,
					FireHitAverage = 100000.125,
					TotalEHP = 99708.95,
					PhysicalMaximumHitTaken = 14204.125,
					FireMaximumHitTaken = 47010,
					FireResist = 77,
					ChaosResist = -30,
				},
			},
			searchCoverage = { phase = {
				archivedRoutePatterns = {
					availablePatterns = 3,
					generatedCandidates = 4, retainedDirectCandidates = 3,
					generatedComposedCandidates = 5, retainedComposedCandidates = 4,
					exactEvaluations = 3, exactDirectEvaluations = 1, exactComposedEvaluations = 2,
					exactFeasible = 2, exactDirectFeasible = 1, exactComposedFeasible = 1,
				},
				exactEvaluationPlan = { familyOrder = { "equipment", "skills", "combined", "tree", "configuration", "other" },
					windowSize = 5, windowFamilyDiversity = 4,
					windowFamilyCounts = { baseline = 1, equipment = 1, skills = 1, tree = 2 } },
				exactEvaluationsByFamily = { equipment = 1, skills = 2, tree = 4 },
			} },
		}
		stampOptimizerResult(tab)
		local rows = OptimizerTab.FormatResultDetails(tab, 900)
		local textRows = { }
		for _, row in ipairs(rows) do textRows[#textRows + 1] = StripEscapes(row[1] or "") end
		local report = table.concat(textRows, "\n")
		assert.is_truthy(report:find("Damage focus: Fire guides proposal generation and exact ranking", 1, true), report)
		assert.is_truthy(report:find("Fire average hit (native average damage per hit, not isolated elemental DPS)", 1, true), report)
		assert.is_truthy(report:find("Fire average hit: 123,456.789012 (Δ +23,456.664012)", 1, true), report)
		assert.is_truthy(report:find("Combined DPS: 50,259,480.125 (Δ +8,518,989.0625)", 1, true), report)
		assert.is_truthy(report:find("Full DPS: 71,071,280.123456 (Δ +12,245,470.000456)", 1, true), report)
		assert.is_truthy(report:find("2 builds do mesmo patch/árvore e classe-base (mesma Main Skill); 3 padrões passivos no local archive.", 1, true), report)
		assert.is_truthy(report:find("Rotas diretas: 4 geradas / 3 retidas. Combinações compostas com mutações: 5 geradas / 4 retidas.", 1, true), report)
		assert.is_truthy(report:find("Recálculos nativos exatos: 3 (1 diretas, 2 compostas); passaram todos os pisos: 2 (1 diretas, 1 compostas).", 1, true), report)
		assert.is_truthy(report:find("Rota composta a partir de padrão passivo observado em builds arquivadas", 1, true), report)
		assert.is_truthy(report:find("Effective HP (EHP): 135,385.75 (Δ +35,676.8)", 1, true), report)
		assert.is_truthy(report:find("Physical maximum hit: 16,376.25 (Δ +2,172.125)", 1, true), report)
		assert.is_truthy(report:find("Fire resistance: 77% (Δ +0%)", 1, true), report)
		assert.is_truthy(report:find("Chaos resistance: 5% (Δ +35%)", 1, true), report)
		assert.is_nil(report:find("CombinedDPS", 1, true), "internal metric keys are not shown to the player")
		assert.is_nil(report:find("e+07", 1, true), "large values must not use scientific notation")
		assert.is_truthy(report:find("Plano do lote exato (5):", 1, true), report)
		assert.is_truthy(report:find("4 famílias representadas", 1, true), report)
		assert.is_truthy(report:find("Cálculos exatos concluídos por família:", 1, true), report)
		newBuild()
	end)

	it("lets the Route Planner select and apply a fresh exact Pareto route", function()
		newBuild()
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		tab.textValues.damageFocus = "Fire"
		local winner = {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { 101 },
			label = "Highest DPS route",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Highest DPS route",
				metrics = { CombinedDPS = 200, FireHitAverage = 10, TotalEHP = 40000 } },
		}
		local alternative = {
			feasible = true,
			sourceSignature = sourceSignature,
			gearVariant = {
				changedSlots = { "Ring 1" },
				items = { { slot = "Ring 1", name = "Synthetic Opal Ring", synthetic = true, affixCount = 4 } },
				generatedItems = { { slotName = "Ring 1", item = { explicitModLines = {
					{ line = "+50 to maximum Life" }, { line = "+20% to Fire Resistance" },
				} } } },
			},
			label = "Defensive route",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Defensive route",
				metrics = { CombinedDPS = 160, FireHitAverage = 8, TotalEHP = 60000 } },
		}
		local duplicateMetrics = {
			feasible = true,
			sourceSignature = sourceSignature,
			gemVariants = { { groupIndex = 1, gemIndex = 2, gemId = "test" } },
			label = "Same metrics from a different equipment proposal",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Same metrics from a different equipment proposal",
				metrics = { CombinedDPS = 200, FireHitAverage = 10, TotalEHP = 40000 } },
		}
		local baseline = {
			feasible = true,
			sourceSignature = sourceSignature,
			label = "Current build baseline",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Current build baseline",
				metrics = { CombinedDPS = 120, TotalEHP = 45000 } },
		}
		local flaskAlternative = {
			feasible = true,
			sourceSignature = sourceSignature,
			gearVariant = { changedSlots = { "Flask 5" } },
			label = "Forbidden flask upgrade",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Forbidden flask upgrade",
				metrics = { CombinedDPS = 500, TotalEHP = 70000 } },
		}
		tab.result = {
			status = "feasible", routePlanner = true, objectiveMetric = "CombinedDPS",
			candidate = winner, evaluation = winner.evaluation, paretoFront = { baseline, winner, duplicateMetrics, alternative, flaskAlternative },
			sourceBuildBaseline = { comparisonOnly = true, socketRepairRequired = true,
				label = "Loaded build — native PoB output (comparison only)",
				metrics = { CombinedDPS = 120, FireHitAverage = 6, TotalEHP = 45000 } },
		}
		stampOptimizerResult(tab)

		local popup = tab:OpenResultDetails()
		assert.are.equal(3, #popup.controls.routeSelect.list,
			"the route picker should preserve structurally distinct exact routes even when their metrics match")
		local winnerChoice = popup.controls.routeSelect:GetSelValue()
		assert.are.equal(winner, winnerChoice.candidate)
		assert.is_truthy(winnerChoice.label:find("Combined DPS 200", 1, true), winnerChoice.label)
		assert.is_truthy(winnerChoice.label:find("Effective HP (EHP) 40,000", 1, true), winnerChoice.label)
		assert.is_truthy(winnerChoice.label:find("Fire average hit 10 (Δ +4)", 1, true), winnerChoice.label)
		assert.is_nil(winnerChoice.label:find("e+", 1, true), winnerChoice.label)
		assert.is_true(popup.controls.applyRoute.enabled())
		local sameMetricsChoice = popup.controls.routeSelect.list[2]
		assert.are.equal(duplicateMetrics, sameMetricsChoice.candidate)
		assert.is_truthy(sameMetricsChoice.label:find("mesmas métricas avaliadas da rota 1; alteração diferente", 1, true),
			sameMetricsChoice.label)
		popup.controls.routeSelect:SetSel(2)
		assert.are.equal(duplicateMetrics, tab.selectedRouteCandidate,
			"a structurally distinct same-metric route must be selectable")
		local routeOverview = table.concat(OptimizerTab.FormatGuidedWorkflow(tab, BuildReadiness.Evaluate(build)), "\n")
		assert.is_truthy(routeOverview:find("3 rotas exatas aprovadas", 1, true), routeOverview)
		local sameMetricsDetails = { }
		for _, row in ipairs(popup.controls.details.list or { }) do
			sameMetricsDetails[#sameMetricsDetails + 1] = StripEscapes(row[1] or "")
		end
		assert.is_truthy(table.concat(sameMetricsDetails, "\n"):find("Same metrics from a different equipment proposal", 1, true))
		local originalApply = tab.ApplyCandidate
		local appliedCandidate
		tab.ApplyCandidate = function(_, selected)
			appliedCandidate = selected
			return true, "Applied test route as a variation"
		end
		popup.controls.routeSelect:SetSel(3)
		assert.are.equal(tab.result, tab.selectedRouteResult,
			"the overview must track the exact route chosen in the route selector")
		assert.are.equal(alternative, tab.selectedRouteCandidate)
		local liveOverview = table.concat(OptimizerTab.FormatGuidedWorkflow(tab, BuildReadiness.Evaluate(build)), "\n")
		assert.is_truthy(liveOverview:find("Rota selecionada: Defensive route", 1, true), liveOverview)
		assert.is_truthy(liveOverview:find("Combined DPS: 160 (Δ +40)", 1, true), liveOverview)
		assert.is_truthy(liveOverview:find("Effective HP (EHP): 60,000 (Δ +15,000)", 1, true), liveOverview)
		local selectedDetails = { }
		for _, row in ipairs(popup.controls.details.list or { }) do selectedDetails[#selectedDetails + 1] = StripEscapes(row[1] or "") end
		local selectedReport = table.concat(selectedDetails, "\n")
		assert.is_truthy(selectedReport:find("Selected exact route — Defensive route", 1, true), selectedReport)
		assert.is_truthy(selectedReport:find("Comparison reference — loaded build's native PoB output only", 1, true), selectedReport)
		assert.is_truthy(selectedReport:find("Main Skill sockets/links require repair", 1, true), selectedReport)
		assert.is_truthy(selectedReport:find("Alterações exatas contra a build base", 1, true), selectedReport)
		assert.is_truthy(selectedReport:find("Ring 1 → Synthetic Opal Ring (raro teórico; 4/4 afixos)", 1, true), selectedReport)
		assert.is_truthy(selectedReport:find("Afixo em Ring 1 → +50 to maximum Life", 1, true), selectedReport)
		assert.is_truthy(selectedReport:find("Afixo em Ring 1 → +20% to Fire Resistance", 1, true), selectedReport)
		assert.is_truthy(selectedReport:find("Combined DPS: 160 (Δ +40)", 1, true), selectedReport)
		assert.is_truthy(selectedReport:find("Fire average hit: 8 (Δ +2)", 1, true), selectedReport)
		assert.is_truthy(selectedReport:find("Effective HP (EHP): 60,000 (Δ +15,000)", 1, true), selectedReport)
		local originalObjective = tab.textValues.objectiveMetric
		tab.textValues.objectiveMetric = tostring(originalObjective) .. " changed"
		popup.controls.applyRoute:Click()
		assert.is_nil(appliedCandidate, "stale Matrix results must not dispatch an exact route")
		assert.is_truthy(tab.statusMessage:find("Cannot apply stale optimizer result", 1, true))
		assert.are.equal(popup, main.popups[1], "a stale result remains open for review and explicit dismissal")
		tab.textValues.objectiveMetric = originalObjective
		popup.controls.applyRoute:Click()
		tab.ApplyCandidate = originalApply
		assert.are.equal(alternative, appliedCandidate, "Apply must dispatch the explicitly selected route")
		assert.are.equal(popup, main.popups[1], "successful application feedback remains visible until the user closes the result")
		assert.is_truthy(popup.controls.applyFeedback:GetProperty("label"):find("Rota 3 aplicada como variação reversível", 1, true))
		main:ClosePopup(popup)
		newBuild()
	end)

	it("keeps the invalid Main Skill recovery action inside a compact Route Planner popup", function()
		newBuild()
		build.mainSocketGroup = 999
		local tab = build.optimizerTab
		tab:OpenRoutePlanner()
		local popup = assert(main.popups[1])
		assert.are.equal(DisplayText.Native("AI Planner — build bloqueada"), popup.title)
		assert.is_truthy(popup.controls.blockingReason)
		assert.is_truthy(popup.controls.fixSkills)
		assert.is_nil(popup.controls.run, "an invalid Main Skill cannot start a route search")
		local popupWidth, popupHeight = popup:GetSize()
		assert.are.equal(900, popupWidth)
		assert.is_true(popupHeight <= 240, "a blocked build must use the compact recovery dialog")
		local popupX, popupY = popup:GetPos()
		for _, key in ipairs({ "blockingReason", "fixSkills", "close" }) do
			local control = popup.controls[key]
			local x, y = control:GetPos()
			local width, height = control:GetSize()
			assert.is_true(x >= popupX and x + width <= popupX + popupWidth, key .. " must fit horizontally")
			assert.is_true(y >= popupY and y + height <= popupY + popupHeight, key .. " must fit vertically")
		end
		popup.controls.fixSkills:Click()
		assert.are.equal("SKILLS", build.viewMode, "the recovery action opens the native Skills tab")
		assert.is_nil(main.popups[1], "the recovery popup closes before the Skills tab opens")
		newBuild()
	end)

	it("blocks a flask-mutating Route Planner winner before details or application", function()
		newBuild()
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		local flaskWinner = {
			feasible = true,
			sourceSignature = sourceSignature,
			gearVariant = { changedSlots = { "Flask 5" } },
			label = "Stored item pair: Weapon 1 + Flask 5",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Forbidden flask upgrade",
				metrics = { CombinedDPS = 100000000, TotalEHP = 80000 } },
		}
		tab.textValues.objectiveMetric = "CombinedDPS"
		tab.result = {
			status = "feasible", routePlanner = true, objectiveMetric = "CombinedDPS",
			sourceSignature = sourceSignature, candidate = flaskWinner, evaluation = flaskWinner.evaluation,
			paretoFront = { flaskWinner },
		}
		stampOptimizerResult(tab)
		local rows = OptimizerTab.FormatResultDetails(tab, 900)
		local textRows = { }
		for _, row in ipairs(rows) do textRows[#textRows + 1] = StripEscapes(row[1] or "") end
		local report = table.concat(textRows, "\n")
		assert.is_truthy(report:find("não permite alterar frascos", 1, true), report)
		assert.is_nil(report:find("100,000,000", 1, true), report)
		local popup = tab:OpenResultDetails()
		assert.is_nil(popup.controls.routeSelect, "a flask-mutating stale payload cannot offer a route")
		assert.is_nil(popup.controls.applyRoute, "a flask-mutating candidate cannot be applied")
		main:ClosePopup(popup)
		newBuild()
	end)

	it("caps the exact route selector at twenty-five distinct Pareto results", function()
		newBuild()
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		local winner = {
			feasible = true,
			sourceSignature = sourceSignature,
			gearVariant = { changedSlots = { "Ring 1" } },
			label = "Exact route 0",
			evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Exact route 0",
				metrics = { CombinedDPS = 100, TotalEHP = 40000 } },
		}
		local paretoFront = { winner }
		for index = 1, 30 do
			paretoFront[#paretoFront + 1] = {
				feasible = true,
				sourceSignature = sourceSignature,
				gearVariant = { changedSlots = { "Ring 1" } },
				label = "Exact route " .. tostring(index),
				evaluation = { feasible = true, objective = "CombinedDPS", candidateLabel = "Exact route " .. tostring(index),
					metrics = { CombinedDPS = 100 + index, TotalEHP = 40000 + index } },
			}
		end
		tab.textValues.objectiveMetric = "CombinedDPS"
		tab.result = {
			status = "feasible", routePlanner = true, objectiveMetric = "CombinedDPS",
			sourceSignature = sourceSignature, candidate = winner, evaluation = winner.evaluation,
			paretoFront = paretoFront,
			searchBaseline = { exact = true, label = "Current build", metrics = { CombinedDPS = 90, TotalEHP = 39000 } },
		}
		stampOptimizerResult(tab)
		local popup = tab:OpenResultDetails()
		assert.are.equal(25, #popup.controls.routeSelect.list,
			"the UI must keep a large exact Pareto front reviewable without overflowing its selector")
		assert.is_truthy(popup.controls.routeSelect.list[25].label:find("Δ +34", 1, true))
		main:ClosePopup(popup)
		newBuild()
	end)

	it("migrates a saved point cap above 130 down to the supported ceiling", function()
		local input = { value = nil, SetText = function(self, value) self.value = value end }
		local tab = {
			textValues = { maxTotalPoints = "130" },
			controls = { text_maxTotalPoints = input, pointCapSlider = { val = 0 } },
		}
		OptimizerTab.Load(tab, { { elem = "Input", attrib = { name = "maxTotalPoints", value = "133" } } })
		assert.are.equal("130", tab.textValues.maxTotalPoints)
		assert.are.equal("130", input.value)
		assert.are.equal(1, tab.controls.pointCapSlider.val)
		assert.is_false(tab.modFlag)
	end)

	it("formats numeric hard-gate deficits with exact zero values", function()
		assert.are.equal("Spell suppression: 0% < 100%", OptimizerTab.FormatViolation({
			key = "SpellSuppressionChance",
			label = "Spell suppression",
			actual = 0,
			required = 100,
			reason = "Below strict minimum",
		}))
		assert.are.equal("Passive point cap: 121 > 120", OptimizerTab.FormatViolation({
			key = "passive_point_cap",
			label = "Passive point cap",
			actual = 121,
			required = 120,
			reason = "Above strict maximum",
		}))
	end)

	it("keeps all metric fields and both action rows inside narrow and wide PoB viewports", function()
		local tab = { fieldLabels = { }, textFieldLabels = { }, controls = { } }
		for _, definition in ipairs(Inputs.metricDefinitions) do
			tab.fieldLabels[#tab.fieldLabels + 1] = { }
			tab.controls["metric_" .. definition.key] = { }
		end
		for _, key in ipairs({
			"maxManualButtons", "conversionMin", "allowedRegions", "requiredRegions", "forbiddenRegions",
			"maxAddedPoints", "maxTotalPoints", "evaluationBudget", "objectiveMetric", "seed", "targetNodeIds",
			"addNodeIds", "removeNodeIds", "requiredNodeIds", "forbiddenNodeIds", "scenarioProfile",
		}) do
			tab.textFieldLabels[key] = { }
			tab.controls["text_" .. key] = { }
		end
		for _, key in ipairs({ "run", "cancel", "apply", "direction", "aiRequest", "mcpRequest", "compareRoots", "activitySchedule", "equipment", "classResults", "marketBudget", "studyRecords", "resultDetails", "pageMatrix", "pageNodePotential", "pageOverview",
			"overviewDetails", "overviewResult", "overviewReport", "overviewClassLabel", "overviewSkillLabel", "overviewGemLabel", "overviewSkill", "overviewGem",
			"overviewDamageLabel", "overviewDefenseLabel", "overviewPriorityLabel", "overviewUseImportedRoutes", "overviewAscendancy", "overviewImport",
			"overviewDirection", "overviewAI", "overviewRoutes", "overviewRun", "overviewAdvanced", "overviewRefresh", "overviewCancel" }) do
			tab.controls[key] = {
				width = key == "activitySchedule" and 112 or key == "equipment" and 150 or key == "classResults" and 142 or key == "marketBudget" and 122 or key == "studyRecords" and 90 or key == "resultDetails" and 92 or key == "overviewRoutes" and 132 or key == "overviewRun" and 86 or 118,
				SetAnchor = function(self, point, other, otherPoint, x, y)
					self.x, self.y = x, y
				end,
				CheckDroppedWidth = function() end,
			}
		end

		OptimizerTab.Layout(tab, { width = 556 })
		assert.is_true(tab.compactLayout)
		assert.are.equal(548, tab.statusY)
		assert.are.equal(tab.controls.overviewDirection.y, tab.controls.overviewRoutes.y,
			"build setup and route generation must share the primary action row")
		assert.is_true(tab.controls.overviewDirection.x + tab.controls.overviewDirection.width <= tab.controls.overviewRoutes.x,
			"the route action must not overlap build setup")
		assert.is_true(tab.controls.overviewRoutes.y > tab.controls.overviewUseImportedRoutes.y,
			"the combination action must sit below the route-evidence preference")
		assert.are.equal(290, tab.controls.text_maxManualButtons.y)
		for _, definition in ipairs(Inputs.metricDefinitions) do
			local control = tab.controls["metric_" .. definition.key]
			assert.is_true(control.x + control.width <= 544, definition.key .. " metric input extends past the viewport")
			assert.is_true(control.y < 290, definition.key .. " metric overlaps the advanced Matrix fields")
			assert.is_true(control.y + 14 <= tab.controls.text_maxManualButtons.y,
				definition.key .. " metric control overlaps the first advanced Matrix input")
		end
		for _, key in ipairs({
			"maxManualButtons", "conversionMin", "allowedRegions", "requiredRegions", "forbiddenRegions",
			"maxAddedPoints", "maxTotalPoints", "evaluationBudget", "objectiveMetric", "seed", "targetNodeIds",
			"addNodeIds", "removeNodeIds", "requiredNodeIds", "forbiddenNodeIds", "scenarioProfile",
		}) do
			local control = tab.controls["text_" .. key]
			assert.is_true(control.x + control.width <= 544, key .. " Matrix input extends past the viewport")
		end
		for _, key in ipairs({ "run", "cancel", "apply", "direction", "aiRequest", "mcpRequest", "compareRoots" }) do
			local control = tab.controls[key]
			assert.is_truthy(control.x and control.y, key .. " button was not positioned")
			assert.is_true(control.x < 556, key .. " button starts outside the viewport")
		end
		assert.is_true(tab.controls.activitySchedule.x + tab.controls.activitySchedule.width <= 556)
		assert.is_true(tab.controls.classResults.x + tab.controls.classResults.width <= 556)
		assert.are.equal(520, tab.controls.classResults.y)
		assert.are.equal(334, tab.controls.classResults.x)
		assert.are.equal(420, tab.controls.marketBudget.x)
		assert.are.equal(494, tab.controls.marketBudget.y)
		assert.is_true(tab.controls.marketBudget.x + tab.controls.marketBudget.width <= 556)
		assert.are.equal(480, tab.controls.studyRecords.x)
		assert.are.equal(520, tab.controls.studyRecords.y)
		assert.are.equal(72, tab.controls.studyRecords.width)
		assert.is_true(tab.controls.studyRecords.x + tab.controls.studyRecords.width <= 556)

		OptimizerTab.Layout(tab, { width = 800 })
		assert.is_false(tab.compactLayout)
		assert.are.equal(548, tab.statusY)
		assert.is_true(tab.controls.metric_SkillTriggerRate.y > tab.controls.metric_ChaosResistOverCap.y)
		assert.is_true(tab.controls.metric_SkillTriggerRate.x + tab.controls.metric_SkillTriggerRate.width <= 800)
		assert.are.equal(488, tab.controls.text_scenarioProfile.x)
		assert.are.equal(494, tab.controls.activitySchedule.y)
		assert.are.equal(132, tab.controls.activitySchedule.x)
		assert.are.equal(494, tab.controls.classResults.y)
		assert.are.equal(410, tab.controls.classResults.x)
		assert.are.equal(570, tab.controls.marketBudget.x)
		assert.are.equal(704, tab.controls.studyRecords.x)
		assert.are.equal(494, tab.controls.studyRecords.y)
		assert.are.equal(12, tab.controls.resultDetails.x)
		assert.are.equal(520, tab.controls.resultDetails.y)

		OptimizerTab.Layout(tab, { width = 1026 })
		for _, definition in ipairs(Inputs.metricDefinitions) do
			local control = tab.controls["metric_" .. definition.key]
			assert.is_true(control.x + control.width <= 1026, definition.key .. " metric input extends past a 1026px viewport")
			assert.is_true(control.y < 290, definition.key .. " metric overlaps the advanced Matrix fields at 1026px")
			assert.is_true(control.y + 14 <= tab.controls.text_maxManualButtons.y,
				definition.key .. " metric control overlaps an advanced Matrix input at 1026px")
		end
	end)

	it("opens a native activity-schedule editor and evaluates only PoB resource sustain", function()
		newBuild()
		local function resource(cost, regen)
			return { cost = cost, netRegen = regen, leech = 0, onHit = 0 }
		end
		local record = {
			identity = "Fireball\31Main\31",
			name = "Fireball",
			group = "Main",
			skillPart = "",
			count = 1,
			kind = "manual",
			hasDamage = true,
			exact = true,
			resources = {
				Life = resource(0, 0),
				Mana = resource(2, 1),
				ES = resource(0, 0),
			},
			otherResourceCosts = { },
			poBDamage = { player = { TotalDPS = 800, TotalDotDPS = 500 } },
		}
		local setupRecord = {
			identity = "Exposure\\31Utility\\31",
			name = "Exposure",
			group = "Utility",
			skillPart = "",
			count = 1,
			kind = "manual",
			hasDamage = true,
			exact = true,
			resources = {
				Life = resource(0, 0),
				Mana = resource(0, 1),
				ES = resource(0, 0),
			},
			otherResourceCosts = { },
			poBDamage = { player = { TotalDPS = 0 } },
		}
		build.calcsTab.mainOutput = {
			OptimizerMainSkillActivity = record,
			FullDPSActivity = { record, setupRecord },
			FullDPSActivityTruncated = false,
		}
		local tab = build.optimizerTab
		tab:OpenActivitySchedule()
		local popup = main.popups[1]
		assert.are.equal("AI Planner — Activity Schedule", popup.title)
		assert.is_truthy(popup.controls.actionCap)
		popup.controls.actionCap:SetText("2", true)
		assert.are.equal("2", tab.textValues.maxManualDamageButtons)
		assert.is_truthy(popup.controls.activity_row_mode_1)
		assert.is_truthy(popup.controls.activity_row_rate_1)
		assert.is_truthy(popup.controls.activity_row_requires_1)
		assert.are.equal(2, #popup.controls.activity_row_requires_1.list)
		local popupX = select(1, popup:GetPos())
		local requiresX = select(1, popup.controls.activity_row_requires_1:GetPos())
		local requiresWidth = select(1, popup.controls.activity_row_requires_1:GetSize())
		assert.is_true(requiresX >= popupX and requiresX + requiresWidth <= popupX + 720, "Requires selector must fit the native schedule popup")
		popup.controls.activity_row_requires_1:SetSel(2)
		assert.is_truthy(popup.controls.activity_row_label_1.tooltipText:find("Exact PoB activity outputs", 1, true))
		assert.is_truthy(popup.controls.activity_row_label_1.tooltipText:find("player.TotalDPS=800", 1, true))
		popup.controls.activity_row_mode_1:SetSel(2)
		popup.controls.activity_row_rate_1:SetText("25", true)
		assert.is_truthy(popup.controls.activity_row_label_1.tooltipText:find("Linear per%-activity projection at 25%%"))
		assert.is_truthy(popup.controls.activity_row_label_1.tooltipText:find("player.TotalDPS=200", 1, true))
		assert.is_truthy(popup.controls.activity_row_label_1.tooltipText:find("not summed across skills", 1, true))
		popup.controls.evaluate:Click()
		local status = popup.controls.scheduleStatus:GetProperty("label")
		local detail = popup.controls.scheduleDetails:GetProperty("label")
		assert.is_truthy(status:find("Sustain estimate: PASS", 1, true))
		assert.is_truthy(status:find("Scheduled DPS certification: NO", 1, true))
		assert.is_truthy(detail:find("0.5", 1, true))
		assert.is_truthy(tab.textValues.activityScheduleJson:find("Fireball", 1, true))
		local savedSchedule = require("dkjson").decode(tab.textValues.activityScheduleJson)
		assert.are.equal(setupRecord.identity, savedSchedule.scopes.full_dps[1].requires)
		main:ClosePopup(popup)
		tab:OpenActivitySchedule()
		popup = main.popups[1]
		assert.are.equal("2", popup.controls.actionCap.buf)
		assert.are.equal(2, popup.controls.activity_row_mode_1.selIndex)
		assert.are.equal("25", popup.controls.activity_row_rate_1.buf)
		assert.are.equal(2, popup.controls.activity_row_requires_1.selIndex)
		local utilityActivity = {
			identity = "MoltenShell\31group-2\31skill-1\31",
			name = "Molten Shell",
			group = "Utility",
			kind = "manual",
			count = 1,
			hasDamage = false,
			costScheduleEligible = true,
			exact = true,
			resources = {
				Life = resource(0, 0),
				Mana = resource(1, 1),
				ES = resource(0, 0),
			},
			otherResourceCosts = { },
			damageUnsupportedReason = "",
		}
		build.calcsTab.mainOutput.OptimizerSkillCostAudit = {
			scheduleActivities = { utilityActivity },
			scheduleTruncated = false,
		}
		popup.controls.scope:SetSel(3)
		assert.is_truthy(popup.controls.activity_row_label_1.tooltipText:find("Exact PoB recurring resource rates", 1, true))
		assert.is_truthy(popup.controls.activity_row_label_1.tooltipText:find("Mana cost 1/s", 1, true))
		popup.controls.evaluate:Click()
		assert.is_truthy(popup.controls.scheduleStatus:GetProperty("label"):find("Sustain estimate: PASS", 1, true))
		assert.is_truthy(popup.controls.scheduleDetails:GetProperty("label"):find("Resource-only estimate", 1, true))
		popup.controls.optimizerGate:Click()
		local gateState = require("dkjson").decode(tab.textValues.activityScheduleJson)
		assert.is_true(gateState.optimizerGateEnabled)
		assert.are.equal("all_enabled_skills", gateState.optimizerGateScope)
		local parsedGate = assert(Inputs.Parse({ activityScheduleJson = tab.textValues.activityScheduleJson }))
		assert.are.equal("all_enabled_skills", parsedGate.search.activitySchedule.scope)
		assert.are.equal(1, #parsedGate.search.activitySchedule.activities)
		popup.controls.scope:SetSel(2)
		assert.is_false(popup.controls.optimizerGate.enabled,
			"Main Skill remains diagnostic and cannot replace whole-build resource sustain in Run optimizer")
		main:ClosePopup(popup)
		newBuild()
	end)

	it("scrolls complete activity lists without exposing off-screen row controls", function()
		newBuild()
		local function resource()
			return { cost = 0, netRegen = 0, leech = 0, onHit = 0 }
		end
		local activities = { }
		for index = 1, 13 do
			activities[index] = {
				identity = "Skill" .. index .. "\31Group\31",
				name = "Skill " .. index,
				group = "Group",
				count = 1,
				kind = "manual",
				hasDamage = true,
				exact = true,
				resources = { Life = resource(), Mana = resource(), ES = resource() },
				otherResourceCosts = { },
			}
		end
		build.calcsTab.mainOutput = { FullDPSActivity = activities, FullDPSActivityTruncated = false }
		build.optimizerTab:OpenActivitySchedule()
		local popup = main.popups[1]
		assert.is_true(popup.controls.scrollBar.enabled)
		popup.controls.scrollBar:Scroll(1)
		popup.scrollBarFunc()
		assert.is_false(popup.controls.activity_row_label_1:IsShown())
		assert.is_true(popup.controls.activity_row_label_2:IsShown())
		main:ClosePopup(popup)
		newBuild()
	end)

	it("shows raw PoB damage and withholds the schedule projection for unsupported cadence", function()
		newBuild()
		local function resource()
			return { cost = 0, netRegen = 0, leech = 0, onHit = 0 }
		end
		local record = {
			identity = "Summon Example\31Main\31", name = "Summon Example", group = "Main", skillPart = "",
			kind = "minion", hasDamage = true, exact = true, count = 1,
			unsupportedReason = "PoB does not certify summon replacement cadence",
			poBDamage = { minion = { TotalDPS = 250 } },
			resources = { Life = resource(), Mana = resource(), ES = resource() },
			otherResourceCosts = { },
		}
		build.calcsTab.mainOutput = { FullDPSActivity = { record }, FullDPSActivityTruncated = false }
		build.optimizerTab:OpenActivitySchedule()
		local tooltip = main.popups[1].controls.activity_row_label_1.tooltipText
		assert.is_truthy(tooltip:find("minion.TotalDPS=250", 1, true))
		assert.is_truthy(tooltip:find("Schedule projection unsupported", 1, true))
		assert.is_nil(tooltip:find("Linear per%-activity projection"))
		main:ClosePopup(main.popups[1])
		newBuild()
	end)

	it("lists exact schedule identities once and rejects truncated FullDPS activity data", function()
		local record = {
			identity = "Arc\31Main\31", name = "Arc", group = "Main", skillPart = "",
			kind = "manual", hasDamage = true, exact = true, count = 1,
		}
		local listed = assert(Activity.ListScheduleActivities(record, { record }, false))
		assert.are.equal(1, #listed)
		assert.are.equal(record.identity, listed[1].identity)
		local truncated, err = Activity.ListScheduleActivities(record, { record }, true)
		assert.is_nil(truncated)
		assert.is_truthy(err:find("truncated", 1, true))
		local utility = {
			identity = "MoltenShell\31group-2\31skill-1\31",
			name = "Molten Shell",
			group = "Utility",
			kind = "manual",
			hasDamage = false,
			costScheduleEligible = true,
			exact = true,
			resources = { Mana = { cost = 0, netRegen = 2, leech = 0, onHit = 0 } },
		}
		local allEnabled = assert(Activity.ListScheduleActivities(nil, { utility }, false, true))
		assert.are.equal(1, #allEnabled)
		assert.is_true(allEnabled[1].resourceOnly)
		assert.is_false(allEnabled[1].hasDamage)
		assert.are.equal(2, allEnabled[1].resources.Mana.netRegen)
		local truncatedSkills, truncatedSkillsError = Activity.ListScheduleActivities(nil, { utility }, true, true)
		assert.is_nil(truncatedSkills)
		assert.is_truthy(truncatedSkillsError:find("enabled-skill schedule", 1, true))
	end)

	it("writes skill-colored leveling notes with act, item, warning, and budget guidance", function()
		newBuild()
		build.characterLevel = 12
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.calcsTab:BuildOutput()
		local tab = build.optimizerTab
		tab.textValues.baseClassId = tostring(build.spec.curClassId)
		tab.textValues.targetSkillGroupIndex = "1"
		tab.textValues.targetSkillIndex = "1"
		local added, message = tab:AppendBuildPlanToNotes()
		assert.is_true(added, message)
		local noteText = build.notesTab.controls.edit.buf
		assert.is_truthy(noteText:find("AI PLANNER", 1, true))
		assert.is_truthy(noteText:find("Blue / Intelligence", 1, true))
		local extraPoints = build.calcsTab.mainOutput.ExtraPoints or 0
		local actTwoStart = build:GetPassivePointLimitForLevel(12, extraPoints)
		local actTwoEnd = build:GetPassivePointLimitForLevel(21, extraPoints)
		local expectedActTwo = DisplayText.Native(string.format("Act 2 | levels 12–21 | PoB legal passive points %d–%d", actTwoStart, actTwoEnd))
		assert.is_truthy(noteText:find(expectedActTwo, 1, true), "Leveling notes must use PoB's exact act boundaries and point limits")
		assert.is_truthy(noteText:find("LEVELING ITEM TEMPLATES", 1, true))
		assert.is_truthy(noteText:find("Cast Speed (3rd priority)", 1, true))
		assert.is_truthy(noteText:find("CURRENT POB WARNINGS", 1, true))
		assert.is_truthy(noteText:find("Neither is a currency budget", 1, true))
		assert.is_true(build.notesTab.modFlag)
		newBuild()
	end)

	it("writes readable generated leveling notes when punctuation glyphs are escaped", function()
		local originalUnicode, originalWidth = main.unicode, DrawStringWidth
		local ok, failure = pcall(function()
			main.unicode = true
			DrawStringWidth = function(_, _, text)
				if text == "—" or text == "–" or text == "→" or text == "Δ" or text == "·" or text == "•" or text == "…" or text == "═" then return 80 end
				return 20
			end
			newBuild()
			build.characterLevel = 12
			build.characterLevelAutoMode = false
			build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
			build.mainSocketGroup = 1
			build.calcsTab:BuildOutput()
			local tab = build.optimizerTab
			tab.textValues.baseClassId = tostring(build.spec.curClassId)
			tab.textValues.targetSkillGroupIndex = "1"
			tab.textValues.targetSkillIndex = "1"
			local added, message = tab:AppendBuildPlanToNotes()
			assert.is_true(added, message)
			local noteText = build.notesTab.controls.edit.buf
			assert.is_nil(noteText:find("[\128-\255]"), "generated notes must not persist glyph escape markers")
			assert.is_truthy(noteText:find("AI PLANNER - BUILD PLAN", 1, true))
			assert.is_truthy(noteText:find("Acts 1-5 (levels 1-43)", 1, true))
			newBuild()
		end)
		main.unicode, DrawStringWidth = originalUnicode, originalWidth
		if not ok then error(failure) end
	end)

	it("does not invent progression point limits when PoB's native method is unavailable", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.calcsTab:BuildOutput()
		local tab = build.optimizerTab
		tab.textValues.baseClassId = tostring(build.spec.curClassId)
		tab.textValues.targetSkillGroupIndex = "1"
		tab.textValues.targetSkillIndex = "1"
		local nativeMethod = build.GetPassivePointLimitForLevel
		build.GetPassivePointLimitForLevel = false
		local callOk, added, message = pcall(tab.AppendBuildPlanToNotes, tab)
		build.GetPassivePointLimitForLevel = nativeMethod
		assert.is_true(callOk, tostring(added))
		assert.is_true(added, message)
		local noteText = build.notesTab.controls.edit.buf
		assert.is_truthy(noteText:find("Native progression point limits unavailable", 1, true))
		assert.is_truthy(noteText:find("PoB's native point limit is unavailable; point legality is not certified", 1, true))
		newBuild()
	end)
end)

describe("AI Planner native spatial zone editor", function()
	it("keeps edit instructions above the northwest and northeast zone labels", function()
		newBuild()
		local treeTab = build.treeTab
		assert.is_true(treeTab:StartOptimizerZoneEdit())
		local labels = { }
		local images = { }
		local layers = { }
		local originalDrawString = DrawString
		local originalDrawImage = DrawImage
		local originalSetDrawLayer = SetDrawLayer
		DrawString = function(x, y, align, size, font, text)
			labels[tostring(text)] = { x = x, y = y, align = align }
		end
		DrawImage = function(image, x, y, width, height)
			images[#images + 1] = { image = image, x = x, y = y, width = width, height = height }
		end
		SetDrawLayer = function(texture, layer)
			layers[#layers + 1] = layer
		end
		local ok, drawError = pcall(function()
			treeTab.viewer:DrawOptimizerZones(build, { x = 20, y = 30, width = 800, height = 600 }, function(x, y)
				return 420 + x, 330 + y
			end, 0.01)
		end)
		DrawString = originalDrawString
		DrawImage = originalDrawImage
		SetDrawLayer = originalSetDrawLayer
		assert.is_true(ok, tostring(drawError))
		local instructions = labels["^7AI Planner zones: click allow  |  Shift+click require  |  right-click forbid"]
		local northWest = labels["^xC1CAD6NW  OPEN"]
		local northEast = labels["^xC1CAD6NE  OPEN"]
		local southWest = labels["^xC1CAD6SW  OPEN"]
		local southEast = labels["^xC1CAD6SE  OPEN"]
		local hub = labels["^xC1CAD6HUB  OPEN"]
		local banner
		local badgeCount = 0
		local northEastBadge
		local southEastBadge
		for _, image in ipairs(images) do
			if image.image == nil and image.x == 20 and image.y == 30 and image.width == 800 and image.height == 24 then
				banner = image
			elseif image.image == nil and image.width == 180 and image.height == 20 then
				badgeCount = badgeCount + 1
				if northEast and image.y == northEast.y - 3 then northEastBadge = image end
				if southEast and image.y == southEast.y - 3 then southEastBadge = image end
			end
		end
		assert.is_truthy(instructions)
		assert.is_truthy(northWest)
		assert.is_truthy(northEast)
		assert.is_truthy(southWest)
		assert.is_truthy(southEast)
		assert.is_truthy(hub)
		assert.is_truthy(banner)
		assert.are.equal(20, banner.x)
		assert.are.equal(30, banner.y)
		assert.are.equal(800, banner.width)
		assert.are.equal(24, banner.height)
		assert.are.equal(4, badgeCount, "every quadrant label must have a readable background")
		assert.is_true(instructions.y < northWest.y)
		assert.is_true(instructions.y < northEast.y)
		assert.are.equal("RIGHT_X", northEast.align)
		assert.are.equal("RIGHT_X", southEast.align)
		assert.is_truthy(northEastBadge, "NE label must have a right-anchored background")
		assert.is_truthy(southEastBadge, "SE label must have a right-anchored background")
		assert.are.equal(northEast.x - 180 + 6, northEastBadge.x)
		assert.are.equal(southEast.x - 180 + 6, southEastBadge.x)
		assert.is_true(hub.y < southEast.y, "hub label must stay clear of the southeast quadrant label")
		assert.are.equal(30, layers[1], "zone labels must draw above passive nodes and below tooltips")
		treeTab:StopOptimizerZoneEdit()
		newBuild()
	end)

	it("keeps the Hub label inside a panned viewport when its ring is clipped", function()
		newBuild()
		local treeTab = build.treeTab
		assert.is_true(treeTab:StartOptimizerZoneEdit())
		local labels = { }
		local images = { }
		local originalDrawString = DrawString
		local originalDrawImage = DrawImage
		DrawString = function(x, y, align, size, font, text)
			labels[tostring(text)] = { x = x, y = y, align = align }
		end
		DrawImage = function(image, x, y, width, height)
			images[#images + 1] = { image = image, x = x, y = y, width = width, height = height }
		end
		local ok, drawError = pcall(function()
			treeTab.viewer:DrawOptimizerZones(build, { x = 20, y = 30, width = 800, height = 600 }, function(x, y)
				return 790 + x, 600 + y
			end, 0.01)
		end)
		DrawString = originalDrawString
		DrawImage = originalDrawImage
		assert.is_true(ok, tostring(drawError))
		local hub = labels["^xC1CAD6HUB  OPEN"]
		assert.is_truthy(hub)
		assert.are.equal("LEFT", hub.align)
		local badge
		for _, image in ipairs(images) do
			if image.image == nil and image.width == 130 and image.height == 20 then badge = image end
		end
		assert.is_truthy(badge, "Hub badge must remain visible when the ring is outside the viewport")
		assert.is_true(badge.x >= 20 and badge.x + badge.width <= 820)
		assert.is_true(badge.y >= 30 and badge.y + badge.height <= 630)
		treeTab:StopOptimizerZoneEdit()
		newBuild()
	end)

	it("edits the solver's spatial filters without allocating or removing passives", function()
		newBuild()
		local treeTab = build.treeTab
		local optimizerTab = build.optimizerTab
		local spec = build.spec
		local allocations = spec.allocNodes
		local allocatedCount = 0
		for _ in pairs(allocations) do allocatedCount = allocatedCount + 1 end

		local started, startError = treeTab:StartOptimizerZoneEdit()
		assert.is_true(started, startError)
		local metadata = treeTab.viewer.zoneMetadata
		local outsideHub = metadata.hubRadius + (metadata.medianEdgeLength or 50) * 4
		local consumed, region = treeTab.viewer:ApplyOptimizerZoneClick(build, "LEFT", metadata.centerX - outsideHub, metadata.centerY - outsideHub, true)
		assert.is_true(consumed, "zone edit clicks must be consumed before native passive allocation")
		assert.are.equal("NorthWest", region)
		assert.are.equal("NorthWest", optimizerTab.textValues.requiredRegions)
		assert.are.equal("", optimizerTab.textValues.allowedRegions, "a required waypoint must not silently restrict other zones")
		assert.are.equal("NorthWest", optimizerTab.controls.text_requiredRegions.buf)
		assert.are.equal("required", optimizerTab:GetSpatialRegionState("NW"))

		consumed = treeTab.viewer:ApplyOptimizerZoneClick(build, "RIGHT", metadata.centerX - outsideHub, metadata.centerY - outsideHub, false)
		assert.is_true(consumed)
		assert.are.equal("", optimizerTab.textValues.requiredRegions)
		assert.are.equal("NorthWest", optimizerTab.textValues.forbiddenRegions)
		assert.are.equal("forbidden", optimizerTab:GetSpatialRegionState("NorthWest"))
		assert.are.equal(spec, build.spec)
		assert.are.equal(allocations, spec.allocNodes)
		local afterCount = 0
		for _ in pairs(spec.allocNodes) do afterCount = afterCount + 1 end
		assert.are.equal(allocatedCount, afterCount)
		treeTab.viewer:DrawOptimizerZones(build, { x = 0, y = 0, width = 800, height = 600 }, function(x, y)
			return 400 + x, 300 + y
		end, 0.1)
		treeTab:StopOptimizerZoneEdit()
	end)

	it("shares the solver's canonical zone names and coordinate boundaries", function()
		local metadata = { centerX = 100, centerY = -50, hubRadius = 10 }
		assert.are.equal("Hub", SpatialZones.Classify(100, -50, metadata))
		assert.are.equal("NorthWest", SpatialZones.Classify(89, -61, metadata))
		assert.are.equal("NorthEast", SpatialZones.Classify(111, -61, metadata))
		assert.are.equal("SouthWest", SpatialZones.Classify(89, -39, metadata))
		assert.are.equal("SouthEast", SpatialZones.Classify(111, -39, metadata))
		assert.are.equal("NorthEast", SpatialZones.CanonicalRegionName("NE"))
	end)

	it("refuses class-start filters without clearing or rewriting them", function()
		newBuild()
		local treeTab = build.treeTab
		local optimizerTab = build.optimizerTab
		optimizerTab.textValues.allowedRegions = "Witch"
		local started = treeTab:StartOptimizerZoneEdit()
		assert.is_false(started)
		assert.are.equal("Witch", optimizerTab.textValues.allowedRegions)
		assert.is_false(optimizerTab:ToggleSpatialRegion("NorthEast", "allow"))
		assert.are.equal("Witch", optimizerTab.textValues.allowedRegions)
	end)

	it("refuses contradictory spatial filters until the Matrix is repaired", function()
		newBuild()
		local treeTab = build.treeTab
		local optimizerTab = build.optimizerTab
		optimizerTab.textValues.allowedRegions = "NorthWest"
		optimizerTab.textValues.forbiddenRegions = "NorthWest"
		local started = treeTab:StartOptimizerZoneEdit()
		assert.is_false(started)
		assert.are.equal("NorthWest", optimizerTab.textValues.allowedRegions)
		assert.are.equal("NorthWest", optimizerTab.textValues.forbiddenRegions)
	end)

	it("prevents changing a Matrix while an exact search is running", function()
		newBuild()
		local optimizerTab = build.optimizerTab
		optimizerTab.job = { status = "running" }
		local changed = optimizerTab:ToggleSpatialRegion("SouthEast", "forbid")
		assert.is_false(changed)
		assert.are.equal("", optimizerTab.textValues.forbiddenRegions)
		optimizerTab.job = nil
	end)
end)
