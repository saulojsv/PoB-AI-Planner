-- Read-only readiness of the selected native PoB skill setup. Completeness is
-- scoped: this never certifies encounter uptime, acquisition, or a whole build.
local Version = require("Modules.Optimizer.Version")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local TreeSearch = require("Modules.Optimizer.TreeSearch")
local Validator = require("Modules.Optimizer.Validator")
local Activity = require("Modules.Optimizer.Activity")
local SkillAvailability = require("Modules.Optimizer.SkillAvailability")
local ImportLifecycle = require("Modules.Optimizer.ImportLifecycle")
local DisplayText = require("Modules.Optimizer.DisplayText")
local ConfigOptions = require("Modules.ConfigOptions")

local readiness = { }
local labels = { complete = "Completa neste escopo", partial = "Parcial", invalid = "Inválida neste escopo",
	outdated = "Desatualizada", unverified = "Não verificada" }
local MAX_COMPONENT_EQUIPMENT_SLOTS = 512
local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function text(value, limit)
	if type(value) ~= "string" then return nil end
	value = value:gsub("%c", " "):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""):gsub("%^", ""):sub(1, limit or 200)
	return value ~= "" and value or nil
end

-- Reuse the labels rendered by PoB's Configuration tab. The raw variable name
-- is retained in parentheses so advanced users can reproduce the exact setup.
local configOptionLabels = { }
for _, option in ipairs(ConfigOptions) do
	if type(option.var) == "string" and type(option.label) == "string" and not configOptionLabels[option.var] then
		configOptionLabels[option.var] = text(option.label, 180)
	end
end

local function effect(skill)
	return skill and skill.activeEffect and skill.activeEffect.grantedEffect
end

-- CalcPerform exposes the winning native requirement source for each
-- aggregate Req* value. Map that object identity back to its active socket
-- group/item slot so the report can identify the blocker without deriving
-- gem or item requirement formulae itself.
local function requirementSourceLocation(build, key, output)
	local source
	if key == "level_requirement" then
		source = output and output.ReqLevelSource
	else
		local attribute = type(key) == "string" and key:match("^attribute_requirement_(%w+)$")
		if attribute then source = output and output["Req" .. attribute .. "Item"] end
	end
	if type(source) ~= "table" then return nil end
	local location = { sourceKind = text(source.source, 20), sourceLocationStatus = "unlocated" }
	if source.sourceGem then
		local gem = source.sourceGem
		location.sourceName = text(gem.nameSpec or gem.name, 100)
		location.sourceGemLevel = finite(gem.level) and gem.level or nil
		location.sourceGemQuality = finite(gem.quality) and gem.quality or nil
		for groupIndex, group in ipairs(build and build.skillsTab and build.skillsTab.socketGroupList or { }) do
			for _, currentGem in ipairs(group.gemList or { }) do
				if currentGem == gem then
					location.sourceLocationStatus = "active_skill_group"
					location.sourceGroupIndex = groupIndex
					location.sourceGroupLabel = text(group.label, 80)
					location.sourceSlot = text(group.slot, 80)
					location.sourceGroupEnabled = group.enabled ~= false and group.slotEnabled ~= false
					return location
				end
			end
		end
	elseif source.sourceItem then
		location.sourceName = text(source.sourceItem.name, 100)
		location.sourceSlot = text(source.sourceSlot, 80)
		if location.sourceSlot then location.sourceLocationStatus = "active_item_slot" end
	end
	return location
end

