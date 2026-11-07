local BuildReviewPair = require("Modules.Optimizer.BuildReviewPair")
local json = require("dkjson")
local ffi = require("ffi")

pcall(ffi.cdef, [[
typedef int reviewPairBOOL;
reviewPairBOOL __stdcall CreateDirectoryA(const char *lpPathName, void *lpSecurityAttributes);
unsigned long __stdcall GetLastError(void);
reviewPairBOOL __stdcall RemoveDirectoryA(const char *lpPathName);
]])
local kernel32 = ffi.load("kernel32")

local function createDirectory(path)
	path = tostring(path):gsub("[/\\]+$", "")
	if kernel32.CreateDirectoryA(path, nil) ~= 0 then return true end
	if tonumber(kernel32.GetLastError()) == 183 then return nil, "No error" end
	return nil, "CreateDirectoryA failed with Windows error " .. tostring(tonumber(kernel32.GetLastError()))
end

local function removeDirectory(path)
	if kernel32.RemoveDirectoryA(path) ~= 0 then return true end
	return false
end

local function newUserPath()
	local path = os.tmpname() .. "-pob-build-review-pair"
	os.remove(path)
	assert.is_truthy(createDirectory(path))
	assert.is_truthy(createDirectory(path .. "\\OptimizerStudies"))
	return path
end

local function archiveLineage(userPath, lineageHash)
	local directory = userPath .. "\\OptimizerStudies\\Builds"
	assert.is_truthy(createDirectory(directory))
	local row = {
		recordType = "build_archive_observation",
		schemaVersion = 1,
		lineageSha256 = lineageHash,
		xmlSha256 = string.rep("d", 64),
		profile = { schema = "pob-ai-planner-build-profile", schemaVersion = 1 },
	}
	local file = assert(io.open(directory .. "\\builds.jsonl", "ab"))
	assert.is_truthy(file:write(assert(json.encode(row)), "\n"))
	assert.is_truthy(file:close())
end

local function appendOrphanReview(userPath, lineageHash)
	local row = {
		recordType = "build_review_pair_index",
		schemaVersion = 1,
		reviewerProtocolVersion = 99,
		lineageSha256 = lineageHash,
		reportSha256 = string.rep("c", 64),
		report = lineageHash .. "-review-v99.json",
		effectIds = { "fireball" },
		createdAt = os.time() + 1,
		hypothesisCount = 999,
		challengeCount = 999,
		responseCount = 999,
		status = "reviewed_hypotheses_untested",
	}
	local file = assert(io.open(userPath .. "\\OptimizerStudies\\BuildReviews\\reviews.jsonl", "ab"))
	assert.is_truthy(file:write(assert(json.encode(row)), "\n"))
	assert.is_truthy(file:close())
end

local function profile()
	return {
		schemaVersion = 1,
		engine = { pobVersion = "fixture", dataVersion = "3.29", treeVersion = "3_29" },
		character = { class = "Witch", level = 90 },
		configuredSkillEffects = { { effectId = "fireball", gemId = "SkillGemFireball", name = "Fireball" } },
		availableSkillEffects = { },
		skillGroups = { { groupIndex = 1, selectedMainGroup = true, skills = { { selectedMainSkill = true, effects = {
			{ effectId = "fireball", gemId = "SkillGemFireball", gameId = "fireball", variantId = "", name = "Fireball", selected = true },
		} } } } },
		supportGemIds = { "SupportSpellEcho" },
		allocatedNodeIds = { 1, 2, 3 },
		masterySelections = { },
		itemSlots = { { slot = "Weapon", name = "Wand", base = "Prophecy Wand" } },
	}
end

local function catalog()
	return {
		{ effectId = "fireball", gemId = "SkillGemFireball", gameId = "fireball", variantId = "", effectName = "Fireball", tags = "spell, fire, projectile" },
		{ effectId = "arc", gemId = "SkillGemArc", gameId = "arc", variantId = "", effectName = "Arc", tags = "spell, lightning, chaining" },
		{ effectId = "frostblink", gemId = "SkillGemFrostblink", gameId = "frostblink", variantId = "", effectName = "Frostblink", tags = "cold, movement" },
	}
end

