-- Module: privacy-safe progress snapshot for the local build intake dashboard.
-- The collector writes only stage/count metadata; PoB codes and XML never go here.
local json = require("dkjson")

local status = { }
local MAX_STATUS_BYTES = 65536
local MAX_RESULT_BYTES = 65536
local MAX_RESULT_ROWS = 32
local MAX_PAIRED_HISTORY_BYTES = 268435456
local MAX_PAIRED_HISTORY_ROWS = 100000
local MAX_PAIRED_HISTORY_LINE_BYTES = 4096
local pairedHistoryCache = nil
local stages = {
	preflight = "preflight",
	checking_source = "checando fonte",
	fetching_code = "extraindo código",
	source_code_staged = "código extraído",
	native_import = "validando no PoB",
	completed = "concluída",
	failed = "falhou",
}
local resultStatuses = {
	archived = "arquivada",
	already_archived = "já arquivada",
	target_gate_rejected = "fora do escopo",
	native_load_failed = "falha ao carregar no PoB",
	native_load_unconfirmed = "PoB não confirmou carga",
	native_tree_load_unconfirmed = "árvore não confirmada",
	profile_failed = "perfil não extraído",
	archive_failed = "falha ao arquivar",
	ingestion_exception = "falha na ingestão",
	archive_source_lookup_failed = "falha ao conferir duplicata",
	lineage_failed = "linhagem não extraída",
	already_reviewed = "revisão já feita",
	reviewed = "revisada",
	review_failed = "falha na revisão",
	review_catalog_unavailable = "catálogo indisponível",
	archive_snapshot_unresolved = "snapshot não resolvido",
	not_found = "código não encontrado",
	request_failed = "falha na fonte",
	request_blocked = "pedido bloqueado pela fonte",
}
local rejectionReasons = {
	event_secondary_ascendancy = "ascendência secundária de evento",
	event_bloodline_node_allocated = "nó Bloodline alocado",
	tree_not_in_3_26_to_3_29 = "rejeitada pelo escopo antigo 3.26–3.29",
	tree_not_in_3_24_to_3_29 = "árvore fora de 3.24–3.29",
	main_skill_not_identifiable = "skill principal não identificada",
	skill_not_in_patch_catalog = "skill fora do catálogo do patch",
	support_granted_effect_not_independent_target = "efeito concedido por suporte",
	skill_category_out_of_scope = "categoria de skill fora do escopo",
	skill_effect_catalog_mismatch = "identidade não coincide com o catálogo",
	secondary_ascendancy_unverified = "ascendência secundária não verificada",
	active_spec_not_verified = "spec ativa não verificada",
	source_main_skill_mismatch = "Main Skill diverge da fonte",
	source_build_quality_quarantined = "qualidade em quarentena",
	source_build_quality_audit_invalid = "auditoria de qualidade inválida",
}

local function boundedInteger(value, minimum, maximum)
	value = tonumber(value)
	if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
	if value ~= math.floor(value) or value < minimum or value > maximum then return nil end
	return value
end

