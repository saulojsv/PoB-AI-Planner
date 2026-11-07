-- Path of Building
--
-- Module: Persistent, deterministic local review pair for archived PoE builds.
-- The opportunity scout and adversarial critic are product roles implemented
-- as local rules; they are not external language models. Their hypotheses are
-- discovery records only and can never become exact results or MLP labels.

local json = require("dkjson")
local sha = require("sha2")
local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local Scout = require("Modules.Optimizer.BuildReviewScout")
local Critic = require("Modules.Optimizer.BuildReviewCritic")

local reviewPair = { }

local STORE_FOLDER = "BuildReviews"
local INDEX_FILE = "reviews.jsonl"
local REPORT_SCHEMA = "pob-ai-planner-build-review-pair"
local REPORT_SCHEMA_VERSION = 1
local REVIEW_PROTOCOL_VERSION = 11
local MAX_REPORT_BYTES = 4 * 1024 * 1024
local MAX_INDEX_LINE_BYTES = 131072
local sequence = 0
local generation = 0

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function joinPath(left, right, separator)
	local base = tostring(left or "")
	while base:sub(-1) == "/" or base:sub(-1) == "\\" do base = base:sub(1, -2) end
	return base .. separator .. right
end

local function separator()
	return package.config and package.config:sub(1, 1) or "\\"
end

local function validHash(value)
	return type(value) == "string" and #value == 64 and value:match("^[%da-f]+$") ~= nil
end

local function pathsFor(userPath)
	local archivePaths, pathError = StudyBuilds.GetPaths(userPath)
	if not archivePaths then return nil, pathError end
	local root = joinPath(archivePaths.studies, STORE_FOLDER, separator())
	return { root = root, index = joinPath(root, INDEX_FILE, separator()) }
end

local function ensureDirectory(path, createDirectory)
	if type(createDirectory) ~= "function" then return nil, "PoB's native directory creator is unavailable" end
	local ok, created, createError = pcall(createDirectory, path .. separator())
	if not ok then return nil, "Could not create build-review storage: " .. tostring(created):sub(1, 200) end
	if not created and createError ~= "No error" then
		return nil, "Could not create build-review storage: " .. tostring(createError or "unknown"):sub(1, 200)
	end
	return true
end

local function safeArray(value)
	return type(value) == "table" and value or { }
end

local function count(value)
	local total = 0
	for _ in ipairs(safeArray(value)) do total = total + 1 end
	return total
end

local function cleanText(value, maxLength)
	if type(value) ~= "string" or value == "" or #value > (maxLength or 300) or value:find("[%c]") then return nil end
	return value
end

local function effectIdFromFactor(factor)
	if type(factor) ~= "table" then return nil end
	local direct = cleanText(tostring(factor.effectId or ""), 180)
	if direct and direct ~= "" then return direct end
	return nil
end

local function addEffectId(set, value)
	local id = type(value) == "table" and effectIdFromFactor(value) or cleanText(tostring(value or ""), 180)
	if id and id ~= "" then set[id] = true end
end

