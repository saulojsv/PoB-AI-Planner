-- Native import events and bounded origin metadata. Payloads, links, account
-- names and character identifiers are never retained by this module.
local lifecycle = { }
local BoundedInflate = require("Modules.Optimizer.BoundedInflate")
local MAX_POB_XML_BYTES = BoundedInflate.MAX_OUTPUT_BYTES
local DEFAULT_MAX_BUILD_CODE_BYTES = 16777216
local states = {
	empty = true, invalid_preview = true, valid_preview = true, fetching = true,
	download_failed = true, decode_failed = true, applying = true, loaded = true,
	native_load_unconfirmed = true,
}
local kinds = { build_code = true, provider_url = true, character_payload = true }
local components = { build = true, tree = true, items = true, skills = true }
local operations = { replace = true, merge = true, replace_tree_keep_jewels = true }
local statusLabels = {
	empty = "nenhuma entrada", not_verified = "sem tentativa confirmada",
	invalid_preview = "entrada não reconhecida", valid_preview = "entrada reconhecida; ainda não carregada",
	fetching = "download em andamento", download_failed = "download não concluído",
	decode_failed = "código não decodificado", applying = "carregamento em andamento",
	loaded = "carregamento nativo concluído", native_load_unconfirmed = "carregamento não confirmado",
}
local failures = {
	invalid_code = "O código não pôde ser decodificado/descomprimido. Use um export do PoB.",
	invalid_xml = "O conteúdo não é um XML válido do PoB. A build carregada não foi substituída.",
	wrong_root = "O XML não usa a raiz PathOfBuilding esperada pelo PoB.",
	download_failed = "Falha ao obter o export do provedor. Confira o link ou use o código diretamente.",
	download_invalid_response = "O provedor não devolveu um export de build utilizável.",
	download_too_large = "O export excede o limite de tamanho permitido para importação.",
	download_start_failed = "O PoB não conseguiu iniciar o download do provedor.",
	payload_too_large = "O export excede o limite de tamanho permitido para validação XML.",
	inflater_unavailable = "O runtime atual não disponibiliza zlib para importar este código com limite de memória.",
	decompression_failed = "O código comprimido não pôde ser expandido com segurança.",
	provider_unresolved = "O PoB não encontrou um provedor de download para esse link.",
	provider_link_mismatch = "O domínio do link não corresponde ao provedor selecionado. Escolha a fonte correspondente ou use o código exportado.",
	provider_link_invalid = "O formato do link não é válido para esse provedor. Revise o endereço ou use o código exportado.",
	unsupported_target = "A versão declarada não corresponde às versões de PoE 1 reconhecidas por este PoB. Use um export compatível.",
	native_load_failed = "O carregamento nativo não confirmou uma build calculável. Revise o export.",
	native_shutdown_failed = "O PoB falhou ao fechar a build atual para iniciar a importação.",
	native_commit_failed = "O PoB não conseguiu concluir o estado da build importada.",
	source_snapshot_failed = "A build atual não pôde ser preservada para recuperação; nenhuma importação foi aplicada.",
	source_restore_failed = "A importação falhou e a restauração da build anterior não foi confirmada. Não trate o estado atual como íntegro.",
}
local function safe(value, limit)
	if type(value) ~= "string" or value == "" or #value > limit or value:find("%c") then return nil end
	return value:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""):gsub("%^", "")
end
local function providerId(value)
	for _, provider in ipairs(buildSites and buildSites.websiteList or { }) do
		if value == provider.id then return provider.id end
	end
end
local function descriptor(input)
	input = input or { }
	return { kind = kinds[input.kind] and input.kind or "build_code", providerId = providerId(input.providerId) }
end
local function copyCoverage(input)
	if type(input) ~= "table" then return nil end
	local result = { }
	for _, section in ipairs({ "Build", "Tree", "Skills", "Items", "Config" }) do result[section] = input[section] == true end
	return result
end

function lifecycle.Begin(owner, source)
	owner.plannerImportRevision = (owner.plannerImportRevision or 0) + 1
	local origin = descriptor(source)
	owner.plannerImportAttempt = { revision = owner.plannerImportRevision, status = "empty", kind = origin.kind,
		providerId = origin.providerId, changedAt = os.time() }
	return owner.plannerImportRevision
end

function lifecycle.IsCurrent(owner, revision)
	return owner.build and owner.build.importTab == owner and owner.plannerImportAttempt
		and owner.plannerImportAttempt.revision == revision or false
end

function lifecycle.Update(owner, revision, status, reason, coverage)
	local state = owner.plannerImportAttempt
	if not state or state.revision ~= revision or not states[status] then return false end
	state.status, state.changedAt = status, os.time()
	state.reasonCode = failures[reason] and reason or nil
	if coverage then state.sectionCoverage = copyCoverage(coverage) end
	return true
end

function lifecycle.FailureMessage(reason)
	return failures[reason] or failures.native_load_failed
