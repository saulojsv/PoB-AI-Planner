local BuildIngestionStatus = require("Modules.Optimizer.BuildIngestionStatus")
local json = require("dkjson")

local function progress(overrides)
	local record = {
		schema = "pob-ai-planner-build-ingestion-progress",
		schemaVersion = 1,
		state = "running",
		stage = "fetching_code",
		updatedAtUnix = 1792861200,
		totalCount = 7,
		processedCount = 2,
		requestCount = 4,
		archivedCount = 0,
		rejectedCount = 0,
		notFoundCount = 0,
		failedCount = 0,
		minimumDelaySeconds = 60,
		currentId = "abc_123-xy",
		code = "must not escape the status projection",
		sourceUrl = "https://example.invalid/private",
	}
	for key, value in pairs(overrides or { }) do record[key] = value end
	return record
end

describe("Optimizer build-ingestion live status", function()
	it("projects only bounded progress fields and never exposes code or source URL", function()
		local record = BuildIngestionStatus.Parse(assert(json.encode(progress())))
		assert.is_truthy(record)
		assert.are.equal("running", record.state)
		assert.are.equal(2, record.processedCount)
		assert.are.equal(0, record.notFoundCount)
		assert.are.equal("abc_123-xy", record.currentId)
		assert.is_nil(record.code)
		assert.is_nil(record.sourceUrl)
	end)

	it("reads a small progress file from the configured local status path", function()
		local path = os.tmpname() .. "-pob-ingestion-status.json"
		local file = assert(io.open(path, "wb"))
		assert.is_truthy(file:write(assert(json.encode(progress()))))
		assert.is_truthy(file:close())
		local record = BuildIngestionStatus.ReadFile(path)
		assert.is_truthy(os.remove(path))
		assert.is_truthy(record)
		assert.are.equal("fetching_code", record.stage)
		assert.are.equal(7, record.totalCount)
	end)

	it("reads the sidecar from OptimizerStudies/BuildIngestion at the PoB user path", function()
		local originalReadFile = BuildIngestionStatus.ReadFile
		local capturedPath
		BuildIngestionStatus.ReadFile = function(path)
			capturedPath = path
			return { state = "running" }
		end
		local ok, result = pcall(BuildIngestionStatus.Read, "C:/Users/test/Documents/Path of Building")
		BuildIngestionStatus.ReadFile = originalReadFile
		assert.is_true(ok)
		assert.is_truthy(result)
		assert.are.equal("C:/Users/test/Documents/Path of Building/OptimizerStudies/BuildIngestion/status.json", capturedPath)
	end)

	it("formats active extraction progress without leaking arbitrary source text", function()
		local record = BuildIngestionStatus.Parse(assert(json.encode(progress({ title = "malicious ^1 label" }))))
		local text = BuildIngestionStatus.Format(record, record.updatedAtUnix + 30)
		assert.are.equal("^7Extração: extraindo código 2/7 | pedidos 4 | 404 0 | ID abc_123-xy", text)
		assert.is_false(text:find("malicious", 1, true) ~= nil)
	end)

	it("marks stale work visibly instead of claiming a live request", function()
		local record = BuildIngestionStatus.Parse(assert(json.encode(progress())))
		local text = BuildIngestionStatus.Format(record, record.updatedAtUnix + 181)
		assert.is_truthy(text:find("sem atualização", 1, true))
	end)

	it("summarizes completed and failed imports with separate counters", function()
		local complete = BuildIngestionStatus.Parse(assert(json.encode(progress({
			state = "completed", stage = "completed", archivedCount = 3, rejectedCount = 4, notFoundCount = 1,
		}))))
		local failed = BuildIngestionStatus.Parse(assert(json.encode(progress({
			state = "failed", stage = "failed", archivedCount = 2, rejectedCount = 3, notFoundCount = 1, failedCount = 2,
		}))))
		assert.are.equal("^8Última extração concluída: arquivadas 3; recusadas 4; 404 1; falhas 0.",
			BuildIngestionStatus.Format(complete, complete.updatedAtUnix))
		assert.are.equal("^1Última extração: falhas 2; arquivadas 2; recusadas 3; 404 1.",
			BuildIngestionStatus.Format(failed, failed.updatedAtUnix))
	end)

	it("reads bounded live result rows and exposes only safe PoB identity fields", function()
		local path = os.tmpname() .. "-pob-ingestion-results.jsonl"
		local file = assert(io.open(path, "wb"))
		file:write(assert(json.encode({ schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
			id = "abc_123-xy", status = "target_gate_rejected", reason = "event_secondary_ascendancy",
			patch = "3.28", skill = "Arc^1 of Oscillating | raw", category = "transfigured", ascendancy = "Inquisitor" })), "\n")
		file:write(assert(json.encode({ schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
			id = "bad-code", status = "unexpected_source_text", skill = "must not display" })), "\n")
		file:close()
		local rows = BuildIngestionStatus.ReadLatestResults(path)
		assert.is_truthy(os.remove(path))
		assert.are.equal(1, #rows)
		assert.are.equal("3.28", rows[1].patch)
		assert.are.equal("transfigured", rows[1].category)
		assert.are.equal("Arc1 of Oscillating raw", rows[1].skill)
		assert.are.equal("ascendência secundária de evento", rows[1].reason)
		local record = { latestResults = rows }
		local summary = BuildIngestionStatus.FormatLatestResults(record)
		assert.is_truthy(summary:find("3.28 Arc1 of Oscillating raw [transfigured] — fora do escopo", 1, true))
		assert.is_false(summary:find("^1", 1, true) ~= nil)
		assert.is_truthy(BuildIngestionStatus.FormatLatestResultsDetails(record):find("abc_123-xy", 1, true))
	end)

	it("projects the approved 3.24–3.29 patch range and retains historical rejection labels", function()
		local path = os.tmpname() .. "-pob-ingestion-historical-patches.jsonl"
		local file = assert(io.open(path, "wb"))
		file:write(assert(json.encode({ schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
			id = "historical_324", status = "target_gate_rejected", patch = "3.24",
			reason = "tree_not_in_3_26_to_3_29", skill = "Splitting Steel of Ammunition", category = "transfigured" })), "\n")
		file:write(assert(json.encode({ schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
			id = "historical_325", status = "target_gate_rejected", patch = "3.25",
			reason = "tree_not_in_3_24_to_3_29", skill = "Lacerate", category = "normal" })), "\n")
		file:write(assert(json.encode({ schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
			id = "unsupported_old", status = "target_gate_rejected", patch = "3.23",
			reason = "tree_not_in_3_24_to_3_29" })), "\n")
		file:close()
		local rows = BuildIngestionStatus.ReadLatestResults(path)
		assert.is_truthy(os.remove(path))
		assert.are.equal(3, #rows)
		assert.are.equal("3.24", rows[1].patch)
		assert.are.equal("rejeitada pelo escopo antigo 3.26–3.29", rows[1].reason)
		assert.are.equal("3.25", rows[2].patch)
		assert.are.equal("árvore fora de 3.24–3.29", rows[2].reason)
		assert.is_nil(rows[3].patch)
	end)

	it("shows bounded independent reviewer findings and untested build ideas in dashboard details", function()
		local path = os.tmpname() .. "-pob-ingestion-review-audit.jsonl"
		local file = assert(io.open(path, "wb"))
		file:write(assert(json.encode({ schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
			id = "reviewed_build", status = "reviewed", patch = "3.28", skill = "Summon Raging Spirit",
			reviewAudit = {
				reviewers = { "Scout", "Critic" }, summary = "Disabled gem remains in socket ordinal",
				pairedReviewCompleted = true, sourceStatus = "target_gate_rejected",
				reportPath = "docs/optimizer/QA_PUBLIC_BUILD_CROSS_REVIEW_ROUND9_2026-10-25.md",
				validationScope = "main_skill_group_only", mainSkillCoverageEligible = false,
				fullBuildStatus = "quarantined", trainingEligible = false,
				ideas = { { title = "SRS + Flame Golem", status = "untested",
					linkedSkills = { "Summon Raging Spirit", "Summon Flame Golem" },
					testPlan = "Compare 2 x 2 with fixed tree, gear and target." } },
				sourceUrl = "https://secret.invalid/build", rawXml = "secret xml", code = "secret code",
			},
		})), "\n")
		file:close()
		local rows = BuildIngestionStatus.ReadLatestResults(path)
		assert.is_truthy(os.remove(path))
		assert.are.equal(1, #rows)
		assert.are.equal("Scout", rows[1].reviewAudit.reviewers[1])
		assert.is_true(rows[1].reviewAudit.pairedReviewCompleted)
		assert.are.equal("target_gate_rejected", rows[1].reviewAudit.sourceStatus)
		assert.are.equal(false, rows[1].reviewAudit.mainSkillCoverageEligible)
		assert.are.equal("untested", rows[1].reviewAudit.ideas[1].status)
		local details = BuildIngestionStatus.FormatLatestResultsDetails({ latestResults = rows })
		assert.is_truthy(details:find("Revisão independente: Scout + Critic", 1, true))
		assert.is_truthy(details:find("Par Scout/Critic concluído; status original: fora do escopo", 1, true))
		assert.is_truthy(details:find("Hipótese untested: SRS + Flame Golem", 1, true))
		assert.is_truthy(details:find("Main conta para cobertura: não", 1, true))
		assert.is_truthy(details:find("Treino: bloqueado", 1, true))
		assert.is_truthy(details:find("QA_PUBLIC_BUILD_CROSS_REVIEW_ROUND9_2026-10-25.md", 1, true))
		assert.is_false(details:find("secret", 1, true) ~= nil)
	end)

	it("shows the tail of cumulative intake history across batches", function()
		local path = os.tmpname() .. "-pob-ingestion-history.jsonl"
		local file = assert(io.open(path, "wb"))
		for index = 1, 40 do
			file:write(assert(json.encode({ schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
				id = string.format("build_%02d", index), status = "archived", patch = "3.29",
				skill = "Arc", category = "normal" })), "\n")
		end
		file:close()
		local rows = BuildIngestionStatus.ReadLatestResults(path)
		assert.is_truthy(os.remove(path))
		assert.are.equal(32, #rows)
		assert.are.equal("build_09", rows[1].id)
		assert.are.equal("build_40", rows[#rows].id)
		local details = BuildIngestionStatus.FormatLatestResultsDetails({ latestResults = rows })
		assert.is_truthy(details:find("build_40", 1, true))
		assert.is_false(details:find("build_08", 1, true) ~= nil)
	end)

	it("indexes every paired review beyond the recent tail and paginates newest-first by patch and skill", function()
		local path = os.tmpname() .. "-pob-paired-review-history.jsonl"
		local file = assert(io.open(path, "wb"))
		for index = 1, 40 do
			local patch = index <= 20 and "3.26" or "3.29"
			local record = {
				schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
				id = string.format("build_%02d", index), status = index % 2 == 0 and "reviewed" or "archived",
				patch = patch, skill = index <= 20 and "Arc" or "Cyclone", category = "normal",
			}
			if index % 2 == 0 then
				record.reviewAudit = { pairedReviewCompleted = true, sourceStatus = "archived",
					reviewers = { "Scout", "Critic" }, summary = "paired " .. index,
					trainingEligible = false, ideas = { } }
			end
			assert.is_truthy(file:write(assert(json.encode(record)), "\n"))
		end
		file:close()

		local filters = assert(BuildIngestionStatus.ReadPairedReviewFilters(path))
		assert.are.equal(20, filters.pairedReviewCount)
		local first = assert(BuildIngestionStatus.ReadPairedReviewPage(path, "", "", "", 1, 8))
		local second = assert(BuildIngestionStatus.ReadPairedReviewPage(path, "", "", "", 2, 8))
		local third = assert(BuildIngestionStatus.ReadPairedReviewPage(path, "", "", "", 3, 8))
		assert.are.equal(20, first.total)
		assert.are.equal("build_40", first.items[1].id)
		assert.are.equal("build_26", first.items[8].id)
		assert.are.equal("build_24", second.items[1].id)
		assert.are.equal("build_10", second.items[8].id)
		assert.are.equal("build_08", third.items[1].id)
		assert.are.equal("build_02", third.items[4].id)
		local filtered = assert(BuildIngestionStatus.ReadPairedReviewPage(path, "3.26", "normal", "Arc", 2, 8))
		assert.are.equal(10, filtered.total)
		assert.are.equal(2, #filtered.items)
		assert.are.equal("build_04", filtered.items[1].id)
		assert.are.equal("build_02", filtered.items[2].id)
		assert.is_truthy(os.remove(path))
	end)

	it("formats review details with paired decisions and hypotheses while excluding source payloads", function()
		local path = os.tmpname() .. "-pob-paired-review-details.jsonl"
		local file = assert(io.open(path, "wb"))
		file:write(assert(json.encode({ schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
			id = "safe_build", status = "reviewed", patch = "3.28", skill = "Forbidden Rite of Soul Sacrifice",
			category = "transfigured", ascendancy = "Occultist", sourceUrl = "https://secret.invalid/build",
			rawXml = "secret XML", code = "secret PoB code", reviewAudit = {
				pairedReviewCompleted = true, sourceStatus = "archived", reviewers = { "Scout", "Critic" },
				summary = "Main sockets verified", validationScope = "main_skill_group_only",
				mainSkillCoverageEligible = true, fullBuildStatus = "quarantined", trainingEligible = false,
				ideas = { { title = "Forbidden Rite + Cyclone", status = "untested",
					linkedSkills = { "Forbidden Rite", "Cyclone" }, testPlan = "Hold tree, gear, target, and Main group fixed." } },
				reportPath = "docs/optimizer/QA_PUBLIC_BUILD_CROSS_REVIEW_ROUND22_2026-10-25.md",
			},
		})), "\n")
		file:close()
		local page = assert(BuildIngestionStatus.ReadPairedReviewPage(path, "", "", "", 1, 8))
		local line = BuildIngestionStatus.FormatPairedReviewListRow(page.items[1])
		local detail = BuildIngestionStatus.FormatPairedReviewDetails(page.items[1])
		assert.is_truthy(line:find("Forbidden Rite of Soul Sacrifice [transfigured] / Occultist", 1, true))
		assert.is_truthy(detail:find("Revisores: Scout + Critic", 1, true))
		assert.is_truthy(detail:find("Main elegível para cobertura: sim", 1, true))
		assert.is_truthy(detail:find("Treino: bloqueado", 1, true))
		assert.is_truthy(detail:find("Teste: Hold tree, gear, target, and Main group fixed", 1, true))
		assert.is_truthy(detail:find("QA_PUBLIC_BUILD_CROSS_REVIEW_ROUND22_2026-10-25.md", 1, true))
		assert.is_false(line:find("secret", 1, true) ~= nil)
		assert.is_false(detail:find("secret", 1, true) ~= nil)
		assert.is_nil(page.items[1].sourceUrl)
		assert.is_nil(page.items[1].rawXml)
		assert.is_nil(page.items[1].code)
		assert.is_truthy(os.remove(path))
	end)

	it("rejects malformed, oversized, wrong-schema, and impossible counters", function()
		assert.is_nil(BuildIngestionStatus.Parse("{"))
		assert.is_nil(BuildIngestionStatus.Parse(string.rep("x", 65537)))
		assert.is_nil(BuildIngestionStatus.Parse(assert(json.encode(progress({ schemaVersion = 2 })))))
		assert.is_nil(BuildIngestionStatus.Parse(assert(json.encode(progress({ processedCount = 8 })))))
	end)
end)