-- Structural coverage is deliberately independent from exact Main Skill
-- metrics and gameplay uptime. It inspects the active PoB skill/item sets and
-- delegates socket/slot legality to PoB's native validators.
local function evaluateComponentCoverage(build)
	local coverage = {
		schemaVersion = 1,
		scope = "active_skill_set_and_active_item_set_structure",
		status = "unverified",
		issues = { },
		skillGroups = { status = "unverified", total = 0, enabled = 0, linked = 0,
			granted = 0, unlinked = 0, invalid = 0, unresolved = 0, disabled = 0, inactiveWeaponSet = 0, groups = { } },
		equipment = { status = "unverified", selected = 0, valid = 0, invalid = 0,
			inactive = 0, unverified = 0, slots = { } },
	}
	local function addIssue(code, severity, component, detail, action, location)
		if #coverage.issues >= 32 then coverage.issuesTruncated = true; return end
		local row = { code = code, severity = severity, component = component,
			detail = text(detail, 320), action = text(action, 220) }
		if type(location) == "table" then
			for key, value in pairs(location) do row[key] = value end
		end
		coverage.issues[#coverage.issues + 1] = row
	end
	local skillsTab = build and build.skillsTab
	local groups = skillsTab and skillsTab.socketGroupList
	if type(groups) ~= "table" then
		coverage.skillGroups.status = "unverified"
		addIssue("skill_groups_unavailable", "unknown", "skills", "A lista de grupos de skills ativos do PoB não está disponível.",
			"Abra Skills e aguarde o PoB carregar os grupos.")
	else
		local groupCount = #groups
		coverage.skillGroups.total = groupCount
		local skillInvalid, skillPartial, activeGroups = false, false, 0
		for index, group in ipairs(groups) do
			if index > 64 then coverage.skillGroups.truncated = true; skillPartial = true; break end
			local row = { groupIndex = index, label = text(group.label, 80), status = "unverified",
				gemCount = #(group.gemList or { }), enabledGems = 0, activeSkills = #(group.displaySkillList or { }) }
			coverage.skillGroups.groups[#coverage.skillGroups.groups + 1] = row
			if group.enabled == false then
				row.status = "disabled"
				coverage.skillGroups.disabled = coverage.skillGroups.disabled + 1
			elseif group.slotEnabled == false then
				row.status = "inactive_weapon_set"
				coverage.skillGroups.inactiveWeaponSet = coverage.skillGroups.inactiveWeaponSet + 1
			else
				activeGroups = activeGroups + 1
				coverage.skillGroups.enabled = coverage.skillGroups.enabled + 1
				local unresolved, unsupported = 0, 0
				for _, gem in ipairs(group.gemList or { }) do
					if gem.enabled ~= false then
						row.enabledGems = row.enabledGems + 1
						local gemEffect = effect(gem) or gem.grantedEffect or (gem.gemData and gem.gemData.grantedEffect)
						if not gemEffect then
							unresolved = unresolved + 1
						elseif gemEffect and gemEffect.unsupported then
							unsupported = unsupported + 1
						end
					end
				end
				row.unresolvedGems = unresolved
				row.unsupportedGems = unsupported
				coverage.skillGroups.unresolved = coverage.skillGroups.unresolved + unresolved
				local callOk, valid, socketData = pcall(SkillCatalog.ValidateSocketGroup, build, index)
				if callOk and valid and type(socketData) == "table" and socketData.status == "granted_skill" then
					row.status = "granted"
					coverage.skillGroups.granted = coverage.skillGroups.granted + 1
				elseif callOk and valid and type(socketData) == "table" then
					row.status = "linked"
					row.slot = text(socketData.slot, 80)
					row.socketCount = socketData.socketCount
					coverage.skillGroups.linked = coverage.skillGroups.linked + 1
				elseif callOk and valid then
					-- Defensive compatibility for older helper contracts returning a boolean.
					row.status = "granted"
					coverage.skillGroups.granted = coverage.skillGroups.granted + 1
				else
					local unlinked = (type(group.slot) ~= "string" or group.slot == "") and not group.source
					if row.enabledGems == 0 then
						row.status = "empty"
						skillPartial = true
					elseif unlinked then
						row.status = "unlinked_planning_group"
						coverage.skillGroups.unlinked = coverage.skillGroups.unlinked + 1
						skillPartial = true
					else
						row.status = "invalid"
						row.detail = text(callOk and socketData or valid, 240)
						coverage.skillGroups.invalid = coverage.skillGroups.invalid + 1
						skillInvalid = true
					end
				end
				if unresolved > 0 or unsupported > 0 then
					skillPartial = true
					if row.status ~= "invalid" and row.status ~= "unlinked_planning_group" then row.status = "unverified" end
				end
				if row.status == "unlinked_planning_group" and index ~= build.mainSocketGroup then
					addIssue("secondary_skill_group_unlinked", "warning", "skills",
						"O grupo " .. tostring(index) .. " pode ser calculado em planejamento, mas não está ligado a sockets de um item.",
						"Associe o grupo ao item, às cores e aos links corretos na aba Skills/Items.", { groupIndex = index })
				elseif row.status == "invalid" then
					addIssue("skill_group_structure_invalid", "error", "skills",
						"O grupo habilitado " .. tostring(index) .. " não passa pela validação nativa de sockets/links: " .. tostring(row.detail or "estrutura incompatível"),
						"Corrija o item, socket, link ou efeito deste grupo na aba Skills/Items.", { groupIndex = index })
				elseif unresolved > 0 or unsupported > 0 then
					addIssue("skill_group_effect_unverified", "warning", "skills",
						"O grupo " .. tostring(index) .. " contém " .. tostring(unresolved + unsupported) .. " gema(s) ativa(s) sem efeito suportado e resolvido.",
						"Confira nomes, versão e suporte nativo das gemas na aba Skills.", { groupIndex = index })
				end
			end
		end
		if groupCount > 64 then coverage.skillGroups.truncated = true end
		if activeGroups == 0 then
			coverage.skillGroups.status = "unverified"
			skillPartial = true
		elseif skillInvalid then
			coverage.skillGroups.status = "invalid"
		elseif skillPartial then
			coverage.skillGroups.status = "partial"
		else
			coverage.skillGroups.status = "valid"
		end
	end

	local itemsTab = build and build.itemsTab
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId])
	local slots = itemsTab and itemsTab.slots
	if type(itemSet) ~= "table" or type(slots) ~= "table" then
		coverage.equipment.status = "unverified"
		addIssue("active_equipment_unavailable", "unknown", "equipment", "O item set ativo ou os slots nativos do PoB não estão disponíveis.",
			"Abra Items e aguarde o PoB carregar o item set ativo.")
	else
		local names = { }
		for slotName in pairs(slots) do names[#names + 1] = slotName end
		table.sort(names)
		local equipmentInvalid, equipmentUnknown = false, false
		for index, slotName in ipairs(names) do
			if index > MAX_COMPONENT_EQUIPMENT_SLOTS then coverage.equipment.truncated = true; equipmentUnknown = true; break end
			local slot = slots[slotName]
			local rawItemId
			if slot and slot.nodeId then
				if build.spec and build.spec.allocNodes and build.spec.allocNodes[slot.nodeId] then
					rawItemId = build.spec.jewels and build.spec.jewels[slot.nodeId]
				end
			else
				local entry = itemSet[slotName]
				rawItemId = type(entry) == "table" and entry.selItemId or nil
			end
			local itemId = tonumber(rawItemId)
			if itemId and itemId > 0 then
				coverage.equipment.selected = coverage.equipment.selected + 1
				local row = { slot = text(slotName, 80), itemId = itemId, status = "unverified" }
				coverage.equipment.slots[#coverage.equipment.slots + 1] = row
				local shown = true
				if type(slot.shown) == "function" then
					local shownOk, shownValue = pcall(slot.shown)
					if not shownOk then
						shown = nil
						row.detail = "PoB não confirmou se o slot está ativo neste estado."
					elseif shownValue == false then
						shown = false
					end
				end
				if shown == false then
					row.status = "inactive"
					coverage.equipment.inactive = coverage.equipment.inactive + 1
				elseif shown == nil then
					coverage.equipment.unverified = coverage.equipment.unverified + 1
					equipmentUnknown = true
				else
					local item = itemsTab.items and itemsTab.items[itemId]
					if not item then
						row.status = "missing_item"
						row.detail = "O slot seleciona um item ID que não existe na lista carregada do PoB."
						coverage.equipment.invalid = coverage.equipment.invalid + 1
						equipmentInvalid = true
					elseif type(itemsTab.IsItemValidForSlot) ~= "function" then
						row.status = "unverified"
						coverage.equipment.unverified = coverage.equipment.unverified + 1
						equipmentUnknown = true
					else
						local callOk, valid = pcall(itemsTab.IsItemValidForSlot, itemsTab, item, slotName, itemSet)
						if callOk and valid == true then
							row.status = "valid"
							coverage.equipment.valid = coverage.equipment.valid + 1
						elseif callOk then
							row.status = "invalid"
							row.detail = "O item selecionado não é compatível com este slot segundo ItemsTab:IsItemValidForSlot do PoB."
							coverage.equipment.invalid = coverage.equipment.invalid + 1
							equipmentInvalid = true
						else
							row.status = "unverified"
							row.detail = "O validador nativo de compatibilidade do PoB não concluiu a verificação."
							coverage.equipment.unverified = coverage.equipment.unverified + 1
							equipmentUnknown = true
						end
					end
				end
				if row.status == "invalid" or row.status == "missing_item" then
					addIssue("active_equipment_slot_invalid", "error", "equipment",
						"Slot " .. tostring(slotName) .. ": " .. tostring(row.detail),
						"Corrija ou remova a referência do item neste slot na aba Items.", { slot = text(slotName, 80), itemId = itemId })
				elseif row.status == "unverified" then
					addIssue("active_equipment_slot_unverified", "warning", "equipment",
						"Slot " .. tostring(slotName) .. " não pôde ser confirmado pelo validador nativo.",
						"Revise o item set ativo e o slot na aba Items.", { slot = text(slotName, 80), itemId = itemId })
				end
			end
		end
		if equipmentInvalid then
			coverage.equipment.status = "invalid"
		elseif equipmentUnknown then
			coverage.equipment.status = "partial"
		else
			coverage.equipment.status = "valid"
		end
	end
	if coverage.skillGroups.status == "invalid" or coverage.equipment.status == "invalid" then
		coverage.status = "invalid"
	elseif coverage.skillGroups.status == "valid" and coverage.equipment.status == "valid" then
		coverage.status = "valid"
	elseif coverage.skillGroups.status == "unverified" and coverage.equipment.status == "unverified" then
		coverage.status = "unverified"
	else
		coverage.status = "partial"
	end
	return coverage
end

local function importIdentityMetadata(importAttempt)
	local metadata = {
		league = { value = nil, status = "not_recorded" },
		sourceRealm = { value = nil, status = "not_recorded" },
		gameMode = { value = nil, status = "not_recorded", inferred = false },
		currentBuildIdentityCertified = false,
		origins = { },
	}
	local function summarize(field)
		local values = { }
		local origins = type(importAttempt) == "table" and type(importAttempt.origins) == "table" and importAttempt.origins or { }
		for index, origin in ipairs(origins) do
			if index > 4 then break end
			if type(origin) == "table" then
				local value = text(origin[field], 120)
				if value then
					local evidence = values[value] or { observed = false, saved = false }
					if origin.evidence == "saved_metadata_unverified" then evidence.saved = true
					elseif origin.evidence == "observed_import_event" then evidence.observed = true end
					values[value] = evidence
				end
			end
		end
		local unique, count
		count = 0
		for value, evidence in pairs(values) do unique = { value = value, evidence = evidence }; count = count + 1 end
		if count == 0 then return { value = nil, status = "not_recorded" } end
		if count > 1 then return { value = nil, status = "conflicting_sources" } end
		return { value = unique.value, status = unique.evidence.observed and "source_declared_unverified" or "saved_metadata_unverified" }
	end
	metadata.league = summarize("league")
	metadata.sourceRealm = summarize("realm")
	local origins = type(importAttempt) == "table" and type(importAttempt.origins) == "table" and importAttempt.origins or { }
	for index, origin in ipairs(origins) do
		if index > 4 then break end
		if type(origin) == "table" then
			metadata.origins[#metadata.origins + 1] = {
				component = text(origin.component, 20), kind = text(origin.kind, 32),
				providerId = text(origin.providerId, 64), league = text(origin.league, 120),
				realm = text(origin.realm, 20), evidence = text(origin.evidence, 40),
				currentStateCertified = false,
			}
		end
	end
	return metadata
end

function readiness.Evaluate(build)
	local report = {
		presentation = DisplayText.Evidence(),
		schemaVersion = 1, scope = "selected_main_skill_setup", status = "unverified", issues = { },
		identity = { game = "Path of Exile 1", engine = Version.Snapshot(build),
			patchEvidence = Version.DataSource(build), leagueStatus = "not_recorded",
			platformStatus = "not_recorded", gameModeStatus = "not_recorded" },
		capabilities = { exactMetrics = false, selectedSkillMetrics = false, treeComparison = false, physicalSkillSetup = false,
			activeSkillGroups = false, activeEquipmentSlots = false, wholeBuildStructure = false },
		playabilityCertified = false, planOnly = true,
		limitations = {
			"A versão de dados exibida vem da tabela carregada do PoB ou da chave da árvore; não verifica separadamente todos os dados de gemas e itens.",
			"Liga e realm podem aparecer como metadados da origem importada; não comprovam a liga, plataforma ou modo da build ativa.",
			"A cobertura estrutural verifica grupos ativos e compatibilidade dos slots equipados pelo PoB; isso não calcula dano por grupo nem certifica uptime, aquisição ou sobrevivência em combate.",
		},
	}
	local invalid, outdated, partial, unknown = false, false, false, false
	local function issue(code, severity, title, detail, action)
		local row = {
			code = code, severity = severity, title = title, detail = text(detail, 400), action = text(action, 240),
		}
		if #report.issues < 48 then report.issues[#report.issues + 1] = row else report.issuesTruncated = true end
		if severity == "error" then invalid = true elseif severity == "warning" then partial = true elseif severity == "unknown" then unknown = true end
		return row
	end
	local function finish()
		report.status = invalid and "invalid" or outdated and "outdated" or partial and "partial" or unknown and "unverified" or "complete"
		report.label = labels[report.status]
		report.nextAction = "Escolha o objetivo e compare mudanças antes de aplicar."
		-- Informational messages must not hide the first actionable problem.
		for _, row in ipairs(report.issues) do if (row.severity ~= "info" or row.code == "older_tree") and row.action then report.nextAction = row.action break end end
		if report.nextAction == "Escolha o objetivo e compare mudanças antes de aplicar."
			and report.componentCoverage and report.componentCoverage.issues[1] then
			report.nextAction = report.componentCoverage.issues[1].action or report.nextAction
		end
		return report
	end
	if type(build) ~= "table" or not build.spec then
		issue("build_missing", "error", "Build indisponível", "O PoB não disponibilizou uma árvore ativa.", "Abra ou importe uma build no PoB.")
		return finish()
	end
	local spec = build.spec
	local contentIdentityStatus = report.identity.engine.manifestFingerprintStatus
	if report.identity.engine.manifestInventoryFingerprint and contentIdentityStatus == "pending" then
		issue("engine_content_identity_pending", "unknown", "Identidade dos dados de cálculo em verificação",
			"O PoB está a conferir em segundo plano os ficheiros de cálculo com o manifest. Métricas exatas continuam a vir do PoB; estudos versionados e priorização aprendida ficam indisponíveis até a conferência terminar.",
			"Aguarde a verificação do motor antes de guardar estudos ou usar ranking aprendido.")
	elseif report.identity.engine.manifestInventoryFingerprint and contentIdentityStatus == "mismatch" then
		issue("engine_content_identity_mismatch", "unknown", "Ficheiros de cálculo diferentes do manifest",
			"Pelo menos um ficheiro local de código/dados não corresponde ao hash declarado pelo manifest. O cálculo atual continua a usar o PoB carregado, mas a sua identidade não pode ser certificada.",
			"Repare ou regenere corretamente o manifest antes de recolher estudos ou usar ranking aprendido.")
	elseif report.identity.engine.manifestInventoryFingerprint and contentIdentityStatus == "unavailable" then
		issue("engine_content_identity_unavailable", "unknown", "Identidade dos dados de cálculo não verificada",
			"A verificação local dos ficheiros não terminou com sucesso. Não use estudos versionados nem ranking aprendido nesta sessão.",
			"Verifique os ficheiros do PoB e reinicie a sessão para repetir a verificação.")
	end
	report.componentCoverage = evaluateComponentCoverage(build)
	report.capabilities.activeSkillGroups = report.componentCoverage.skillGroups.status == "valid"
	report.capabilities.activeEquipmentSlots = report.componentCoverage.equipment.status == "valid"
	report.capabilities.wholeBuildStructure = report.componentCoverage.status == "valid"
	report.identity.name = text(build.buildName, 120)
	report.identity.class = text(spec.curClassName, 80)
	report.identity.ascendancy = text(spec.curAscendClassName, 80)
	report.identity.level = finite(build.characterLevel) and build.characterLevel or nil
	report.identity.treeVersion = spec.treeVersion
	if not report.identity.engine.pobVersion or not report.identity.engine.treeVersion then
		issue("version_unverified", "unknown", "Versão incompleta", "A identidade do motor/árvore não está completa.", "Carregue os dados da árvore e recalcule no PoB.")
	end
	if latestTreeVersion and spec.treeVersion ~= latestTreeVersion then
		outdated = true
		issue("older_tree", "info", "Árvore de outra versão", "A árvore salva difere da versão mais recente carregada neste PoB.", "Revise a conversão nativa da árvore antes de usar regras do patch atual.")
	end
	if report.identity.name == "Download information not found" then
		issue("import_error_title", "info", "Título herdado de importação", "Esse texto é emitido pelo resolvedor de links quando não encontra um provedor. Como título, não comprova uma falha atual nem corrupção da build carregada.", "Confira os dados abaixo; tente um link suportado ou código de exportação na aba Import/Export.")
	end
	report.importAttempt = ImportLifecycle.Snapshot(build.importTab or build)
	report.identity.sourceMetadata = importIdentityMetadata(report.importAttempt)
	report.identity.leagueStatus = report.identity.sourceMetadata.league.status
	-- Import realms describe the source endpoint. They do not prove the current
	-- build's platform, and a league name does not establish SSF/Hardcore mode.
	report.identity.sourceRealmStatus = report.identity.sourceMetadata.sourceRealm.status
	if report.importAttempt.reasonCode then
		issue("import_attempt_failed", "info", "Tentativa de importação não concluída", report.importAttempt.message,
			"Confira a origem na aba Import/Export. A tentativa não comprova um problema nos dados carregados.")
	end
	local output = build.calcsTab and build.calcsTab.mainOutput
	local env = build.calcsTab and build.calcsTab.mainEnv
	local current = type(output) == "table" and finite(output.Life) and env and env.player and env.player.output == output
		and build.buildFlag ~= true
	report.calculation = { status = current and "current" or build.buildFlag and "pending" or "unavailable", source = "PoB MAIN calculation" }
	if not current then
		issue("calculation_unverified", "unknown", "Cálculo ainda não confirmado", "O resultado nativo está ausente, pendente ou não corresponde ao ambiente MAIN ativo.", "Aguarde o recálculo do PoB antes de comparar métricas.")
	else
		report.capabilities.exactMetrics = true
	end
	local input = build.configTab and build.configTab.input or { }
	local configSet = build.configTab and build.configTab.configSets and build.configTab.configSets[build.configTab.activeConfigSetId]
	report.scenario = { configSetId = build.configTab and build.configTab.activeConfigSetId,
		configTitle = text(configSet and configSet.title, 80), activeBooleanFields = { },
		enemyLevel = current and env.enemy and finite(env.enemy.level) and env.enemy.level or nil,
		bossSetting = text(input.enemyIsBoss, 80), hasCustomModifiers = type(input.customMods) == "string" and input.customMods ~= "" or false,
		uptimeCertified = false }
	local activeFields = { }
	for key, value in pairs(input) do if value == true and type(key) == "string" then activeFields[#activeFields + 1] = key end end
	table.sort(activeFields)
	for index = 1, math.min(32, #activeFields) do report.scenario.activeBooleanFields[index] = text(activeFields[index], 100) end
	report.scenario.activeBooleanFieldsTruncated = #activeFields > 32
	report.metrics = { }
	if current then
		for _, key in ipairs({ "Life", "EnergyShield", "Ward", "TotalEHP", "PhysicalMaximumHitTaken", "FireMaximumHitTaken",
			"ColdMaximumHitTaken", "LightningMaximumHitTaken", "ChaosMaximumHitTaken" }) do
			if finite(output[key]) then report.metrics[key] = output[key] end
		end
	end
	if not next(spec.allocNodes or { }) then
		report.tree = { status = "missing" }
		issue("tree_missing", "warning", "Árvore ainda não montada", "Nenhuma alocação foi carregada; não há uma rota existente para validar.", "Escolha a classe em Definir objetivo ou importe uma árvore.")
	else
		local treeOk, treeValid, treeError = pcall(TreeSearch.ValidateCandidate, spec, { }, { branch = { }, search = { } }, nil, { }, spec)
		report.tree = { status = treeOk and treeValid and "valid" or treeOk and "invalid" or "unverified" }
		if not treeOk or not treeValid then
			issue("tree_structure", treeOk and "error" or "unknown", "Revisar árvore", text(treeOk and treeError or treeValid, 300), "Revise classe inicial, conectividade e ascendência na árvore nativa.")
		end
	end
	if type(spec.CountAllocNodes) == "function" then report.tree.pointsUsed = spec:CountAllocNodes() end
	if current and finite(output.ExtraPoints) and type(build.GetPassivePointLimitForLevel) == "function" then
		local level = build.characterLevel
		if build.characterLevelAutoMode and type(build.GetEstimatedLevelForPoints) == "function" then
			level = build:GetEstimatedLevelForPoints(report.tree.pointsUsed, output.ExtraPoints)
		end
		local limit = build:GetPassivePointLimitForLevel(level, output.ExtraPoints)
		if finite(limit) then
			report.tree.pointLimit = limit
			if finite(report.tree.pointsUsed) and report.tree.pointsUsed > limit then
				report.tree.status = "invalid"
				issue("passive_point_limit", "error", "Pontos acima do limite nativo", string.format("PoB: %d pontos alocados, limite %d para o nível e quests configurados.", report.tree.pointsUsed, limit), "Reduza os pontos ou ajuste o nível e as quests reais.")
			end
		end
	end
	if not report.tree.pointLimit then
		issue("native_point_limit_unverified", "unknown", "Limite de pontos não confirmado", "Faltam nível, ExtraPoints ou o limite nativo para validar o orçamento legal da árvore.", "Aguarde o cálculo e revise nível/quests no PoB.")
	end
	report.capabilities.treeComparison = current and report.tree.status == "valid" and finite(report.tree.pointLimit) or false
	local groupIndex = build.mainSocketGroup
	local group = build.skillsTab and build.skillsTab.socketGroupList and build.skillsTab.socketGroupList[groupIndex]
	local skillIndex = group and (group.mainActiveSkill or 1)
	local selected = group and group.displaySkillList and group.displaySkillList[skillIndex]
	local selectedEffect = effect(selected)
	report.skill = { groupIndex = groupIndex, skillIndex = skillIndex, status = "missing" }
	if not group or not selectedEffect then
		issue("main_skill_missing", "warning", "Selecione uma skill principal", "O grupo selecionado não contém um efeito ativo resolvido pelo PoB.", "Escolha a skill em Build direction ou carregue um grupo válido na aba Skills.")
		return finish()
	end
	report.skill.name, report.skill.effectId = text(selectedEffect.name, 100), text(selectedEffect.id, 120)
	report.skill.status = "resolved"
	if group.enabled == false or group.slotEnabled == false or selectedEffect.unsupported then
		issue("main_skill_disabled", "error", "Skill desativada ou não suportada", "O efeito ou seu grupo não está disponível no estado atual do PoB.", "Ative um grupo/effect suportado na aba Skills.")
		return finish()
	end
	local native = current and env.player.mainSkill
	local nativeEffect = effect(native)
	local matches = nativeEffect and nativeEffect.id == selectedEffect.id and native.socketGroup == group
	report.capabilities.selectedSkillMetrics = matches and true or false
	if matches and finite(output.CombinedDPS) then report.metrics.CombinedDPS = output.CombinedDPS end
	if not matches then
		issue("selected_effect_unverified", "unknown", "Skill e cálculo não correspondem", "A identidade do efeito/grupo selecionado não foi confirmada no cálculo MAIN atual.", "Selecione a skill principal e aguarde o recálculo.")
	end
	local socketOk, socketData = SkillCatalog.ValidateSocketGroup(build, groupIndex)
	local unlinked = (type(group.slot) ~= "string" or group.slot == "") and not group.source
	report.skill.sockets = { status = socketOk and socketData.status or (unlinked and "unlinked_planning_group" or "invalid"), detail = type(socketData) == "string" and text(socketData, 300) or nil }
	if not socketOk then
		issue(unlinked and "unlinked_planning_group" or "socket_mismatch", unlinked and "warning" or "error",
			unlinked and "Grupo sem vínculo com equipamento" or "Sockets/links incompatíveis",
			unlinked and "O PoB pode calcular este grupo de planejamento, mas nenhum item/link foi confirmado. Isso não significa que a gema não tem cálculo nem que precisa obrigatoriamente de suporte."
				or socketData, "Associe o grupo ao item, às cores e ao link corretos na aba Skills/Items.")
	end
	local applied = { }
	report.skill.supportsConfigured = 0
	if matches then report.skill.supportsApplied = 0 end
	for _, entry in ipairs(matches and native.effectList or { }) do
		if entry.grantedEffect and entry.grantedEffect.support then
			report.skill.supportsApplied = report.skill.supportsApplied + 1
			if entry.srcInstance then applied[entry.srcInstance] = true end
		end
	end
	for _, gem in ipairs(group.gemList or { }) do
		local data = gem.gemData
		local granted = gem.grantedEffect or data and data.grantedEffect
		if gem.enabled ~= false then
			if not data and not granted then
				issue("gem_unresolved", "warning", "Gema não resolvida", "Há uma entrada habilitada sem dados de gema/efeito carregados.", "Confira o nome e a versão da gema na aba Skills.")
			elseif granted and granted.support then
				report.skill.supportsConfigured = report.skill.supportsConfigured + 1
				if matches and not applied[gem] then
					issue("support_not_applied", "warning", "Suporte não aplicado à skill selecionada", text(data and data.name or granted.name or gem.nameSpec, 100) .. " não aparece nos efeitos aplicados pelo PoB; pode pertencer a outra skill do grupo.", "Revise a compatibilidade e os efeitos suportados na aba Skills.")
				end
			end
		end
	end
	if report.skill.supportsConfigured == 0 then
		issue("no_support_gems", "info", "Nenhuma gema de suporte configurada", "Uma skill pode ser calculada sozinha; a ausência de suportes não prova corrupção nem falta de link.", "Compare suportes compatíveis apenas se fizerem parte do seu objetivo.")
	end
	local requirementsValid = false
	if matches then
		local requirementAudit = Validator.CheckRequirements(output, build.characterLevel)
		requirementsValid = requirementAudit.feasible
		report.requirements = { feasible = requirementsValid, status = requirementsValid and "valid" or "violated",
			scope = "PoB native aggregate requirements for the active item set and evaluated skill groups" }
		for _, violation in ipairs(requirementAudit.violations) do
			local missing = not finite(violation.actual) or not finite(violation.required)
			if missing then report.requirements.status = "unverified" end
			local row = issue(violation.key, missing and "unknown" or "error", violation.label, violation.reason, "Ajuste nível ou atributos antes de tratar o setup como utilizável.")
			if not missing then row.actual, row.required = violation.actual, violation.required end
			if finite(violation.deficit) then row.deficit = violation.deficit end
			local sourceLocation = requirementSourceLocation(build, violation.key, output)
			if sourceLocation then
				for key, value in pairs(sourceLocation) do row[key] = value end
			end
		end
		local sustainAudit = Activity.Evaluate({ objective = "CombinedDPS", hard = { } }, output.OptimizerMainSkillActivity, output.FullDPSActivity, output.FullDPSActivityTruncated)
		report.sustain = { status = sustainAudit.status, feasible = sustainAudit.feasible }
		if not sustainAudit.feasible then
			local violation = sustainAudit.violations and sustainAudit.violations[1]
			local reason = violation and violation.reason or sustainAudit.unsupported and sustainAudit.unsupported[1]
			issue("selected_skill_sustain", "warning", "Sustentação não certificada", reason or "O ledger nativo não certificou os custos recorrentes da skill selecionada.", "Abra Activity schedule e confira custos, recuperação e condições.")
		end
		local availabilityAudit = SkillAvailability.Evaluate({ objective = "CombinedDPS", hard = { } }, env.player, output.FullDPSSkillAvailability, output)
		report.availability = { status = availabilityAudit.status, feasible = availabilityAudit.feasible }
		if not availabilityAudit.feasible then
			issue("selected_skill_availability", "warning", "Disponibilidade de dano não certificada", availabilityAudit.reason, "Revise almas Vaal, ciclos de trigger ou stacks sustentáveis antes de interpretar DPS contínuo.")
		end
	end
	report.capabilities.physicalSkillSetup = matches and socketOk and requirementsValid and report.tree.status == "valid" and finite(report.tree.pointLimit) or false
	report.planOnly = not report.capabilities.physicalSkillSetup
	return finish()
end

function readiness.Describe(report)
	local id = report.identity
	local dataVersionEvidence = id.patchEvidence == "tree_compatibility_key" and "chave de compatibilidade da árvore"
		or id.patchEvidence == "pob_loaded_data_table_version" and "versão da tabela de dados carregada pelo PoB"
		or "origem de versão não disponível"
	local lines = {
		"Skill principal: " .. report.label .. " — métricas e setup continuam limitados à skill selecionada",
		"Build: " .. (id.name or "sem nome confirmado"),
		"PoE 1 | dados " .. tostring(id.engine.dataVersion or id.treeVersion or "não verificados") .. " (" .. dataVersionEvidence .. ") | PoB " .. tostring(id.engine.pobVersion or "não verificado"),
		"Classe: " .. (id.class or "não verificada") .. " | Ascendência: " .. (id.ascendancy or "não selecionada") .. " | Nível: " .. tostring(id.level or "não verificado"),
		"Cálculo MAIN: " .. tostring(report.calculation and report.calculation.status or "indisponível"),
	}
	local coverage = report.componentCoverage
	if coverage then
		local skillGroups = coverage.skillGroups or { }
		local equipment = coverage.equipment or { }
		lines[#lines + 1] = "Integridade estrutural ativa: " .. tostring(coverage.status)
			.. " | grupos habilitados " .. tostring(skillGroups.enabled or 0) .. "/" .. tostring(skillGroups.total or 0)
			.. " (ligados " .. tostring(skillGroups.linked or 0) .. ", concedidos " .. tostring(skillGroups.granted or 0)
			.. ", sem vínculo " .. tostring(skillGroups.unlinked or 0) .. ", inválidos " .. tostring(skillGroups.invalid or 0) .. ")"
			.. " | itens selecionados " .. tostring(equipment.selected or 0) .. " (compatíveis " .. tostring(equipment.valid or 0)
			.. ", inválidos " .. tostring(equipment.invalid or 0) .. ", não verificados " .. tostring(equipment.unverified or 0) .. ")"
		for _, row in ipairs(coverage.issues or { }) do
			lines[#lines + 1] = "Cobertura " .. tostring(row.component or "build") .. " [" .. tostring(row.severity) .. "]"
			lines[#lines + 1] = row.detail or "Detalhe não disponível."
			if row.action then lines[#lines + 1] = "Ação: " .. row.action end
		end
		if coverage.issuesTruncated then lines[#lines + 1] = "Parte dos diagnósticos estruturais foi truncada; consulte Skills e Items no PoB." end
	end
	local sourceMetadata = id.sourceMetadata or { }
	local function describeSourceField(label, field)
		local value, status = field and field.value, field and field.status or "not_recorded"
		if status == "source_declared_unverified" then
			return label .. ": " .. tostring(value) .. " (declarada na origem importada; não confirma o contexto atual da build)."
		elseif status == "saved_metadata_unverified" then
			return label .. ": " .. tostring(value) .. " (metadado salvo; não verificado para a build atual)."
		elseif status == "conflicting_sources" then
			return label .. ": fontes de importação divergem; valor não definido."
		end
		return label .. ": não registrada como identidade desta build."
	end
	lines[#lines + 1] = describeSourceField("Liga na origem", sourceMetadata.league)
	lines[#lines + 1] = describeSourceField("Realm na origem", sourceMetadata.sourceRealm)
	lines[#lines + 1] = "Identidade ativa da build: não certificada pelos metadados de origem."
	lines[#lines + 1] = "Plataforma atual: não registrada; realm de origem não a confirma."
	lines[#lines + 1] = "Modo atual (Hardcore/SSF/Ruthless): não registrado; não inferido do nome da liga."
	local import = report.importAttempt
	if import then
		for _, line in ipairs(ImportLifecycle.Describe(import)) do lines[#lines + 1] = line end
	end
	if report.skill then
		lines[#lines + 1] = "Skill: " .. (report.skill.name or "não selecionada") .. " | Suportes de gemas: " .. tostring(report.skill.supportsConfigured or "não verificados")
			.. " | Efeitos de suporte aplicados: " .. tostring(report.skill.supportsApplied or "não verificados")
	end
	if report.tree then lines[#lines + 1] = "Pontos: " .. tostring(report.tree.pointsUsed or "não verificados") .. " / " .. tostring(report.tree.pointLimit or "limite não verificado") end
	if report.scenario then
		local scenario = report.scenario
		lines[#lines + 1] = "Configuração: " .. (scenario.configTitle or tostring(scenario.configSetId or "não verificada"))
			.. " | Inimigo nível " .. tostring(scenario.enemyLevel or "não verificado") .. " | Chefe: " .. (scenario.bossSetting or "padrão nativo")
		lines[#lines + 1] = "Flags configuradas (sem certificar uptime):"
		if #scenario.activeBooleanFields > 0 then
			for _, field in ipairs(scenario.activeBooleanFields) do
				local label = configOptionLabels[field]
				lines[#lines + 1] = "  - " .. (label or field) .. (label and label ~= field and (" [" .. field .. "]") or "")
			end
		else
			lines[#lines + 1] = "  Nenhuma flag booleana explicitamente ativa."
		end
		if scenario.activeBooleanFieldsTruncated then lines[#lines + 1] = "Lista de flags truncada; confira a configuração completa na aba Configuration." end
		if scenario.hasCustomModifiers then lines[#lines + 1] = "Há modificadores customizados. Revise-os na aba Configuration antes de interpretar os resultados." end
	end
	local function metric(key) return finite(report.metrics and report.metrics[key]) and string.format("%.6g", report.metrics[key]) or "não verificado" end
	if report.capabilities.exactMetrics then
		lines[#lines + 1] = "Resumo PoB (valores exibidos arredondados): Vida " .. metric("Life") .. " | ES " .. metric("EnergyShield") .. " | EHP " .. metric("TotalEHP")
		lines[#lines + 1] = "Max hit Phys/Fire/Cold/Lightning/Chaos: " .. metric("PhysicalMaximumHitTaken") .. " / " .. metric("FireMaximumHitTaken") .. " / " .. metric("ColdMaximumHitTaken") .. " / " .. metric("LightningMaximumHitTaken") .. " / " .. metric("ChaosMaximumHitTaken")
		if report.capabilities.selectedSkillMetrics then lines[#lines + 1] = "CombinedDPS da skill selecionada: " .. metric("CombinedDPS") .. "; não é certificação de dano sustentado." end
	end
	lines[#lines + 1] = "Próximo passo: " .. (report.nextAction or "Revisar diagnóstico.")
	for _, row in ipairs(report.issues) do
		lines[#lines + 1] = ""
		lines[#lines + 1] = row.title .. " [" .. row.severity .. "]"
		lines[#lines + 1] = row.detail or "Detalhe não disponível."
		if row.sourceLocationStatus == "active_skill_group" then
			lines[#lines + 1] = "Origem do requisito: " .. (row.sourceName or "gema")
				.. " | grupo " .. tostring(row.sourceGroupIndex or "não localizado")
				.. (row.sourceGroupLabel and (" (" .. row.sourceGroupLabel .. ")") or "")
				.. (row.sourceSlot and (" | slot " .. row.sourceSlot) or "")
		elseif row.sourceLocationStatus == "active_item_slot" then
			lines[#lines + 1] = "Origem do requisito: " .. (row.sourceName or "item") .. " | slot " .. row.sourceSlot
		elseif row.sourceName then
			lines[#lines + 1] = "Origem do requisito PoB: " .. row.sourceName .. " (localização não encontrada na seleção ativa)."
		end
		if finite(row.actual) and finite(row.required) then lines[#lines + 1] = string.format("PoB: disponível %.6g; necessário %.6g.", row.actual, row.required) end
		if row.action then lines[#lines + 1] = "Ação: " .. row.action end
	end
	if report.issuesTruncated then lines[#lines + 1] = "Outros diagnósticos foram truncados; revise os avisos completos nas abas nativas." end
	lines[#lines + 1] = ""
	for _, limitation in ipairs(report.limitations) do lines[#lines + 1] = limitation end
	return lines
end

-- A compact first-page summary. The complete report remains available on
-- demand, while the initial view exposes the most actionable issue instead
-- of forcing new users to scan every configuration field and metric.
function readiness.DescribeSummary(report)
	local lines = { "Build: " .. tostring(report.identity and report.identity.name or "sem nome confirmado") }
	for _, line in ipairs(ImportLifecycle.DescribeSummary(report.importAttempt)) do lines[#lines + 1] = line end
	local importantIssues = { }
	for _, severity in ipairs({ "error", "warning", "unknown" }) do
		for _, row in ipairs(report.issues or { }) do
			if row.severity == severity then
				importantIssues[#importantIssues + 1] = row
				if #importantIssues >= 2 then break end
			end
		end
		if #importantIssues >= 2 then break end
	end
	for _, row in ipairs(report.issues or { }) do
		if row.code == "import_error_title" or row.code == "import_attempt_failed" then
			lines[#lines + 1] = (row.code == "import_error_title" and "Nota sobre o título: " or "Detalhe da tentativa: ")
				.. (row.detail or "O estado da importação não está disponível.")
			break
		end
	end
	if #importantIssues > 0 then
		local primary = importantIssues[1]
		local primarySeverity = primary.severity == "error" and "erro" or primary.severity == "warning" and "aviso" or "não verificado"
		lines[#lines + 1] = "Diagnóstico principal (" .. primarySeverity .. "): " .. tostring(primary.title or "Revisar build")
			.. (primary.detail and (" — " .. primary.detail) or "")
		lines[#lines + 1] = "Próxima ação: " .. tostring(primary.action or report.nextAction or "Revise o diagnóstico completo.")
		if importantIssues[2] then
			local secondary = importantIssues[2]
			local secondarySeverity = secondary.severity == "error" and "erro" or secondary.severity == "warning" and "aviso" or "não verificado"
			lines[#lines + 1] = "Outro ponto (" .. secondarySeverity .. "): " .. tostring(secondary.title or "Revisar build")
				.. (secondary.detail and (" — " .. secondary.detail) or "")
		end
	else
		lines[#lines + 1] = "Nenhum bloqueio de integridade foi encontrado neste escopo. Isso não certifica uptime ou disponibilidade em combate."
		lines[#lines + 1] = "Próxima ação: " .. tostring(report.nextAction or "Revise o cenário e compare as mudanças.")
	end
	return lines
end

return readiness