end

-- Validate framing through the same native XML parser as Build.LoadDB. This
-- does not certify skill legality, passive points, or completeness of a build.
function lifecycle.ValidateXML(xmlText)
	if type(xmlText) ~= "string" or xmlText == "" then return nil, "invalid_xml" end
	if #xmlText > MAX_POB_XML_BYTES then return nil, "payload_too_large" end
	local ok, nodes, parseError = pcall(common.xml.ParseXML, xmlText)
	if not ok or parseError or type(nodes) ~= "table" or type(nodes[1]) ~= "table" then return nil, "invalid_xml" end
	if nodes[1].elem ~= "PathOfBuilding" then return nil, "wrong_root" end
	local coverage, target = { }, nil
	for _, node in ipairs(nodes[1]) do
		if type(node) == "table" then
			if node.elem == "Build" then
				if coverage.Build then return nil, "invalid_xml" end
				local declared = node.attrib and node.attrib.targetVersion
				target = safe(declared, 40)
				if declared ~= nil and not target then return nil, "unsupported_target" end
			end
			if node.elem == "Spec" then coverage.Tree = true else coverage[node.elem] = true end
		end
	end
	-- GameVersions.lua is the native, versioned compatibility authority. Do not
	-- silently force unknown game families/versions through CompareEntry's
	-- current-version coercion. A missing version follows native legacy handling.
	local effectiveTarget = target or legacyTargetVersion
	if effectiveTarget ~= liveTargetVersion and effectiveTarget ~= legacyTargetVersion then return nil, "unsupported_target" end
	return { sectionCoverage = copyCoverage(coverage), targetVersion = target,
		requiresConversion = effectiveTarget ~= liveTargetVersion,
		validationScope = "pob1_xml_structure_only" }
end

-- Decode every untrusted PoB build-code entry through the same bounded path.
-- This is shared by the main import tab, comparisons, party imports, protocol
-- links and the generic ImportBuild API so no alternate UI path can fall back
-- to the native inflater, whose output allocation is not bounded here.
function lifecycle.DecodeBuildCode(code)
	if type(code) ~= "string" or code == "" then return nil, "invalid_code" end
	local maxCodeBytes = buildSites and buildSites.MAX_BUILD_CODE_BYTES or DEFAULT_MAX_BUILD_CODE_BYTES
	if #code > maxCodeBytes then return nil, "payload_too_large" end
	local decodeOk, compressed = pcall(common.base64.decode, code:gsub("-", "+"):gsub("_", "/"))
	if not decodeOk or type(compressed) ~= "string" or compressed == "" then return nil, "invalid_code" end
	if #compressed > maxCodeBytes then return nil, "payload_too_large" end
	local inflateOk, xmlText, inflateReason = pcall(BoundedInflate.inflate, compressed)
	if not inflateOk then return nil, "invalid_code" end
	if type(xmlText) ~= "string" or xmlText == "" then
		local knownReasons = { payload_too_large = true, inflater_unavailable = true,
			decompression_failed = true, invalid_code = true }
		return nil, knownReasons[inflateReason] and inflateReason or "invalid_code"
	end
	local coverage, reason = lifecycle.ValidateXML(xmlText)
	if not coverage then return nil, reason end
	return xmlText, coverage
end

lifecycle.MAX_POB_XML_BYTES = MAX_POB_XML_BYTES

local function originRecord(component, source, operation, payload, realm)
	if not components[component] then return nil end
	local origin = descriptor(source)
	return { component = component, kind = origin.kind, providerId = origin.providerId,
		operation = operations[operation] and operation or "replace", observedAt = os.time(),
		league = safe(payload and payload.league, 120), realm = safe(realm, 20),
		evidence = "observed_import_event", currentStateCertified = false }
end

function lifecycle.Observe(owner, component, source, operation, payload, realm)
	local record = originRecord(component, source, operation, payload, realm)
	if not record then return end
	owner.plannerImportOrigins = owner.plannerImportOrigins or { }
	owner.plannerImportOrigins[component] = record
	owner.plannerOriginRevision = (owner.plannerOriginRevision or 0) + 1
end

function lifecycle.AdoptLoaded(owner, source, coverage, target)
	local revision = lifecycle.Begin(owner, source)
	lifecycle.Update(owner, revision, "loaded", nil, coverage)
	owner.plannerImportAttempt.target = target
	lifecycle.Observe(owner, "build", source, "replace")
end