describe("AI Planner paired local build review journal", function()
	local userPath

	after_each(function()
		if userPath then
			local root = userPath .. "\\OptimizerStudies\\BuildReviews"
			for _, name in ipairs({ string.rep("a", 64) .. "-review-v11.json", string.rep("b", 64) .. "-review-v11.json", "reviews.jsonl" }) do
				os.remove(root .. "\\" .. name)
			end
			removeDirectory(root)
			os.remove(userPath .. "\\OptimizerStudies\\Builds\\builds.jsonl")
			removeDirectory(userPath .. "\\OptimizerStudies\\Builds")
			removeDirectory(userPath .. "\\OptimizerStudies")
			removeDirectory(userPath)
			userPath = nil
		end
	end)

	it("records independent A/B work, challenges each scout proposal, and keeps every idea untested", function()
		local result, summary = BuildReviewPair.Analyze(profile(), catalog(), { }, string.rep("a", 64))
		assert.is_truthy(result)
		assert.are.equal("hybrid_local_pair", result.runtime.mode)
		assert.is_false(result.runtime.llmConfigured)
		assert.is_true(result.runtime.independentCriticPass)
		assert.are.equal("not_run", result.exactTest.status)
		assert.is_false(result.modelTraining.eligible)
		assert.are.equal(#result.scout.hypotheses, #result.criticChallenge.critiques)
		assert.are.equal(#result.criticChallenge.critiques + #result.criticChallenge.questions, #result.scoutResponse.responses)
		assert.are.equal(#result.scout.hypotheses + #result.criticIndependent.independentHypotheses, summary.hypothesisCount)
		for _, idea in ipairs(result.scout.hypotheses) do assert.are.equal("untested", idea.status) end
		for _, idea in ipairs(result.criticIndependent.independentHypotheses) do assert.are.equal("untested", idea.status) end
		assert.is_truthy(json.encode(result))
	end)

	it("persists one report per lineage and treats a reimport as idempotent", function()
		userPath = newUserPath()
		local lineage = string.rep("a", 64)
		archiveLineage(userPath, lineage)
		local first = assert(BuildReviewPair.Process(profile(), catalog(), { }, userPath, lineage, createDirectory))
		assert.are.equal("reviewed_hypotheses_untested", first.status)
		assert.is_true(first.responseCount > 0)
		local duplicate = assert(BuildReviewPair.Process(profile(), catalog(), { }, userPath, lineage, createDirectory))
		assert.are.equal("already_reviewed", duplicate.status)
		assert.are.equal(first.responseCount, duplicate.responseCount)
		appendOrphanReview(userPath, string.rep("b", 64))
		local summary = assert(BuildReviewPair.Summary(userPath))
		assert.are.equal(1, summary.storage.reviewedLineages)
		assert.is_true(summary.counts.hypotheses > 0)
		assert.is_true(summary.counts.critiquesAndQuestions > 0)
		assert.is_true(summary.counts.scoutProposed > 0)
		assert.is_true(summary.counts.scoutCandidates >= summary.counts.scoutProposed)
		assert.are.equal(summary.counts.scoutCandidates - summary.counts.scoutProposed,
			summary.counts.scoutUnreviewedCandidates)
		assert.are.equal(0, summary.counts.exactTests)
		assert.is_false(summary.model.trainingEligible)
	end)

	it("serves separate fact and idea pages and filters them by either effect", function()
		userPath = newUserPath()
		local lineage = string.rep("a", 64)
		archiveLineage(userPath, lineage)
		BuildReviewPair.Process(profile(), catalog(), { }, userPath, lineage, createDirectory)
		local facts = assert(BuildReviewPair.ListPage(userPath, "facts", "fireball", 1, 20))
		assert.is_true(facts.total > 0)
		for _, item in ipairs(facts.items) do
			assert.are.equal("observed_fact", item.category)
			assert.is_true(item.status == "observed" or item.status == "observed_snapshot")
		end
		local ideas = assert(BuildReviewPair.ListPage(userPath, "ideas", "arc", 1, 20))
		assert.is_true(ideas.total > 0)
		local sawScout, sawCritic, sawChallenge, sawResponse = false, false, false, false
		for _, item in ipairs(ideas.items) do
			sawScout = sawScout or item.role == "Discussão local A/B"
			sawCritic = sawCritic or item.role == "Crítico B independente"
			sawChallenge = sawChallenge or item.detail:find("B contesta:", 1, true) ~= nil
			sawResponse = sawResponse or item.detail:find("A responde à", 1, true) ~= nil
			assert.is_true(item.status ~= "validated")
		end
		assert.is_true(sawScout)
		assert.is_true(sawCritic)
		assert.is_true(sawChallenge)
		assert.is_true(sawResponse)
	end)

	it("explores every loaded-catalog pairing page with two independent local reviewers", function()
		local profileSnapshot, activeCatalog = profile(), catalog()
		local first = assert(BuildReviewPair.ExploreSkillPage(profileSnapshot, activeCatalog, { }, "fireball", { }, 1))
		assert.are.equal("pob-ai-planner-live-skill-exploration-page", first.schema)
		assert.are.equal("Fireball", first.anchor.name)
		assert.are.same({ "opportunity_scout", "adversarial_critic" }, first.reviewers)
		assert.is_true(first.counts.scoutCandidates > first.counts.scoutShown)
		assert.is_true(first.pages.hasMore)
		assert.is_false(first.modelTraining.eligible)
		local scoutItem
		for _, item in ipairs(first.items) do if item.category == "scout_hypothesis" then scoutItem = item; break end end
		assert.is_truthy(scoutItem)
		assert.is_truthy(scoutItem.detail:find("B contesta:", 1, true))
		assert.is_truthy(scoutItem.detail:find("A responde:", 1, true))
		local second = assert(BuildReviewPair.ExploreSkillPage(profileSnapshot, activeCatalog, { }, "fireball", first.nextCursors, 1))
		local firstIds = { }
		for _, item in ipairs(first.items) do firstIds[item.category .. ":" .. item.id] = true end
		for _, item in ipairs(second.items) do assert.is_false(firstIds[item.category .. ":" .. item.id] == true) end
		assert.are.equal(0, second.counts.exactTests)
		assert.are.equal(0, second.counts.trainingLabels)
	end)

	it("rejects a review lineage that has not been durably archived", function()
		userPath = newUserPath()
		local result, processError = BuildReviewPair.Process(profile(), catalog(), { }, userPath, string.rep("a", 64), createDirectory)
		assert.is_nil(result)
		assert.is_truthy(processError:find("must exist in the local build archive", 1, true))
		local summary = assert(BuildReviewPair.Summary(userPath))
		assert.are.equal(0, summary.storage.reviewedLineages)
	end)

	it("rejects unsupported sections, oversized page requests, and malformed lineage hashes", function()
		local page, pageError = BuildReviewPair.ListPage("C:\\fixture", "training", nil, 1, 8)
		assert.is_nil(page)
		assert.is_truthy(pageError)
		page, pageError = BuildReviewPair.ListPage("C:\\fixture", "ideas", nil, 1, 21)
		assert.is_nil(page)
		assert.is_truthy(pageError)
		local result, processError = BuildReviewPair.Analyze(profile(), catalog(), { }, "not-a-hash")
		assert.is_nil(result)
		assert.is_truthy(processError)
	end)
end)
