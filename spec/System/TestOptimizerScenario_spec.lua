local Scenario = require("Modules.Optimizer.Scenario")
local ConfigurationChoices = require("Modules.Optimizer.ConfigurationChoices")

describe("Optimizer exact scenario profiles", function()
	local function fixture()
		local itemSet = {
			["Flask 1"] = { selItemId = 101, active = true },
			["Flask 2"] = { selItemId = 102, active = false },
			Helmet = { selItemId = 103, active = true },
		}
		local configSet = {
			input = {
				enemyIsBoss = "Boss",
				conditionKilledRecently = true,
				multiplierKilledRecently = 4,
				conditionEnemyCursed = true,
				conditionUsingFlask = true,
				useFrenzyCharges = true,
				conditionGainedPowerChargeRecently = true,
				conditionEnergyShieldRechargeRecently = true,
				overrideInspirationCharges = 4,
				overrideBloodCharges = 2,
				hoaOverkill = 25,
				customMods = "10% increased Damage while you have Killed Recently\n20% increased Armour\n5% increased Skill Effect Duration",
			},
			placeholder = { multiplierKilledRecently = 2, enemyLevel = 84 },
			customModsList = {
				{ title = "Kill setup", enabled = true, text = "20% increased Damage if you have Killed Recently\n10% increased Life" },
			},
		}
		local controls = {
			enemySpeed = { placeholder = "", SetPlaceholder = function(self, value, notify) self.placeholder = tostring(value); if notify then self.touchedSource = true end end },
		}
		local configTab = {
			activeConfigSetId = 1,
			configSets = { [1] = configSet },
			input = configSet.input,
			placeholder = configSet.placeholder,
			varControls = controls,
			BuildModList = function(self)
				self.rebuilt = true
				self.varControls.enemySpeed:SetPlaceholder(700, true)
			end,
		}
		local build = {
			configTab = configTab,
			itemsTab = {
				activeItemSetId = 1,
				activeItemSet = itemSet,
				itemSets = { [1] = itemSet },
				items = { [101] = { type = "Flask" }, [102] = { type = "Flask" }, [103] = { type = "Helmet" } },
				orderedSlots = {
					{ slotName = "Flask 1", selItemId = 101, active = true, label = "First flask" },
					{ slotName = "Flask 2", selItemId = 102, active = false, label = "Second flask" },
					{ slotName = "Helmet", selItemId = 103, active = true, label = "Helmet" },
				},
			},
		}
		return build, configSet, itemSet, controls
	end

	it("creates a Pinnacle no-flask/no-kill clone without changing the active build", function()
		local build, sourceConfig, sourceItems, sourceControls = fixture()
		local proxyBuild = { }
		local options = {
			{ var = "enemyIsBoss", type = "list" },
			{ var = "conditionKilledRecently", type = "check" },
			{ var = "multiplierKilledRecently", type = "count" },
			{ var = "conditionEnemyCursed", type = "check" },
			{ var = "conditionUsingFlask", type = "check" },
			{ var = "useFrenzyCharges", type = "check" },
			{ var = "conditionGainedPowerChargeRecently", type = "check" },
			{ var = "conditionEnergyShieldRechargeRecently", type = "check" },
			{ var = "overrideInspirationCharges", type = "countAllowZero" },
			{ var = "overrideBloodCharges", type = "countAllowZero" },
			{ var = "overrideCrabBarriers", type = "countAllowZero" },
			{ var = "hoaOverkill", type = "count" },
		}
		local config, items, details, err = Scenario.Create(build, "PinnacleUnbuffed", proxyBuild, options)
		assert.is_nil(err)
		assert.is_true(config.rebuilt)
		assert.are.equal("Pinnacle", config.input.enemyIsBoss)
		assert.is_nil(config.input.conditionKilledRecently)
		assert.is_nil(config.input.multiplierKilledRecently)
		assert.is_nil(config.placeholder.multiplierKilledRecently)
		assert.is_nil(config.input.conditionUsingFlask)
		assert.is_true(config.input.conditionEnemyCursed)
		assert.is_nil(config.input.useFrenzyCharges)
		assert.is_nil(config.input.conditionGainedPowerChargeRecently)
		assert.is_true(config.input.conditionEnergyShieldRechargeRecently,
			"ES recharge conditions must not be mistaken for charge-stack controls")
		assert.are.equal(0, config.input.overrideInspirationCharges)
		assert.are.equal(0, config.input.overrideBloodCharges)
		assert.are.equal(0, config.input.overrideCrabBarriers)
		assert.are.equal(25, config.input.hoaOverkill)
		assert.are.equal("20% increased Armour\n5% increased Skill Effect Duration", config.input.customMods)
		assert.are.equal("10% increased Life", config.configSets[1].customModsList[1].text)
		assert.are.equal(2, details.removedCustomModLines)
		assert.are.equal(3, details.retainedCustomModLines)
		local assumptionsByKey = { }
		for _, assumption in ipairs(details.preservedConditionalAssumptions) do assumptionsByKey[assumption.key] = assumption end
		assert.are.same({ key = "conditionEnemyCursed", value = true, source = "input", configType = "check",
			category = "condition", certification = "configured_state_only" }, assumptionsByKey.conditionEnemyCursed)
		assert.is_nil(assumptionsByKey.useFrenzyCharges)
		assert.are.same({ key = "conditionEnergyShieldRechargeRecently", value = true, source = "input", configType = "check",
			category = "condition", certification = "configured_state_only" }, assumptionsByKey.conditionEnergyShieldRechargeRecently)
		assert.are.same({ key = "hoaOverkill", value = 25, source = "input", configType = "count",
			category = "mechanic_parameter", certification = "configured_state_only" }, assumptionsByKey.hoaOverkill)
		local preserved = table.concat(details.preservedConditionalFields, ",")
		assert.is_truthy(preserved:find("conditionEnemyCursed", 1, true))
		assert.is_nil(preserved:find("useFrenzyCharges", 1, true))
		assert.is_truthy(preserved:find("conditionEnergyShieldRechargeRecently", 1, true))
		local clearedByKey = { }
		for _, row in ipairs(details.clearedChargeState) do clearedByKey[row.key] = row end
		assert.are.equal("cleared", clearedByKey.useFrenzyCharges.policy)
		assert.are.equal(true, clearedByKey.useFrenzyCharges.inputValue)
		assert.are.equal("forced_zero", clearedByKey.overrideInspirationCharges.policy)
		assert.is_truthy(clearedByKey.overrideCrabBarriers)
		assert.are.equal("manual_charge_stacks_removed_native_minimum_floors_retained", details.chargePolicy)
		assert.is_true(config.configSets[1].input ~= sourceConfig.input)
		assert.is_true(items ~= build.itemsTab)
		assert.is_false(items.orderedSlots[1].active)
		assert.is_false(items.activeItemSet["Flask 1"].active)
		assert.is_true(items.orderedSlots[3].active)
		assert.are.equal("PinnacleUnbuffed", details.profile)
		assert.are.equal(1, details.disabledFlasks)
		assert.is_true(sourceConfig.input.conditionKilledRecently)
		assert.is_true(sourceConfig.input.conditionUsingFlask)
		assert.is_true(sourceConfig.input.useFrenzyCharges)
		assert.are.equal(4, sourceConfig.input.overrideInspirationCharges)
		assert.is_true(sourceItems["Flask 1"].active)
		assert.is_nil(sourceControls.enemySpeed.touchedSource)
	end)

	it("reports exact static charge output without claiming generation or uptime", function()
		local audit = Scenario.AuditCharges({
			PowerCharges = 3, PowerChargesMin = 0, PowerChargesMax = 3, PowerChargesDuration = 10,
			FrenzyCharges = 3, FrenzyChargesMin = 0, FrenzyChargesMax = 3, FrenzyChargesDuration = 10,
			EnduranceCharges = 0, EnduranceChargesMin = 0, EnduranceChargesMax = 3, EnduranceChargesDuration = 10,
		}, { { key = "useFrenzyCharges", value = true, source = "input", category = "charges" } })
		assert.are.equal("static_counts_only_uptime_unverified", audit.status)
		assert.is_true(audit.countsAreExactPoBOutput)
		assert.is_false(audit.generationConsumptionSimulated)
		assert.is_false(audit.uptimeCertified)
		assert.are.same({ key = "useFrenzyCharges", value = true, source = "input" }, audit.configuredFields[1])
		assert.are.equal(3, audit.charges[1].current)
		assert.are.equal(3, audit.charges[2].maximum)
		assert.is_true(audit.hasUnverifiedTransientCharges)
		local valid, reason = Scenario.CheckChargeAudit("PinnacleUnbuffed", audit)
		assert.is_false(valid)
		assert.is_truthy(reason:find("above its native minimum", 1, true))
		assert.is_true(Scenario.CheckChargeAudit("Current", audit))
		assert.is_truthy(audit.note:find("does not simulate charge gain", 1, true))
	end)

	it("certifies native minimum charge floors without treating unused maximum capacity as active", function()
		local audit = Scenario.AuditCharges({
			PowerCharges = 1, PowerChargesMin = 1, PowerChargesMax = 3,
			FrenzyCharges = 0, FrenzyChargesMin = 0, FrenzyChargesMax = 3,
			EnduranceCharges = 0, EnduranceChargesMin = 0, EnduranceChargesMax = 3,
		}, { })
		assert.are.equal("native_minimum_charge_floor_only", audit.status)
		assert.is_true(audit.uptimeCertified)
		assert.is_false(audit.hasUnverifiedTransientCharges)
		assert.is_true(Scenario.CheckChargeAudit("PinnacleChassis", audit))
	end)

	it("rejects a Pinnacle result when exact charge output is unavailable", function()
		local valid, reason = Scenario.CheckChargeAudit("PinnacleUnbuffed", Scenario.AuditCharges(nil, { }))
		assert.is_false(valid)
		assert.is_truthy(reason:find("did not provide exact charge counts", 1, true))
	end)

	it("preserves charge inputs in Current while Pinnacle edits only its cloned config", function()
		local build, sourceConfig = fixture()
		local current = assert(Scenario.Create(build, "Current", { }, {
			{ var = "useFrenzyCharges", type = "check" },
		}, nil))
		assert.is_true(current.input.useFrenzyCharges)
		local pinnacle = assert(Scenario.Create(build, "PinnacleUnbuffed", { }, {
			{ var = "useFrenzyCharges", type = "check" },
		}, nil))
		assert.is_nil(pinnacle.input.useFrenzyCharges)
		assert.is_true(sourceConfig.input.useFrenzyCharges)
	end)

	it("applies native enemy presets on isolated clones and reports the exact tier", function()
		local build, sourceConfig = fixture()
		sourceConfig.placeholder.enemyIsBoss = "stale placeholder"
		local options = {
			{ var = "enemyIsBoss", type = "list", defaultIndex = 3, list = {
				{ val = "None", label = "No" }, { val = "Boss", label = "Standard Boss" },
				{ val = "Pinnacle", label = "Pinnacle" }, { val = "Uber", label = "Uber" },
			} },
		}
		local current, _, currentDetails, currentError = Scenario.Create(build, "Current", { }, options, nil, "Uber")
		assert.is_nil(currentError)
		assert.are.equal("Uber", current.input.enemyIsBoss)
		assert.is_nil(current.placeholder.enemyIsBoss)
		assert.are.equal("Uber", currentDetails.enemyIsBoss)
		assert.is_true(current ~= build.configTab)
		assert.are.equal("Boss", sourceConfig.input.enemyIsBoss, "the active PoB enemy setting must remain unchanged")
		assert.are.equal("stale placeholder", sourceConfig.placeholder.enemyIsBoss)

		local pinnacle, _, pinnacleDetails, pinnacleError = Scenario.Create(build, "PinnacleChassis", { }, options, nil, "Uber")
		assert.is_nil(pinnacleError)
		assert.are.equal("Uber", pinnacle.input.enemyIsBoss)
		assert.are.equal("Uber", pinnacleDetails.enemyIsBoss)
		local rejected, _, _, rejection = Scenario.Create(build, "PinnacleUnbuffed", { }, options, nil, "Boss")
		assert.is_nil(rejected)
		assert.is_truthy(rejection:find("require the native Pinnacle or Uber", 1, true))
	end)

	it("distinguishes manual Shock configuration from the exact static PoB result", function()
		local configured = Scenario.AuditShock({ CurrentShock = 65 }, {
			{ key = "conditionEnemyShocked", value = true, source = "input", category = "enemy_ailment" },
			{ key = "conditionShockEffect", value = 65, source = "input", category = "enemy_ailment" },
		})
		assert.are.equal("configured_shock_with_exact_pob_output", configured.status)
		assert.are.equal(65, configured.effectivePoBOutput)
		assert.is_false(configured.uptimeCertified)
		assert.are.equal(2, #configured.configuredAssumptions)
		local absent = Scenario.AuditShock({ CurrentShock = 0 }, { })
		assert.are.equal("no_shock_in_exact_output", absent.status)
		assert.is_true(absent.uptimeCertified)
	end)

	it("removes manual ailment and enemy-stat padding only from the chassis clone", function()
		local build, sourceConfig, sourceItems = fixture()
		sourceConfig.input.conditionEnemyShocked = true
		sourceConfig.input.conditionShockEffect = 65
		sourceConfig.input.conditionShockedEnemyRecently = true
		sourceConfig.input.conditionPoisonedEnemyRecently = true
		sourceConfig.input.conditionEnemyFrozen = true
		sourceConfig.input.enemyLevel = 1
		sourceConfig.input.enemyPhysicalDamage = 1
		sourceConfig.input.presetBossSkills = "manual-preset"
		sourceConfig.input.enemyDamageType = "Untyped"
		sourceConfig.placeholder.conditionEnemyChilledEffect = 30
		sourceConfig.placeholder.enemyFireResist = -200
		local config, items, details, err = Scenario.Create(build, "PinnacleChassis", { }, { })
		assert.is_nil(err)
		assert.are.equal("Pinnacle", config.input.enemyIsBoss)
		assert.is_nil(config.input.conditionEnemyShocked)
		assert.is_nil(config.input.conditionShockEffect)
		assert.is_nil(config.input.conditionShockedEnemyRecently)
		assert.is_nil(config.input.conditionPoisonedEnemyRecently)
		assert.is_nil(config.input.conditionEnemyFrozen)
		assert.is_nil(config.input.enemyLevel)
		assert.is_nil(config.input.enemyPhysicalDamage)
		assert.is_nil(config.input.presetBossSkills)
		assert.is_nil(config.input.enemyDamageType)
		assert.is_nil(config.placeholder.conditionEnemyChilledEffect)
		assert.is_nil(config.placeholder.enemyFireResist)
		assert.is_nil(config.input.customMods)
		assert.are.equal("", config.configSets[1].customModsList[1].text)
		assert.is_false(config.configSets[1].customModsList[1].enabled)
		assert.are.equal(0, details.retainedCustomModLines)
		assert.are.equal(3, details.disabledCustomModLines)
		assert.is_true(details.guardBuffsExcluded)
		assert.are.equal("native_guaranteed_no_manual_overrides", details.ailmentPolicy)
		assert.is_false(items.activeItemSet["Flask 1"].active)
		assert.is_true(sourceItems["Flask 1"].active)
		assert.are.equal(65, sourceConfig.input.conditionShockEffect)
		assert.is_true(sourceConfig.input.conditionShockedEnemyRecently)
		assert.is_true(sourceConfig.input.conditionPoisonedEnemyRecently)
		assert.are.equal(1, sourceConfig.input.enemyLevel)
		assert.are.equal("manual-preset", sourceConfig.input.presetBossSkills)
		assert.are.equal(-200, sourceConfig.placeholder.enemyFireResist)
		assert.is_true(sourceConfig.customModsList[1].enabled)
		assert.is_true(sourceConfig.customModsList[1].text:find("Killed Recently", 1, true) ~= nil)
	end)

	it("refuses chassis certification without engine proof that Guard buffs are excluded", function()
		assert.is_false(Scenario.CheckOutput("PinnacleChassis", { GuardSkillActive = false }))
		assert.is_false(Scenario.CheckOutput("PinnacleChassis", { OptimizerGuardBuffsDisabled = true, GuardSkillActive = true }))
		assert.is_true(Scenario.CheckOutput("PinnacleChassis", { OptimizerGuardBuffsDisabled = true, GuardSkillActive = false }))
		assert.is_true(Scenario.CheckOutput("Current", { GuardSkillActive = true }))
		assert.is_true(Scenario.CalculationOverride("PinnacleChassis").disableGuardBuffs)
		assert.is_nil(Scenario.CalculationOverride("PinnacleUnbuffed").disableGuardBuffs)
	end)

	it("certifies only flask effects that CalcPerform activated through native permanent magic-utility modifiers", function()
		local magebloodFlask = {
			type = "Flask", rarity = "MAGIC", base = { flask = { duration = 6 } },
		}
		local modDB = {
			Sum = function(_, _, _, key)
				if key == "LeftActiveMagicUtilityFlasks" then return 2 end
				return 0
			end,
		}
		local sourceItems = {
			orderedSlots = { { slotName = "Flask 1", selItemId = 5, active = true } },
		}
		local audit = Scenario.AuditFlasks("PinnacleChassis", {
			player = { modDB = modDB }, flasks = { [magebloodFlask] = true },
		}, { curAscendClassName = "Pathfinder" }, sourceItems)
		assert.is_true(audit.certified)
		assert.are.equal("native_permanent_magic_utility", audit.status)
		assert.are.equal(1, audit.magebloodPermanentCount)
		assert.are.equal("only_native_permanent_flasks_retained", audit.pathfinderPolicy)
	end)

	it("does not infer Pathfinder flask uptime from class identity", function()
		local audit = Scenario.AuditFlasks("PinnacleUnbuffed", {
			player = { modDB = { Sum = function() return 0 end } }, flasks = { },
		}, { curAscendClassName = "Pathfinder" }, {
			orderedSlots = { { slotName = "Flask 1", selItemId = 12, active = true } },
		})
		assert.is_true(audit.certified)
		assert.are.equal("all_flasks_disabled", audit.status)
		assert.are.equal("disabled_without_exact_uptime_model", audit.pathfinderPolicy)
		local unsupported = Scenario.AuditFlasks("PinnacleChassis", {
			player = { modDB = { Sum = function() return 0 end } },
			flasks = { [{ type = "Flask", rarity = "UNIQUE", base = { flask = { } } }] = true },
		}, { curAscendClassName = "Pathfinder" }, {
			orderedSlots = { { slotName = "Flask 1", selItemId = 12, active = true } },
		})
		assert.is_false(unsupported.certified)
		assert.are.equal("unsupported_active_flask", unsupported.status)
	end)

	it("keeps the Current profile identical and rejects unknown scenario names", function()
		local build = fixture()
		local config, items, details = Scenario.Create(build, "Current")
		assert.is_true(config == build.configTab)
		assert.is_true(items == build.itemsTab)
		assert.are.equal("Current", details.profile)
		local invalid, _, _, err = Scenario.Create(build, "Uber guess")
		assert.is_nil(invalid)
		assert.is_truthy(err:find("Unsupported scenario", 1, true))
	end)

	it("applies an explicit PoB enemy level only to an isolated configuration and validates the loaded maximum", function()
		local build = fixture()
		local sourceConfig = build.configTab.configSets[1]
		sourceConfig.placeholder.enemyLevel = 83
		local proxy = { data = { misc = { MaxEnemyLevel = 85 } } }
		local config, _, details, err = Scenario.Create(build, "Current", proxy,
			require("Modules.ConfigOptions"), nil, "Boss", 68)
		assert.is_nil(err)
		assert.is_true(config ~= build.configTab, "an enemy-level override must not mutate the active configuration")
		assert.are.equal(68, config.configSets[1].input.enemyLevel)
		assert.is_nil(config.configSets[1].placeholder.enemyLevel, "the explicit native input must take precedence over stale placeholders")
		assert.are.equal(83, sourceConfig.placeholder.enemyLevel, "the active build's manual enemy level must remain unchanged")
		assert.are.equal(68, details.enemyLevelOverride)
		assert.are.equal("native_enemy_level_only_no_area_specific_monster_data", details.enemyLevelScope)
		local rejected, _, _, levelError = Scenario.Create(build, "Current", proxy, nil, nil, "Active", 86)
		assert.is_nil(rejected)
		assert.is_truthy(levelError:find("1 to 85", 1, true))
	end)

	it("restores the user-requested enemy level after the Pinnacle chassis clears source overrides", function()
		local build = fixture()
		local sourceConfig = build.configTab.configSets[1]
		sourceConfig.input.enemyLevel = 82
		local proxy = { data = { misc = { MaxEnemyLevel = 85 } } }
		local config, _, details, err = Scenario.Create(build, "PinnacleChassis", proxy,
			require("Modules.ConfigOptions"), nil, "Pinnacle", 70)
		assert.is_nil(err)
		assert.are.equal(70, config.configSets[1].input.enemyLevel)
		assert.are.equal(82, sourceConfig.input.enemyLevel)
		assert.are.equal(70, details.enemyLevelOverride)
		assert.is_truthy(details.clearedEnemyFields)
	end)

	it("enumerates native Bandit and Pantheon choices deterministically across the axes", function()
		local build = fixture()
		local configSet = build.configTab.configSets[1]
		configSet.input.bandit = "None"
		configSet.input.pantheonMajorGod = "None"
		configSet.input.pantheonMinorGod = "None"
		local candidates, coverage, err = ConfigurationChoices.BuildCandidates(build, 180, 7)
		assert.is_nil(err)
		assert.are.equal(179, #candidates)
		assert.are.equal(180, coverage.totalCombinations)
		assert.are.equal(3, coverage.individualChoiceCandidates.bandit)
		assert.are.equal(4, coverage.individualChoiceCandidates.pantheonMajorGod)
		assert.are.equal(8, coverage.individualChoiceCandidates.pantheonMinorGod)
		assert.are.equal(164, coverage.generatedMultiChoiceCandidates)
		assert.are.equal("Oak", candidates[1].configurationVariant.bandit)
		assert.are.equal("TheBrineKing", candidates[2].configurationVariant.pantheonMajorGod)
		assert.are.equal("Gruthkul", candidates[3].configurationVariant.pantheonMinorGod)
		local limited = assert(ConfigurationChoices.BuildCandidates(build, 3, 7))
		assert.are.equal("Oak", limited[1].configurationVariant.bandit)
		assert.are.equal("TheBrineKing", limited[2].configurationVariant.pantheonMajorGod)
		assert.are.equal("Gruthkul", limited[3].configurationVariant.pantheonMinorGod)
		for _, candidate in ipairs(candidates) do
			assert.is_true(ConfigurationChoices.Validate(candidate.configurationVariant))
		end
	end)

	it("clones current configuration choices without editing the active PoB config", function()
		local build, sourceConfig, _, sourceControls = fixture()
		sourceConfig.input.bandit = "None"
		sourceConfig.input.pantheonMajorGod = "None"
		sourceConfig.input.pantheonMinorGod = "None"
		local proxyBuild = { }
		local clone, items, details, err = Scenario.Create(build, "Current", proxyBuild, nil, {
			bandit = "Oak", pantheonMajorGod = "TheBrineKing", pantheonMinorGod = "Gruthkul",
		})
		assert.is_nil(err)
		assert.is_true(clone ~= build.configTab)
		assert.is_true(items == build.itemsTab)
		assert.is_true(clone.rebuilt)
		assert.are.equal("Oak", clone.input.bandit)
		assert.are.equal("TheBrineKing", clone.input.pantheonMajorGod)
		assert.are.equal("Gruthkul", clone.input.pantheonMinorGod)
		assert.are.equal("TheBrineKing", clone.configSets[1].input.pantheonMajorGod)
		assert.are.equal("Bandit: Help Oak; Major: Soul of the Brine King; Minor: Soul of Gruthkul", details.configurationVariant)
		assert.is_true(proxyBuild.configTab == clone)
		assert.is_nil(sourceConfig.input.touchedSource)
		assert.are.equal("None", sourceConfig.input.bandit)
		assert.are.equal("None", sourceConfig.input.pantheonMajorGod)
		assert.are.equal("None", sourceConfig.input.pantheonMinorGod)
		assert.is_nil(sourceControls.enemySpeed.touchedSource)
	end)
end)
