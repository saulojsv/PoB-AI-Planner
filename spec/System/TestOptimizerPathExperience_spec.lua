local PathExperience = require("Modules.Optimizer.PathExperience")
local PathPatterns = require("Modules.Optimizer.PathPatterns")
local Version = require("Modules.Optimizer.Version")
local Inputs = require("Modules.Optimizer.Inputs")
local Candidate = require("Modules.Optimizer.Candidate")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local Calcs = require("Modules.Calcs")
local json = require("dkjson")
local ffi = require("ffi")
local TestSupport = require("OptimizerTestSupport")

pcall(ffi.cdef, [[
	int _mkdir(const char *dirname);
	int _rmdir(const char *dirname);
	int _access(const char *path, int mode);
	int mkdir(const char *path, unsigned int mode);
	int rmdir(const char *path);
	int access(const char *path, int mode);
]])

local isWindows = package.config and package.config:sub(1, 1) == "\\"
local crt = isWindows and ffi.load("msvcr100") or nil

local function makeDirectory(path)
	path = path:gsub("[/\\]+$", "")
	local result
	if isWindows then
		result = crt._mkdir(path)
	else
		result = ffi.C.mkdir(path, 493)
	end
	if result == 0 then return true end
	local exists = isWindows and crt._access(path, 0) == 0 or (not isWindows and ffi.C.access(path, 0) == 0)
	if exists then return nil, "No error" end
	return nil, "could not create test directory"
end

local function removeDirectory(path)
	if isWindows then return crt._rmdir(path) end
	return ffi.C.rmdir(path)
end

local function createSandbox()
	TestSupport.MarkCalculationContentVerified()
	local temp = os.tmpname()
	os.remove(temp)
	local root = temp .. "_path_experience"
	assert(makeDirectory(root))
	local state = PathExperience.Open(root, Version.Snapshot({
		data = { version = "3.29", gems = { } }, spec = { treeVersion = "3_29" },
	}))
	return root, state
end

local function cleanupSandbox(root, state)
	if state and state.path then os.remove(state.path) end
	if state and state.directory then removeDirectory(state.directory) end
	if root then removeDirectory(root) end
end

local function createDirectory(path)
	return makeDirectory(path)
end

local function readFile(path)
	local file = assert(io.open(path, "rb"))
	local content = file:read("*a")
	file:close()
	return content
end

local function writeFile(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content))
	file:close()
end

local function buildFixture()
	return {
		data = {
			version = "3.29",
			gems = { Fireball = { name = "Fireball", tagString = "Projectile, Spell, AoE, Fire" } },
		},
		characterLevel = 90,
		spec = {
			curClassId = 2, curAscendClassId = 4, treeVersion = "3_29",
			allocNodes = { [100] = true },
			nodes = {
				[100] = { linkedId = { 201, 301 } },
				[201] = { linkedId = { 100, 202 } },
				[202] = { linkedId = { 201 } },
				[301] = { linkedId = { 100 } },
			},
		},
	}
end

local function parsedFixture(overrides)
	local parsed = {
		scenarioProfile = "Current", objective = "CombinedDPS",
		hard = { }, conversion = { }, branch = { }, preferences = { },
		search = { maxTotalPoints = 120, maxAddedPoints = 20 },
	}
	for key, value in pairs(overrides or { }) do parsed[key] = value end
	return parsed
end

local function exactRecord(build, candidate, evaluation, sourceSignature, parsed)
	return assert(PathExperience.CreateRecord(build, build.spec, candidate, evaluation,
		parsed or parsedFixture(), { gemId = "Fireball" }, sourceSignature or "fixture-source"))
end

local function baseline(build, signature, parsed)
	return exactRecord(build, { isBaselineCandidate = true }, {
		metrics = { CombinedDPS = 100, TotalEHP = 25000 }, feasible = true,
		normalizedDeficit = 0, passivePointsUsed = 100, violations = { },
	}, signature, parsed)
end

local function recalculateFingerprint(record)
	local payload = { }
	for key, value in pairs(record) do
		if key ~= "observedAt" and key ~= "fingerprint" then payload[key] = value end
	end
	record.fingerprint = PathExperience.Digest(payload)
	return record
end

