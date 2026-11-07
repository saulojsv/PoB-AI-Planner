local Candidate = require("Modules.Optimizer.Candidate")
local MCPBridge = require("Modules.Optimizer.MCPBridge")
local AIChat = require("Modules.Optimizer.AIChat")
local Calcs = require("Modules.Calcs")
local Inputs = require("Modules.Optimizer.Inputs")
local Breakpoints = require("Modules.Optimizer.Breakpoints")
local Activity = require("Modules.Optimizer.Activity")
local SkillAvailability = require("Modules.Optimizer.SkillAvailability")
local ExactFixtures = require("System.fixtures.OptimizerExactMechanics_3_29")

describe("Optimizer native skill-mechanics snapshot", function()
	it("exposes loaded gem tags, selected-effect types, and exact PoB conversion to MCP, Ask AI, and planner QA", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.configTab.input.customMods = [[
50% of Physical Damage Converted to Lightning Damage
50% of Lightning Damage Converted to Cold Damage
]]
		build.configTab:BuildModList()
		build.calcsTab:BuildOutput()

		local sourceSignature = Candidate.BuildSignature(build)
		local nativeSkill = assert(build.calcsTab.mainEnv.player.mainSkill)
		local nativeConversion = assert(nativeSkill.conversionTable)
		local snapshot, snapshotError = MCPBridge:CallLocal("get_build_snapshot", { })
		assert.is_nil(snapshotError)
		local mechanics = assert(snapshot.mainSkillMechanics)
		assert.are.equal("resolved", mechanics.status)
		assert.are.equal("Fireball", mechanics.name)
		assert.are.equal("Fireball", mechanics.gem.name)
		assert.are.equal("exact", mechanics.effectTypeStatus)
		local effectTypes = { }
		for _, effectType in ipairs(mechanics.effectTypes) do effectTypes[effectType] = true end
		assert.is_true(effectTypes.Spell)
		assert.is_true(effectTypes.Projectile)
		assert.is_true(effectTypes.Fire)
		assert.is_nil(effectTypes.Vaal)
		local tags = { }
		for _, tag in ipairs(mechanics.tags) do tags[tag] = true end
		assert.is_true(tags.Projectile)
		assert.is_true(tags.Spell)
		assert.is_true(tags.Fire)
		assert.are.equal("exact", mechanics.conversion.status)
		assert.are.equal("PoB CalcOffence active-skill conversionTable", mechanics.conversion.source)
		local snapshotTool
		for _, namespace in ipairs(AIChat.ToolDefinitions) do
			for _, tool in ipairs(namespace.tools or { }) do
				if tool.name == "get_build_snapshot" then snapshotTool = tool break end
			end
		end
		assert.is_truthy(snapshotTool)
		assert.is_truthy(snapshotTool.description:find("loaded gem tags", 1, true))
		assert.is_truthy(snapshotTool.description:find("native active-effect skill types", 1, true))
		assert.is_truthy(snapshotTool.description:find("distinct for variants such as Vaal gems", 1, true))
		assert.is_truthy(snapshotTool.description:find("CalcOffence conversion", 1, true))

		local edgeByPair = { }
		for _, edge in ipairs(mechanics.conversion.converted) do
			edgeByPair[edge.from .. ">" .. edge.to] = edge
		end
		assert.are.equal(0.5, edgeByPair["Physical>Lightning"].fraction)
		assert.are.equal(nativeConversion.Physical.conversion.Lightning, edgeByPair["Physical>Lightning"].fraction)
		assert.are.equal(0.5, edgeByPair["Lightning>Cold"].fraction)
		assert.are.equal(nativeConversion.Lightning.conversion.Cold, edgeByPair["Lightning>Cold"].fraction)
		assert.are.equal(5, #mechanics.conversion.remaining)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))

		local started, startError = MCPBridge:CallLocal("qa_start", { suite = "planner" })
		assert.is_nil(startError)
		for _ = 1, 16 do
			MCPBridge:StepQASuites()
			local current = assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId }))
			if current.status ~= "running" then break end
		end
		local qaResult = assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId }))
		assert.are.equal("passed", qaResult.status, qaResult.error)
		assert.are.equal(6, #qaResult.checks, "the current source must expose all six native Planner QA checks")
		for _, check in ipairs(qaResult.checks) do
			assert.are.equal("pass", check.status, check.name .. " must pass against the current source")
		end
		local mechanicsCheck
		for _, check in ipairs(qaResult.checks or { }) do
			if check.name == "Native skill tags and exact damage-conversion provenance" then mechanicsCheck = check end
		end
		assert.is_truthy(mechanicsCheck)
		assert.are.equal("pass", mechanicsCheck.status)
		assert.is_truthy(mechanicsCheck.detail:find("CalcOffence", 1, true))
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
	end)

	it("keeps Vaal gem tags separate from the selected non-Vaal active effect", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Vaal Fireball 20/0  1")
		build.mainSocketGroup = 1
		local group = build.skillsTab.socketGroupList[1]
		group.includeInFullDPS = true
		build.calcsTab:BuildOutput()

		local normalFireballIndex
		for index, activeSkill in ipairs(group.displaySkillList or { }) do
			local effect = activeSkill.activeEffect or (activeSkill.effectList and activeSkill.effectList[1])
			if effect and effect.grantedEffect and effect.grantedEffect.id == "Fireball" then
				normalFireballIndex = index
				break
			end
		end
		assert.is_truthy(normalFireballIndex, "Vaal Fireball should expose its native secondary Fireball effect")
		group.mainActiveSkill = normalFireballIndex
		build.calcsTab:BuildOutput()

		local snapshot = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
		local mechanics = assert(snapshot.mainSkillMechanics)
		assert.are.equal("Vaal Fireball", mechanics.gem.name)
		assert.are.equal("Fireball", mechanics.effect.name)
		assert.are.equal("exact", mechanics.effectTypeStatus)
		local gemTags, effectTypes = { }, { }
		for _, tag in ipairs(mechanics.gem.tags) do gemTags[tag] = true end
		for _, effectType in ipairs(mechanics.effectTypes) do effectTypes[effectType] = true end
		assert.is_true(gemTags.Vaal)
		assert.is_nil(effectTypes.Vaal)
		assert.are.equal("exact", mechanics.conversion.status)
	end)

	it("keeps Vaal Cold Snap damage exact while gating only its uncertified soul cadence", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Vaal Cold Snap 20/0 1")
		build.mainSocketGroup = 1
		local group = build.skillsTab.socketGroupList[1]
		group.includeInFullDPS = true
		build.calcsTab:BuildOutput()

		local vaalIndex, regularIndex
		for index, activeSkill in ipairs(group.displaySkillList or { }) do
			local effect = activeSkill.activeEffect or (activeSkill.effectList and activeSkill.effectList[1])
			local effectId = effect and effect.grantedEffect and effect.grantedEffect.id
			if effectId == "VaalColdSnap" then vaalIndex = index end
			if effectId == "ColdSnap" then regularIndex = index end
		end
		assert.is_truthy(vaalIndex, "Vaal Cold Snap gem must expose PoB's Vaal effect")
		assert.is_truthy(regularIndex, "Vaal Cold Snap gem must expose PoB's regular Cold Snap effect")
		local inputs = assert(Inputs.Parse({ objectiveMetric = "CombinedDPS" }))

		group.mainActiveSkill = vaalIndex
		build.calcsTab:BuildOutput()
		local vaalOutput = build.calcsTab.mainOutput
		local vaalSnapshot = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
		local vaalMechanics = assert(vaalSnapshot.mainSkillMechanics)
		assert.are.equal("Vaal Cold Snap", vaalMechanics.gem.name)
		assert.are.equal("Vaal Cold Snap", vaalMechanics.effect.name)
		assert.are.equal("exact", vaalMechanics.effectTypeStatus)
		assert.are.equal("exact", vaalMechanics.conversion.status)
		assert.is_true(type(vaalOutput.CombinedDPS) == "number" and vaalOutput.CombinedDPS > 0,
			"the Vaal effect must retain PoB's exact damage output")
		local vaalAvailability = SkillAvailability.Evaluate(inputs, build.calcsTab.mainEnv.player, nil, vaalOutput)
		assert.are.equal("unsupported", vaalAvailability.status)
		assert.is_false(vaalAvailability.feasible)
		assert.is_truthy(vaalAvailability.reason:find("soul generation", 1, true))

		group.mainActiveSkill = regularIndex
		build.calcsTab:BuildOutput()
		local regularSnapshot = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
		local regularMechanics = assert(regularSnapshot.mainSkillMechanics)
		assert.are.equal("Vaal Cold Snap", regularMechanics.gem.name)
		assert.are.equal("Cold Snap", regularMechanics.effect.name)
		local gemHasVaalTag, effectHasVaalType = false, false
		for _, tag in ipairs(regularMechanics.gem.tags) do if tag == "Vaal" then gemHasVaalTag = true end end
		for _, effectType in ipairs(regularMechanics.effectTypes) do if effectType == "Vaal" then effectHasVaalType = true end end
		assert.is_true(gemHasVaalTag, "the source gem must retain its Vaal identity")
		assert.is_false(effectHasVaalType, "the selected regular effect must not inherit the Vaal skill type")
		local regularAvailability = SkillAvailability.Evaluate(inputs, build.calcsTab.mainEnv.player, nil, build.calcsTab.mainOutput)
		assert.are.equal("valid", regularAvailability.status,
			"the regular Cold Snap mode must not be rejected by the Vaal soul-cadence gate")
	end)

	it("runs attack, minion, DoT, reservation, event-trigger, cooldown-trigger, and conversion fixtures through exact PoB", function()
		local cocMeasurements = { }
		local mineMeasurements = { }
		local fixtureOrder = { "attack", "minion", "dot", "lifeReservation", "manaReservation", "lifeCost", "trigger", "mineControl", "minefield", "trapControl", "totemControl", "brandControl", "cwdt", "heartboundSkeletons", "coc", "cocAttackRate", "cocCooldownRecovery", "cocHighRateRecovery", "chainedConversion" }
		for _, fixtureName in ipairs(fixtureOrder) do
			local fixture = assert(ExactFixtures.fixtures[fixtureName])
			newBuild()
			build.characterLevel = 90
			build.characterLevelAutoMode = false
			local lifeCostControl
			if fixtureName == "lifeCost" then
				build.skillsTab:PasteSocketGroup("Fireball 20/0 1")
				build.mainSocketGroup = 1
				runCallback("OnFrame")
				build.calcsTab:BuildOutput()
				lifeCostControl = {
					lifePerSecond = assert(build.calcsTab.mainOutput.LifePerSecondCost),
					manaPerSecond = assert(build.calcsTab.mainOutput.ManaPerSecondCost),
				}
				assert.is_true(lifeCostControl.manaPerSecond > 0,
					"self-cast control must spend mana before comparing Lifetap")
				newBuild()
				build.characterLevel = 90
				build.characterLevelAutoMode = false
			end
			local itemRaw = fixture.item or fixture.weapon
			if itemRaw then
				-- Go through the same parser and auto-equip path as the native Items tab.
				build.itemsTab:CreateDisplayItemFromRaw(itemRaw)
				build.itemsTab:AddDisplayItem()
				build.itemsTab:PopulateSlots()
				build:SyncLoadouts()
			end
			build.mainSocketGroup = fixture.mainSocketGroup or 1
			for _, socketGroup in ipairs(fixture.socketGroups) do
				build.skillsTab:PasteSocketGroup(socketGroup)
			end
			local group = assert(build.skillsTab.socketGroupList[build.mainSocketGroup])
			group.includeInFullDPS = true
			if fixture.customMods then
				build.configTab.input.customMods = fixture.customMods
				build.configTab:BuildModList()
			end
			runCallback("OnFrame")
			if fixture.triggeredMainSkill then
				local triggeredSkillIndex
				for index, activeSkill in ipairs(group.displaySkillList or { }) do
					local effect = activeSkill.activeEffect or (activeSkill.effectList and activeSkill.effectList[1])
					if effect and effect.grantedEffect and effect.grantedEffect.name == fixture.triggeredMainSkill then
						triggeredSkillIndex = index
						break
					end
				end
				assert.is_truthy(triggeredSkillIndex, fixture.id .. " must resolve the intended triggered skill")
				group.mainActiveSkill = triggeredSkillIndex
				build.modFlag = true
				build.buildFlag = true
				runCallback("OnFrame")
			end
			if fixture.activeMineCount then
				local calcsGroup = assert(build.skillsTab.socketGroupList[build.calcsTab.input.skill_number])
				local selected = assert(calcsGroup.displaySkillListCalcs[calcsGroup.mainActiveSkillCalcs or 1])
				selected.activeEffect.srcInstance.skillMineCountCalcs = fixture.activeMineCount
				build.modFlag = true
				build.buildFlag = true
				runCallback("OnFrame")
			end
			build.calcsTab:BuildOutput()

			local sourceSignature = Candidate.BuildSignature(build)
			local baseline = assert(build.calcsTab.mainOutput)
			local snapshot = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
			assert.are.equal("3_29", snapshot.treeVersion, fixture.id .. " must use the active 3.29 tree data")
			assert.is_truthy(snapshot.mainSkill, fixture.id .. " must resolve a native Main Skill")
			for _, metric in ipairs(fixture.requireFiniteMetrics) do
				assert.is_true(type(baseline[metric]) == "number" and baseline[metric] == baseline[metric]
					and baseline[metric] ~= math.huge and baseline[metric] ~= -math.huge,
					fixture.id .. " must produce finite exact " .. metric)
				assert.is_true(type(snapshot.exactMetrics[metric]) == "number",
					fixture.id .. " MCP snapshot must expose exact " .. metric)
			end
			for _, metric in ipairs(fixture.minimumPositiveMetrics or { }) do
				assert.is_true(baseline[metric] > 0, fixture.id .. " must exercise positive " .. metric)
			end
			if fixture.expectedEffectType then
				local found = false
				for _, effectType in ipairs(snapshot.mainSkillMechanics.effectTypes or { }) do
					if effectType == fixture.expectedEffectType then found = true break end
				end
				assert.is_true(found, fixture.id .. " must expose its exact native " .. fixture.expectedEffectType .. " skill type")
			end
			if fixture.expectedActivityKind then
				local selected = assert(build.calcsTab.mainEnv.player.mainSkill)
				if fixture.expectedSkillFlag then
					assert.is_true(selected.skillFlags[fixture.expectedSkillFlag],
						fixture.id .. " must retain PoB's native " .. fixture.expectedSkillFlag .. " skill flag")
				end
				if fixture.expectedSkillType then
					assert.is_true(selected.skillTypes[SkillType[fixture.expectedSkillType]],
						fixture.id .. " must retain PoB's native " .. fixture.expectedSkillType .. " skill type")
				end
				local activityRecord = assert(baseline.OptimizerMainSkillActivity)
				assert.are.equal(fixture.expectedActivityKind, activityRecord.kind)
				assert.is_truthy(activityRecord.unsupportedReason)
				assert.is_truthy(activityRecord.unsupportedReason:find(fixture.expectedUnsupportedFragment, 1, true))
				local sustain = Activity.Evaluate({ objective = "CombinedDPS", hard = { } }, activityRecord, { }, false)
				assert.are.equal("unsupported", sustain.status,
					fixture.id .. " exact configured DPS must not certify unsimulated activity cadence")
				assert.is_false(sustain.feasible)
				print(string.format("ACTIVITY_BOUNDARY %s kind=%s combinedDPS=%.9f fullDPS=%.9f gate=%s reason=%s",
					fixture.id, activityRecord.kind, baseline.CombinedDPS, baseline.FullDPS,
					sustain.status, table.concat(sustain.unsupported or { }, "; ")))
			end
			if fixtureName == "attack" then
				assert.is_true(baseline.CombinedDPS > 0 and baseline.Speed > 0,
					"attack fixture must expose selected DPS and native attack rate")
			elseif fixtureName == "minion" then
				assert.is_true(baseline.FullDPS > 0, "minion fixture must contribute exact included-group DPS")
				assert.is_true(#(snapshot.fullDPSBreakdown or { }) > 0,
					"minion fixture must expose PoB's included-skill damage breakdown")
			elseif fixtureName == "dot" then
				assert.is_true(baseline.FullDotDPS > 0, "DoT fixture must expose exact included-group DoT DPS")
			elseif fixtureName == "lifeReservation" then
				assert.is_true(baseline.LifeReserved > 0 and baseline.LifeUnreserved > 0,
					"Arrogance must reserve life while leaving a positive native life pool")
			elseif fixtureName == "manaReservation" then
				assert.is_true(baseline.ManaReserved > 0 and baseline.ManaUnreserved > 0,
					"Determination must reserve mana while leaving a positive native mana pool")
			elseif fixtureName == "lifeCost" then
				assert.is_true(baseline.LifePerSecondCost > 0,
					"Lifetap must move the exact recurring skill cost onto life")
				assert.is_true(baseline.ManaPerSecondCost < lifeCostControl.manaPerSecond,
					"Lifetap must reduce the exact recurring mana cost against the self-cast control")
				assert.is_true(baseline.LifePerSecondCost > lifeCostControl.lifePerSecond,
					"Lifetap must increase the exact recurring life cost against the self-cast control")
			elseif fixtureName == "trigger" then
				assert.is_true(type(baseline.SkillTriggerRate) == "number" and baseline.SkillTriggerRate > 0,
					"trigger fixture must reach PoB's native trigger-rate output")
				assert.is_true(type(baseline.TriggerRateCap) == "number" and baseline.TriggerRateCap > 0,
					"trigger fixture must retain the server-cooldown trigger cap")
			elseif fixtureName == "mineControl" then
				local selected = assert(build.calcsTab.calcsEnv.player.mainSkill)
				assert.is_true(selected.skillTypes[SkillType.RemoteMined], "Icicle Mine control must resolve as a native remotely-mined skill")
				assert.are.equal(1, baseline.MineThrowCount, "self-cast Icicle Mine must start with one mine per throw")
				assert.are.equal(1, selected.activeMineCount, "the control must use the explicit one-active-mine CALCS input")
				local activityRecord = assert(baseline.OptimizerMainSkillActivity)
				assert.is_truthy(activityRecord.unsupportedReason, "mine damage output must not certify mine stock/detonation cadence")
				local sustain = Activity.Evaluate({ objective = "CombinedDPS", hard = { } }, activityRecord, { }, false)
				assert.are.equal("unsupported", sustain.status, "a mine damage snapshot alone must not certify sustained DPS")
				mineMeasurements.control = {
					mineThrowCount = baseline.MineThrowCount,
					mineLayingSpeed = baseline.MineLayingSpeed,
					mineLayingTime = baseline.MineLayingTime,
					combinedDPS = baseline.CombinedDPS,
				}
			elseif fixtureName == "minefield" then
				local selected = assert(build.calcsTab.mainEnv.player.mainSkill)
				assert.is_true(selected.skillTypes[SkillType.RemoteMined], "Minefield fixture must retain the native remotely-mined skill type")
				assert.is_true(selected.supportList and #selected.supportList > 0, "Minefield support must be applied through PoB's native socket links")
				local minefieldFound = false
				for _, support in ipairs(selected.supportList) do
					local effect = support.grantedEffect or support.activeEffect and support.activeEffect.grantedEffect
					if effect and effect.name == "Minefield" then minefieldFound = true end
				end
				assert.is_true(minefieldFound, "the linked support must resolve to PoB's native Minefield effect")
				assert.are.equal(5, baseline.MineThrowCount, "PoB's Minefield support must report its native four additional mines")
				assert.is_true(baseline.MineLayingSpeed < mineMeasurements.control.mineLayingSpeed,
					"PoB's native extra-throw time penalty must lower laying speed against the no-support control")
				local activityRecord = assert(baseline.OptimizerMainSkillActivity)
				assert.is_truthy(activityRecord.unsupportedReason, "mine placement/detonation cadence must remain explicitly uncertified")
				assert.is_truthy(activityRecord.unsupportedReason:find("mine stock, detonation, and replacement cadence", 1, true),
					"the unsupported boundary must name the exact mine cadence PoB does not model")
				for _, count in ipairs(fixture.activeMineCounts) do
					local calcsGroup = assert(build.skillsTab.socketGroupList[build.calcsTab.input.skill_number])
					local calcsSkill = assert(calcsGroup.displaySkillListCalcs[calcsGroup.mainActiveSkillCalcs or 1])
					calcsSkill.activeEffect.srcInstance.skillMineCountCalcs = count
					build.calcsTab:BuildOutput()
					local sweptOutput = assert(build.calcsTab.calcsOutput)
					assert.are.equal(count, build.calcsTab.calcsEnv.player.mainSkill.activeMineCount,
						"the native active-mines configuration must be reflected by the exact CALCS environment")
					assert.is_true(type(sweptOutput.CombinedDPS) == "number" and sweptOutput.CombinedDPS > 0,
						"each active-mine count must yield an exact positive PoB skill calculation")
					mineMeasurements[count] = {
						combinedDPS = sweptOutput.CombinedDPS,
						fullDPS = sweptOutput.FullDPS,
						totalDPS = sweptOutput.TotalDPS,
						averageHit = sweptOutput.AverageHit,
						mineThrowCount = sweptOutput.MineThrowCount,
						mineLayingSpeed = sweptOutput.MineLayingSpeed,
						mineLayingTime = sweptOutput.MineLayingTime,
					}
				end
				assert.are.equal(mineMeasurements[1].mineThrowCount, mineMeasurements[5].mineThrowCount,
					"active-mine count changes must not overwrite the native mines-per-throw output")
				local finalSnapshot = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
				assert.are.equal("CALCS", finalSnapshot.calculationView.mode)
				assert.are.equal("available", finalSnapshot.calculationView.status)
				assert.are.equal("Icicle Mine", finalSnapshot.calculationView.mainSkill)
				assert.are.equal(build.calcsTab.input.skill_number, finalSnapshot.calculationView.socketGroupIndex)
				assert.are.equal(group.mainActiveSkillCalcs, finalSnapshot.calculationView.skillIndex)
				assert.are.equal(5, finalSnapshot.calculationView.activeMineCount,
					"MCP must expose the exact active-mine CALCS input in a separate calculator view")
				assert.are.equal(mineMeasurements[5].combinedDPS, finalSnapshot.calculationView.exactMetrics.CombinedDPS,
					"MCP CALCS damage must match the exact PoB output for the final active-mine input")
				for _, key in ipairs({ "MineThrowCount", "MineLayingSpeed", "MineLayingTime" }) do
					assert.is_true(type(finalSnapshot.calculationView.exactMetrics[key]) == "number",
						"MCP CALCS metrics must expose PoB's native " .. key .. " output")
				end
				print(string.format("MINEFIELD_EXACT control={throws=%d,speed=%.9f,time=%.9f} minefield={throws=%d,speed=%.9f,time=%.9f} dpsAt1=%.9f dpsAt3=%.9f dpsAt5=%.9f fullDpsAt5=%.9f totalDpsAt5=%.9f averageHitAt5=%.9f activity=unsupported",
					mineMeasurements.control.mineThrowCount, mineMeasurements.control.mineLayingSpeed, mineMeasurements.control.mineLayingTime,
					baseline.MineThrowCount, baseline.MineLayingSpeed, baseline.MineLayingTime,
					mineMeasurements[1].combinedDPS, mineMeasurements[3].combinedDPS, mineMeasurements[5].combinedDPS,
					mineMeasurements[5].fullDPS or 0, mineMeasurements[5].totalDPS or 0, mineMeasurements[5].averageHit or 0))
			elseif fixtureName == "cwdt" then
				local selected = assert(build.calcsTab.mainEnv.player.mainSkill)
				assert.are.equal("Fireball", selected.activeEffect.grantedEffect.name,
					"CWDT fixture must select Fireball as its triggered damage skill")
				assert.are.equal("Cast when Damage Taken", selected.triggeredBy.grantedEffect.name,
					"CWDT fixture must resolve the native trigger support")
				assert.is_true(selected.skillData.triggeredByDamageTaken > 0,
					"PoB must expose the native damage threshold attached to the triggered skill")
				assert.is_true(type(baseline.CWDTThreshold) == "number" and baseline.CWDTThreshold == baseline.CWDTThreshold
					and baseline.CWDTThreshold ~= math.huge and baseline.CWDTThreshold ~= -math.huge and baseline.CWDTThreshold > 0,
					"PoB must expose the exact CWDT threshold after its applicable modifiers")
				assert.is_true(baseline.TriggerRateCap > 0 and baseline.SkillTriggerRate > 0,
					"PoB must preserve its exact cooldown ceiling and reported rate for inspection")
				local floor = Breakpoints.Evaluate(selected, baseline, baseline.SkillTriggerRate)
				assert.are.equal("unsupported", floor.status,
					"a finite CWDT cooldown ceiling must not certify an incoming-damage event rate")
				assert.is_truthy(floor.violations[1]:find("incoming damage-event cadence", 1, true))
				local activityRecord = assert(baseline.OptimizerMainSkillActivity)
				assert.is_truthy(activityRecord.unsupportedReason,
					"PoB activity records must expose the unmodeled CWDT event cadence")
				local sustain = Activity.Evaluate({ objective = "CombinedDPS", hard = { } }, activityRecord, { }, false)
				assert.are.equal("unsupported", sustain.status,
					"triggered damage with unknown event frequency must not pass sustained-DPS certification")
				local activities = assert(Activity.ListScheduleActivities(activityRecord, { }, false))
				local scheduled = Activity.EvaluateSchedule({ }, activityRecord, { }, false, {
					{ identity = activities[1].identity, mode = "continuous" },
				})
				assert.are.equal("unsupported", scheduled.sustainStatus,
					"explicit average-rate schedules must preserve the unmodeled CWDT event-cadence gate")
				print(string.format("CWDT_EXACT threshold=%.9f skillRate=%.9f cooldownCap=%.9f status=%s",
					baseline.CWDTThreshold, baseline.SkillTriggerRate, baseline.TriggerRateCap, floor.status))
			elseif fixtureName == "heartboundSkeletons" then
				local selected = assert(build.calcsTab.mainEnv.player.mainSkill)
				assert.are.equal("Summon Skeletons", selected.activeEffect.grantedEffect.name,
					"Heartbound fixture must resolve Summon Skeletons as the native self-hit source")
				assert.is_true(type(baseline.SummonedMinionsPerCast) == "number" and baseline.SummonedMinionsPerCast > 0,
					"PoB must expose the exact number of Skeletons summoned per cast")
				local activityRecord = assert(baseline.OptimizerMainSkillActivity)
				assert.are.equal("minion", activityRecord.kind)
				assert.is_truthy(activityRecord.unsupportedReason,
					"PoB activity must keep summon/death cadence unsupported for Wardloop")
				assert.is_true(baseline.SelfHitDamage > 0,
					"PoB must calculate the Heartbound Loop self-hit from the native ring and summon count")
				local sustain = Activity.Evaluate({ objective = "CombinedDPS", hard = { } }, activityRecord, { }, false)
				assert.are.equal("unsupported", sustain.status,
					"an exact per-cast self-hit does not certify minion trigger cadence or sustained damage")
				print(string.format("HEARTBOUND_EXACT selfHitDamage=%.9f summonedMinionsPerCast=%.9f activity=%s",
					baseline.SelfHitDamage, baseline.SummonedMinionsPerCast, sustain.status))
			elseif fixtureName == "coc" or fixtureName == "cocAttackRate" or fixtureName == "cocCooldownRecovery" or fixtureName == "cocHighRateRecovery" then
				local selected = assert(build.calcsTab.mainEnv.player.mainSkill)
				assert.are.equal("Ice Spear", selected.activeEffect.grantedEffect.name,
					fixture.id .. " must select Ice Spear as the exact triggered skill")
				assert.are.equal("Cast On Critical Strike", selected.triggeredBy.grantedEffect.name,
					fixture.id .. " must resolve PoB's native Cast On Critical Strike support")
				assert.are.equal(1, selected.skillData.triggeredByCoc,
					fixture.id .. " must use the native CoC trigger mode")
				local exactFloor = Breakpoints.Evaluate(selected, baseline, baseline.SkillTriggerRate)
				local aboveExactFloor = Breakpoints.Evaluate(selected, baseline, baseline.SkillTriggerRate + 0.001)
				assert.are.equal("valid", exactFloor.status,
					fixture.id .. " must accept the equality boundary on PoB's exact triggered rate")
				assert.are.equal("violated", aboveExactFloor.status,
					fixture.id .. " must reject a floor 0.001/s above PoB's exact triggered rate")
				cocMeasurements[fixtureName] = {
					skillTriggerRate = baseline.SkillTriggerRate,
					triggerRateCap = baseline.TriggerRateCap,
					speed = baseline.Speed,
					combinedDPS = baseline.CombinedDPS,
					fullDPS = baseline.FullDPS,
				}
			elseif fixtureName == "chainedConversion" then
				local edgeByPair = { }
				for _, edge in ipairs(snapshot.mainSkillMechanics.conversion.converted or { }) do
					edgeByPair[edge.from .. ">" .. edge.to] = edge.fraction
				end
				for _, expected in ipairs(fixture.conversionEdges) do
					assert.are.equal(expected.fraction, edgeByPair[expected.from .. ">" .. expected.to],
						fixture.id .. " must preserve the native ordered conversion edge")
				end
			end

			local projected, projectionError, isolatedItems = Candidate.BuildPassiveSpec(build, { }, { })
			assert.is_truthy(projected, projectionError)
			local isolatedBuild = { spec = projected, itemsTab = isolatedItems }
			setmetatable(isolatedBuild, { __index = build })
			local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
			local exactOutput, exactEnv = exactCalc({ spec = projected, returnEnv = true }, true)
			assert.is_truthy(exactOutput, fixture.id .. " candidate must recalculate in PoB")
			assert.is_truthy(exactEnv, fixture.id .. " exact candidate must return the native PoB environment")
			for _, metric in ipairs(fixture.requireFiniteMetrics) do
				assert.are.equal(baseline[metric], exactOutput[metric],
					fixture.id .. " no-op candidate must match the active exact PoB metric " .. metric)
			end
			assert.are.equal(sourceSignature, Candidate.BuildSignature(build), fixture.id .. " exact phantom calculation must preserve the source build")
		end
		local coc = assert(cocMeasurements.coc)
		local fasterCoc = assert(cocMeasurements.cocAttackRate)
		local fasterRecoveryCoc = assert(cocMeasurements.cocCooldownRecovery)
		local highRateRecoveryCoc = assert(cocMeasurements.cocHighRateRecovery)
		assert.is_true(fasterCoc.skillTriggerRate > coc.skillTriggerRate,
			"higher attack speed must increase the exact CoC triggered rate in this controlled fixture")
		assert.are.equal(coc.triggerRateCap, fasterCoc.triggerRateCap,
			"attack speed alone must not change the exact CoC cooldown/tick cap")
		assert.are.equal(coc.skillTriggerRate, fasterRecoveryCoc.skillTriggerRate,
			"cooldown recovery alone must not raise a source-limited CoC rate")
		assert.is_true(fasterRecoveryCoc.triggerRateCap > coc.triggerRateCap,
			"14% native cooldown recovery must move the CoC cooldown/tick cap in this 3.29 fixture")
		assert.are.equal(fasterRecoveryCoc.triggerRateCap, highRateRecoveryCoc.triggerRateCap,
			"the combined CoC cell must preserve the exact cooldown-recovery cap")
		assert.is_true(highRateRecoveryCoc.skillTriggerRate > fasterCoc.skillTriggerRate,
			"cooldown recovery must lift the CoC rate above its previous tick-capped value when attack rate allows")
		print(string.format("COC_EXACT baseline={rate=%.9f,cap=%.9f,speed=%.9f,dps=%.9f,full=%.9f} attackSpeed={rate=%.9f,cap=%.9f} cooldownRecovery={rate=%.9f,cap=%.9f} combined={rate=%.9f,cap=%.9f}",
			coc.skillTriggerRate, coc.triggerRateCap, coc.speed, coc.combinedDPS, coc.fullDPS,
			fasterCoc.skillTriggerRate, fasterCoc.triggerRateCap,
			fasterRecoveryCoc.skillTriggerRate, fasterRecoveryCoc.triggerRateCap,
			highRateRecoveryCoc.skillTriggerRate, highRateRecoveryCoc.triggerRateCap))
	end)

	it("keeps unsupported event cadence fatal for a non-main FullDPS CWDT group without a trigger floor", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.mainSocketGroup = 1
		build.skillsTab:PasteSocketGroup("Arc 20/0 1")
		build.skillsTab:PasteSocketGroup("Cast when Damage Taken 1/0 1\nFireball 1/0 2")
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.skillsTab.socketGroupList[2].includeInFullDPS = true
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		local output = assert(build.calcsTab.mainOutput)
		local mainSkill = assert(build.calcsTab.mainEnv.player.mainSkill)
		assert.are.equal("Arc", mainSkill.activeEffect.grantedEffect.name)
		assert.is_nil(mainSkill.triggeredBy, "the main selected skill is the manual control")
		local triggeredActivity
		for _, record in ipairs(output.FullDPSActivity or { }) do
			if record.kind == "triggered" and record.name == "Fireball" then triggeredActivity = record break end
		end
		assert.is_truthy(triggeredActivity, "the non-main included CWDT damage group must enter PoB's FullDPS activity ledger")
		assert.is_truthy(triggeredActivity.unsupportedReason)
		assert.is_truthy(triggeredActivity.unsupportedReason:find("incoming damage-event cadence", 1, true))

		local sustain = Activity.Evaluate({ objective = "FullDPS", hard = { } }, output.OptimizerMainSkillActivity,
			output.FullDPSActivity, output.FullDPSActivityTruncated)
		assert.are.equal("unsupported", sustain.status,
			"the exact optimizer activity gate must reject unsupported trigger cadence even without a SkillTriggerRate floor")
		assert.is_false(sustain.feasible)
		local unsupportedSummary = table.concat(sustain.unsupported or { }, "; ")
		assert.is_truthy(unsupportedSummary:find("incoming damage-event cadence", 1, true))
		local unsupportedViolationFound = false
		for _, violation in ipairs(sustain.violations) do
			if violation.key == "activity_sustain_unsupported" then unsupportedViolationFound = true break end
		end
		assert.is_true(unsupportedViolationFound,
			"the non-main FullDPS trigger must add the strict unsupported activity violation alongside any exact resource deficit")
	end)
end)
