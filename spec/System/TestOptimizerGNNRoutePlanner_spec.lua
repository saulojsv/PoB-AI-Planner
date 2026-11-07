local RoutePlanner = require("Modules.Optimizer.RoutePlanner")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local Inputs = require("Modules.Optimizer.Inputs")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local RoutePlannerProgress = require("Modules.Optimizer.RoutePlannerProgress")
local TreeSearch = require("Modules.Optimizer.TreeSearch")

local function makeBuild()
	local gemId = "Metadata/Items/Gems/SkillGemIceSpear"
	local gemData = {
		id = gemId, grantedEffectId = "IceSpear", tags = { grants_active_skill = true },
		grantedEffect = { id = "IceSpear", color = "B", levels = { { levelRequirement = 1 } } },
		naturalMaxLevel = 1,
	}
	local sourceGem = { gemData = gemData, enabled = true, level = 20, quality = 20 }
	local activeEffect = { grantedEffect = { id = "IceSpear" }, srcInstance = sourceGem }
	local group = {
		enabled = true, slotEnabled = true, slot = "Body Armour", mainActiveSkill = 1,
		includeInFullDPS = true,
		displaySkillList = { { activeEffect = activeEffect } },
		gemList = { sourceGem },
	}
	local itemId = 91
	return {
		mainSocketGroup = 1,
		characterLevel = 100,
		skillsTab = { socketGroupList = { group } },
		itemsTab = {
			slots = { ["Body Armour"] = { } },
			items = { [itemId] = {
				id = itemId,
				base = { socketLimit = 6 },
				sockets = { { group = 0, color = "B" } },
			} },
			activeItemSet = { ["Body Armour"] = { selItemId = itemId } },
		},
		calcsTab = { mainOutput = {
			CombinedDPS = 1234567, FullDPS = 1400000, TotalEHP = 45678,
			PhysicalMaximumHitTaken = 12000, FireMaximumHitTaken = 13000,
			ColdMaximumHitTaken = 14000, LightningMaximumHitTaken = 15000,
			FireResist = 75, ColdResist = 75, LightningResist = 75, ChaosResist = 10,
		} },
		data = { gems = { [gemId] = gemData } },
	}
end

