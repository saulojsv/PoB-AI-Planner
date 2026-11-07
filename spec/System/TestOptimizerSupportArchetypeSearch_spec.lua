local Candidate = require("Modules.Optimizer.Candidate")
local Inputs = require("Modules.Optimizer.Inputs")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local SkillSeed = require("Modules.Optimizer.SkillSeed")
local json = require("dkjson")

local fixtures = {
	{ name = "Fireball", archetype = "spell_projectile" },
	{ name = "Cyclone", archetype = "melee_attack" },
	{ name = "Summon Raging Spirit", archetype = "minion" },
	{ name = "Caustic Arrow", archetype = "bow_chaos_dot" },
	{ name = "Explosive Trap", archetype = "trap" },
	{ name = "Spark", archetype = "spell_projectile" },
}

local function exactGemByName(build, wantedName)
	local catalog, catalogError = SkillCatalog.ListActive(build, "", 1000)
	assert(catalog, catalogError)
	for _, row in ipairs(catalog.gems) do
		if row.name == wantedName then return row end
	end
	error("PoB's loaded active skill catalog does not contain " .. wantedName)
end

local function executeSkillsPhase(gemId)
	build.characterLevel = 90
	build.characterLevelAutoMode = false
	build.configTab.input.customMods = "+1000 to Strength\n+1000 to Dexterity\n+1000 to Intelligence"
	build.configTab:BuildModList()
	build.calcsTab:BuildOutput()
	local seed, seedError = SkillSeed.Create(build, gemId)
	assert(seed, seedError)
	assert(seed.linked == false, "the controlled fixture must remain explicitly unlinked")
	local sourceSignature = Candidate.BuildSignature(build)
	local parsed = assert(Inputs.Parse({
		generationPhase = "skills",
		objectiveMetric = "CombinedDPS",
		evaluationBudget = "16",
		maxAddedPoints = "0",
		maxTotalPoints = "120",
		targetSkillGroupIndex = tostring(seed.groupIndex),
		targetSkillIndex = tostring(seed.skillIndex),
		targetSkillGemId = gemId,
	}))
	local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
	local status, result = "running", nil
	for _ = 1, 5000 do
		status, result = job:Step()
		if status ~= "running" then break end
	end
	assert.is_true(status ~= "running", "support search stalled in phase " .. tostring(job.progress and job.progress.phase))
	assert.is_true(status ~= "error", result and result.message or job.error)
	assert.are.equal("skills", result.generationPhase)
	assert.is_true(result.evaluations > 0 and result.evaluations <= parsed.search.evaluationBudget)
	local coverage = assert(result.searchCoverage and result.searchCoverage.phase)
	assert.is_true(coverage.generatedSupportAddCandidates > 0,
		"PoB support catalog candidates must be generated for " .. gemId)
	assert.is_true(coverage.exactSupportAddEvaluations > 0,
		"support additions must reach the exact calculator for " .. gemId)
	assert.is_true(coverage.compatibleSupportAddEvaluations > 0,
		"PoB must confirm at least one compatible support for " .. gemId)
	assert.is_true(coverage.generatedSupportAddCombinationCandidates > 0,
		"bounded multi-support candidates must be generated for " .. gemId)
	assert.is_true(coverage.exactSupportAddCombinationEvaluations > 0,
		"multi-support candidates must reach the exact calculator for " .. gemId)
	assert.is_true(coverage.compatibleSupportAddCombinationEvaluations > 0,
		"PoB must confirm a multi-support package for " .. gemId)
	assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
		"isolated skill/support search must preserve the seeded source variation")
	return {
		gemId = gemId, generationPhase = result.generationPhase,
		evaluations = result.evaluations,
		generatedSupportAdds = coverage.generatedSupportAddCandidates,
		exactSupportAdds = coverage.exactSupportAddEvaluations,
		compatibleSupportAdds = coverage.compatibleSupportAddEvaluations,
		generatedSupportCombinations = coverage.generatedSupportAddCombinationCandidates,
		exactSupportCombinations = coverage.exactSupportAddCombinationEvaluations,
		compatibleSupportCombinations = coverage.compatibleSupportAddCombinationEvaluations,
		unlinkedPlanning = true,
	}
end

describe("Optimizer exact support search across skill archetypes", function()
	for _, fixture in ipairs(fixtures) do
		local current = fixture
		it("generates and exact-checks native support packages for " .. current.name, function()
			newBuild()
			local gem = exactGemByName(build, current.name)
			local result = executeSkillsPhase(gem.id)
			result.skill = current.name
			result.archetype = current.archetype
			result.pobVersion = build.version
			print("QA_CASE " .. json.encode(result))
		end)
	end
end)
