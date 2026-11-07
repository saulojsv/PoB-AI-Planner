local Readiness = require("Modules.Optimizer.BuildReadiness")
local Candidate = require("Modules.Optimizer.Candidate")
local MCP = require("Modules.Optimizer.MCPBridge")
local ImportLifecycle = require("Modules.Optimizer.ImportLifecycle")
local TestSupport = require("OptimizerTestSupport")

local function recalculate()
	build.calcsTab:BuildOutput()
	build.buildFlag = false
end

local function setup(linked, gemText)
	newBuild()
	-- Run the same verifier against repository bytes for ordinary fixtures;
	-- dedicated cases below override the status to test pending/unavailable.
	TestSupport.MarkCalculationContentVerified()
	build.spec:SelectClass(build.spec.curClassId)
	build.characterLevel, build.characterLevelAutoMode = 90, false
	if gemText then
		build.skillsTab:PasteSocketGroup(gemText)
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		if linked then
			local item = new("Item"):Item("Rarity: NORMAL\nSimple Robe\nSockets: B-B-B\nImplicits: 0\n")
			build.itemsTab:AddItem(item, true)
			build.itemsTab.slots["Body Armour"]:SetSelItemId(item.id)
			build.itemsTab:PopulateSlots()
			build.skillsTab.socketGroupList[1].slot = "Body Armour"
			build:SyncLoadouts()
		end
	end
	recalculate()
end

local function hasIssue(report, code)
	for _, row in ipairs(report.issues) do if row.code == code then return row end end
end

