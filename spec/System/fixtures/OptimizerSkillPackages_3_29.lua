-- Versioned native PoB fixture, not an automatic skill recommendation.
-- The relationship below is a user-authored schedule dependency. PoB remains
-- the source for skill identity and exact resource rates; this fixture does
-- not claim that the setup's damage contribution or timing is modeled.
return {
	schema = "optimizer-native-skill-package-v1",
	pobAppVersion = "2.67.2",
	dataVersion = "3.29",
	treeVersion = "3_29",
	id = "fireball-flame-wall-user-declared-setup-v1",
	characterLevel = 12,
	mainSocketGroup = 1,
	socketGroups = {
		"Fireball 1/0  1",
		"Flame Wall 1/0  1",
	},
	setupSkill = "Flame Wall",
	payoffSkill = "Fireball",
	setupRatePercent = 25,
	payoffRatePercent = 100,
	exactConfigAblation = {
		key = "flameWallAddedDamage",
		baselineCombinedDPS = 13.937432655021,
		withoutConfigCombinedDPS = 13.937432655021,
		withConfigCombinedDPS = 28.522482270797,
	},
	relation = "user_declared_prerequisite",
	certification = {
		resourceRates = "exact_pob_per_skill",
		dependency = "structure_only",
		damageSchedule = "not_certified",
		eventTiming = "not_modeled",
	},
	independentUtility = {
		id = "fireball-molten-shell-independent-utility-v1",
		pobAppVersion = "2.67.2",
		characterLevel = 12,
		mainSocketGroup = 1,
		socketGroups = {
			"Fireball 1/0  1",
			"Molten Shell 1/0  1",
		},
		primarySkill = "Fireball",
		utilitySkill = "Molten Shell",
		primaryRatePercent = 100,
		utilityRatePercent = 10,
		relation = "independent_utility_no_dependency",
	},
}
