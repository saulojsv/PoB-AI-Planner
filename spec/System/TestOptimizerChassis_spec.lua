-- Runs through HeadlessWrapper/normal PoB, not the pure-contract harness.
local Inputs = require("Modules.Optimizer.Inputs")
local Candidate = require("Modules.Optimizer.Candidate")
local Phantom = require("Modules.Optimizer.PhantomSim")
local MCPBridge = require("Modules.Optimizer.MCPBridge")
local SkillCostAudit = require("Modules.Optimizer.SkillCostAudit")
local Activity = require("Modules.Optimizer.Activity")
local calcs = require("Modules.CalcBase")

local function findClassStartNeighbor(spec)
	local class = spec and spec.tree and spec.tree.classes and spec.tree.classes[spec.curClassId]
	local startNode = class and spec.nodes and spec.nodes[class.startNodeId]
	if not startNode then return nil end
	for _, node in pairs(spec.nodes or { }) do
		if node.type == "Normal" and node.path and #node.path == 1 then
			for _, linked in ipairs(node.linked or { }) do
				if linked.id == startNode.id then return node end
			end
		end
	end
	return nil
end

describe("Optimizer chassis native-engine parity", function()
	it("reports native per-skill costs without combining alternatives and shares PoB's EB payable-pool rule", function()
		local audit = SkillCostAudit.Build({ {
			activeSkill = { activeEffect = { grantedEffect = { id = "Fireball", name = "Fireball" } }, skillPartName = "" },
			groupIndex = 1,
			skillIndex = 1,
			group = "Main",
			poolOutput = { ManaUnreserved = 10, EnergyShield = 20, EnergyShieldProtectsMana = true },
			skillOutput = {
				ManaHasCost = true,
				ManaCost = 2,
				ManaPerSecondHasCost = true,
				ManaPerSecondCost = 1.25,
				ManaPercentHasCost = true,
				ManaPercentCost = 0.1,
				ManaPercentPerSecondHasCost = true,
				ManaPercentPerSecondCost = 0.05,
			},
			violations = { },
		}, {
			activeSkill = { activeEffect = { grantedEffect = { id = "MoltenShell", name = "Molten Shell" } }, skillPartName = "" },
			groupIndex = 1,
			skillIndex = 2,
			group = "Utility",
			poolOutput = { },
			skillOutput = { LifePerSecondHasCost = true, LifePerSecondCost = 0.5 },
			violations = { },
		} })
		assert.are.equal("pass", audit.status)
		assert.are.equal("reported_schedule_available", audit.recurringStatus)
		assert.are.equal("per_skill_only", audit.aggregation)
		assert.are.equal(2, #audit.skills)
		assert.are.equal(2, audit.skills[1].resources.mana.upfront)
		assert.are.equal(0.1, audit.skills[1].resources.mana.upfrontPercent)
		assert.are.equal(1.25, audit.skills[1].resources.mana.perSecond)
		assert.are.equal(0.05, audit.skills[1].resources.mana.perSecondPercent)
		assert.are.equal(30, audit.skills[1].resources.mana.availablePool)
		assert.are.equal("Molten Shell", audit.skills[2].name)
		assert.are.equal(0.5, audit.skills[2].resources.life.perSecond)
		assert.is_true(audit.skills[2].exactCosts, "a recurring-only skill must not be misclassified as missing upfront cost")
		assert.is_nil(audit.totalCostPerSecond)
		assert.are.equal(30, calcs.getSkillPayabilityPool({ ManaUnreserved = 10, EnergyShield = 20, EnergyShieldProtectsMana = true }, "ManaCost", "ManaUnreserved"))
		assert.are.equal(10, calcs.getSkillPayabilityPool({ ManaUnreserved = 10, EnergyShield = 20, EnergyShieldProtectsMana = false }, "ManaCost", "ManaUnreserved"))
		local upfrontGate = SkillCostAudit.CheckUpfrontPayability(audit)
		assert.are.equal("pass", upfrontGate.status)
		assert.is_true(upfrontGate.feasible)
	end)

	it("parses an explicitly enabled activity-sustain schedule for the optimizer", function()
		local json = require("dkjson")
		local scheduleState = {
			version = 1,
			optimizerGateEnabled = true,
			optimizerGateScope = "all_enabled_skills",
			scopes = {
				all_enabled_skills = {
					{ identity = "Fireball\31 1\31 1\31 ", mode = "scheduled", ratePercentText = "50", package = "", requires = "" },
				},
			},
		}
		local parsed, err = Inputs.Parse({
			objectiveMetric = "CombinedDPS",
			activityScheduleJson = json.encode(scheduleState),
		})
		assert.is_truthy(parsed, err)
		local schedule = assert(parsed.search.activitySchedule)
		assert.are.equal("all_enabled_skills", schedule.scope)
		assert.are.equal(1, #schedule.activities)
		assert.are.equal("Fireball\31 1\31 1\31 ", schedule.activities[1].identity)
		assert.are.equal(50, schedule.activities[1].ratePercent)
	end)

	it("strictly gates every enabled skill on exact upfront affordability", function()
		local audit = SkillCostAudit.Build({ {
			activeSkill = { activeEffect = { grantedEffect = { id = "Fireball", name = "Fireball" } } },
			groupIndex = 1, skillIndex = 1, group = "Main",
			poolOutput = { ManaUnreserved = 10 },
			skillOutput = { ManaHasCost = true, ManaCost = 2 }, violations = { },
		}, {
			activeSkill = { activeEffect = { grantedEffect = { id = "MoltenShell", name = "Molten Shell" } } },
			groupIndex = 2, skillIndex = 1, group = "Utility",
			poolOutput = { ManaUnreserved = 1 },
			skillOutput = { ManaHasCost = true, ManaCost = 5 },
			violations = { {
				resource = "mana", label = "Mana cost", actual = 1, required = 5, deficit = 4,
				reason = "Exact PoB unreserved pool is below the skill's upfront mana cost",
			} },
		} })
		assert.are.equal("violated", audit.status)
		local gate = SkillCostAudit.CheckUpfrontPayability(audit)
		assert.are.equal("violated", gate.status)
		assert.is_false(gate.feasible)
		assert.are.equal(1, #gate.violations)
		assert.are.equal("Molten Shell upfront cost", gate.violations[1].label)
		assert.are.equal("mana", gate.violations[1].resource)
		assert.are.equal(1, gate.violations[1].actual)
		assert.are.equal(5, gate.violations[1].required)

		local unsupported = SkillCostAudit.CheckUpfrontPayability({
			status = "unsupported", totalEnabledSkills = 2, auditedSkills = 2, skills = { },
			violations = { { skill = "Fireball", resource = "mana", actual = 0, required = 5, deficit = 5, reason = "Exact PoB warning" } },
			unsupported = { "Molten Shell: exact resource pool missing" },
		})
		assert.are.equal("unsupported", unsupported.status)
		assert.is_false(unsupported.feasible)
		assert.is_true(unsupported.normalizedDeficit == math.huge)
		assert.are.equal(2, #unsupported.violations, "Keep known exact failures alongside the unsupported-row reason")
		assert.are.equal("Fireball upfront cost", unsupported.violations[1].label)
	end)

	it("exposes exact Fireball and utility-skill costs in the build output and Ask AI snapshot", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.skillsTab:PasteSocketGroup("Molten Shell 1/0  1")
		build.mainSocketGroup = 1
		for _, group in ipairs(build.skillsTab.socketGroupList) do
			group.enabled = true
			for _, gem in ipairs(group.gemList) do gem.enableGlobal1 = true end
		end
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local signature = Candidate.BuildSignature(build)
		local output = build.calcsTab.mainOutput
		local audit = output.OptimizerSkillCostAudit
		assert.is_table(audit)
		assert.is_true(audit.status == "pass" or audit.status == "violated", require("dkjson").encode(audit))
		assert.are.equal(audit.status, SkillCostAudit.CheckUpfrontPayability(audit).status)
		local byName = { }
		for _, skill in ipairs(audit.skills) do
			byName[skill.name] = skill
			assert.is_true(skill.exactCosts, skill.name .. " costs must come from exact cached PoB output")
			assert.is_true(type(skill.identity) == "string" and skill.identity ~= "")
			assert.is_true(type(skill.groupIndex) == "number" and type(skill.skillIndex) == "number")
		end
		for _, name in ipairs({ "Fireball", "Molten Shell" }) do
			local skill = assert(byName[name], "Missing per-skill audit row: " .. name)
			assert.is_true(skill.resources.mana ~= nil or skill.resources.life ~= nil or skill.resources.energyShield ~= nil or skill.resources.rage ~= nil,
				name .. " should expose its exact PoB resource cost")
		end
		assert.is_nil(audit.totalCostPerSecond)
		assert.are.equal("reported_schedule_available", audit.recurringStatus)
		assert.are.equal(2, #audit.scheduleActivities)
		local scheduleByName = { }
		for _, activity in ipairs(audit.scheduleActivities) do
			scheduleByName[activity.name] = activity
			assert.is_true(activity.costScheduleEligible, activity.name .. " schedule must use exact PoB rates")
		end
		assert.is_truthy(scheduleByName.Fireball)
		assert.is_truthy(scheduleByName["Molten Shell"])
		local snapshot = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
		assert.are.same(audit.skills, snapshot.skillCostAudit.skills)
		assert.are.same(audit.scheduleActivities, snapshot.skillCostAudit.scheduleActivities)
		assert.are.equal("per_skill_only", snapshot.skillCostAudit.aggregation)
		assert.is_nil(snapshot.skillCostAudit.totalCostPerSecond)
		local schedule = { }
		for _, activity in ipairs(audit.scheduleActivities) do
			schedule[#schedule + 1] = { identity = activity.identity, mode = "scheduled", ratePercent = 50 }
		end
		local scheduled, scheduleError = MCPBridge:CallLocal("evaluate_activity_schedule", {
			scope = "all_enabled_skills",
			activities = schedule,
		})
		assert.is_nil(scheduleError)
		assert.are.equal("sustain_estimate", scheduled.status)
		assert.is_true(scheduled.resourceOnly)
		assert.is_false(scheduled.damageScheduleCertified)
		assert.are.equal("not_computed_resource_only", scheduled.damageScheduleProjection.status)
		for _, activity in ipairs(scheduled.activities) do assert.is_nil(activity.poBDamageProjection) end
		local scheduleState = {
			version = 1,
			optimizerGateEnabled = true,
			optimizerGateScope = "all_enabled_skills",
			scopes = { all_enabled_skills = { } },
		}
		for _, activity in ipairs(audit.scheduleActivities) do
			scheduleState.scopes.all_enabled_skills[#scheduleState.scopes.all_enabled_skills + 1] = {
				identity = activity.identity,
				mode = "scheduled",
				ratePercentText = "50",
				package = "",
				requires = "",
			}
		end
		local parsedSchedule = assert(Inputs.Parse({
			objectiveMetric = "CombinedDPS",
			maxAddedPoints = 0,
			evaluationBudget = 1,
			activityScheduleJson = require("dkjson").encode(scheduleState),
		}))
		local expectedActivity = assert(Activity.EvaluateOptimizerSchedule(
			parsedSchedule.search.activitySchedule, build.calcsTab.mainOutput, parsedSchedule))
		local startOk, scheduleJob = build.optimizerTab:StartOptimizer({
			objectiveMetric = "CombinedDPS",
			generationPhase = "tree",
			maxAddedPoints = 0,
			evaluationBudget = 1,
			activityScheduleJson = require("dkjson").encode(scheduleState),
		})
		assert.is_true(startOk, tostring(scheduleJob))
		local scheduleSteps = 0
		while scheduleJob.status == "running" do
			scheduleJob:Step()
			scheduleSteps = scheduleSteps + 1
			assert.is_true(scheduleSteps < 20, "Optimizer schedule gate did not finish within the one-candidate budget")
		end
		assert.are.equal("no_feasible_candidate", scheduleJob.status,
			"The fixture intentionally retains its unrelated native Strength requirement deficit")
		assert.are.equal(2, #expectedActivity.activities,
			"The optimizer must evaluate the configured schedule across all enabled skills, including utility groups")
		for _, key in ipairs({ "SustainedLifeMargin", "SustainedManaMargin", "SustainedEnergyShieldMargin" }) do
			if expectedActivity.metrics[key] ~= nil then
				assert.are.equal(expectedActivity.metrics[key], scheduleJob.result.bestObservedMetrics[key],
					"Run optimizer must use the user schedule's exact candidate metric " .. key)
			end
		end
		assert.are.equal(signature, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("loads supported native selectors and migrates legacy empty Matrix choices", function()
		newBuild()
		local tab = build.optimizerTab
		tab:Load({
			{ elem = "Input", attrib = { name = "scenarioProfile", value = "PinnacleChassis" } },
			{ elem = "Input", attrib = { name = "objectiveMetric", value = "FullDPS" } },
		})
		local profile, objective = tab.controls.text_scenarioProfile, tab.controls.text_objectiveMetric
		assert.are.equal("PinnacleChassis", profile.list[profile.selIndex].val)
		assert.are.equal("FullDPS", objective.list[objective.selIndex].val)
		assert.are.equal("PinnacleChassis", tab.textValues.scenarioProfile)
		tab:Load({
			{ elem = "Input", attrib = { name = "scenarioProfile", value = "" } },
			{ elem = "Input", attrib = { name = "objectiveMetric", value = "" } },
		})
		assert.are.equal("Current", tab.textValues.scenarioProfile)
		assert.are.equal("CombinedDPS", tab.textValues.objectiveMetric)
		assert.are.equal("Current", profile.list[profile.selIndex].val)
	end)

	it("removes native Guard effects and manual enemy padding without changing the source", function()
		newBuild()
		for id, class in pairs(build.spec.tree.classes) do
			if class.name == "Marauder" then build.spec:SelectClass(id); break end
		end
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local strengthNode
		for _, node in pairs(build.spec.nodes) do
			if (node.name or node.dn) == "Strength" and node.path
				and (not strengthNode or #node.path < #strengthNode.path or (#node.path == #strengthNode.path and node.id < strengthNode.id)) then
				strengthNode = node
			end
		end
		assert.is_true(strengthNode ~= nil, "Missing native Strength route for the fixture")
		build.spec:AllocNode(strengthNode)
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.skillsTab:PasteSocketGroup("Molten Shell 1/0  1")
		build.mainSocketGroup = 1
		for _, group in ipairs(build.skillsTab.socketGroupList) do
			group.enabled = true
			for _, gem in ipairs(group.gemList) do gem.enableGlobal1 = true end
		end
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		local input = build.configTab.input
		input.enemyIsBoss = "Boss"
		input.enemyLevel = 1
		input.enemyPhysicalDamage = 1
		input.enemyDamageType = "Untyped"
		input.conditionEnemyShocked = true
		input.conditionShockEffect = 65
		input.conditionEnemyFrozen = true
		input.conditionKilledRecently = true
		input.useFrenzyCharges = true
		input.overrideFrenzyCharges = 1
		build.configTab:BuildModList()
		build.calcsTab:BuildOutput()
		local before = build.calcsTab.mainOutput
		assert.is_true(before.GuardSkillActive)
		assert.are.equal(1, before.FrenzyCharges)
		local signature = Candidate.BuildSignature(build)
		local result
		for _, profile in ipairs({ "PinnacleUnbuffed", "PinnacleChassis" }) do
			local parsed = assert(Inputs.Parse({ scenarioProfile = profile, objectiveMetric = "FullDPS", maxAddedPoints = 0, evaluationBudget = 1 }))
			local job = Phantom.RunPhantomSim(build, parsed)
			local steps = 0
			while job.status == "running" do
				job:Step()
				steps = steps + 1
				assert.is_true(steps < 15, "Bounded scenario did not terminate")
			end
			assert.are.equal("feasible", job.status, job.error or (job.result and require("dkjson").encode(job.result.bestObservedViolations)))
			result = job.result
			assert.are.equal("pass", result.evaluation.activitySustain.status)
			assert.are.equal("pass", result.evaluation.enabledSkillsPayability.status)
			local audit = result.evaluation.scenario
			assert.are.equal(signature, Candidate.BuildSignature(build))
			assert.are.equal(profile, result.scenarioProfile)
			if profile == "PinnacleUnbuffed" then
				assert.is_true(audit.guardSkillActive)
				assert.is_true(audit.chargeAudit.countsAreExactPoBOutput)
				assert.is_false(audit.chargeAudit.generationConsumptionSimulated)
				assert.are.equal(0, audit.chargeAudit.charges[2].current,
					"Pinnacle must not carry the user-configured Frenzy Charge state")
				assert.is_true(audit.chargeAudit.uptimeCertified)
				local removedFrenzyAssumption
				for _, row in ipairs(audit.chargeAudit.clearedConfiguredFields) do
					if row.key == "useFrenzyCharges" then removedFrenzyAssumption = row end
				end
				assert.is_true(removedFrenzyAssumption and removedFrenzyAssumption.inputValue)
				assert.are.equal("configured_shock_with_exact_pob_output", audit.shockAudit.status)
				assert.are.equal(50, audit.shockAudit.effectivePoBOutput)
				local configuredShockEffect
				for _, assumption in ipairs(audit.shockAudit.configuredAssumptions) do
					if assumption.key == "conditionShockEffect" then configuredShockEffect = assumption.value end
				end
				assert.are.equal(65, configuredShockEffect)
				assert.is_false(audit.shockAudit.uptimeCertified)
			else
				assert.is_true(audit.guardBuffsDisabledByEngine)
				assert.is_false(audit.guardSkillActive)
				assert.is_true(audit.suppressedGuardBuffs > 0)
				assert.are.equal(84, audit.enemyLevel)
				assert.are.equal(0, audit.currentShock)
				assert.are.equal("no_shock_in_exact_output", audit.shockAudit.status)
				assert.is_true(audit.shockAudit.uptimeCertified)
				assert.is_true(result.evaluation.metrics.Armour < before.Armour)
			end
		end
		assert.are.equal(1, input.enemyLevel)
		assert.are.equal(65, input.conditionShockEffect)
		assert.is_true(input.conditionEnemyFrozen)
		assert.is_true(input.useFrenzyCharges)
		assert.are.equal(1, input.overrideFrenzyCharges)
		assert.is_true(build.calcsTab.mainOutput == before)

		-- Independent control: prepare the equivalent ordinary PoB build using
		-- normal gem/config state, then compare its unrounded engine outputs.
		build.skillsTab.socketGroupList[2].gemList[1].enabled = false
		input.enemyIsBoss = "Pinnacle"
		for _, key in ipairs({ "enemyLevel", "enemyPhysicalDamage", "enemyDamageType", "conditionEnemyShocked", "conditionShockEffect", "conditionEnemyFrozen", "conditionKilledRecently", "useFrenzyCharges", "overrideFrenzyCharges" }) do
			input[key] = nil
		end
		build.configTab:BuildModList()
		build.calcsTab:BuildOutput()
		local normal = build.calcsTab.mainOutput
		assert.is_false(normal.GuardSkillActive)
		for _, key in ipairs({ "CombinedDPS", "FullDPS", "TotalEHP", "Armour", "Life", "EnergyShield", "PhysicalMaximumHitTaken", "FireMaximumHitTaken" }) do
			local actual, expected = result.evaluation.metrics[key], normal[key]
			assert.is_true(type(actual) == "number" and type(expected) == "number", "Missing exact metric " .. key)
			assert.is_true(math.abs(actual - expected) <= math.max(1, math.abs(expected)) * 1e-9, "Native parity mismatch: " .. key)
		end
		newBuild()
	end)

	it("retains only Mageblood utility flasks that the exact Pinnacle engine activates", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local magebloodData
		for _, unique in pairs(main.uniqueDB.list or { }) do
			if unique.title == "Mageblood" then magebloodData = unique break end
		end
		assert.is_true(magebloodData and type(magebloodData.raw) == "string", "PoB 3.29 Mageblood data is unavailable")
		local mageblood = new("Item"):Item(magebloodData.raw)
		assert.are.equal("Mageblood", mageblood.title)
		assert.are.equal("UNIQUE", mageblood.rarity)
		build.itemsTab:AddItem(mageblood, true)
		build.itemsTab:EquipItemInSet(mageblood, build.itemsTab.activeItemSetId)
		local flasks = { }
		for index, baseName in ipairs({ "Granite Flask", "Quicksilver Flask" }) do
			local flask = new("Item"):Item("Rarity: Magic\n" .. baseName)
			assert.are.equal("Flask", flask.type)
			assert.are.equal("MAGIC", flask.rarity)
			build.itemsTab:AddItem(flask, true)
			build.itemsTab.slots["Flask " .. tostring(index)]:SetSelItemId(flask.id)
			flasks[index] = flask
		end
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			scenarioProfile = "PinnacleChassis", objectiveMetric = "TotalEHP",
			maxAddedPoints = 0, evaluationBudget = 1,
		}))
		local job = Phantom.RunPhantomSim(build, parsed)
		local steps = 0
		while job.status == "running" do
			job:Step()
			steps = steps + 1
			assert.is_true(steps < 20, "Mageblood Pinnacle audit did not terminate")
		end
		assert.are.equal("feasible", job.status, job.error or (job.result and require("dkjson").encode(job.result.bestObservedViolations)))
		local audit = job.result.evaluation.scenario.flaskAudit
		assert.are.equal("native_permanent_magic_utility", audit.status)
		assert.are.equal(2, audit.magebloodPermanentCount)
		assert.are.equal(2, audit.activeCount)
		assert.are.same({ "Granite Flask", "Quicksilver Flask" }, audit.activeNames)
		assert.are.equal(0, audit.unexpectedActiveCount)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("rejects the live Scion Fireball fixture when PoB's exact recurring mana cost is unsustainable", function()
		newBuild()
		build.characterLevel = 9
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local output = build.calcsTab.mainOutput
		local activity = output.OptimizerMainSkillActivity
		assert.is_true(activity and activity.hasDamage)
		assert.is_truthy(activity.poBDamage and activity.poBDamage.player)
		assert.are.equal(output.TotalDPS, activity.poBDamage.player.TotalDPS)
		assert.is_true(activity.resources.Mana.cost > activity.resources.Mana.netRegen)
		local expectedMargin = activity.resources.Mana.netRegen + activity.resources.Mana.leech + activity.resources.Mana.onHit - activity.resources.Mana.cost
		assert.is_true(expectedMargin < 0)
		local signature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({ objectiveMetric = "FullDPS", maxAddedPoints = 0, evaluationBudget = 1 }))
		local job = Phantom.RunPhantomSim(build, parsed)
		while job.status == "running" do job:Step() end
		assert.are.equal("no_feasible_candidate", job.status, job.error)
		assert.is_true(job.result.candidate == nil)
		local sustainViolation
		for _, violation in ipairs(job.result.bestObservedViolations or { }) do
			if violation.key == "activity_sustain_mana" then sustainViolation = violation end
		end
		assert.is_true(sustainViolation ~= nil, require("dkjson").encode(job.result.bestObservedViolations))
		assert.are.equal(expectedMargin, sustainViolation.actual)
		assert.are.equal(signature, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("rejects a candidate that exceeds the exact manual-skill cap and returns the audit", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local before = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			objectiveMetric = "FullDPS",
			maxManualButtons = "0",
			maxAddedPoints = 0,
			evaluationBudget = 1,
		}))
		local job = Phantom.RunPhantomSim(build, parsed)
		while job.status == "running" do job:Step() end
		assert.are.equal("no_feasible_candidate", job.status, job.error)
		assert.is_true(job.result.candidate == nil)
		local violation
		for _, item in ipairs(job.result.bestObservedViolations or { }) do
			if item.key == "manual_button_cap" then violation = item end
		end
		assert.is_true(violation ~= nil, require("dkjson").encode(job.result.bestObservedViolations))
		assert.are.equal(1, violation.actual)
		assert.are.equal(0, violation.required)
		assert.is_true(job.result.bestObservedMetrics.FullDPS ~= nil)
		assert.is_true(job.result.bestObservedMetrics.FullDPS == job.result.bestObservedMetrics.FullDPS)
		assert.are.equal(before, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("rejects a damage action over the separate exact manual-damage cap", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local before = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			objectiveMetric = "FullDPS",
			maxManualDamageButtons = "0",
			maxAddedPoints = 0,
			evaluationBudget = 1,
		}))
		local job = Phantom.RunPhantomSim(build, parsed)
		while job.status == "running" do job:Step() end
		assert.are.equal("no_feasible_candidate", job.status, job.error)
		assert.is_true(job.result.candidate == nil)
		local violation
		for _, item in ipairs(job.result.bestObservedViolations or { }) do
			if item.key == "manual_damage_button_cap" then violation = item end
		end
		assert.is_true(violation ~= nil, require("dkjson").encode(job.result.bestObservedViolations))
		assert.are.equal(1, violation.actual)
		assert.are.equal(0, violation.required)
		assert.are.equal(before, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("uses PoB's recoup-free net recovery when enemy damage-over-time is configured", function()
		newBuild()
		build.characterLevel = 9
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyDamageType = "DamageOverTime"
		build.configTab.input.enemyFireDamage = 10
		build.configTab:BuildModList()
		build.calcsTab:BuildOutput()
		local output = build.calcsTab.mainOutput
		assert.is_true(type(output.FireEnemyDegen) == "number" and output.FireEnemyDegen > 0, require("dkjson").encode({ fire = output.FireEnemyDegen, enemyDamageType = build.configTab.input.enemyDamageType, enemyFireDamage = build.configTab.input.enemyFireDamage }))
		assert.is_true(type(output.OptimizerNetLifeRegen) == "number", "Missing optimizer net life regen")
		assert.is_true(output.OptimizerNetLifeRegen < output.LifeRegenRecovery, require("dkjson").encode({ optimizerNet = output.OptimizerNetLifeRegen, gross = output.LifeRegenRecovery, fire = output.FireEnemyDegen }))
		assert.is_true(type(output.ComprehensiveNetLifeRegen) == "number")
		local withoutRecoup = output.ComprehensiveNetLifeRegen - (output.LifeRecoupRecoveryAvg or 0)
		assert.is_true(math.abs(output.OptimizerNetLifeRegen - withoutRecoup) < 0.000001, require("dkjson").encode({ optimizerNet = output.OptimizerNetLifeRegen, comprehensive = output.ComprehensiveNetLifeRegen, recoup = output.LifeRecoupRecoveryAvg }))
		local record = output.OptimizerMainSkillActivity
		assert.are.equal(output.OptimizerNetLifeRegen, record.resources.Life.netRegen)
		newBuild()
	end)

	it("never returns a candidate whose enabled gem exceeds native attributes or character level", function()
		newBuild()
		build.characterLevel = 10
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local before = Candidate.BuildSignature(build)
		local job = Phantom.RunPhantomSim(build, assert(Inputs.Parse({ objectiveMetric = "FullDPS", maxAddedPoints = 0, evaluationBudget = 1 })))
		while job.status == "running" do job:Step() end
		assert.are.equal("no_feasible_candidate", job.status, job.error)
		assert.is_true(job.result.candidate == nil)
		local violations = { }
		for _, violation in ipairs(job.result.bestObservedViolations) do violations[violation.key] = violation end
		assert.is_true(violations.level_requirement ~= nil)
		assert.is_true(violations.attribute_requirement_Int ~= nil)
		assert.are.equal(10, violations.level_requirement.actual)
		assert.are.equal(build.calcsTab.mainOutput.ReqInt, violations.attribute_requirement_Int.required)
		assert.are.equal(before, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("uses PoB's exact level and act quest-point limits", function()
		newBuild()
		for _, expected in ipairs({
			{ 1, 0, 1 }, { 12, 13, 2 }, { 22, 25, 3 },
			{ 40, 46, 5 }, { 67, 89, 11 }, { 100, 122, 11 },
		}) do
			local actual, act = build:GetPassivePointLimitForLevel(expected[1], 0)
			assert.are.equal(expected[2], actual, "passive points at level " .. tostring(expected[1]))
			assert.are.equal(expected[3], act, "act index at level " .. tostring(expected[1]))
		end
		assert.are.equal(0, build:GetPassivePointLimitForLevel(1, 1))
		assert.are.equal(26, build:GetPassivePointLimitForLevel(22, 1))
		assert.are.equal(123, build:GetPassivePointLimitForLevel(100, 1))
		newBuild()
	end)

	it("rejects a manual level-one tree edit above its native point allowance", function()
		newBuild()
		build.characterLevel = 1
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		local adjacentNode = findClassStartNeighbor(build.spec)
		assert.is_true(adjacentNode ~= nil, "Missing a legal one-point passive-tree neighbor")
		local parsed = assert(Inputs.Parse({
			objectiveMetric = "CombinedDPS",
			addNodeIds = tostring(adjacentNode.id),
			maxAddedPoints = 1,
			evaluationBudget = 1,
		}))
		local job = Phantom.RunPhantomSim(build, parsed)
		while job.status == "running" do job:Step() end
		assert.are.equal("no_feasible_candidate", job.status, job.error)
		assert.is_true(job.result.candidate == nil)
		assert.are.equal("passive_point_limit", job.result.bestObservedViolations[1].key,
			require("dkjson").encode(job.result.bestObservedViolations))
		assert.are.equal(1, job.result.bestObservedViolations[1].actual)
		assert.are.equal(0, job.result.bestObservedViolations[1].required)
		assert.are.equal(0, job.result.evaluations)
		newBuild()
	end)

	it("blocks an MCP passive edit that exceeds the manual character-level point limit", function()
		newBuild()
		build.characterLevel = 1
		build.characterLevelAutoMode = false
		local adjacentNode = findClassStartNeighbor(build.spec)
		assert.is_true(adjacentNode ~= nil, "Missing a legal one-point passive-tree neighbor")
		local signature = Candidate.BuildSignature(build)
		local result, message = MCPBridge:CallLocal("apply_passive_delta", { addNodeIds = { adjacentNode.id } })
		assert.is_nil(result)
		assert.is_truthy(message and message:find("exact passive-point limit", 1, true), message)
		assert.are.equal(signature, Candidate.BuildSignature(build))
		assert.are.equal(0, build.spec:CountAllocNodes())
		newBuild()
	end)
end)