describe("AI Planner scoped build readiness", function()
	it("withholds verified study readiness while local calculation bytes are being checked", function()
		setup(true, "Fireball 1/0 1")
		local previousLaunch = launch
		launch = { versionNumber = "2.67.2", versionBranch = "dev",
			manifestInventoryFingerprint = string.rep("b", 64), manifestFingerprintStatus = "pending" }
		local report = Readiness.Evaluate(build)
		assert.are.equal("unverified", report.status)
		assert.is_truthy(hasIssue(report, "engine_content_identity_pending"))
		assert.is_nil(report.identity.engine.manifestFingerprint)
		assert.is_truthy(table.concat(Readiness.Describe(report), "\n"):find("priorização aprendida ficam indisponíveis", 1, true))
		launch = previousLaunch
	end)

	it("treats absent passive data as an unfinished plan rather than a corrupt allocated tree", function()
		setup(false)
		local proxy = setmetatable({ spec = setmetatable({ allocNodes = { } }, { __index = build.spec }) }, { __index = build })
		local report = Readiness.Evaluate(proxy)
		assert.are.equal("partial", report.status)
		assert.are.equal("missing", report.tree.status)
		assert.is_truthy(hasIssue(report, "tree_missing"))
		assert.is_false(report.capabilities.treeComparison)
	end)

	it("explains an import-error title without classifying an empty loaded build as corrupted", function()
		setup(false)
		build.buildName = "Download information not found"
		local signature = Candidate.BuildSignature(build)
		local report = Readiness.Evaluate(build)
		assert.are.equal("partial", report.status)
		assert.is_truthy(hasIssue(report, "import_error_title"))
		assert.is_truthy(hasIssue(report, "main_skill_missing"))
		assert.is_nil(report.skill.supportsConfigured)
		assert.is_false(report.importAttempt.affectsLoadedBuild)
		assert.are.equal("not_recorded", report.identity.leagueStatus)
		assert.is_true(#Readiness.Describe(report) > 5)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("surfaces the inherited import title and the actionable unlinked-skill warning in the compact summary", function()
		setup(false, "Fireball 1/0 1")
		build.buildName = "Download information not found"
		local summary = table.concat(Readiness.DescribeSummary(Readiness.Evaluate(build)), "\n")
		assert.is_truthy(summary:find("Build: Download information not found", 1, true))
		assert.is_truthy(summary:find("Nota sobre o título", 1, true))
		assert.is_truthy(summary:find("Como título, não comprova uma falha atual", 1, true))
		assert.is_truthy(summary:find("Diagnóstico principal (aviso): Grupo sem vínculo com equipamento", 1, true))
		assert.is_truthy(summary:find("O PoB pode calcular este grupo de planejamento", 1, true))
		assert.is_truthy(summary:find("Associe o grupo ao item", 1, true))
	end)

	it("shows import state, provider, and XML section presence without certifying imported content", function()
		setup(false)
		build.buildName = "QA Build"
		local before = Candidate.BuildSignature(build)
		ImportLifecycle.AdoptLoaded(build.importTab, { kind = "build_code" },
			{ Build = true, Tree = true, Skills = false, Items = true, Config = false }, legacyTargetVersion)
		local summary = table.concat(Readiness.DescribeSummary(Readiness.Evaluate(build)), "\n")
		assert.is_truthy(summary:find("Build: QA Build", 1, true))
		assert.is_truthy(summary:find("Importação: carregamento nativo concluído", 1, true))
		assert.is_truthy(summary:find("Origem declarada: código PoB", 1, true))
		assert.is_truthy(summary:find("Secções XML presentes: Build, árvore, itens", 1, true))
		assert.is_truthy(summary:find("ausentes: skills, configuração", 1, true))
		assert.is_truthy(summary:find("não valida conteúdo ou legalidade", 1, true))
		assert.is_nil(summary:find("account", 1, true))
		assert.is_nil(summary:find("http", 1, true))
		assert.are.equal(before, Candidate.BuildSignature(build))
	end)

	it("reports provider failure and unknown XML coverage as separate provenance facts", function()
		setup(false)
		local revision = ImportLifecycle.Begin(build.importTab, { kind = "provider_url", providerId = "POBBin" })
		ImportLifecycle.Update(build.importTab, revision, "download_failed", "download_failed")
		local summary = table.concat(Readiness.DescribeSummary(Readiness.Evaluate(build)), "\n")
		assert.is_truthy(summary:find("Importação: download não concluído", 1, true))
		assert.is_truthy(summary:find("Origem declarada: link de provedor / POBBin", 1, true))
		assert.is_truthy(summary:find("Secções XML: presença não registada", 1, true))
		assert.is_truthy(summary:find("Detalhe da tentativa: Falha ao obter o export", 1, true))
	end)

	it("reports observed league and realm as source metadata without inferring active identity", function()
		setup(false)
		ImportLifecycle.Observe(build.importTab, "build", { kind = "character_payload" }, "replace",
			{ league = "Example League" }, "pc")
		local before = Candidate.BuildSignature(build)
		local report = Readiness.Evaluate(build)
		assert.are.equal("Example League", report.identity.sourceMetadata.league.value)
		assert.are.equal("source_declared_unverified", report.identity.leagueStatus)
		assert.are.equal("pc", report.identity.sourceMetadata.sourceRealm.value)
		assert.are.equal("source_declared_unverified", report.identity.sourceRealmStatus)
		assert.are.equal("not_recorded", report.identity.platformStatus)
		assert.are.equal("not_recorded", report.identity.gameModeStatus)
		assert.is_false(report.identity.sourceMetadata.currentBuildIdentityCertified)
		local lines = table.concat(Readiness.Describe(report), "\n")
		assert.is_truthy(lines:find("declarada na origem importada", 1, true))
		assert.is_truthy(lines:find("realm de origem não a confirma", 1, true))
		assert.is_truthy(lines:find("não inferido do nome da liga", 1, true))
		assert.are.equal(before, Candidate.BuildSignature(build))
	end)

	it("marks conflicting import origins explicitly and keeps legacy metadata unverified", function()
		setup(false)
		ImportLifecycle.Observe(build.importTab, "tree", { kind = "character_payload" }, "replace", { league = "League A" }, "pc")
		ImportLifecycle.Observe(build.importTab, "items", { kind = "character_payload" }, "merge", { league = "League B" }, "xbox")
		local report = Readiness.Evaluate(build)
		assert.are.equal("conflicting_sources", report.identity.sourceMetadata.league.status)
		assert.is_nil(report.identity.sourceMetadata.league.value)
		assert.are.equal("conflicting_sources", report.identity.sourceRealmStatus)
		assert.is_false(report.identity.sourceMetadata.currentBuildIdentityCertified)
		local lines = table.concat(Readiness.Describe(report), "\n")
		assert.is_truthy(lines:find("fontes de importação divergem", 1, true))

		local restored = { }
		ImportLifecycle.Load(restored, { { elem = "PlannerOrigin", attrib = { schemaVersion = "1", component = "build",
			kind = "character_payload", operation = "replace", league = "Old League", realm = "pc" } } })
		local savedProxy = setmetatable({ importTab = restored }, { __index = build })
		local saved = Readiness.Evaluate(savedProxy)
		assert.are.equal("saved_metadata_unverified", saved.identity.leagueStatus)
		assert.are.equal("Old League", saved.identity.sourceMetadata.league.value)
		assert.is_false(saved.identity.sourceMetadata.currentBuildIdentityCertified)
	end)

	it("labels loaded PoB data version separately from the tree compatibility fallback", function()
		setup(false)
		local treeReport = Readiness.Evaluate(build)
		assert.are.equal("tree_compatibility_key", treeReport.identity.patchEvidence)
		local dataTableProxy = setmetatable({ data = { version = "pob-data-table-fixture" } }, { __index = build })
		local dataReport = Readiness.Evaluate(dataTableProxy)
		assert.are.equal("pob_loaded_data_table_version", dataReport.identity.patchEvidence)
		assert.are.equal("pob-data-table-fixture", dataReport.identity.engine.dataVersion)
		local lines = table.concat(Readiness.Describe(dataReport), "\n")
		assert.is_truthy(lines:find("versão da tabela de dados carregada pelo PoB", 1, true))
		assert.is_truthy(lines:find("não verifica separadamente todos os dados de gemas e itens", 1, true))
	end)

	it("keeps exact unlinked Fireball calculations separate from physical link readiness", function()
		setup(false, "Fireball 1/0 1")
		local report = Readiness.Evaluate(build)
		assert.are.equal("partial", report.status)
		assert.is_true(report.capabilities.selectedSkillMetrics)
		assert.is_false(report.capabilities.physicalSkillSetup)
		assert.are.equal("unlinked_planning_group", report.skill.sockets.status)
		assert.is_truthy(hasIssue(report, "unlinked_planning_group"))
		assert.are.equal("info", hasIssue(report, "no_support_gems").severity)
	end)

	it("validates a native linked standalone skill without requiring arbitrary supports", function()
		setup(true, "Fireball 1/0 1")
		build.buildName = "Download information not found"
		local report = Readiness.Evaluate(build)
		assert.are.equal("complete", report.status)
		assert.is_true(report.capabilities.physicalSkillSetup)
		assert.is_false(report.playabilityCertified)
		assert.are.equal("linked", report.skill.sockets.status)
		assert.are.equal(0, report.skill.supportsConfigured)
		assert.are.equal(build:GetPassivePointLimitForLevel(90, build.calcsTab.mainOutput.ExtraPoints), report.tree.pointLimit)
		local nativeSlotCount = 0
		for _ in pairs(build.itemsTab.slots) do nativeSlotCount = nativeSlotCount + 1 end
		assert.is_true(nativeSlotCount > 128, "the fixture must include the native jewel-slot range beyond the former cap")
		assert.is_false(report.componentCoverage.equipment.truncated == true)
		assert.are.equal("valid", report.componentCoverage.status)
		assert.is_true(report.capabilities.wholeBuildStructure)
	end)

	it("counts native item-granted skills as structurally valid without requiring sockets", function()
		setup(true, "Fireball 1/0 1")
		local itemId = tonumber(build.itemsTab.activeItemSet["Body Armour"].selItemId)
		local item = build.itemsTab.items[itemId]
		local originalGroup = build.skillsTab.socketGroupList[1]
		local originalGem = originalGroup.gemList[1]
		local source = item.modSource
		local grantedEffect = originalGem.grantedEffect or originalGem.gemData and originalGem.gemData.grantedEffect
			or originalGroup.displaySkillList[1].activeEffect.grantedEffect
		item.grantedSkills = { { source = source, skillId = originalGem.skillId } }
		build.skillsTab.socketGroupList[#build.skillsTab.socketGroupList + 1] = {
			enabled = true,
			slotEnabled = true,
			slot = "Body Armour",
			source = source,
			sourceItem = item,
			gemList = { { skillId = originalGem.skillId, fromItem = true, grantedEffect = grantedEffect } },
			displaySkillList = { { activeEffect = { grantedEffect = grantedEffect } } },
		}
		local report = Readiness.Evaluate(build)
		assert.are.equal("granted", report.componentCoverage.skillGroups.groups[2].status)
		assert.are.equal(1, report.componentCoverage.skillGroups.granted)
		assert.are.equal("valid", report.componentCoverage.skillGroups.status)
		assert.are.equal("valid", report.componentCoverage.status)
		assert.is_true(report.capabilities.wholeBuildStructure)
		for _, issue in ipairs(report.componentCoverage.issues) do
			assert.is_not.equal("skill_group_structure_invalid", issue.code)
		end
	end)

	it("reports an unlinked secondary group without erasing exact Main Skill readiness", function()
		setup(true, "Fireball 1/0 1")
		build.skillsTab:PasteSocketGroup("Arc 1/0 1")
		recalculate()
		local before = Candidate.BuildSignature(build)
		local report = Readiness.Evaluate(build)
		assert.is_true(report.capabilities.selectedSkillMetrics)
		assert.are.equal("unlinked_planning_group", report.componentCoverage.skillGroups.groups[2].status)
		assert.are.equal("partial", report.componentCoverage.status)
		assert.is_false(report.capabilities.wholeBuildStructure)
		local lines = table.concat(Readiness.Describe(report), "\n")
		assert.is_truthy(lines:find("Integridade estrutural ativa: partial", 1, true))
		assert.is_truthy(lines:find("grupo 2", 1, true))
		assert.are.equal(before, Candidate.BuildSignature(build))
	end)

	it("exposes an invalid enabled secondary link even when the Main Skill remains exact", function()
		setup(true, "Fireball 1/0 1")
		build.skillsTab:PasteSocketGroup("Arc 1/0 1")
		local secondary = build.skillsTab.socketGroupList[2]
		secondary.slot = "Ring 1"
		secondary.slotEnabled = true
		recalculate()
		local before = Candidate.BuildSignature(build)
		local report = Readiness.Evaluate(build)
		assert.is_true(report.capabilities.selectedSkillMetrics)
		assert.are.equal("invalid", report.status, "the active Arc's native attribute requirement must remain visible")
		local requirementIssue = hasIssue(report, "attribute_requirement_Int")
		assert.is_truthy(requirementIssue)
		assert.are.equal("PoB native aggregate requirements for the active item set and evaluated skill groups", report.requirements.scope)
		assert.are.equal("active_skill_group", requirementIssue.sourceLocationStatus)
		assert.are.equal(2, requirementIssue.sourceGroupIndex)
		assert.are.equal("Arc", requirementIssue.sourceName)
		assert.is_truthy(table.concat(Readiness.Describe(report), "\n"):find("Origem do requisito: Arc | grupo 2", 1, true))
		assert.are.equal("invalid", report.componentCoverage.skillGroups.status)
		assert.are.equal("invalid", report.componentCoverage.status)
		assert.are.equal("invalid", report.componentCoverage.skillGroups.groups[2].status)
		local groupIssue
		for _, issue in ipairs(report.componentCoverage.issues) do
			if issue.code == "skill_group_structure_invalid" then groupIssue = issue end
		end
		assert.is_truthy(groupIssue)
		assert.are.equal(2, groupIssue.groupIndex)
		assert.are.equal(before, Candidate.BuildSignature(build))
	end)

	it("checks selected active-item slots with PoB native item compatibility", function()
		setup(true, "Fireball 1/0 1")
		local bodyItemId = build.itemsTab.activeItemSet["Body Armour"].selItemId
		build.itemsTab.activeItemSet["Ring 1"].selItemId = bodyItemId
		recalculate()
		local before = Candidate.BuildSignature(build)
		local report = Readiness.Evaluate(build)
		assert.is_true(report.capabilities.selectedSkillMetrics)
		assert.are.equal("invalid", report.componentCoverage.equipment.status)
		assert.are.equal("invalid", report.componentCoverage.status)
		local invalidRing
		for _, slot in ipairs(report.componentCoverage.equipment.slots) do
			if slot.slot == "Ring 1" then invalidRing = slot end
		end
		assert.is_truthy(invalidRing)
		assert.are.equal("invalid", invalidRing.status)
		assert.are.equal(before, Candidate.BuildSignature(build))
	end)

	it("copies current defense metrics and configuration flags without certifying uptime", function()
		setup(true, "Fireball 1/0 1")
		build.configTab.input.usePowerCharges = true
		build.configTab:BuildModList()
		recalculate()
		local before = Candidate.BuildSignature(build)
		local report = Readiness.Evaluate(build)
		for _, key in ipairs({ "Life", "EnergyShield", "TotalEHP", "PhysicalMaximumHitTaken", "CombinedDPS" }) do
			assert.are.equal(build.calcsTab.mainOutput[key], report.metrics[key])
		end
		local found
		for _, key in ipairs(report.scenario.activeBooleanFields) do if key == "usePowerCharges" then found = true end end
		assert.is_true(found)
		assert.is_false(report.scenario.uptimeCertified)
		assert.are.equal(before, Candidate.BuildSignature(build))
	end)

	it("renders native configuration labels and preserves raw keys in the detailed report", function()
		setup(true, "Fireball 1/0 1")
		local report = Readiness.Evaluate(build)
		report.scenario.activeBooleanFields = { "conditionAlwaysIgnited", "usePowerCharges", "useFrenzyCharges", "conditionKilledRecently" }
		local lines = Readiness.Describe(report)
		local rendered = table.concat(lines, "\n")
		assert.is_truthy(rendered:find("  - Do you use Power Charges? [usePowerCharges]", 1, true))
		assert.is_truthy(rendered:find("  - Do you use Frenzy Charges? [useFrenzyCharges]", 1, true))
		assert.is_truthy(rendered:find("  - Have you Killed Recently? [conditionKilledRecently]", 1, true))
		assert.is_truthy(rendered:find("  - conditionAlwaysIgnited", 1, true), "Unknown native options retain their raw key")
		assert.is_false(report.scenario.uptimeCertified, "Displaying configuration flags cannot certify uptime")
	end)

	it("uses native applied effects for support compatibility and rejects crossed item links", function()
		setup(true, "Fireball 1/0 1\nAdded Lightning Damage 1/0 1")
		local report = Readiness.Evaluate(build)
		assert.are.equal("complete", report.status)
		assert.are.equal(1, report.skill.supportsConfigured)
		assert.is_true(report.skill.supportsApplied >= 1)
		assert.is_nil(hasIssue(report, "support_not_applied"))
		local itemId = build.itemsTab.activeItemSet["Body Armour"].selItemId
		local item = build.itemsTab.items[itemId]
		item.sockets[2].group = item.sockets[1].group + 1
		recalculate()
		local invalid = Readiness.Evaluate(build)
		assert.are.equal("invalid", invalid.status)
		assert.is_truthy(hasIssue(invalid, "socket_mismatch"))
		assert.is_false(invalid.capabilities.physicalSkillSetup)
	end)

	it("does not certify stale or mismatched selected-effect output", function()
		setup(true, "Fireball 1/0 1")
		build.buildFlag = true
		local pending = Readiness.Evaluate(build)
		assert.are.equal("pending", pending.calculation.status)
		assert.is_false(pending.capabilities.selectedSkillMetrics)
		assert.is_nil(pending.skill.supportsApplied)
		assert.is_nil(next(pending.metrics))
		build.buildFlag = false
		local proxy = setmetatable({ calcsTab = { mainOutput = build.calcsTab.mainOutput,
			mainEnv = { player = { output = build.calcsTab.mainOutput, mainSkill = { socketGroup = build.skillsTab.socketGroupList[1],
				activeEffect = { grantedEffect = { id = "different-effect" } } } } } } }, { __index = build })
		local mismatched = Readiness.Evaluate(proxy)
		assert.are.equal("unverified", mismatched.status)
		assert.is_truthy(hasIssue(mismatched, "selected_effect_unverified"))
	end)

	it("separates disabled skills and exact unmet gem requirements from planning gaps", function()
		setup(true, "Fireball 20/0 1")
		local report = Readiness.Evaluate(build)
		assert.are.equal("invalid", report.status)
		assert.is_truthy(hasIssue(report, "attribute_requirement_Int"))
		build.skillsTab.socketGroupList[1].enabled = false
		recalculate()
		local disabled = Readiness.Evaluate(build)
		assert.are.equal("invalid", disabled.status)
		assert.is_truthy(hasIssue(disabled, "main_skill_disabled"))
	end)

	it("labels historical tree selectors as outdated without claiming current gem-data provenance", function()
		setup(true, "Fireball 1/0 1")
		local oldVersion
		for version in pairs(treeVersions) do if version ~= latestTreeVersion then oldVersion = version break end end
		assert.is_truthy(oldVersion)
		local proxy = setmetatable({ spec = setmetatable({ treeVersion = oldVersion }, { __index = build.spec }) }, { __index = build })
		local report = Readiness.Evaluate(proxy)
		assert.are.equal("outdated", report.status)
		assert.are.equal("tree_compatibility_key", report.identity.patchEvidence)
		assert.is_truthy(hasIssue(report, "older_tree"))
	end)

	it("keeps Vaal damage exact while exposing uncertified cadence in JSON-safe diagnostics", function()
		setup(false, "Vaal Cold Snap 1/0 1")
		local group = build.skillsTab.socketGroupList[1]
		local vaalIndex
		for index, skill in ipairs(group.displaySkillList) do
			if skill.activeEffect.grantedEffect.skillTypes[SkillType.Vaal] then vaalIndex = index break end
		end
		assert.is_truthy(vaalIndex)
		group.mainActiveSkill = vaalIndex
		recalculate()
		local report = Readiness.Evaluate(build)
		assert.is_true(report.capabilities.selectedSkillMetrics)
		assert.are.equal("unsupported", report.availability.status)
		assert.is_truthy(hasIssue(report, "selected_skill_availability"))
		local json = require("dkjson")
		local encoded, err = json.encode(report)
		assert.is_truthy(encoded, err)
		assert.is_true(#encoded < 32768)
	end)

	it("exposes the same read-only integrity report through the native MCP snapshot", function()
		setup(false, "Fireball 1/0 1")
		build.skillsTab:PasteSocketGroup("Arc 1/0 1")
		recalculate()
		local before = Candidate.BuildSignature(build)
		local snapshot = assert(MCP:CallLocal("get_build_snapshot", { }))
		local readiness = Readiness.Evaluate(build)
		assert.are.equal(readiness.status, snapshot.buildReadiness.status)
		assert.are.equal(readiness.componentCoverage.status, snapshot.buildReadiness.componentCoverage.status)
		assert.are.equal("Path of Exile 1", snapshot.buildReadiness.identity.game)
		assert.is_false(snapshot.buildReadiness.identity.sourceMetadata.currentBuildIdentityCertified)
		local requirementIssue = hasIssue(snapshot.buildReadiness, "attribute_requirement_Int")
		assert.is_truthy(requirementIssue)
		assert.are.equal(2, requirementIssue.sourceGroupIndex)
		assert.are.equal("Arc", requirementIssue.sourceName)
		assert.are.equal(before, Candidate.BuildSignature(build))
	end)

	it("starts with a compact diagnosis, exposes full details on demand, and keeps Matrix accessible", function()
		setup(false, "Fireball 1/0 1")
		local tab = build.optimizerTab
		assert.are.equal("overview", tab.innerView)
		for _, width in ipairs({ 500, 556, 800, 1200 }) do
			tab.width, tab.height = width, 520
			tab:Layout({ width = width, height = 520 })
			tab:RefreshReadiness(true)
			local listWidth, listHeight = tab.controls.overviewReport:GetSize()
			local detailsX = tab.controls.overviewDetails:GetPos()
			local detailsWidth = tab.controls.overviewDetails:GetSize()
			assert.is_true(listWidth <= width - 24)
			assert.is_true(listHeight <= 520 - 140)
			assert.is_true(detailsX + detailsWidth <= width - 12, "the detail toggle must remain inside compact viewports")
			assert.is_true(#tab.controls.overviewReport.list > 5)
			assert.is_true(tab.controls.overviewReport:IsShown())
			assert.is_true(tab.controls.overviewDetails:IsShown())
			local x = tab.controls.pageOverview:GetPos()
			assert.is_true(x >= 140)
		end
		local function overview()
			local rows = { }
			for _, row in ipairs(tab.controls.overviewReport.list or { }) do rows[#rows + 1] = row[1] end
			return table.concat(rows, "\n")
		end
		assert.is_false(tab.readinessDetailsExpanded)
		assert.is_truthy(overview():find("grupo de planeamento, não jogável", 1, true))
		assert.is_nil(overview():find("Flags configuradas", 1, true), "the compact summary must not dump every technical setting")
		tab.controls.overviewDetails:Click()
		tab:RefreshReadiness()
		assert.is_true(tab.readinessDetailsExpanded)
		assert.is_truthy(overview():find("Flags configuradas", 1, true))
		tab.controls.overviewDetails:Click()
		tab:RefreshReadiness()
		assert.is_false(tab.readinessDetailsExpanded)
		tab.controls.pageMatrix:Click()
		assert.are.equal("matrix", tab.innerView)
		assert.is_false(tab.controls.overviewReport:IsShown())
		assert.is_true(tab.controls.run:IsShown())
		tab.controls.pageOverview:Click()
		assert.are.equal("overview", tab.innerView)
	end)
end)