describe("Optimizer contextual path experience", function()
	local oldLaunch

	before_each(function()
		oldLaunch = {
			versionNumber = launch.versionNumber,
			versionBranch = launch.versionBranch,
			devMode = launch.devMode,
		}
		launch.versionNumber, launch.versionBranch, launch.devMode = "path-memory-fixture", "dev", false
	end)

	after_each(function()
		launch.versionNumber = oldLaunch.versionNumber
		launch.versionBranch = oldLaunch.versionBranch
		launch.devMode = oldLaunch.devMode
	end)

	it("stores only allowlisted exact context and deduplicates reopened records", function()
		local root, state = createSandbox()
		local build, parsed = buildFixture(), parsedFixture()
		local rawItem = "Rarity: Rare\nDoom Veil\n+120 to maximum Life"
		build.itemsTab = { items = { [17] = {
			name = "Doom Veil", rarity = "Rare",
			BuildRaw = function() return rawItem end,
		} } }
		local baseRecord = baseline(build, "private-build-signature", parsed)
		local gearRecord = exactRecord(build, {
			gearVariant = { items = { { slot = "Helmet", itemId = 17, raw = rawItem, notes = "private note" } } },
		}, {
			metrics = { CombinedDPS = 105, TotalEHP = 26000 }, feasible = true,
			normalizedDeficit = 0, passivePointsUsed = 100, violations = { },
		}, "private-build-signature", parsed)
		assert.is_true(type(gearRecord.candidate.mutationSignature) == "string")
		assert.is_true(type(gearRecord.candidate.mutations[1].items[1].itemDigest) == "string")
		local appended = PathExperience.AppendBatch(state, { baseRecord, gearRecord }, createDirectory)
		assert.are.equal(2, appended.stored)
		assert.are.equal("ready", appended.status)
		local encoded = readFile(state.path)
		assert.is_nil(encoded:find(rawItem, 1, true))
		assert.is_nil(encoded:find("private note", 1, true))
		assert.is_nil(encoded:find("Doom Veil", 1, true))
		assert.is_nil(encoded:find("private-build-signature", 1, true))

		local reopened = PathExperience.Open(root, Version.Snapshot(build))
		assert.are.equal(2, reopened.compatibleRecords)
		assert.are.equal(2, #reopened.records)
		local duplicate = PathExperience.AppendBatch(reopened, { gearRecord }, createDirectory)
		assert.are.equal(0, duplicate.stored)
		assert.are.equal(1, duplicate.duplicates)
		cleanupSandbox(root, reopened)
	end)

	it("ranks exact gem and item variants by their own mutation signatures", function()
		local parsed = parsedFixture()
		local records = { }
		local gemA = { gemVariant = {
			kind = "support_swap", gemId = "SupportA", skillId = "support_a", fromGemId = "SupportOld",
			groupIndex = 1, gemIndex = 2, level = 20, quality = 20,
		} }
		local gemB = { gemVariant = {
			kind = "support_swap", gemId = "SupportB", skillId = "support_b", fromGemId = "SupportOld",
			groupIndex = 1, gemIndex = 2, level = 20, quality = 20,
		} }
		local signatureA = assert(PathExperience.CandidateMutationSignature(gemA))
		local signatureB = assert(PathExperience.CandidateMutationSignature(gemB))
		assert.are_not.equal(signatureA, signatureB)

		for buildIndex = 1, 5 do
			local build = buildFixture()
			local source = "gem-mutation-build-" .. tostring(buildIndex)
			records[#records + 1] = baseline(build, source, parsed)
			records[#records + 1] = exactRecord(build, gemA, {
				metrics = { CombinedDPS = 150 }, feasible = true, normalizedDeficit = 0,
				passivePointsUsed = 100, violations = { },
			}, source, parsed)
			records[#records + 1] = exactRecord(build, gemB, {
				metrics = { CombinedDPS = 80 }, feasible = false, normalizedDeficit = 0.2,
				passivePointsUsed = 100, violations = { { key = "hard_dps", deficit = 20 } },
			}, source, parsed)
		end

		local index = assert(PathPatterns.BuildIndex(records, Version.Snapshot(buildFixture())))
		local candidates = {
			{ id = "locked-baseline", isBaselineCandidate = true },
			{ id = "support-b", gemVariant = gemB.gemVariant },
			{ id = "support-a", gemVariant = gemA.gemVariant },
		}
		local context = assert(PathExperience.MakeBaseContext(buildFixture(), parsed, { gemId = "Fireball" }, "rank-source"))
		local ranked = PathPatterns.RankCandidates(index, candidates, context, buildFixture().spec)
		assert.are.equal("locked-baseline", ranked[1].id)
		assert.are.equal("support-a", ranked[2].id)
		assert.are.equal("support-b", ranked[3].id)

		local rawA, rawB = "Rarity: Rare\nAlpha Hood\n+100 to maximum Life", "Rarity: Rare\nBeta Hood\n+100 to maximum Life"
		local gearRecords = { }
		for buildIndex = 1, 5 do
			local itemAId, itemBId = 100 + buildIndex * 2, 101 + buildIndex * 2
			local build = buildFixture()
			build.itemsTab = { items = {
				[itemAId] = { BuildRaw = function() return rawA end },
				[itemBId] = { BuildRaw = function() return rawB end },
			} }
			local source = "gear-mutation-build-" .. tostring(buildIndex)
			gearRecords[#gearRecords + 1] = baseline(build, source, parsed)
			gearRecords[#gearRecords + 1] = exactRecord(build, {
				gearVariant = { changedSlots = { "Helmet" }, items = { { slot = "Helmet", itemId = itemAId } } },
			}, { metrics = { CombinedDPS = 145 }, feasible = true, normalizedDeficit = 0, violations = { } }, source, parsed)
			gearRecords[#gearRecords + 1] = exactRecord(build, {
				gearVariant = { changedSlots = { "Helmet" }, items = { { slot = "Helmet", itemId = itemBId } } },
			}, { metrics = { CombinedDPS = 75 }, feasible = false, normalizedDeficit = 0.25, violations = { { key = "hard_dps", deficit = 25 } } }, source, parsed)
		end
		local gearIndex = assert(PathPatterns.BuildIndex(gearRecords, Version.Snapshot(buildFixture())))
		local itemBuild = buildFixture()
		itemBuild.itemsTab = { items = {
			[21] = { BuildRaw = function() return rawA end },
			[22] = { BuildRaw = function() return rawB end },
		} }
		local gearCandidates = {
			{ id = "locked-baseline", isBaselineCandidate = true },
			{ id = "gear-b", gearVariant = { changedSlots = { "Helmet" }, items = { { slot = "Helmet", itemId = 22 } } } },
			{ id = "gear-a", gearVariant = { changedSlots = { "Helmet" }, items = { { slot = "Helmet", itemId = 21 } } } },
		}
		local gearRanked = PathPatterns.RankCandidates(gearIndex, gearCandidates,
			assert(PathExperience.MakeBaseContext(itemBuild, parsed, { gemId = "Fireball" }, "gear-rank-source")),
			itemBuild.spec, nil, itemBuild)
		assert.are.equal("locked-baseline", gearRanked[1].id)
		assert.are.equal("gear-a", gearRanked[2].id)
		assert.are.equal("gear-b", gearRanked[3].id)
	end)

	it("rejects tampered rows and isolates incompatible engine versions", function()
		local root, state = createSandbox()
		local build = buildFixture()
		local row = baseline(build, "versioned-source")
		assert.are.equal(1, PathExperience.AppendBatch(state, { row }, createDirectory).stored)
		local oldVersion = json.decode(readFile(state.path))
		oldVersion.engine.dataVersion = "3.28"
		oldVersion.engine.treeVersion = "3_28"
		recalculateFingerprint(oldVersion)
		writeFile(state.path, readFile(state.path) .. json.encode(oldVersion) .. "\n")

		local reopened = PathExperience.Open(root, Version.Snapshot(build))
		assert.are.equal(1, reopened.compatibleRecords)
		assert.are.equal(1, reopened.incompatibleRecords)
		assert.are.equal(1, #reopened.records)
		local tampered = json.decode(readFile(state.path))
		tampered.outcome.metrics.CombinedDPS = 999999
		writeFile(state.path, json.encode(tampered) .. "\n")
		local corrupt = PathExperience.Open(root, Version.Snapshot(build))
		assert.are.equal("corrupt", corrupt.status)
		assert.are.equal(0, #corrupt.records)
		local mismatchedMutation = exactRecord(build, {
			gemVariant = { kind = "support_swap", gemId = "SupportA", level = 20, quality = 20 },
		}, { metrics = { CombinedDPS = 101 }, feasible = true, normalizedDeficit = 0, violations = { } }, "tamper-source")
		mismatchedMutation.candidate.mutationSignature = string.rep("0", 64)
		recalculateFingerprint(mismatchedMutation)
		writeFile(state.path, json.encode(mismatchedMutation) .. "\n")
		local corruptMutation = PathExperience.Open(root, Version.Snapshot(build))
		assert.are.equal("corrupt", corruptMutation.status)
		cleanupSandbox(root, corruptMutation)
	end)

	it("keeps skill route evidence isolated by hard-constraint context", function()
		local build = buildFixture()
		local first = assert(PathExperience.MakeBaseContext(build, parsedFixture(), { gemId = "Fireball" }, "source"))
		local second = assert(PathExperience.MakeBaseContext(build, parsedFixture({
			hard = { TotalEHP = { op = ">=", value = 50000 } },
		}), { gemId = "Fireball" }, "source"))
		assert.are_not.equal(first.skillScopeKey, second.skillScopeKey)
		assert.are_not.equal(first.archetypeScopeKey, second.archetypeScopeKey)
		local baseCandidateScope = PathExperience.CandidateContext(first, { nodeIds = { 201 } })
		local otherClassScope = PathExperience.CandidateContext(first, { nodeIds = { 201 }, classVariant = { classId = 6 } })
		assert.are_not.equal(baseCandidateScope.skillScopeKey, otherClassScope.skillScopeKey)
	end)

	it("isolates learned route evidence by resolved native enemy preset", function()
		local build = buildFixture()
		build.configTab = {
			activeConfigSetId = 1,
			configSets = { [1] = { input = { enemyIsBoss = "Boss" } } },
		}
		local activeBoss = assert(PathExperience.MakeBaseContext(build, parsedFixture({ scenarioEnemyPreset = "Active" }),
			{ gemId = "Fireball" }, "enemy-context-source"))
		local explicitUber = assert(PathExperience.MakeBaseContext(build, parsedFixture({ scenarioEnemyPreset = "Uber" }),
			{ gemId = "Fireball" }, "enemy-context-source"))
		local pinnacleDefault = assert(PathExperience.MakeBaseContext(build, parsedFixture({
			scenarioProfile = "PinnacleUnbuffed", scenarioEnemyPreset = "Active",
		}), { gemId = "Fireball" }, "enemy-context-source"))
		assert.are.equal("Boss", activeBoss.scenarioEnemyPreset,
			"Active under Current must resolve to the selected native PoB enemy tier")
		assert.are.equal("Uber", explicitUber.scenarioEnemyPreset)
		assert.are.equal("Pinnacle", pinnacleDefault.scenarioEnemyPreset,
			"Active under a Pinnacle profile must resolve to the native Pinnacle target")
		assert.are_not.equal(activeBoss.skillScopeKey, explicitUber.skillScopeKey)
		assert.are_not.equal(activeBoss.archetypeScopeKey, explicitUber.archetypeScopeKey)
		assert.are_not.equal(activeBoss.exactScopeKey, explicitUber.exactScopeKey)
		local record = exactRecord(build, { isBaselineCandidate = true }, {
			metrics = { CombinedDPS = 100 }, feasible = true, normalizedDeficit = 0, violations = { },
		}, "enemy-context-source", parsedFixture({ scenarioEnemyPreset = "Active" }))
		assert.are.equal("Boss", record.context.scenarioEnemyPreset)
	end)

	it("learns a successful completed route after a losing prefix without pruning exploration", function()
		local records = { }
		local parsed = parsedFixture()
		for buildIndex = 1, 5 do
			local build = buildFixture()
			local signature = "independent-build-" .. tostring(buildIndex)
			records[#records + 1] = baseline(build, signature, parsed)
			records[#records + 1] = exactRecord(build, { nodeIds = { 201 } }, {
				metrics = { CombinedDPS = 90 }, feasible = false, normalizedDeficit = 0.2,
				passivePointsUsed = 101, violations = { { key = "hard_dps", deficit = 10 } },
			}, signature, parsed)
			records[#records + 1] = exactRecord(build, { nodeIds = { 201, 202 } }, {
				metrics = { CombinedDPS = 130 }, feasible = true, normalizedDeficit = 0,
				passivePointsUsed = 102, violations = { },
			}, signature, parsed)
		end
		local currentEngine = Version.Snapshot(buildFixture())
		local index, indexSummary = PathPatterns.BuildIndex(records, currentEngine)
		assert.are.equal(15, indexSummary.compatibleRecords)
		assert.are.equal(10, indexSummary.labeledRecords)
		assert.is_true(indexSummary.patternCount > 0)

		local candidates = {
			{ id = "baseline", isBaselineCandidate = true },
			{ id = "bad-prefix", nodeIds = { 201 } },
			{ id = "unknown-route", nodeIds = { 301 } },
			{ id = "complete-synergy", nodeIds = { 201, 202 } },
			{ id = "other-family", nodeIds = { 301 }, gearVariant = { items = { } } },
		}
		local ranked, rankSummary = PathPatterns.RankCandidates(index, candidates,
			assert(PathExperience.MakeBaseContext(buildFixture(), parsed, { gemId = "Fireball" }, "active-source")),
			buildFixture().spec)
		assert.are.equal("baseline", ranked[1].id)
		assert.are.equal("complete-synergy", ranked[2].id)
		assert.are.equal("unknown-route", ranked[3].id)
		assert.are.equal("bad-prefix", ranked[4].id)
		assert.are.equal("other-family", ranked[5].id)
		assert.are.equal(#candidates, #ranked)
		assert.are.equal(2, rankSummary.preservedExploration)
		local secondRank, secondSummary = PathPatterns.RankCandidates(index, candidates,
			assert(PathExperience.MakeBaseContext(buildFixture(), parsed, { gemId = "Fireball" }, "active-source")),
			buildFixture().spec)
		for indexValue, candidate in ipairs(ranked) do assert.are.equal(candidate.id, secondRank[indexValue].id) end
		assert.are.equal(rankSummary.reorderedCandidates, secondSummary.reorderedCandidates)
	end)

	it("uses imported exact route pairs as cross-build ranking evidence", function()
		TestSupport.MarkCalculationContentVerified()
		local build, parsed, records = buildFixture(), parsedFixture(), { }
		for buildIndex = 1, 3 do
			local sourceSignature = "imported-route-build-" .. tostring(buildIndex)
			local baseContext = assert(PathExperience.MakeBaseContext(build, parsed, { gemId = "Fireball" }, sourceSignature))
			baseContext.observationSource = "imported_study"
			local function add(candidate, dps)
				local record, recordError = PathExperience.CreateRecord(build, build.spec, candidate, {
					metrics = { CombinedDPS = dps }, feasible = true, normalizedDeficit = 0,
					passivePointsUsed = 100, violations = { },
				}, parsed, { gemId = "Fireball" }, sourceSignature, baseContext)
				assert.is_truthy(record, recordError)
				assert.are.equal("imported_study", record.context.observationSource)
				records[#records + 1] = record
			end
			add({ isBaselineCandidate = true }, 100)
			add({ nodeIds = { 201, 202 } }, 130)
		end

		local engine = Version.Snapshot(build)
		local index, indexSummary = PathPatterns.BuildIndex(records, engine)
		assert.are.equal(6, indexSummary.compatibleRecords)
		assert.are.equal(3, indexSummary.labeledRecords)
		assert.is_true(indexSummary.patternCount > 0)
		local candidates = {
			{ id = "baseline", isBaselineCandidate = true },
			{ id = "unexplored", nodeIds = { 301 } },
			{ id = "imported-positive", nodeIds = { 201, 202 } },
		}
		local ranked = PathPatterns.RankCandidates(index, candidates,
			assert(PathExperience.MakeBaseContext(build, parsed, { gemId = "Fireball" }, "destination-build")), build.spec)
		assert.are.equal("baseline", ranked[1].id)
		assert.are.equal("imported-positive", ranked[2].id)
		assert.are.equal("unexplored", ranked[3].id)
	end)

	it("keeps an objective-losing feasible route behind an unexplored route", function()
		local records, parsed = { }, parsedFixture()
		for buildIndex = 1, 5 do
			local build = buildFixture()
			local signature = "objective-loss-build-" .. tostring(buildIndex)
			records[#records + 1] = baseline(build, signature, parsed)
			records[#records + 1] = exactRecord(build, { nodeIds = { 201 } }, {
				metrics = { CombinedDPS = 90 }, feasible = true, normalizedDeficit = 0,
				passivePointsUsed = 101, violations = { },
			}, signature, parsed)
		end
		local index = assert(PathPatterns.BuildIndex(records, Version.Snapshot(buildFixture())))
		local candidates = {
			{ id = "baseline", isBaselineCandidate = true },
			{ id = "known-objective-loss", nodeIds = { 201 } },
			{ id = "unexplored-route", nodeIds = { 301 } },
		}
		local currentBuild = buildFixture()
		local ranked, summary = PathPatterns.RankCandidates(index, candidates,
			assert(PathExperience.MakeBaseContext(currentBuild, parsed, { gemId = "Fireball" }, "objective-loss-source")),
			currentBuild.spec)
		assert.are.equal("baseline", ranked[1].id)
		assert.are.equal("unexplored-route", ranked[2].id)
		assert.are.equal("known-objective-loss", ranked[3].id)
		assert.are.equal(1, summary.rankedCandidates)
		assert.are.equal(1, summary.preservedExploration)
	end)

	it("prioritizes exact deficit improvements while keeping them below feasible outcomes", function()
		local records, parsed = { }, parsedFixture()
		for buildIndex = 1, 5 do
			local build = buildFixture()
			local signature = "deficit-improvement-build-" .. tostring(buildIndex)
			records[#records + 1] = exactRecord(build, { isBaselineCandidate = true }, {
				metrics = { CombinedDPS = 100 }, feasible = false, normalizedDeficit = 0.2,
				passivePointsUsed = 100, violations = { { key = "hard_dps", deficit = 20 } },
			}, signature, parsed)
			records[#records + 1] = exactRecord(build, { nodeIds = { 201 } }, {
				metrics = { CombinedDPS = 80 }, feasible = false, normalizedDeficit = 0.1,
				passivePointsUsed = 101, violations = { { key = "hard_dps", deficit = 10 } },
			}, signature, parsed)
		end
		local index = assert(PathPatterns.BuildIndex(records, Version.Snapshot(buildFixture())))
		local currentBuild = buildFixture()
		local candidates = {
			{ id = "baseline", isBaselineCandidate = true },
			{ id = "unexplored-route", nodeIds = { 301 } },
			{ id = "exact-deficit-improvement", nodeIds = { 201 } },
		}
		local ranked, summary = PathPatterns.RankCandidates(index, candidates,
			assert(PathExperience.MakeBaseContext(currentBuild, parsed, { gemId = "Fireball" }, "deficit-improvement-source")),
			currentBuild.spec)
		assert.are.equal("baseline", ranked[1].id)
		assert.are.equal("exact-deficit-improvement", ranked[2].id)
		assert.are.equal("unexplored-route", ranked[3].id)
		assert.are.equal(1, summary.rankedCandidates)
		assert.are.equal(1, summary.preservedExploration)
	end)

	it("reserves early exact evaluations for unexplored routes under a narrow budget", function()
		local records, parsed = { }, parsedFixture()
		local routeDps = { { 201, 110 }, { 301, 108 }, { 401, 106 }, { 501, 104 }, { 601, 102 } }
		local allNodeIds = { 201, 301, 401, 501, 601, 701, 801 }
		for buildIndex = 1, 5 do
			local build = buildFixture()
			build.spec.nodes[100].linkedId = allNodeIds
			for _, nodeId in ipairs(allNodeIds) do build.spec.nodes[nodeId] = { linkedId = { 100 } } end
			local signature = "exploration-build-" .. tostring(buildIndex)
			records[#records + 1] = baseline(build, signature, parsed)
			for _, route in ipairs(routeDps) do
				records[#records + 1] = exactRecord(build, { nodeIds = { route[1] } }, {
					metrics = { CombinedDPS = route[2] }, feasible = true, normalizedDeficit = 0,
					passivePointsUsed = 101, violations = { },
				}, signature, parsed)
			end
		end
		local index = assert(PathPatterns.BuildIndex(records, Version.Snapshot(buildFixture())))
		local currentBuild = buildFixture()
		currentBuild.spec.nodes[100].linkedId = allNodeIds
		for _, nodeId in ipairs(allNodeIds) do currentBuild.spec.nodes[nodeId] = { linkedId = { 100 } } end
		local candidates = {
			{ id = "locked-baseline", isBaselineCandidate = true },
			{ id = "known-good-301", nodeIds = { 301 } },
			{ id = "unexplored-701", nodeIds = { 701 } },
			{ id = "known-good-501", nodeIds = { 501 } },
			{ id = "known-good-201", nodeIds = { 201 } },
			{ id = "known-good-601", nodeIds = { 601 } },
			{ id = "unexplored-801", nodeIds = { 801 } },
			{ id = "known-good-401", nodeIds = { 401 } },
		}
		local context = assert(PathExperience.MakeBaseContext(currentBuild, parsed, { gemId = "Fireball" }, "active-exploration-source"))
		local ranked, summary = PathPatterns.RankCandidates(index, candidates, context, currentBuild.spec)
		assert.are.equal("locked-baseline", ranked[1].id)
		assert.are.equal("known-good-201", ranked[2].id)
		assert.are.equal("unexplored-701", ranked[3].id)
		assert.are.equal("known-good-301", ranked[4].id)
		assert.are.equal("known-good-401", ranked[5].id)
		assert.are.equal("known-good-501", ranked[6].id)
		assert.are.equal("unexplored-801", ranked[7].id)
		assert.are.equal("known-good-601", ranked[8].id)
		assert.are.equal(2, summary.promotedExploration)
		assert.are.equal(2, summary.preservedExploration)
		assert.are.equal(#candidates, #ranked)
	end)

	it("skips large-route scoring while exact path evidence is still being collected", function()
		local candidates = { }
		for indexValue = 1, 128 do candidates[indexValue] = { id = indexValue, nodeIds = { 1000 + indexValue } } end
		local context = assert(PathExperience.MakeBaseContext(buildFixture(), parsedFixture(), { gemId = "Fireball" }, "cancel-source"))
		local progressCalls = 0
		local ranked, summary = PathPatterns.RankCandidates({ }, candidates, context, buildFixture().spec,
			function() progressCalls = progressCalls + 1; return false end)
		assert.are.equal(candidates, ranked)
		assert.are.equal("collecting_independent_evidence", summary.status)
		assert.are.equal(0, progressCalls)
		assert.are.equal(128, summary.preservedExploration)
	end)

	it("ignores incompatible engine rows while building the index", function()
		local build = buildFixture()
		local compatible = baseline(build, "compatible-source")
		local old = baseline(build, "old-source")
		old.engine.dataVersion, old.engine.treeVersion = "3.28", "3_28"
		recalculateFingerprint(old)
		local index, summary = PathPatterns.BuildIndex({ compatible, old }, Version.Snapshot(build))
		assert.is_table(index)
		assert.are.equal(1, summary.compatibleRecords)
	end)

	it("persists only exact RunPhantomSim results while preserving the active build", function()
		launch.versionNumber, launch.versionBranch, launch.devMode = oldLaunch.versionNumber, oldLaunch.versionBranch, oldLaunch.devMode
		newBuild()
		build.characterLevel, build.characterLevelAutoMode = 90, false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		for _, group in ipairs(build.skillsTab.socketGroupList) do
			group.enabled = true
			for _, gem in ipairs(group.gemList) do gem.enableGlobal1 = true end
		end
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local oldUserPath = main.userPath
		local oldMakeDir = MakeDir
		local root = os.tmpname()
		os.remove(root)
		root = root .. "_optimizer_run"
		assert(makeDirectory(root))
		main.userPath = root
		MakeDir = createDirectory
		local runOk, runError = pcall(function()
			local parsed = assert(Inputs.Parse({
				generationPhase = "tree", objectiveMetric = "CombinedDPS",
				baseClassId = tostring(build.spec.curClassId), targetSkillGroupIndex = "1",
				targetSkillIndex = "1", maxAddedPoints = "0", maxTotalPoints = "120",
				evaluationBudget = "8", scenarioProfile = "Current",
			}))
			local job = PhantomSim.RunPhantomSim(build, parsed)
			local steps = 0
			while job.status == "running" do
				job:Step()
				steps = steps + 1
				assert.is_true(steps < 2000, "Path-memory integration search did not terminate")
			end
			assert.is_true(job.status == "feasible" or job.status == "no_feasible_candidate", job.error or job.status)
			assert.is_true(job.result.evaluations <= 8, "Path memory must respect the exact evaluation budget")
			assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
			local coverage = job.result.searchCoverage.pathLearning
			assert.are.equal(job.result.evaluations, coverage.exactObservations, json.encode(coverage))
			assert.are.equal(job.result.evaluations, coverage.storedThisRun, json.encode(coverage))
			local saved = PathExperience.Open(root, Version.Snapshot(build))
			assert.are.equal(job.result.evaluations, saved.compatibleRecords, json.encode({ coverage = coverage, saved = saved }))
			local baselineSaved, exactFireballIdentity = false, false
			for _, record in ipairs(saved.records) do
				if record.candidate.isBaseline then baselineSaved = true end
				if record.context.skillId:find("Fireball", 1, true) then exactFireballIdentity = true end
			end
			assert.is_true(baselineSaved, "The exact source baseline is needed to score future route deltas")
			assert.is_true(exactFireballIdentity, "Path memory must resolve the selected PoB gem ID")
			cleanupSandbox(root, saved)
		end)
		main.userPath = oldUserPath
		MakeDir = oldMakeDir
		if not runOk then
			local saved = PathExperience.Open(root, Version.Snapshot(build))
			cleanupSandbox(root, saved)
			error(runError)
		end
	end)

	it("flushes exact path observations when RunPhantomSim ends with a normal error result", function()
		launch.versionNumber, launch.versionBranch, launch.devMode = oldLaunch.versionNumber, oldLaunch.versionBranch, oldLaunch.devMode
		newBuild()
		build.characterLevel, build.characterLevelAutoMode = 90, false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		for _, group in ipairs(build.skillsTab.socketGroupList) do
			group.enabled = true
			for _, gem in ipairs(group.gemList) do gem.enableGlobal1 = true end
		end
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local oldUserPath, oldMakeDir = main.userPath, MakeDir
		local oldGetMiscCalculator = Calcs.getMiscCalculator
		local root = os.tmpname()
		os.remove(root)
		root = root .. "_optimizer_error_flush"
		assert(makeDirectory(root))
		main.userPath = root
		MakeDir = createDirectory
		local exactCalls = 0
		Calcs.getMiscCalculator = function(evalBuild, baseOverride)
			local exactCalc, baselineOutput, baselineEnv = oldGetMiscCalculator(evalBuild, baseOverride)
			return function(...)
				exactCalls = exactCalls + 1
				if exactCalls == 2 then error("injected failure after first exact observation") end
				return exactCalc(...)
			end, baselineOutput, baselineEnv
		end
		local runOk, runError = pcall(function()
			local parsed = assert(Inputs.Parse({
				generationPhase = "tree", objectiveMetric = "CombinedDPS",
				baseClassId = tostring(build.spec.curClassId), targetSkillGroupIndex = "1",
				targetSkillIndex = "1", maxAddedPoints = "4", maxTotalPoints = "120",
				evaluationBudget = "8", scenarioProfile = "Current",
			}))
			local job = PhantomSim.RunPhantomSim(build, parsed)
			local steps = 0
			while job.status == "running" do
				job:Step()
				steps = steps + 1
				assert.is_true(steps < 2000, "Error-path memory flush search did not terminate")
			end
			assert.are.equal("error", job.status)
			assert.is_true(tostring(job.result.message):find("injected failure", 1, true) ~= nil)
			assert.are.equal(2, exactCalls, "The injected failure must occur after one exact candidate calculation")
			assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
			local coverage = job.result.searchCoverage.pathLearning
			assert.are.equal(1, coverage.exactObservations, json.encode(coverage))
			assert.are.equal(1, coverage.storedThisRun, json.encode(coverage))
			local saved = PathExperience.Open(root, Version.Snapshot(build))
			assert.are.equal(1, saved.compatibleRecords, json.encode({ coverage = coverage, saved = saved }))
			assert.is_true(saved.records[1].candidate.isBaseline, "The first exact baseline must survive a later normal error return")
			cleanupSandbox(root, saved)
		end)
		Calcs.getMiscCalculator = oldGetMiscCalculator
		main.userPath = oldUserPath
		MakeDir = oldMakeDir
		if not runOk then
			local saved = PathExperience.Open(root, Version.Snapshot(build))
			cleanupSandbox(root, saved)
			error(runError)
		end
	end)
end)