describe("GNN route planner categorical native gates", function()
	it("budgets fixed-level routes at the selected level and reserves level 100 for auto-level builds", function()
		local function pointLimitedBuild(level, autoLevel)
			return {
				characterLevel = level,
				characterLevelAutoMode = autoLevel,
				GetPassivePointLimitForLevel = function(_, requestedLevel, extraPoints)
					return requestedLevel + 23 + (extraPoints or 0)
				end,
			}
		end

		local fixedLimit, fixedLevel = PhantomSim.ResolveSearchPointLimit(pointLimitedBuild(95, false), 0)
		assert.are.equal(95, fixedLevel)
		assert.are.equal(118, fixedLimit, "a level 95 search must not admit level 100 tree routes")

		local autoLimit, autoLevel = PhantomSim.ResolveSearchPointLimit(pointLimitedBuild(95, true), 2)
		assert.are.equal(100, autoLevel)
		assert.are.equal(125, autoLimit, "auto-level searches retain the level 100 ceiling and native ExtraPoints")
	end)

	it("uses the native PoB fallback unless a safe approved package ID is selected", function()
		local native = assert(RoutePlanner.Prepare(makeBuild(), { }))
		assert.are.equal("deterministic_fallback", native.modelMode)
		assert.is_nil(native.modelPackageId)

		local selected = assert(RoutePlanner.Prepare(makeBuild(), {
			routePlannerModelPackageId = "v1.2.0_IceSpear_PinnacleBoss",
		}))
		assert.are.equal("approved_gnn", selected.modelMode)
		assert.are.equal("v1.2.0_IceSpear_PinnacleBoss", selected.modelPackageId)

		local invalid, err = RoutePlanner.Prepare(makeBuild(), { routePlannerModelPackageId = "../unapproved" })
		assert.is_nil(invalid)
		assert.is_truthy(err:find("package ID is invalid", 1, true))
	end)

	it("builds a bounded categorical RunSpec and exact hard floors", function()
		local runSpec, floors = RoutePlanner.Prepare(makeBuild(), {
			routePlannerDpsTier = "TIER_25M_TO_50M",
			routePlannerEhpTier = "TIER_100K_PLUS",
			routePlannerElementalHitTier = "TIER_15K_TO_25K",
			routePlannerPhysicalHitTier = "TIER_20K_PLUS",
			routePlannerElementalResists = "CAP_EFFECTIVE",
			routePlannerChaosResist = "CAP_EFFECTIVE",
		})
		assert.is_table(runSpec)
		assert.are.equal("IceSpear", runSpec.skill.effectId)
		assert.are.equal(1000, runSpec.budget.minProposals)
		assert.are.equal(40000, runSpec.budget.maxProposals)
		assert.are.equal(5000, runSpec.budget.maxExactEvaluations,
			"the default route-search budget should explore broadly without requiring the one-hour profile")
		assert.are.equal(1800, runSpec.budget.timeoutSeconds)
		assert.are.equal(24, runSpec.maxAddedPoints, "the default route depth must allow full multi-route portfolios")
		assert.are.equal(130, runSpec.maxTotalPoints, "native PoB level and quest gates, not the old 120-point ceiling, bound endgame trees")
		assert.are.equal(25000000, floors.CombinedDPS)
		assert.are.equal(100000, floors.TotalEHP)
		assert.are.equal(15000, floors.FireMaximumHitTaken)
		assert.are.equal(20000, floors.PhysicalMaximumHitTaken)
		assert.are.equal(75, floors.FireResist)
		assert.are.equal(75, floors.ChaosResist)
		assert.are.equal("linked", runSpec.skill.socketEvidence.status)
	end)

	it("accepts only structured exact-recalculation budgets", function()
		local quick = assert(RoutePlanner.Prepare(makeBuild(), { routePlannerExactEvaluationBudget = "250" }))
		local balanced = assert(RoutePlanner.Prepare(makeBuild(), { routePlannerExactEvaluationBudget = "500" }))
		local deep = assert(RoutePlanner.Prepare(makeBuild(), { routePlannerExactEvaluationBudget = "1000" }))
		local expanded = assert(RoutePlanner.Prepare(makeBuild(), { routePlannerExactEvaluationBudget = "2500" }))
		local maximum = assert(RoutePlanner.Prepare(makeBuild(), { routePlannerExactEvaluationBudget = "5000" }))
		local fullSearch = assert(RoutePlanner.Prepare(makeBuild(), { routePlannerExactEvaluationBudget = "10000" }))
		assert.are.equal(250, quick.budget.maxExactEvaluations)
		assert.are.equal(120, quick.budget.timeoutSeconds)
		assert.are.equal(500, balanced.budget.maxExactEvaluations)
		assert.are.equal(240, balanced.budget.timeoutSeconds)
		assert.are.equal(1000, deep.budget.maxExactEvaluations)
		assert.are.equal(480, deep.budget.timeoutSeconds)
		assert.are.equal(2500, expanded.budget.maxExactEvaluations)
		assert.are.equal(900, expanded.budget.timeoutSeconds)
		assert.are.equal(5000, maximum.budget.maxExactEvaluations)
		assert.are.equal(1800, maximum.budget.timeoutSeconds)
		assert.are.equal(10000, fullSearch.budget.maxExactEvaluations)
		assert.are.equal(3600, fullSearch.budget.timeoutSeconds)
		local parsed = assert(Inputs.Parse({ evaluationBudget = "5000", proposalBudget = "100000", timeoutSeconds = "1800" }))
		assert.are.equal(5000, parsed.search.evaluationBudget)
		assert.are.equal(1800, parsed.search.timeoutSeconds)
		assert.are.equal(1801,
			assert(Inputs.Parse({ evaluationBudget = "5000", timeoutSeconds = "1801" })).search.timeoutSeconds,
			"the expanded timeout ceiling must accept deadlines above the previous 1,800-second maximum")
		local fullHour = assert(Inputs.Parse({ evaluationBudget = "10000", proposalBudget = "100000", timeoutSeconds = "3600" }))
		assert.are.equal(10000, fullHour.search.evaluationBudget)
		assert.are.equal(3600, fullHour.search.timeoutSeconds)
		assert.is_nil(Inputs.Parse({ evaluationBudget = "10001", timeoutSeconds = "3600" }))
		assert.is_nil(Inputs.Parse({ evaluationBudget = "10000", timeoutSeconds = "3601" }))
		local invalid, err = RoutePlanner.Prepare(makeBuild(), { routePlannerExactEvaluationBudget = "10001" })
		assert.is_nil(invalid)
		assert.is_truthy(err:find("250, 500, 1000, 2500, 5000, or 10000", 1, true))
	end)

	it("preserves exact Pareto routes and near misses when a Route Planner job is interrupted", function()
		local exactRoute = { feasible = true, label = "Exact native route",
			evaluation = { feasible = true, metrics = { CombinedDPS = 12000000 } } }
		local nearMiss = { label = "Exact near miss", feasible = false }
		local result = PhantomSim.BuildInterruptedSearchResult({
			reason = "timeout", feasibleBest = exactRoute, paretoFront = { exactRoute },
			exactNearMisses = { { summary = nearMiss } }, evaluations = 765,
			generationPhase = "combined", objectiveMetric = "CombinedDPS", sourceSignature = "seed-signature",
			searchCoverage = { phase = { exactEvaluations = 765 } }, scenarioProfile = "Current",
		})
		assert.are.equal("feasible", result.status)
		assert.are.equal(exactRoute, result.candidate)
		assert.are.equal(exactRoute, result.paretoFront[1])
		assert.are.equal(nearMiss, result.nearMisses[1])
		assert.are.equal("seed-signature", exactRoute.sourceSignature)
		assert.is_true(result.searchInterrupted)
		assert.is_true(result.searchTimedOut)
		assert.are.equal("timeout", result.terminationReason)
		assert.are.equal(765, result.evaluations)
	end)

	it("distinguishes a time limit reached before the first exact calculation from user cancellation", function()
		local timedOut = PhantomSim.BuildInterruptedSearchResult({
			reason = "timeout", evaluations = 0, generationPhase = "combined",
			objectiveMetric = "CombinedDPS", sourceSignature = "seed-signature",
		})
		assert.are.equal("timed_out", timedOut.status)
		assert.is_true(timedOut.searchInterrupted)
		assert.is_true(timedOut.searchTimedOut)
		assert.are.equal("timeout", timedOut.terminationReason)
		assert.are.equal(0, timedOut.evaluations)

		local cancelled = PhantomSim.BuildInterruptedSearchResult({
			reason = "user_cancelled", evaluations = 0, generationPhase = "combined",
		})
		assert.are.equal("cancelled", cancelled.status)
		assert.is_false(cancelled.searchTimedOut)
	end)

	it("preserves cumulative Analyzer counters across tree-validation progress updates", function()
		local best = { label = "Exact route" }
		local job = {
			routePlannerExactFeasibleMutations = 4,
			progress = {
				phase = "Exact calculations", processed = 179, total = 500,
				generatedProposals = 40000, uniqueProposals = 39437, retainedProposals = 39437,
				paretoRoutes = 3, exactFeasibleMutations = 4, bestExactRoute = best,
			},
		}
		local progress = RoutePlannerProgress.Merge(job, {
			phase = "Tree validation", processed = 179, total = 500, current = "candidate point limit",
		}, { generatedCandidates = 40000, uniqueCandidates = 39437, retainedCandidates = 39437 })
		assert.are.equal("Tree validation", progress.phase)
		assert.are.equal(179, progress.processed)
		assert.are.equal(40000, progress.generatedProposals)
		assert.are.equal(39437, progress.uniqueProposals)
		assert.are.equal(39437, progress.retainedProposals)
		assert.are.equal(3, progress.paretoRoutes)
		assert.are.equal(4, progress.exactFeasibleMutations)
		assert.are.equal(best, progress.bestExactRoute)
	end)

	it("preserves exact failure evidence when no route passed before a cancellation", function()
		local exactFailure = { selectedBaseClassName = "Duelist", selectedAscendancyName = "Slayer",
			metrics = { CombinedDPS = 9000000 }, violations = { { key = "CombinedDPS" } }, normalizedDeficit = 0.1 }
		local result = PhantomSim.BuildInterruptedSearchResult({
			reason = "user_cancelled", exactFailureBest = exactFailure, evaluations = 12,
			exactNearMisses = { { summary = { label = "Exact near miss" } } },
			generationPhase = "combined", objectiveMetric = "CombinedDPS",
		})
		assert.are.equal("no_feasible_candidate", result.status)
		assert.are.equal(9000000, result.bestObservedMetrics.CombinedDPS)
		assert.are.equal("Duelist", result.bestObservedIdentity.baseClass)
		assert.are.equal(1, #result.nearMisses)
		assert.is_false(result.searchTimedOut)
		assert.are.equal("user_cancelled", result.terminationReason)
	end)

	it("records elemental and Energy Shield focus, exact ranking order, and bounded proposal limits", function()
		local runSpec = assert(RoutePlanner.Prepare(makeBuild(), {
			damageFocus = "Fire", defenseProfile = "EnergyShield", rankingPriority = "DefenseFirst",
			routePlannerProposalLimit = "100000", routePlannerUseNodePower = "true",
		}))
		assert.are.same({ damageFocus = "Fire", defenseProfile = "EnergyShield", rankingPriority = "DefenseFirst" }, runSpec.preferences)
		assert.are.equal(100000, runSpec.budget.maxProposals)
		assert.are.equal("EnergyShield", runSpec.nodePower.requestedStat,
			"Show Node Power should use the selected native defense stat when available")
		assert.is_false(runSpec.nodePower.enabled,
			"a missing or uncalculated native Node Power cache must fall back without pretending it was used")
		local disabled = assert(RoutePlanner.Prepare(makeBuild(), {
			routePlannerUseNodePower = "false",
		}))
		assert.is_false(disabled.nodePower.requested)
		assert.is_false(disabled.nodePower.enabled)
	end)

	it("bounds the planner's resident exact queue without dropping reserved route classes", function()
		local candidates = {
			{ isBaselineCandidate = true, label = "Native baseline" },
			{ progressiveRouteBundle = true, nodeIds = { 101 }, plannerFamilyOverride = "tree", label = "Progressive route" },
			{ archivedRoutePattern = true, plannerFamilyOverride = "tree", label = "Archived route" },
		}
		for index = 1, 97 do
			candidates[#candidates + 1] = {
				plannerFamilyOverride = index % 2 == 0 and "equipment" or "skills",
				proposalId = index,
			}
		end
		local coverage = {
			baselineReserved = true,
			progressiveTreeReservationStatus = "reserved",
			progressiveTreeReservationPosition = 2,
			archivedRoutePatterns = { },
		}
		local progressive = candidates[2]
		local queue, plan = PhantomSim.InterleavePlannerCandidateFamilies(candidates,
			coverage, 32, progressive)

		assert.are.equal(100, plan.candidateCount, "the full unique proposal count remains reportable")
		assert.are.equal(96, #queue, "the exact budget plus bounded 25%/64-item slack is retained")
		assert.are.equal(96, coverage.exactQueueLimit)
		assert.are.equal(100, coverage.exactQueueInputCandidates)
		assert.are.equal(96, coverage.exactQueueRetainedCandidates)
		assert.are.equal(4, coverage.exactQueueDiscardedCandidates)
		assert.are.equal(candidates[1], queue[1], "the native baseline must remain first")
		assert.are.equal(progressive, queue[2], "a progressive passive route must remain reserved")
		assert.is_true(coverage.archivedRoutePatterns.reservedExactEvaluations > 0,
			"the archive route quota must remain reserved before pruning")
		assert.are.equal(32, plan.windowSize, "the exact budget remains distinct from queue retention")
	end)

	it("records an optional categorical conversion chain as an exact native gate", function()
		local runSpec = assert(RoutePlanner.Prepare(makeBuild(), {
			damageFocus = "Fire",
			routePlannerConversionRoute = "PHYSICAL_TO_FIRE",
			routePlannerConversionMinimum = "75",
		}))
		assert.are.same({ "Physical", "Fire" }, runSpec.conversion.route)
		assert.are.equal("Physical>Fire", runSpec.conversion.routeText)
		assert.are.equal(75, runSpec.conversion.minPercent)
		assert.is_nil(RoutePlanner.Prepare(makeBuild(), { routePlannerConversionRoute = "CHAOS_TO_PHYSICAL" }),
			"unsupported or reverse-order conversion chains must fail before search")
	end)

	it("maps route breadth to bounded passive-point budgets that allow progressive combinations", function()
		local conservative = assert(RoutePlanner.Prepare(makeBuild(), {
			routePlannerAggressiveness = "CONSERVATIVE_FINE_TUNE",
		}))
		local balanced = assert(RoutePlanner.Prepare(makeBuild(), {
			routePlannerAggressiveness = "BALANCED_LOCAL_SEARCH",
		}))
		local aggressive = assert(RoutePlanner.Prepare(makeBuild(), {
			routePlannerAggressiveness = "AGGRESSIVE_CLUSTER_EXPANSION",
		}))
		assert.are.equal(12, conservative.maxAddedPoints)
		assert.are.equal(24, balanced.maxAddedPoints)
		assert.are.equal(40, aggressive.maxAddedPoints)
		assert.is_true(balanced.maxAddedPoints > 5,
			"the default route depth must not trigger PhantomSim's progressive-route skip condition")
	end)

	it("composes several target paths into a bounded progressive passive route", function()
		local routes = {
			{ nodeIds = { 101, 102 }, targetId = 102, targetRegion = "NW", label = "Life route" },
			{ nodeIds = { 102, 103 }, targetId = 103, targetRegion = "NE", label = "Damage route" },
			{ nodeIds = { 104 }, targetId = 104, targetRegion = "SE", label = "Jewel route" },
		}
		local candidates = TreeSearch.CombineCandidates(routes, 32, 24)
		local progressive
		for _, candidate in ipairs(candidates) do
			if candidate.progressiveRouteBundle == true then progressive = candidate; break end
		end
		assert.is_table(progressive, "multiple target paths should produce a progressive portfolio")
		assert.is_true(progressive.routeCount >= 3)
		assert.is_true(#progressive.nodeIds <= 24)
	end)

	it("keeps an unlinked Main Skill searchable while exact evaluation still requires a native socket proof", function()
		local build = makeBuild()
		build.skillsTab.socketGroupList[1].slot = nil
		local skill, message, context = RoutePlanner.GetMainSkill(build)
		assert.is_nil(skill)
		assert.is_truthy(message:find("native PoB item socket/link", 1, true))
		assert.is_truthy(message:find("no equipment socket", 1, true))
		assert.are.equal(1234567, context.baseline.CombinedDPS,
			"baseline metrics should remain available for exact diagnostics")
		assert.is_truthy(context.socketWarnings and #context.socketWarnings > 0,
			"the unlinked Main Skill must be retained as an explicit exact-evaluation warning")
		local runSpec, prepareError = RoutePlanner.Prepare(build, { })
		assert.is_table(runSpec, prepareError)
		assert.is_false(SkillCatalog.ValidateEnabledSocketGroups(build),
			"exact candidate validation must continue to reject a build with no physical socket proof")
	end)

	it("keeps the generator available when a native item rework can repair socket colors", function()
		local build = makeBuild()
		build.itemsTab.items[91].sockets[1].color = "R"
		local skill, message = RoutePlanner.GetMainSkill(build)
		assert.is_table(skill, "a repairable native socket mismatch must remain eligible for route generation")
		assert.is_nil(message)
		local context = RoutePlanner.InspectMainSkill(build)
		assert.are.equal("native_item_rework_required", context.socketRepair.status)
		assert.are.same({ "B" }, context.socketRepair.colors)
		assert.are.same({ 0 }, context.socketRepair.linkGroups)
		assert.are.equal("Body Armour", context.socketRepair.slot)
		local runSpec, prepareError = RoutePlanner.Prepare(build, { })
		assert.is_table(runSpec, prepareError)
		assert.are.equal("Body Armour", runSpec.skill.socketRepair.slot)
		local gemVariant, gemError, gemDetails = SkillCatalog.ResolveTarget(build, 1, 1,
			"Metadata/Items/Gems/SkillGemIceSpear", { allowSocketRepair = true })
		assert.is_table(gemVariant, gemError)
		assert.is_table(gemDetails.socketRepair)
		assert.are.equal("R", build.itemsTab.items[91].sockets[1].color,
			"socket planning must never mutate the loaded build")
	end)

	it("rebuilds a missing display skill from one unambiguous installed gem when its primary socket is invalid", function()
		local build = makeBuild()
		local group = build.skillsTab.socketGroupList[1]
		group.displaySkillList = { }
		build.itemsTab.items[91].sockets[1].color = "R"
		local runSpec, prepareError = RoutePlanner.Prepare(build, { })
		assert.is_table(runSpec, prepareError)
		assert.are.equal("IceSpear", runSpec.skill.effectId)
		assert.are.same({ "B" }, runSpec.skill.socketRepair.colors)
		local variant, resolveError, details = SkillCatalog.ResolveTarget(build, 1, 1,
			"Metadata/Items/Gems/SkillGemIceSpear", { allowSocketRepair = true })
		assert.is_table(variant, resolveError)
		assert.are.equal("IceSpear", variant.skillId)
		assert.is_table(details.socketRepair)

		local parsed = assert(Inputs.Parse({ generationPhase = "combined", objectiveMetric = "CombinedDPS",
			targetSkillGroupIndex = "1", targetSkillIndex = "1",
			targetSkillGemId = "Metadata/Items/Gems/SkillGemIceSpear" }))
		parsed.search.allowSocketRepair = true
		build.spec = { }
		local valid, validationError = Inputs.ValidateBuild(build, parsed)
		assert.is_true(valid, validationError)
	end)

	it("propagates item repair when an installed support, rather than the main gem, has the wrong socket color", function()
		local build = makeBuild()
		local supportId = "Metadata/Items/Gems/SkillGemSupportMeleePhysicalDamage"
		local supportData = { id = supportId, name = "Melee Physical Damage Support",
			grantedEffect = { id = "SupportMeleePhysicalDamage", support = true, color = 1 } }
		local supportGem = { gemData = supportData, enabled = true, level = 20, quality = 20 }
		local group = build.skillsTab.socketGroupList[1]
		group.gemList[2] = supportGem
		build.data.gems[supportId] = supportData
		build.itemsTab.items[91].sockets = {
			{ group = 0, color = "B" }, { group = 0, color = "G" },
		}

		local variant, resolveError, details = SkillCatalog.ResolveTarget(build, 1, 1,
			"Metadata/Items/Gems/SkillGemIceSpear", { allowSocketRepair = true })
		assert.is_table(variant, resolveError)
		assert.are.equal("B", build.itemsTab.items[91].sockets[1].color,
			"the selected active skill already fits its current socket")
		assert.are.equal("native_item_rework_required", details.socketRepair.status,
			"the repair plan must include invalid support sockets too")
		assert.are.same({ "B", "R" }, details.socketRepair.colors)
		assert.are.same({ 0, 0 }, details.socketRepair.linkGroups)
	end)

	it("returns exact baseline metrics and socket evidence for the loaded Main Skill", function()
		local skill, message, context = RoutePlanner.GetMainSkill(makeBuild())
		assert.is_table(skill, message)
		assert.are.equal("IceSpear", skill.effectId)
		assert.are.equal("Body Armour", skill.slot)
		assert.are.equal("linked", skill.socketEvidence.status)
		assert.are.equal(1234567, context.baseline.CombinedDPS)
		assert.are.equal(45678, context.baseline.TotalEHP)
	end)

	it("keeps Single Skill planning available when another enabled skill group has no legal socket repair", function()
		local build = makeBuild()
		build.itemsTab.slots.Gloves = { }
		build.itemsTab.activeItemSet.Gloves = { selItemId = 0 }
		build.skillsTab.socketGroupList[2] = {
			enabled = true, slotEnabled = true, includeInFullDPS = true,
			slot = "Gloves", mainActiveSkill = 1, gemList = { build.skillsTab.socketGroupList[1].gemList[1] },
		}
		local skill, message, context = RoutePlanner.GetMainSkill(build, false, true)
		assert.is_table(skill, message)
		assert.are.equal("IceSpear", skill.effectId)
		assert.is_truthy(context.socketValidationError,
			"the invalid enabled group must remain visible as a hard exact-candidate warning")
		assert.is_table(context.socketRepairAudit)
		assert.are.equal("Gloves", context.socketRepairAudit.blockers[1].group)
		assert.are.equal("Gloves", context.socketWarnings[1].group)
		local runSpec, prepareError = RoutePlanner.Prepare(build, { })
		assert.is_table(runSpec, prepareError)
		assert.are.equal("IceSpear", runSpec.skill.effectId,
			"a secondary unsupported socket group must not prevent structural Single Skill proposals")
		assert.is_false(SkillCatalog.ValidateEnabledSocketGroups(build),
			"an unrepairable secondary skill remains a hard candidate gate, never a generator gate")
	end)

	it("fails closed for trigger and cross-skill mutation modes", function()
		local trigger, triggerError = RoutePlanner.Prepare(makeBuild(), { routePlannerCrossSkillMode = "ALLOW_COC_AND_CWC" })
		assert.is_nil(trigger)
		assert.is_truthy(triggerError:find("unsupported", 1, true))
		local cross, crossError = RoutePlanner.Prepare(makeBuild(), { routePlannerSearchMode = "CROSS_SKILL_COMBINATION" })
		assert.is_nil(cross)
		assert.is_truthy(crossError:find("not yet certified", 1, true))
	end)

	it("rejects unrecognized free-form values and graph radii", function()
		local badTier = RoutePlanner.Prepare(makeBuild(), { routePlannerDpsTier = "999999999" })
		assert.is_nil(badTier)
		local badRadius = RoutePlanner.Prepare(makeBuild(), { routePlannerGraphRadius = "5" })
		assert.is_nil(badRadius)
		local badProposalLimit = RoutePlanner.Prepare(makeBuild(), { routePlannerProposalLimit = "999999999" })
		assert.is_nil(badProposalLimit)
		local badNodePower = RoutePlanner.Prepare(makeBuild(), { routePlannerUseNodePower = "sometimes" })
		assert.is_nil(badNodePower)
	end)
end)