function status.Parse(content)
	if type(content) ~= "string" or #content == 0 or #content > MAX_STATUS_BYTES then return nil end
	local ok, record = pcall(json.decode, content)
	if not ok or type(record) ~= "table" or record.schema ~= "pob-ai-planner-build-ingestion-progress"
		or tonumber(record.schemaVersion) ~= 1 then return nil end
	if record.state ~= "running" and record.state ~= "completed" and record.state ~= "failed" then return nil end
	local updatedAtUnix = boundedInteger(record.updatedAtUnix, 1, 4102444800)
	local totalCount = boundedInteger(record.totalCount, 0, 100000)
	local processedCount = boundedInteger(record.processedCount, 0, 100000)
	local requestCount = boundedInteger(record.requestCount, 0, 1000000)
	local archivedCount = boundedInteger(record.archivedCount or 0, 0, 100000)
	local rejectedCount = boundedInteger(record.rejectedCount or 0, 0, 100000)
	local notFoundCount = boundedInteger(record.notFoundCount or 0, 0, 100000)
	local failedCount = boundedInteger(record.failedCount or 0, 0, 100000)
	local minimumDelaySeconds = boundedInteger(record.minimumDelaySeconds or 60, 1, 3600)
	if not updatedAtUnix or not totalCount or not processedCount or not requestCount or not archivedCount
		or not rejectedCount or not notFoundCount or not failedCount or not minimumDelaySeconds then return nil end
	if processedCount > totalCount then return nil end
	local currentId = type(record.currentId) == "string" and record.currentId or ""
	if #currentId > 64 or currentId:find("[^A-Za-z0-9_%-]") then currentId = "" end
	local stage = stages[record.stage] and record.stage or "preflight"
	return {
		state = record.state,
		stage = stage,
		updatedAtUnix = updatedAtUnix,
		totalCount = totalCount,
		processedCount = processedCount,
		requestCount = requestCount,
		archivedCount = archivedCount,
		rejectedCount = rejectedCount,
		notFoundCount = notFoundCount,
		failedCount = failedCount,
		minimumDelaySeconds = minimumDelaySeconds,
		currentId = currentId,
	}
end

function status.ReadFile(path)
	if type(path) ~= "string" or path == "" or path:find("%z") then return nil end
	local file = io.open(path, "rb")
	if not file then return nil end
	local content = file:read(MAX_STATUS_BYTES + 1)
	file:close()
	return status.Parse(content)
end