local function collectEffectIds(profile, catalogEffects, scout, critic)
	local ids = { }
	for _, effect in ipairs(safeArray(profile.configuredSkillEffects)) do addEffectId(ids, effect) end
	for _, effect in ipairs(safeArray(profile.availableSkillEffects)) do addEffectId(ids, effect) end
	for _, effect in ipairs(safeArray(type(catalogEffects) == "table" and catalogEffects.effects or catalogEffects)) do addEffectId(ids, effect) end
	local function collectHypotheses(result)
		for _, idea in ipairs(safeArray(result and result.hypotheses)) do
			addEffectId(ids, idea.effectA)
			addEffectId(ids, idea.effectB)
		end
	end
	collectHypotheses(scout)
	collectHypotheses(critic)
	local result = { }
	for id in pairs(ids) do result[#result + 1] = id end
	table.sort(result)
	return result
end

local function snapshotFacts(profile)
	local facts = { }
	local character = profile.character or { }
	local engine = profile.engine or { }
	local effects = safeArray(profile.configuredSkillEffects)
	local selected = { }
	for _, effect in ipairs(effects) do
		local id = effectIdFromFactor(effect)
		if id then selected[#selected + 1] = { effectId = id, name = cleanText(effect.name or id, 120), gemId = cleanText(effect.gemId or "", 160) } end
	end
	table.sort(selected, function(left, right) return left.effectId < right.effectId end)
	local supportCount, itemCount = #safeArray(profile.supportGemIds), #safeArray(profile.itemSlots)
	facts[#facts + 1] = {
		id = "snapshot:identity",
		category = "snapshot_observation",
		source = "PoB build profile",
		status = "observed",
		title = "Identidade do snapshot",
		detail = string.format("%s; dados %s; árvore %s; personagem %s nível %s.",
			tostring(engine.pobVersion or "PoB desconhecido"), tostring(engine.dataVersion or "desconhecidos"),
			tostring(engine.treeVersion or "desconhecida"), tostring(character.class or character.classId or "classe desconhecida"),
			tostring(character.level or "desconhecido")),
	}
	facts[#facts + 1] = {
		id = "snapshot:skills",
		category = "snapshot_observation",
		source = "PoB selected/configured skill effects",
		status = "observed",
		effectIds = (function() local result = { }; for _, effect in ipairs(selected) do result[#result + 1] = effect.effectId end; return result end)(),
		title = "Skills configuradas",
		detail = #selected > 0 and table.concat((function() local result = { }; for _, effect in ipairs(selected) do result[#result + 1] = effect.name end; return result end)(), ", ") or "O snapshot não tem efeito ativo configurado.",
	}
	facts[#facts + 1] = {
		id = "snapshot:context",
		category = "snapshot_observation",
		source = "PoB build profile",
		status = "observed",
		title = "Contexto estrutural registrado",
		detail = string.format("%d efeitos configurados; %d supports ativos; %d slots de item resumidos; %d nós e %d masteries alocados.",
			#selected, supportCount, itemCount, #safeArray(profile.allocatedNodeIds), #safeArray(profile.masterySelections)),
	}
	return facts
end

local function normalizeResult(result, role)
	if type(result) ~= "table" then return nil, role .. " returned no review record" end
	if result.schemaVersion ~= 1 or result.role ~= role then return nil, role .. " returned an unsupported review contract" end
	return result
end

local function pairsObservedInProfile(profile, knownPairs)
	local result = { }
	for _, pair in ipairs(safeArray(knownPairs)) do
		if type(pair) == "table" then result[#result + 1] = pair end
	end
	local configured = { }
	for _, effect in ipairs(safeArray(profile.configuredSkillEffects)) do
		if effectIdFromFactor(effect) then configured[#configured + 1] = effect end
	end
	table.sort(configured, function(left, right)
		local a, b = effectIdFromFactor(left), effectIdFromFactor(right)
		if a ~= b then return a < b end
		return tostring(left.gemId or "") < tostring(right.gemId or "")
	end)
	for index = 1, #configured do
		for other = index + 1, #configured do
			result[#result + 1] = { effectA = configured[index], effectB = configured[other], source = "co_configured_in_this_snapshot" }
		end
	end
	return result
end

function reviewPair.Analyze(profile, catalogEffects, knownPairs, lineageHash)
	if type(profile) ~= "table" then return nil, "A PoB build profile is required" end
	if not validHash(lineageHash) then return nil, "A valid exact build-lineage SHA-256 is required" end
	local catalogRows = type(catalogEffects) == "table" and type(catalogEffects.effects) == "table"
		and catalogEffects.effects or catalogEffects
	local excludedPairs = pairsObservedInProfile(profile, knownPairs)
	local scoutOk, scoutProposal = pcall(Scout.Propose, profile, catalogRows, excludedPairs)
	if not scoutOk then return nil, "Opportunity scout failed: " .. tostring(scoutProposal):sub(1, 200) end
	local normalizedScout, scoutError = normalizeResult(scoutProposal, "opportunity_scout")
	if not normalizedScout then return nil, scoutError end

	-- The critic first produces its own idea set without seeing the scout's work.
	local independentOk, independent = pcall(Critic.Review, profile, catalogRows, excludedPairs, nil)
	if not independentOk then return nil, "Independent critic pass failed: " .. tostring(independent):sub(1, 200) end
	local normalizedIndependent, independentError = normalizeResult(independent, "adversarial_critic")
	if not normalizedIndependent then return nil, independentError end

	-- A second critic pass receives the proposal solely to challenge it; its
	-- independent hypothesis set above remains the persisted first pass.
	local challengeOk, challenge = pcall(Critic.Review, profile, catalogRows, excludedPairs, normalizedScout)
	if not challengeOk then return nil, "Cross-review critic pass failed: " .. tostring(challenge):sub(1, 200) end
	local normalizedChallenge, challengeError = normalizeResult(challenge, "adversarial_critic")
	if not normalizedChallenge then return nil, challengeError end
	local responseOk, response = pcall(Scout.Respond, profile, normalizedScout, {
		critiques = safeArray(normalizedChallenge.critiques),
		questions = safeArray(normalizedChallenge.questions),
	})
	if not responseOk then return nil, "Scout response pass failed: " .. tostring(response):sub(1, 200) end
	if type(response) ~= "table" or response.role ~= "opportunity_scout" or type(response.responses) ~= "table" then
		return nil, "Scout returned an unsupported cross-review response contract"
	end
	local relatedEffectsById = { }
	local function relate(id, left, right)
		if type(id) ~= "string" then return end
		local related = { }
		for _, factor in ipairs({ left, right }) do
			local effectId = effectIdFromFactor(factor)
			if effectId then related[#related + 1] = effectId end
		end
		relatedEffectsById[id] = related
	end
	for _, idea in ipairs(safeArray(normalizedScout.hypotheses)) do relate(idea.id, idea.effectA, idea.effectB) end
	for _, note in ipairs(safeArray(normalizedChallenge.critiques)) do
		relate(note.id, note.effectA, note.effectB)
		if not relatedEffectsById[note.id] or #relatedEffectsById[note.id] == 0 then relatedEffectsById[note.id] = note.observedEffectIds end
	end
	for _, note in ipairs(safeArray(normalizedChallenge.questions)) do
		relate(note.id, note.effectA, note.effectB)
		if not relatedEffectsById[note.id] or #relatedEffectsById[note.id] == 0 then relatedEffectsById[note.id] = note.observedEffectIds end
	end
	for _, note in ipairs(safeArray(response.responses)) do
		local related = relatedEffectsById[note.targetId] or relatedEffectsById[note.proposalId]
		if type(related) == "table" then note.effectIds = related end
	end

	local createdAt = os.time()
	local review = {
		schema = REPORT_SCHEMA,
		schemaVersion = REPORT_SCHEMA_VERSION,
		reviewerProtocolVersion = REVIEW_PROTOCOL_VERSION,
		lineageSha256 = lineageHash,
		createdAt = createdAt,
		engine = profile.engine or { },
		profileSchemaVersion = tonumber(profile.schemaVersion) or 0,
		runtime = {
			mode = "hybrid_local_pair",
			roles = { "opportunity_scout", "adversarial_critic" },
			implementation = "deterministic_local_rules",
			llmConfigured = false,
			independentCriticPass = true,
			crossExaminationPass = true,
		},
		observedFacts = snapshotFacts(profile),
		scout = normalizedScout,
		criticIndependent = normalizedIndependent,
		criticChallenge = normalizedChallenge,
		scoutResponse = response,
		exactTest = {
			status = "not_run",
			resultCount = 0,
			trainingEligible = false,
			requirement = "Cada ideia exige um estudo exato de quatro células no mesmo snapshot, cenário e identidade PoB; palpites e desacordos não são evidência causal.",
		},
		modelTraining = {
			eligible = false,
			reason = "review_opinions_are_not_exact_labels",
			topologyChanged = false,
		},
	}
	local hypotheses = count(normalizedScout.hypotheses) + count(normalizedIndependent.independentHypotheses)
	local challenges = count(normalizedChallenge.critiques) + count(normalizedChallenge.questions)
	local responses = count(response.responses)
	local effectIds = collectEffectIds(profile, catalogRows, normalizedScout, normalizedIndependent)
	return review, {
		createdAt = createdAt,
		lineageSha256 = lineageHash,
		effectIds = effectIds,
		observedFactCount = count(review.observedFacts) + count(normalizedScout.facts) + count(normalizedIndependent.facts),
		hypothesisCount = hypotheses,
		scoutCandidateCount = tonumber(normalizedScout.candidateCount) or count(normalizedScout.hypotheses),
		criticCandidateCount = tonumber(normalizedIndependent.candidateCount) or count(normalizedIndependent.independentHypotheses),
		criticIndependentIdeaCount = count(normalizedIndependent.independentHypotheses),
		scoutProposedCount = tonumber(normalizedScout.proposedCount) or count(normalizedScout.hypotheses),
		scoutUnreviewedCandidateCount = tonumber(normalizedScout.unreviewedCandidateCount) or 0,
		criticCandidateCountStatus = cleanText(tostring(normalizedIndependent.candidateCountStatus or "unknown"), 80),
		challengeCount = challenges,
		responseCount = responses,
		status = hypotheses > 0 and "reviewed_hypotheses_untested" or "reviewed_no_candidate_hypotheses",
		independentCriticPass = true,
		exactTestStatus = "not_run",
	}
end

local function profileForExplorationAnchor(profile, catalogEffects, anchorEffectId)
	if type(profile) ~= "table" or type(catalogEffects) ~= "table" then return nil, "A build profile and loaded PoB skill catalog are required" end
	anchorEffectId = cleanText(anchorEffectId, 180)
	if not anchorEffectId then return nil, "A valid active-skill effect ID is required" end
	local catalogRows = type(catalogEffects.effects) == "table" and catalogEffects.effects or catalogEffects
	local anchor
	for _, row in ipairs(safeArray(catalogRows)) do
		if type(row) == "table" and row.effectId == anchorEffectId
			and cleanText(row.gemId, 180) then
			anchor = {
				effectId = cleanText(row.effectId, 180),
				gemId = cleanText(row.gemId, 180),
				gameId = cleanText(row.gameId, 200) or "",
				variantId = cleanText(row.variantId, 200) or "",
				name = cleanText(row.effectName or row.name, 160) or anchorEffectId,
			}
			break
		end
	end
	if not anchor then return nil, "The selected effect is not in the currently loaded PoB active-skill catalog" end
	local contextGroup
	for _, group in ipairs(safeArray(profile.skillGroups)) do
		if type(group) == "table" then
			for _, skill in ipairs(safeArray(group.skills)) do
				if type(skill) == "table" and skill.selectedMainSkill == true then contextGroup = group; break end
			end
		end
		if contextGroup then break end
	end
	local anchored = { }
	for key, value in pairs(profile) do anchored[key] = value end
	anchored.configuredSkillEffects = { anchor }
	local groupEnabled = not contextGroup or contextGroup.enabled ~= false
	local groupSlotEnabled = not contextGroup or contextGroup.slotEnabled ~= false
	anchored.skillGroups = { {
		groupIndex = tonumber(contextGroup and contextGroup.groupIndex) or 1,
		selectedMainGroup = true,
		enabled = groupEnabled,
		slotEnabled = groupSlotEnabled,
		gems = contextGroup and contextGroup.gems or { },
		skills = { { skillIndex = 1, name = anchor.name, selectedMainSkill = true,
			effects = { { effectId = anchor.effectId, gemId = anchor.gemId, gameId = anchor.gameId,
				variantId = anchor.variantId, name = anchor.name, selected = true } } } },
	} }
	return anchored, anchor
end

local function explorationCard(value, role, category, detail)
	local left = type(value.effectA) == "table" and cleanText(value.effectA.name or value.effectA.effectId, 120) or ""
	local right = type(value.effectB) == "table" and cleanText(value.effectB.name or value.effectB.effectId, 120) or ""
	local title = left ~= "" and right ~= "" and (left .. " + " .. right) or cleanText(value.title or value.question or value.kind, 180) or category
	local ids = { }
	if left ~= "" and value.effectA.effectId then ids[#ids + 1] = value.effectA.effectId end
	if right ~= "" and value.effectB.effectId then ids[#ids + 1] = value.effectB.effectId end
	for _, id in ipairs(safeArray(value.observedEffectIds)) do
		id = cleanText(tostring(id), 180)
		if id then ids[#ids + 1] = id end
	end
	return { id = cleanText(value.id, 240) or category .. ":" .. tostring(#ids + 1),
		category = category, role = role, status = cleanText(value.status or "untested", 48),
		title = title, detail = cleanText(detail or value.rationale or value.reason and value.reason.summary or value.challenge or value.question, 1800) or "",
		effectA = value.effectA, effectB = value.effectB, effectIds = ids, requiredTest = value.requiredTest }
end

function reviewPair.ExploreSkillPage(profile, catalogEffects, knownPairs, anchorEffectId, cursors, pageSize)
	local anchoredProfile, anchor = profileForExplorationAnchor(profile, catalogEffects, anchorEffectId)
	if not anchoredProfile then return nil, anchor end
	pageSize = tonumber(pageSize) or 4
	if pageSize ~= math.floor(pageSize) or pageSize < 1 or pageSize > 20 then return nil, "Exploration page size must be from 1 to 20" end
	cursors = type(cursors) == "table" and cursors or { }
	local excluded = pairsObservedInProfile(anchoredProfile, knownPairs)
	local scoutResult
	if cursors.scout and cursors.scout.done == true then
		scoutResult = { schemaVersion = 1, role = "opportunity_scout", hypotheses = { },
			candidateCount = tonumber(cursors.scout.candidateCount) or 0, proposedCount = 0,
			page = { hasMore = false, nextCursor = nil, remainingAfterCursor = 0 } }
	else
		scoutResult = Scout.ProposePage(anchoredProfile, catalogEffects, excluded,
			cursors.scout and cursors.scout.cursor or nil, pageSize)
	end
	if type(scoutResult.page) ~= "table" then return nil, "Scout could not produce the requested complete-frontier page" end
	local criticOptions = { limit = pageSize,
		cursor = cursors.critic and cursors.critic.cursor or nil,
		skipIndependent = cursors.critic and cursors.critic.done == true or false }
	local criticResult, criticError = Critic.Review(anchoredProfile, catalogEffects, excluded, scoutResult, criticOptions)
	if not criticResult then return nil, criticError end
	if criticOptions.skipIndependent then
		criticResult.candidateCount = tonumber(cursors.critic and cursors.critic.candidateCount) or 0
	end
	local response = Scout.Respond(anchoredProfile, scoutResult, {
		critiques = safeArray(criticResult.critiques), questions = safeArray(criticResult.questions),
	})
	local critiqueByProposal, questionByProposal, responseByTarget = { }, { }, { }
	for _, row in ipairs(safeArray(criticResult.critiques)) do critiqueByProposal[row.proposalId] = row end
	for _, row in ipairs(safeArray(criticResult.questions)) do questionByProposal[row.proposalId] = row end
	for _, row in ipairs(safeArray(response.responses)) do responseByTarget[row.targetId] = row end
	local items = { }
	for _, hypothesis in ipairs(safeArray(scoutResult.hypotheses)) do
		local challenge, question = critiqueByProposal[hypothesis.id], questionByProposal[hypothesis.id]
		local responseText = challenge and responseByTarget[challenge.id] and responseByTarget[challenge.id].response
			or question and responseByTarget[question.id] and responseByTarget[question.id].response
		local detail = table.concat({
			"A: " .. tostring(hypothesis.reason and hypothesis.reason.summary or "exploração do catálogo"),
			challenge and "B contesta: " .. tostring(challenge.challenge or "") or "B: sem contestação gerada",
			question and "B pergunta: " .. tostring(question.question or "") or "B: sem pergunta gerada",
			responseText and "A responde: " .. tostring(responseText) or "A: resposta não disponível",
		}, " | ")
		items[#items + 1] = explorationCard(hypothesis, "Scout A + Critic B", "scout_hypothesis", detail)
	end
	for _, hypothesis in ipairs(safeArray(criticResult.independentHypotheses)) do
		items[#items + 1] = explorationCard(hypothesis, "Critic B independente", "critic_independent_hypothesis",
			tostring(hypothesis.rationale or "") .. " | Hipótese heurística; requer o factorial PoB antes de qualquer conclusão.")
	end
	local nextCursors = {
		scout = { cursor = scoutResult.page.nextCursor,
			done = scoutResult.page.hasMore ~= true,
			candidateCount = tonumber(scoutResult.candidateCount) or 0 },
		critic = { cursor = criticResult.page and criticResult.page.nextCursor or nil,
			done = not (criticResult.page and criticResult.page.hasMore == true),
			candidateCount = tonumber(criticResult.candidateCount) or 0 },
	}
	return {
		schema = "pob-ai-planner-live-skill-exploration-page", schemaVersion = 1,
		anchor = anchor, context = "current_build_structure_with_target_skill_anchor",
		catalog = { source = catalogEffects.source or "loaded_pob_gem_database",
			dataVersion = anchoredProfile.engine and anchoredProfile.engine.dataVersion,
			treeVersion = anchoredProfile.engine and anchoredProfile.engine.treeVersion,
			exactEvaluation = false },
		items = items,
		counts = { scoutCandidates = tonumber(scoutResult.candidateCount) or 0,
			scoutShown = count(scoutResult.hypotheses), criticCandidates = tonumber(criticResult.candidateCount) or 0,
			criticShown = count(criticResult.independentHypotheses),
			critiques = count(criticResult.critiques), questions = count(criticResult.questions),
			responses = count(response.responses), exactTests = 0, trainingLabels = 0 },
		pages = { scout = scoutResult.page, critic = criticResult.page,
			hasMore = scoutResult.page.hasMore == true or criticResult.page and criticResult.page.hasMore == true },
		nextCursors = nextCursors,
		reviewers = { "opportunity_scout", "adversarial_critic" },
		exactTestStatus = "ideas_unverified_until_exact_factorial",
		modelTraining = { eligible = false, topologyChanged = false, reason = "heuristic_ideas_are_not_exact_labels" },
	}
end

local function readIndex(path)
	local file, openError = io.open(path, "rb")
	if not file then
		local message = tostring(openError or ""):lower()
		if message:find("no such file", 1, true) or message:find("cannot find", 1, true)
			or message:find("does not exist", 1, true) or message:find("system cannot find", 1, true) then return { } end
		return nil, "Could not read build-review index: " .. tostring(openError):sub(1, 200)
	end
	local rows, lineNumber = { }, 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if #line > MAX_INDEX_LINE_BYTES then file:close(); return nil, "Build-review index row exceeds its safety limit at line " .. lineNumber end
		if line ~= "" then
			local ok, row = pcall(json.decode, line)
			if not ok or type(row) ~= "table" or row.recordType ~= "build_review_pair_index"
				or row.schemaVersion ~= 1 or not validHash(row.lineageSha256)
				or not validHash(row.reportSha256) or type(row.report) ~= "string"
				or type(row.effectIds) ~= "table"
				or row.reviewerProtocolVersion ~= nil and (not isFinite(tonumber(row.reviewerProtocolVersion))
					or tonumber(row.reviewerProtocolVersion) < 1 or tonumber(row.reviewerProtocolVersion) ~= math.floor(tonumber(row.reviewerProtocolVersion))) then
				file:close(); return nil, "Build-review index contains an invalid record at line " .. lineNumber
			end
			rows[#rows + 1] = row
		end
	end
	file:close()
	return rows
end

local function readReport(paths, indexRow)
	local path = joinPath(paths.root, indexRow.report, separator())
	local file, openError = io.open(path, "rb")
	if not file then return nil, "Review report is missing: " .. tostring(openError):sub(1, 160) end
	local size = file:seek("end") or 0
	file:seek("set", 0)
	local payload = size <= MAX_REPORT_BYTES and file:read("*a") or nil
	file:close()
	if type(payload) ~= "string" or sha.sha256(payload) ~= indexRow.reportSha256 then return nil, "Review report failed its SHA-256 or size check" end
	local ok, report = pcall(json.decode, payload)
	if not ok or type(report) ~= "table" or report.schema ~= REPORT_SCHEMA
		or report.schemaVersion ~= REPORT_SCHEMA_VERSION or report.lineageSha256 ~= indexRow.lineageSha256 then
		return nil, "Review report has an invalid schema or lineage"
	end
	return report
end

local function writeReport(path, payload, digest)
	local existing = io.open(path, "rb")
	if existing then
		local size = existing:seek("end") or 0
		existing:seek("set", 0)
		local current = size <= MAX_REPORT_BYTES and existing:read("*a") or nil
		existing:close()
		if type(current) == "string" and sha.sha256(current) == digest then return true, "duplicate" end
		return nil, "An existing content-addressed review report failed its SHA-256 check"
	end
	sequence = sequence + 1
	local tempPath = path .. ".tmp-" .. tostring(os.time()) .. "-" .. tostring(sequence)
	local file, openError = io.open(tempPath, "wb")
	if not file then return nil, "Could not create review report: " .. tostring(openError):sub(1, 200) end
	local wrote, writeError = file:write(payload)
	local flushed, flushError = wrote and file:flush()
	local closed, closeError = file:close()
	if not wrote or not flushed or not closed then
		os.remove(tempPath)
		return nil, "Could not write review report: " .. tostring(writeError or flushError or closeError or "write failed"):sub(1, 200)
	end
	local renamed, renameError = os.rename(tempPath, path)
	if renamed then return true, "stored" end
	os.remove(tempPath)
	local verify = io.open(path, "rb")
	if verify then
		local current = verify:read("*a")
		verify:close()
		if type(current) == "string" and sha.sha256(current) == digest then return true, "duplicate" end
	end
	return nil, "Could not finalize review report: " .. tostring(renameError or "rename failed"):sub(1, 200)
end

local function appendIndex(path, row)
	local encoded, encodeError = json.encode(row)
	if type(encoded) ~= "string" or #encoded > MAX_INDEX_LINE_BYTES then
		return nil, "The build-review index row exceeds its safety limit: " .. tostring(encodeError or "row too large")
	end
	local file, openError = io.open(path, "ab")
	if not file then return nil, "Could not append build-review index: " .. tostring(openError):sub(1, 200) end
	local wrote, writeError = file:write(encoded, "\n")
	local flushed, flushError = wrote and file:flush()
	local closed, closeError = file:close()
	if not wrote or not flushed or not closed then
		return nil, "Could not persist build-review index: " .. tostring(writeError or flushError or closeError or "write failed"):sub(1, 200)
	end
	return true
end

local function indexRowFromReview(review, profile, catalogRows, reportFile, reportHash)
	local scout = review.scout or { }
	local independent = review.criticIndependent or { }
	local challenge = review.criticChallenge or { }
	local response = review.scoutResponse or { }
	local hypotheses = count(scout.hypotheses) + count(independent.independentHypotheses)
	local challenges = count(challenge.critiques) + count(challenge.questions)
	return {
		recordType = "build_review_pair_index",
		schemaVersion = 1,
		reviewerProtocolVersion = tonumber(review.reviewerProtocolVersion) or 1,
		lineageSha256 = review.lineageSha256,
		archiveObservation = review.archiveObservation,
		report = reportFile,
		reportSha256 = reportHash,
		createdAt = tonumber(review.createdAt) or os.time(),
		effectIds = collectEffectIds(profile, catalogRows, scout, independent),
		observedFactCount = count(review.observedFacts) + count(scout.facts) + count(independent.facts),
		hypothesisCount = hypotheses,
		challengeCount = challenges,
		responseCount = count(response.responses),
		status = hypotheses > 0 and "reviewed_hypotheses_untested" or "reviewed_no_candidate_hypotheses",
		independentCriticPass = true,
		exactTestStatus = "not_run",
		scoutCandidateCount = tonumber(review.scout and review.scout.candidateCount) or count(scout.hypotheses),
		scoutProposedCount = tonumber(review.scout and review.scout.proposedCount) or count(scout.hypotheses),
		scoutUnreviewedCandidateCount = tonumber(review.scout and review.scout.unreviewedCandidateCount) or 0,
		criticCandidateCount = tonumber(independent.candidateCount) or count(independent.independentHypotheses),
		criticIndependentIdeaCount = count(independent.independentHypotheses),
		criticCandidateCountStatus = cleanText(tostring(independent.candidateCountStatus or "unknown"), 80),
	}
end

local function latestRows(rows)
	local latestByLineage = { }
	for _, row in ipairs(rows or { }) do
		local current = latestByLineage[row.lineageSha256]
		local version, currentVersion = tonumber(row.reviewerProtocolVersion) or 1,
			current and (tonumber(current.reviewerProtocolVersion) or 1) or 0
		if not current or version > currentVersion
			or version == currentVersion and (tonumber(row.createdAt) or 0) > (tonumber(current.createdAt) or 0)
			or version == currentVersion and (tonumber(row.createdAt) or 0) == (tonumber(current.createdAt) or 0)
				and tostring(row.reportSha256) > tostring(current.reportSha256) then
			latestByLineage[row.lineageSha256] = row
		end
	end
	local result = { }
	for _, row in pairs(latestByLineage) do result[#result + 1] = row end
	return result
end

local function archivedReviewRows(userPath, rows)
	local archivedLineages, archiveError = StudyBuilds.ArchivedLineages(userPath)
	if not archivedLineages then return nil, archiveError end
	local result = { }
	for _, row in ipairs(latestRows(rows)) do
		if archivedLineages[row.lineageSha256:lower()] then result[#result + 1] = row end
	end
	return result
end

function reviewPair.Process(profile, catalogEffects, knownPairs, userPath, lineageHash, createDirectory, archiveObservation)
	if not validHash(lineageHash) then return nil, "A valid exact build-lineage SHA-256 is required" end
	local paths, pathError = pathsFor(userPath)
	if not paths then return nil, pathError end
	local archivedLineages, archiveError = StudyBuilds.ArchivedLineages(userPath)
	if not archivedLineages then return nil, archiveError end
	if not archivedLineages[lineageHash:lower()] then
		return nil, "The exact build lineage must exist in the local build archive before review"
	end
	local archiveIdentity
	if archiveObservation ~= nil then
		if type(archiveObservation) ~= "table" or not validHash(archiveObservation.observationId)
			or not validHash(archiveObservation.xmlSha256) or archiveObservation.lineageSha256 ~= lineageHash
			or type(archiveObservation.source) ~= "table"
			or not cleanText(archiveObservation.source.reference or "", 1024) then
			return nil, "The archive observation identity does not match the review lineage"
		end
		archiveIdentity = {
			observationId = archiveObservation.observationId,
			xmlSha256 = archiveObservation.xmlSha256,
			lineageSha256 = archiveObservation.lineageSha256,
			sourceReference = archiveObservation.source.reference,
			sourceProvider = cleanText(archiveObservation.source.provider or "", 80),
			sourceLabel = cleanText(archiveObservation.source.label or "", 120),
		}
	end
	local created, createError = ensureDirectory(paths.root, createDirectory)
	if not created then return nil, createError end
	local rows, indexError = readIndex(paths.index)
	if not rows then return nil, indexError end
	for _, row in ipairs(latestRows(rows)) do
		if row.lineageSha256 == lineageHash and (tonumber(row.reviewerProtocolVersion) or 1) >= REVIEW_PROTOCOL_VERSION then
			local report, reportError = readReport(paths, row)
			if not report then return nil, reportError end
			return { status = "already_reviewed", lineageSha256 = lineageHash,
				hypothesisCount = row.hypothesisCount, challengeCount = row.challengeCount,
				responseCount = row.responseCount,
				reportPath = joinPath(paths.root, row.report, separator()), generation = generation }
		end
	end
	local catalogRows = type(catalogEffects) == "table" and type(catalogEffects.effects) == "table"
		and catalogEffects.effects or catalogEffects
	local reportFile = lineageHash .. "-review-v" .. tostring(REVIEW_PROTOCOL_VERSION) .. ".json"
	local reportPath = joinPath(paths.root, reportFile, separator())
	-- Recover the uncommon crash window where the immutable report was written
	-- but the small index append did not complete.
	local orphan = io.open(reportPath, "rb")
	if orphan then
		local size = orphan:seek("end") or 0
		orphan:seek("set", 0)
		local payload = size <= MAX_REPORT_BYTES and orphan:read("*a") or nil
		orphan:close()
		if type(payload) ~= "string" then return nil, "An orphaned review report exceeds the size limit" end
		local reportHash = sha.sha256(payload)
		local decodedOk, oldReview = pcall(json.decode, payload)
		if not decodedOk or type(oldReview) ~= "table" or oldReview.schema ~= REPORT_SCHEMA
			or oldReview.schemaVersion ~= REPORT_SCHEMA_VERSION or oldReview.lineageSha256 ~= lineageHash
			or tonumber(oldReview.reviewerProtocolVersion) ~= REVIEW_PROTOCOL_VERSION then
			return nil, "An orphaned review report has an invalid schema or lineage"
		end
		local recovered = indexRowFromReview(oldReview, profile, catalogRows, reportFile, reportHash)
		local appended, appendError = appendIndex(paths.index, recovered)
		if not appended then return nil, appendError end
		generation = generation + 1
		return { status = "recovered_review_index", lineageSha256 = lineageHash,
			hypothesisCount = recovered.hypothesisCount, challengeCount = recovered.challengeCount,
			reportPath = reportPath, storageStatus = "recovered", generation = generation }
	end
	local review, summary = reviewPair.Analyze(profile, catalogEffects, knownPairs, lineageHash)
	if not review then return nil, summary end
	review.archiveObservation = archiveIdentity
	local ok, payload = pcall(json.encode, review)
	if not ok or type(payload) ~= "string" or #payload > MAX_REPORT_BYTES then
		return nil, "The paired review could not be encoded within the 4 MiB report limit"
	end
	local reportHash = sha.sha256(payload)
	local stored, storageStatus = writeReport(reportPath, payload, reportHash)
	if not stored then return nil, storageStatus end
	local indexRow = indexRowFromReview(review, profile, catalogRows, reportFile, reportHash)
	local appended, appendError = appendIndex(paths.index, indexRow)
	if not appended then return nil, appendError end
	generation = generation + 1
	return { status = summary.status, lineageSha256 = lineageHash,
		hypothesisCount = summary.hypothesisCount, challengeCount = summary.challengeCount,
		responseCount = summary.responseCount, reportPath = reportPath,
		storageStatus = storageStatus, generation = generation }
end

function reviewPair.Summary(userPath)
	local paths, pathError = pathsFor(userPath)
	if not paths then return nil, pathError end
	local rows, indexError = readIndex(paths.index)
	if not rows then return nil, indexError end
	rows, indexError = archivedReviewRows(userPath, rows)
	if not rows then return nil, indexError end
	local summary = {
		schema = "pob-ai-planner-build-review-summary",
		schemaVersion = 1,
		storage = { root = paths.root, index = paths.index, reviewedLineages = #rows },
		roles = { opportunityScout = "local deterministic opportunity proposer", adversarialCritic = "local deterministic independent reviewer and challenger" },
		counts = { facts = 0, hypotheses = 0, critiquesAndQuestions = 0, responses = 0, exactTests = 0,
			pendingExactTests = 0, disagreements = 0, scoutCandidates = 0, scoutProposed = 0,
			scoutUnreviewedCandidates = 0, criticCandidates = 0, criticIndependentIdeas = 0,
			criticUnreviewedCandidates = 0 },
		byEffect = { },
		model = { trainingEligible = false, trainingCount = 0, topologyChanged = false },
	}
	for _, row in ipairs(rows) do
		summary.counts.facts = summary.counts.facts + (tonumber(row.observedFactCount) or 0)
		summary.counts.hypotheses = summary.counts.hypotheses + (tonumber(row.hypothesisCount) or 0)
		summary.counts.critiquesAndQuestions = summary.counts.critiquesAndQuestions + (tonumber(row.challengeCount) or 0)
		summary.counts.responses = summary.counts.responses + (tonumber(row.responseCount) or 0)
		summary.counts.scoutCandidates = summary.counts.scoutCandidates + (tonumber(row.scoutCandidateCount) or 0)
		summary.counts.scoutProposed = summary.counts.scoutProposed
			+ (tonumber(row.scoutProposedCount) or tonumber(row.scoutCandidateCount) or 0)
		summary.counts.scoutUnreviewedCandidates = summary.counts.scoutUnreviewedCandidates + (tonumber(row.scoutUnreviewedCandidateCount) or 0)
		summary.counts.criticCandidates = summary.counts.criticCandidates + (tonumber(row.criticCandidateCount) or 0)
		summary.counts.criticIndependentIdeas = summary.counts.criticIndependentIdeas + (tonumber(row.criticIndependentIdeaCount) or 0)
		summary.counts.criticUnreviewedCandidates = summary.counts.criticUnreviewedCandidates
			+ math.max(0, (tonumber(row.criticCandidateCount) or 0) - (tonumber(row.criticIndependentIdeaCount) or 0))
		if row.exactTestStatus == "exact_tested" then summary.counts.exactTests = summary.counts.exactTests + 1
		else summary.counts.pendingExactTests = summary.counts.pendingExactTests + (tonumber(row.hypothesisCount) or 0) end
		if (tonumber(row.challengeCount) or 0) > 0 then summary.counts.disagreements = summary.counts.disagreements + 1 end
		for _, id in ipairs(row.effectIds or { }) do
			summary.byEffect[id] = summary.byEffect[id] or { builds = 0, facts = 0, hypotheses = 0, challenges = 0 }
			local effect = summary.byEffect[id]
			effect.builds = effect.builds + 1
			effect.facts = effect.facts + (tonumber(row.observedFactCount) or 0)
			effect.hypotheses = effect.hypotheses + (tonumber(row.hypothesisCount) or 0)
			effect.challenges = effect.challenges + (tonumber(row.challengeCount) or 0)
		end
	end
	return summary
end

local function recordMatchesEffect(row, effectId)
	if not effectId or effectId == "" then return true end
	for _, id in ipairs(row.effectIds or { }) do if id == effectId then return true end end
	return false
end

local function filterCardByEffect(card, effectId)
	if not effectId or effectId == "" then return true end
	for _, id in ipairs(card.effectIds or { }) do if id == effectId then return true end end
	return false
end

local FACT_TITLES = {
	configured_skill_effects = "Skills configuradas no snapshot",
	enabled_skill_groups = "Grupos de skills habilitados",
	selected_effect_count_by_groups = "Efeitos selecionados nos grupos",
	configured_support_gem_count = "Quantidade de supports configurados",
	allocated_passive_node_count = "Nós passivos alocados",
	configured_item_slot_count = "Slots de equipamento resumidos",
	selected_main_skill_effect = "Main Skill selecionada",
	character_class = "Classe observada",
	character_level = "Nível observado",
}

local function factValueText(value)
	if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then return tostring(value) end
	if type(value) ~= "table" then return "" end
	local values = { }
	for _, row in ipairs(value) do
		if type(row) == "table" then
			local name = cleanText(row.name or row.effectName or row.effectId or row.gemId or "", 120)
			if name then values[#values + 1] = name end
		end
	end
	if #values > 0 then return table.concat(values, ", ") end
	local name = cleanText(value.name or value.effectName or value.effectId or value.gemId or "", 120)
	if name then return name end
	local ok, encoded = pcall(json.encode, value)
	return ok and cleanText(encoded, 600) or ""
end

local function collectCardEffectIds(card)
	local ids, seen = { }, { }
	local function add(id)
		id = cleanText(tostring(id or ""), 180)
		if id and id ~= "" and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
	end
	for _, id in ipairs(card.effectIds or { }) do add(id) end
	for _, id in ipairs(card.observedEffectIds or { }) do add(id) end
	add(card.effectId)
	if type(card.value) == "table" then
		add(effectIdFromFactor(card.value))
		for _, row in ipairs(card.value) do add(effectIdFromFactor(row)) end
	end
	add(effectIdFromFactor(card.effectA)); add(effectIdFromFactor(card.effectB))
	add(effectIdFromFactor(card.anchor)); add(effectIdFromFactor(card.candidate))
	return ids
end

local function addCards(target, source, role, category, lineageHash, createdAt, effectId, maxDetail)
	for _, value in ipairs(safeArray(source)) do
		if type(value) == "table" then
			local effectAName = type(value.effectA) == "table" and cleanText(value.effectA.name or value.effectA.effectName or value.effectA.effectId, 120)
			local effectBName = type(value.effectB) == "table" and cleanText(value.effectB.name or value.effectB.effectName or value.effectB.effectId, 120)
			local kind = cleanText(tostring(value.kind or ""), 100)
			local title = value.title or value.question or value.summary or value.name
			if not title and effectAName and effectBName then title = effectAName .. " + " .. effectBName end
			if not title and kind then title = FACT_TITLES[kind:gsub("^observed:", "")] or kind:gsub("_", " ") end
			local detail = value.detail or value.rationale or value.summary or value.challenge or value.question or value.response
			if not detail and value.reason and type(value.reason) == "table" then detail = value.reason.summary end
			if not detail and value.value ~= nil then detail = factValueText(value.value) end
			local card = {
				id = cleanText(tostring(value.id or ""), 240) or (category .. ":" .. tostring(#target + 1)),
				category = category,
				role = role,
				status = cleanText(tostring(value.status or (category == "observed_fact" and "observed" or "untested")), 48),
				title = cleanText(tostring(title or category), 180),
				detail = cleanText(tostring(detail or ""), maxDetail or 900) or "",
				effectA = value.effectA,
				effectB = value.effectB,
				effectId = value.effectId or value.anchorEffectId,
				value = value.value,
				factorIds = value.factorIds,
				observedEffectIds = value.observedEffectIds,
				proposalId = value.proposalId,
				targetId = value.targetId,
				requiredTest = value.requiredTest,
				lineageSha256 = lineageHash,
				createdAt = createdAt,
			}
			card.effectIds = collectCardEffectIds(value)
			if filterCardByEffect(card, effectId) then target[#target + 1] = card end
		end
	end
end

local function reportCards(report, section)
	local result = { }
	local function attachArchiveIdentity()
		local archive = type(report.archiveObservation) == "table" and report.archiveObservation or { }
		for _, card in ipairs(result) do
			card.archiveObservationId = archive.observationId
			card.xmlSha256 = archive.xmlSha256
			card.sourceReference = archive.sourceReference
			card.sourceProvider = archive.sourceProvider
			card.sourceLabel = archive.sourceLabel
		end
	end
	if section == "facts" then
		addCards(result, report.observedFacts, "PoB snapshot", "observed_fact", report.lineageSha256, report.createdAt)
		addCards(result, report.scout and report.scout.facts, "Oportunista A", "observed_fact", report.lineageSha256, report.createdAt)
		addCards(result, report.criticIndependent and report.criticIndependent.facts, "Crítico B", "observed_fact", report.lineageSha256, report.createdAt)
		attachArchiveIdentity()
		return result
	end
	local critiquesByProposal, questionsByProposal, responseByTarget = { }, { }, { }
	for _, critique in ipairs(safeArray(report.criticChallenge and report.criticChallenge.critiques)) do
		if type(critique) == "table" and type(critique.proposalId) == "string" then critiquesByProposal[critique.proposalId] = critique end
	end
	for _, question in ipairs(safeArray(report.criticChallenge and report.criticChallenge.questions)) do
		if type(question) == "table" and type(question.proposalId) == "string" then questionsByProposal[question.proposalId] = question end
	end
	for _, response in ipairs(safeArray(report.scoutResponse and report.scoutResponse.responses)) do
		if type(response) == "table" and type(response.targetId) == "string" then responseByTarget[response.targetId] = response end
	end
	local debates, proposalIds = { }, { }
	for _, proposal in ipairs(safeArray(report.scout and report.scout.hypotheses)) do
		if type(proposal) == "table" then
			local challenge = critiquesByProposal[proposal.id]
			local question = questionsByProposal[proposal.id]
			local challengeResponse = challenge and responseByTarget[challenge.id]
			local questionResponse = question and responseByTarget[question.id]
			local parts = { "A propõe: " .. tostring(proposal.reason and proposal.reason.summary or "exploração do catálogo PoB") }
			if challenge then parts[#parts + 1] = "B contesta: " .. tostring(challenge.challenge or "sem objeção registada") end
			if question then parts[#parts + 1] = "B pergunta: " .. tostring(question.question or "pergunta em aberto") end
			if challengeResponse then parts[#parts + 1] = "A responde à objeção: " .. tostring(challengeResponse.response or "aguarda teste exato") end
			if questionResponse then parts[#parts + 1] = "A responde à pergunta: " .. tostring(questionResponse.response or "aguarda teste exato") end
			proposal.detail = table.concat(parts, " | ")
			proposal.status = "untested"
			proposalIds[proposal.id] = true
			debates[#debates + 1] = proposal
		end
	end
	addCards(result, debates, "Discussão local A/B", "idea_debate", report.lineageSha256, report.createdAt, nil, 1800)
	addCards(result, report.criticIndependent and report.criticIndependent.independentHypotheses,
		"Crítico B independente", "independent_hypothesis", report.lineageSha256, report.createdAt)
	local openQuestions = { }
	for _, question in ipairs(safeArray(report.criticChallenge and report.criticChallenge.questions)) do
		if type(question) == "table" and not proposalIds[question.proposalId] then openQuestions[#openQuestions + 1] = question end
	end
	addCards(result, openQuestions, "Crítico B — pergunta", "open_question", report.lineageSha256, report.createdAt)
	attachArchiveIdentity()
	return result
end

function reviewPair.ListPage(userPath, section, effectId, page, pageSize)
	if section ~= "facts" and section ~= "ideas" then return nil, "Section must be facts or ideas" end
	page, pageSize = tonumber(page) or 1, tonumber(pageSize) or 8
	if not isFinite(page) or page < 1 or page ~= math.floor(page) or page > 1000000 then return nil, "Page must be a positive integer" end
	if not isFinite(pageSize) or pageSize < 1 or pageSize ~= math.floor(pageSize) or pageSize > 20 then return nil, "Page size must be an integer from 1 to 20" end
	if effectId ~= nil and (type(effectId) ~= "string" or #effectId > 180 or effectId:find("[%c]")) then return nil, "Effect filter is invalid" end
	local paths, pathError = pathsFor(userPath)
	if not paths then return nil, pathError end
	local rows, indexError = readIndex(paths.index)
	if not rows then return nil, indexError end
	rows, indexError = archivedReviewRows(userPath, rows)
	if not rows then return nil, indexError end
	table.sort(rows, function(left, right) return (tonumber(left.createdAt) or 0) > (tonumber(right.createdAt) or 0) end)
	local startIndex, endIndex = (page - 1) * pageSize + 1, page * pageSize
	local total, items, brokenReports = 0, { }, 0
	for _, row in ipairs(rows) do
		if recordMatchesEffect(row, effectId) then
			local report, reportError = readReport(paths, row)
			if report then
				local cards = reportCards(report, section)
				for _, card in ipairs(cards) do
					if filterCardByEffect(card, effectId) then
						total = total + 1
						if total >= startIndex and total <= endIndex then items[#items + 1] = card end
					end
				end
			else
				brokenReports = brokenReports + 1
			end
		end
	end
	return { schema = "pob-ai-planner-build-review-page", schemaVersion = 1,
		section = section, effectId = effectId, page = page, pageSize = pageSize,
		total = total, pageCount = math.max(1, math.ceil(total / pageSize)),
		items = items, brokenReports = brokenReports, exactTestStatus = "ideas_unverified_until_exact_factorial" }
end

function reviewPair.Generation()
	return generation
end

return reviewPair