function lifecycle.Snapshot(owner)
	local state = owner and owner.plannerImportAttempt
	local result = { status = state and state.status or "not_verified", affectsLoadedBuild = false,
		validationScope = "import_event_not_build_legality", origins = { } }
	if state then
		for _, key in ipairs({ "revision", "kind", "providerId", "changedAt", "reasonCode", "target" }) do result[key] = state[key] end
		result.sectionCoverage = copyCoverage(state.sectionCoverage)
		result.affectsLoadedBuild = state.status == "loaded" and state.target ~= "comparison"
		result.message = state.reasonCode and lifecycle.FailureMessage(state.reasonCode) or nil
	end
	for _, component in ipairs({ "build", "tree", "items", "skills" }) do
		local record = owner and owner.plannerImportOrigins and owner.plannerImportOrigins[component]
		if record then
			local copy = { }
			for _, key in ipairs({ "component", "kind", "providerId", "operation", "observedAt", "league", "realm", "evidence" }) do copy[key] = record[key] end
			copy.currentStateCertified = false
			result.origins[#result.origins + 1] = copy
		end
	end
	return result
end

function lifecycle.Describe(snapshot)
	local lines = { "Importação: " .. (statusLabels[snapshot.status] or "estado não verificado") .. "; a origem não certifica a integridade da build." }
	local names = { build = "build", tree = "árvore", items = "itens", skills = "gemas" }
	local kindNames = { build_code = "código PoB", provider_url = "link de provedor", character_payload = "dados de personagem" }
	for _, origin in ipairs(snapshot.origins or { }) do
		lines[#lines + 1] = "Origem de " .. (names[origin.component] or "componente") .. ": " .. (kindNames[origin.kind] or "não verificada")
			.. (origin.providerId and (" / " .. origin.providerId) or "")
			.. (origin.evidence == "observed_import_event" and " | observada nesta sessão" or " | metadado salvo, não verificado")
			.. (origin.league and (" | liga declarada nessa origem: " .. origin.league) or "")
	end
	return lines
end

-- Compact provenance for the first-page Planner diagnosis. Keep this limited
-- to allowlisted provider IDs, import kinds, and the XML section-presence
-- preview; never surface the submitted URL, account, or character payload.
function lifecycle.DescribeSummary(snapshot)
	snapshot = type(snapshot) == "table" and snapshot or { }
	local kindNames = { build_code = "código PoB", provider_url = "link de provedor", character_payload = "dados de personagem" }
	local lines = { "Importação: " .. (statusLabels[snapshot.status] or "estado não verificado") }
	local kind = kinds[snapshot.kind] and snapshot.kind or nil
	local provider = providerId(snapshot.providerId)
	if not kind and type(snapshot.origins) == "table" then
		for _, origin in ipairs(snapshot.origins) do
			if type(origin) == "table" and kinds[origin.kind] then
				kind = origin.kind
				provider = provider or providerId(origin.providerId)
				break
			end
		end
	end
	if kind then
		lines[#lines + 1] = "Origem declarada: " .. kindNames[kind]
			.. (provider and (" / " .. provider) or "")
			.. "; metadados não certificam a integridade nem o contexto atual da build."
	end
	if type(snapshot.sectionCoverage) == "table" then
		local present, absent = { }, { }
		for _, section in ipairs({ "Build", "Tree", "Skills", "Items", "Config" }) do
			local label = section == "Tree" and "árvore" or section == "Skills" and "skills" or section == "Items" and "itens" or section == "Config" and "configuração" or "Build"
			local target = snapshot.sectionCoverage[section] and present or absent
			target[#target + 1] = label
		end
		lines[#lines + 1] = "Secções XML presentes: " .. (#present > 0 and table.concat(present, ", ") or "nenhuma")
			.. "; ausentes: " .. (#absent > 0 and table.concat(absent, ", ") or "nenhuma")
			.. " (presença estrutural; não valida conteúdo ou legalidade)."
	else
		lines[#lines + 1] = "Secções XML: presença não registada; estrutura não verificada."
	end
	return lines
end

function lifecycle.Save(owner, xml)
	for _, record in ipairs(lifecycle.Snapshot(owner).origins) do
		local attrib = { schemaVersion = "1" }
		for _, key in ipairs({ "component", "kind", "providerId", "operation", "observedAt", "league", "realm" }) do
			if record[key] ~= nil then attrib[key] = tostring(record[key]) end
		end
		xml[#xml + 1] = { elem = "PlannerOrigin", attrib = attrib }
	end
end

function lifecycle.Load(owner, xml)
	owner.plannerImportOrigins = { }
	for _, node in ipairs(xml or { }) do
		local a = type(node) == "table" and node.elem == "PlannerOrigin" and node.attrib
		if a and a.schemaVersion == "1" and components[a.component] and kinds[a.kind] and operations[a.operation] then
			local record = originRecord(a.component, a, a.operation, a, a.realm)
			local timestamp = tonumber(a.observedAt)
			record.observedAt = timestamp and timestamp >= 0 and timestamp <= 32503680000 and timestamp == math.floor(timestamp) and timestamp or nil
			record.evidence = "saved_metadata_unverified"
			owner.plannerImportOrigins[a.component] = record
		end
	end
	owner.plannerOriginRevision = (owner.plannerOriginRevision or 0) + 1
end

return lifecycle