local function safeLabel(value, maximum)
	if type(value) ~= "string" then return nil end
	value = value:gsub("[^%w%s%-%'()%+/,]", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then return nil end
	return value:sub(1, maximum)
end

local function safeRelativeReportPath(value)
	if type(value) ~= "string" or #value == 0 or #value > 200 or value:sub(1, 1) == "/"
		or value:find("..", 1, true) or value:find("[^%w%._/%-]") then return nil end
	return value
end

local function parseReviewAudit(value)
	if type(value) ~= "table" then return nil end
	local result = { reviewers = { }, ideas = { } }
	for index, role in ipairs(type(value.reviewers) == "table" and value.reviewers or { }) do
		if index > 4 then break end
		local label = safeLabel(role, 32)
		if label then result.reviewers[#result.reviewers + 1] = label end
	end
	result.summary = safeLabel(value.summary, 400)
	result.reportPath = safeRelativeReportPath(value.reportPath)
	result.validationScope = safeLabel(value.validationScope, 72)
	if type(value.pairedReviewCompleted) == "boolean" then result.pairedReviewCompleted = value.pairedReviewCompleted end
	if type(value.sourceStatus) == "string" and resultStatuses[value.sourceStatus] then
		result.sourceStatus = value.sourceStatus
		result.sourceStatusLabel = resultStatuses[value.sourceStatus]
	end
	if type(value.mainSkillCoverageEligible) == "boolean" then result.mainSkillCoverageEligible = value.mainSkillCoverageEligible end
	if value.fullBuildStatus == "reviewed_valid" or value.fullBuildStatus == "quarantined" then
		result.fullBuildStatus = value.fullBuildStatus
	end
	if type(value.trainingEligible) == "boolean" then result.trainingEligible = value.trainingEligible end
	for index, idea in ipairs(type(value.ideas) == "table" and value.ideas or { }) do
		if index > 5 then break end
		if type(idea) == "table" and (idea.status == "untested" or idea.status == "tested") then
			local title = safeLabel(idea.title, 140)
			if title then
				local cleanIdea = { title = title, status = idea.status, linkedSkills = { }, testPlan = safeLabel(idea.testPlan, 320) }
				for skillIndex, skill in ipairs(type(idea.linkedSkills) == "table" and idea.linkedSkills or { }) do
					if skillIndex > 4 then break end
					local label = safeLabel(skill, 72)
					if label then cleanIdea.linkedSkills[#cleanIdea.linkedSkills + 1] = label end
				end
				result.ideas[#result.ideas + 1] = cleanIdea
			end
		end
	end
	if #result.reviewers == 0 and not result.summary and #result.ideas == 0 and not result.reportPath then return nil end
	return result
end

local function parseLatestResult(line)
	if type(line) ~= "string" or #line == 0 or #line > MAX_PAIRED_HISTORY_LINE_BYTES then return nil end
	local ok, value = pcall(json.decode, line)
	if not ok or type(value) ~= "table" or value.schema ~= "pob-ai-planner-ingestion-result"
		or tonumber(value.schemaVersion) ~= 1 then return nil end
	if type(value.id) ~= "string" or #value.id > 64 or not value.id:match("^[A-Za-z0-9_%-]+$") then return nil end
	local resultStatus = resultStatuses[value.status]
	if not resultStatus then return nil end
	local patch = value.patch
	if patch ~= "3.24" and patch ~= "3.25" and patch ~= "3.26" and patch ~= "3.27" and patch ~= "3.28" and patch ~= "3.29" then patch = nil end
	local category = value.category
	if category ~= "normal" and category ~= "transfigured" and category ~= "unknown" then category = nil end
	local reason = rejectionReasons[value.reason]
	return {
		id = value.id,
		status = value.status,
		statusLabel = resultStatus,
		patch = patch,
		skill = safeLabel(value.skill, 72),
		category = category,
		ascendancy = safeLabel(value.ascendancy, 40),
		reason = reason,
		reviewAudit = parseReviewAudit(value.reviewAudit),
	}
end

local function readBoundedLine(file)
	local chunks, length, oversized = { }, 0, false
	while true do
		local chunk = file:read(2048)
		if not chunk then
			if length == 0 and #chunks == 0 and not oversized then return nil end
			break
		end
		local newline = chunk:find("\n", 1, true)
		local segment = newline and chunk:sub(1, newline - 1) or chunk
		if not oversized then
			if length + #segment > MAX_PAIRED_HISTORY_LINE_BYTES then
				oversized, chunks = true, { }
			else
				chunks[#chunks + 1] = segment
				length = length + #segment
			end
		end
		if newline then
			local unread = #chunk - newline
			if unread > 0 then file:seek("cur", -unread) end
			break
		end
	end
	if oversized then return false end
	local line = table.concat(chunks)
	if line:sub(-1) == "\r" then line = line:sub(1, -2) end
	return line
end

local function pairedHistorySignature(file, size)
	file:seek("set", 0)
	local first = file:read(math.min(128, size)) or ""
	file:seek("set", math.max(0, size - 128))
	local last = file:read(128) or ""
	return tostring(size) .. ":" .. first .. ":" .. last
end

local function getPairedHistoryIndex(path)
	if type(path) ~= "string" or path == "" or path:find("%z") then return nil, "invalid_path" end
	local file = io.open(path, "rb")
	if not file then return nil, "history_unavailable" end
	local size = file:seek("end") or 0
	if size > MAX_PAIRED_HISTORY_BYTES then file:close(); return nil, "history_too_large" end
	local signature = pairedHistorySignature(file, size)
	if pairedHistoryCache and pairedHistoryCache.path == path and pairedHistoryCache.signature == signature then
		file:close()
		return pairedHistoryCache
	end
	file:seek("set", 0)
	local index = { path = path, signature = signature, rows = { }, skills = { }, counts = { } }
	while true do
		local offset = file:seek()
		local line = readBoundedLine(file)
		if line == nil then break end
		if line ~= false then
			local row = parseLatestResult(line)
			if row and row.reviewAudit and row.reviewAudit.pairedReviewCompleted == true then
				if #index.rows >= MAX_PAIRED_HISTORY_ROWS then file:close(); return nil, "history_row_limit" end
				local meta = { offset = offset, patch = row.patch, category = row.category, skill = row.skill }
				index.rows[#index.rows + 1] = meta
				local key = (meta.patch or "") .. "\31" .. (meta.category or "") .. "\31" .. (meta.skill or "")
				index.skills[key] = (index.skills[key] or 0) + 1
				local patchKey = (meta.patch or "") .. "\31" .. (meta.category or "")
				index.counts[patchKey] = (index.counts[patchKey] or 0) + 1
			end
		end
	end
	file:close()
	pairedHistoryCache = index
	return index
end

function status.ReadPairedReviewFilters(path, patch, category)
	local index, err = getPairedHistoryIndex(path)
	if not index then return nil, err end
	local skills = { }
	for key, count in pairs(index.skills) do
		local savedPatch, savedCategory, skill = key:match("^([^\31]*)\31([^\31]*)\31(.*)$")
		if skill ~= "" and (not patch or patch == "" or savedPatch == patch)
			and (not category or category == "" or savedCategory == category) then
			skills[#skills + 1] = { skill = skill, category = savedCategory, count = count }
		end
	end
	table.sort(skills, function(left, right)
		if left.skill ~= right.skill then return left.skill < right.skill end
		return tostring(left.category) < tostring(right.category)
	end)
	return { pairedReviewCount = #index.rows, skills = skills, signature = index.signature }
end

local function matchesHistoryFilter(meta, patch, category, skill)
	return (not patch or patch == "" or meta.patch == patch)
		and (not category or category == "" or meta.category == category)
		and (not skill or skill == "" or meta.skill == skill)
end

function status.ReadPairedReviewPage(path, patch, category, skill, page, pageSize)
	local index, err = getPairedHistoryIndex(path)
	if not index then return nil, err end
	pageSize = boundedInteger(pageSize or 8, 1, 50) or 8
	page = boundedInteger(page or 1, 1, 1000000) or 1
	local total = 0
	for _, meta in ipairs(index.rows) do
		if matchesHistoryFilter(meta, patch, category, skill) then total = total + 1 end
	end
	local pageCount = math.max(1, math.ceil(total / pageSize))
	page = math.min(page, pageCount)
	local firstNewest = (page - 1) * pageSize + 1
	local lastNewest = math.min(total, firstNewest + pageSize - 1)
	local rows, matched = { }, 0
	local file = io.open(path, "rb")
	if not file then return nil, "history_unavailable" end
	for indexPosition = #index.rows, 1, -1 do
		local meta = index.rows[indexPosition]
		if matchesHistoryFilter(meta, patch, category, skill) then
			matched = matched + 1
			if matched >= firstNewest and matched <= lastNewest then
				file:seek("set", meta.offset)
				local line = readBoundedLine(file)
				local row = line and line ~= false and parseLatestResult(line) or nil
				if row and row.reviewAudit and row.reviewAudit.pairedReviewCompleted == true then
					rows[#rows + 1] = row
				end
			end
		end
	end
	file:close()
	return { items = rows, total = total, page = page, pageCount = pageCount, pageSize = pageSize }
end

function status.FormatPairedReviewListRow(row)
	if type(row) ~= "table" or type(row.reviewAudit) ~= "table" then return "" end
	local identity = string.format("%s | %s%s%s%s", row.id or "—", row.patch and (row.patch .. " ") or "",
		row.skill or "skill não identificada", row.category and (" [" .. row.category .. "]") or "",
		row.ascendancy and (" / " .. row.ascendancy) or "")
	local audit = row.reviewAudit
	local sourceStatus = audit.sourceStatusLabel and (" | origem: " .. audit.sourceStatusLabel) or ""
	local line = string.format("^7%s^8%s", identity, sourceStatus)
	if audit.summary then line = line .. "\n^8" .. audit.summary end
	if audit.ideas[1] then
		local idea = audit.ideas[1]
		line = line .. "\n^8Ideia " .. idea.status .. ": " .. idea.title
		if #audit.ideas > 1 then line = line .. string.format(" (+%d)", #audit.ideas - 1) end
	end
	return line
end

function status.FormatPairedReviewDetails(row)
	if type(row) ~= "table" or type(row.reviewAudit) ~= "table" then return "Revisão pareada indisponível." end
	local lines = { }
	local audit = row.reviewAudit
	lines[#lines + 1] = string.format("ID: %s | Patch: %s | Skill: %s [%s]", row.id or "—",
		row.patch or "não confirmado", row.skill or "não identificada", row.category or "categoria desconhecida")
	if row.ascendancy then lines[#lines + 1] = "Ascendência: " .. row.ascendancy end
	if audit.sourceStatusLabel then lines[#lines + 1] = "Estado da origem: " .. audit.sourceStatusLabel end
	if #audit.reviewers > 0 then lines[#lines + 1] = "Revisores: " .. table.concat(audit.reviewers, " + ") end
	if audit.summary then lines[#lines + 1] = "Síntese: " .. audit.summary end
	if audit.validationScope then lines[#lines + 1] = "Escopo verificado: " .. audit.validationScope end
	if audit.mainSkillCoverageEligible ~= nil then lines[#lines + 1] = "Main elegível para cobertura: " .. (audit.mainSkillCoverageEligible and "sim" or "não") end
	if audit.fullBuildStatus then lines[#lines + 1] = "Estado da build completa: " .. audit.fullBuildStatus end
	lines[#lines + 1] = "Treino: " .. (audit.trainingEligible == false and "bloqueado; pareceres/hipóteses não são labels" or "não confirmado")
	for _, idea in ipairs(audit.ideas) do
		local linked = #idea.linkedSkills > 0 and (" [" .. table.concat(idea.linkedSkills, " + ") .. "]") or ""
		lines[#lines + 1] = "Hipótese " .. idea.status .. ": " .. idea.title .. linked
		if idea.testPlan then lines[#lines + 1] = "  Teste: " .. idea.testPlan end
	end
	if audit.reportPath then lines[#lines + 1] = "Relatório: " .. audit.reportPath end
	return table.concat(lines, "\n")
end

function status.ReadLatestResults(path)
	if type(path) ~= "string" or path == "" or path:find("%z") then return { } end
	local file = io.open(path, "rb")
	if not file then return { } end
	local size = file:seek("end") or 0
	local offset = math.max(0, size - MAX_RESULT_BYTES)
	if offset > 0 then
		file:seek("set", offset)
		file:read("*l") -- Discard a possibly truncated first JSONL record.
	else
		file:seek("set", 0)
	end
	local content = file:read("*a") or ""
	file:close()
	if #content > MAX_RESULT_BYTES then content = content:sub(-MAX_RESULT_BYTES) end
	local result = { }
	for line in content:gmatch("([^\r\n]+)") do
		local row = parseLatestResult(line)
		if row then
			result[#result + 1] = row
			if #result > MAX_RESULT_ROWS then table.remove(result, 1) end
		end
	end
	return result
end

function status.Read(userPath)
	if type(userPath) ~= "string" or userPath == "" or userPath:find("%z") then return nil end
	local record = status.ReadFile(userPath .. "/OptimizerStudies/BuildIngestion/status.json")
	if record then record.latestResults = status.ReadLatestResults(userPath .. "/OptimizerStudies/BuildIngestion/latest-results.jsonl") end
	return record
end

function status.FormatLatestResults(record)
	local rows = type(record) == "table" and record.latestResults or { }
	if type(rows) ~= "table" or #rows == 0 then return "^8Último lote: aguardando resultados nativos do PoB." end
	local labels = { }
	for index = math.max(1, #rows - 1), #rows do
		local row = rows[index]
		local label = (row.patch and row.patch .. " " or "") .. (row.skill or "skill não identificada")
		if row.category then label = label .. " [" .. row.category .. "]" end
		label = label .. " — " .. (row.statusLabel or "resultado")
		if row.reason then label = label .. ": " .. row.reason end
		labels[#labels + 1] = label
	end
	return "^8Últimos resultados: " .. table.concat(labels, " | ")
end

function status.FormatLatestResultsDetails(record)
	local rows = type(record) == "table" and record.latestResults or { }
	if type(rows) ~= "table" or #rows == 0 then return "Nenhum resultado PoB registrado neste lote." end
	local lines = { }
	for index = math.max(1, #rows - 11), #rows do
		local row = rows[index]
		local label = string.format("%s | %s%s%s | %s", row.id,
			row.patch and (row.patch .. " ") or "", row.skill or "skill não identificada",
			row.ascendancy and (" / " .. row.ascendancy) or "", row.statusLabel or "resultado")
		if row.reason then label = label .. " — " .. row.reason end
		lines[#lines + 1] = label
		local audit = row.reviewAudit
		if audit then
			if audit.pairedReviewCompleted then
				local originalStatus = audit.sourceStatusLabel and ("; status original: " .. audit.sourceStatusLabel) or ""
				lines[#lines + 1] = "  Par Scout/Critic concluído" .. originalStatus
			end
			if #audit.reviewers > 0 then lines[#lines + 1] = "  Revisão independente: " .. table.concat(audit.reviewers, " + ") end
			if audit.summary then lines[#lines + 1] = "  Síntese A/B: " .. audit.summary end
			if audit.validationScope then lines[#lines + 1] = "  Escopo: " .. audit.validationScope end
			if audit.mainSkillCoverageEligible ~= nil then
				lines[#lines + 1] = "  Main conta para cobertura: " .. (audit.mainSkillCoverageEligible and "sim" or "não")
			end
			if audit.fullBuildStatus then lines[#lines + 1] = "  Build completa: " .. audit.fullBuildStatus end
			if audit.trainingEligible == false then lines[#lines + 1] = "  Treino: bloqueado; revisão e hipóteses não são labels." end
			for _, idea in ipairs(audit.ideas) do
				local linked = #idea.linkedSkills > 0 and (" [" .. table.concat(idea.linkedSkills, " + ") .. "]") or ""
				lines[#lines + 1] = "  Hipótese " .. idea.status .. ": " .. idea.title .. linked
				if idea.testPlan then lines[#lines + 1] = "    Teste sugerido: " .. idea.testPlan end
			end
			if audit.reportPath then lines[#lines + 1] = "  Relatório QA: " .. audit.reportPath end
		end
	end
	return table.concat(lines, "\n")
end

function status.Format(record, nowUnix)
	if type(record) ~= "table" then return "^8Extração: sem lote ativo." end
	nowUnix = tonumber(nowUnix) or os.time()
	local age = math.max(0, math.floor(nowUnix - record.updatedAtUnix))
	if record.state == "running" then
		local staleAfter = math.max(180, record.minimumDelaySeconds * 3)
		if age > staleAfter then
			return string.format("^8Extração sem atualização há %ds; estágio: %s.", age, stages[record.stage] or stages.preflight)
		end
		local identifier = record.currentId ~= "" and record.currentId:sub(1, 18) or "—"
		return string.format("^7Extração: %s %d/%d | pedidos %d | 404 %d | ID %s",
			stages[record.stage] or stages.preflight, record.processedCount, record.totalCount,
			record.requestCount, record.notFoundCount, identifier)
	end
	if record.state == "failed" then
		return string.format("^1Última extração: falhas %d; arquivadas %d; recusadas %d; 404 %d.",
			record.failedCount, record.archivedCount, record.rejectedCount, record.notFoundCount)
	end
	return string.format("^8Última extração concluída: arquivadas %d; recusadas %d; 404 %d; falhas %d.",
		record.archivedCount, record.rejectedCount, record.notFoundCount, record.failedCount)
end

return status
