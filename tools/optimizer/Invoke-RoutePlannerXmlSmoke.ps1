<#
Run the native PoB Route Planner against one existing XML build without saving,
exporting, or writing route-learning observations. Candidate calculations use
disposable PoB clones. An optional route-application check mutates only this
isolated HeadlessWrapper build and exits without writing the build.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$XmlPath,
	[ValidateRange(1000, 1000000)][int]$MaxTicks = 200000,
	[ValidateSet('Auto','PhysicalHit','PhysicalImpale','PhysicalDoT','Fire','Cold','Lightning','ChaosPoison','Minions')][string]$DamageFocus = 'Fire',
	[ValidateSet('Auto','Life','EnergyShield','Hybrid','Ward','Armour','Evasion','Block','SpellBlock','SpellSuppression')][string]$DefenseProfile = 'EnergyShield',
	[ValidateSet('ObjectiveFirst','DefenseFirst')][string]$RankingPriority = 'DefenseFirst',
	[ValidateSet('TIER_1M_TO_5M','TIER_5M_TO_10M','TIER_10M_TO_25M','TIER_25M_TO_50M','TIER_50M_PLUS')][string]$DpsTier = 'TIER_10M_TO_25M',
	[ValidateSet('TIER_20K_TO_50K','TIER_50K_TO_100K','TIER_100K_PLUS')][string]$EhpTier = 'TIER_50K_TO_100K',
	[ValidateSet('TIER_5K_TO_10K','TIER_10K_TO_20K','TIER_15K_TO_25K','TIER_20K_PLUS')][string]$ElementalHitTier = 'TIER_10K_TO_20K',
	[ValidateSet('TIER_5K_TO_10K','TIER_10K_TO_20K','TIER_15K_TO_25K','TIER_20K_PLUS')][string]$PhysicalHitTier = 'TIER_10K_TO_20K',
	[ValidateSet('NONE','PHYSICAL_TO_FIRE','PHYSICAL_TO_COLD','PHYSICAL_TO_LIGHTNING','PHYSICAL_TO_CHAOS','PHYSICAL_TO_LIGHTNING_TO_COLD','LIGHTNING_TO_COLD','LIGHTNING_TO_FIRE','COLD_TO_FIRE')][string]$ConversionRoute = 'NONE',
	[ValidateSet('50','75','100')][string]$ConversionMinimum = '100',
	[ValidateSet(10000,40000,100000)][int]$ProposalLimit = 10000,
	[ValidateSet(250,500,1000,2500,5000,10000)][int]$ExactEvaluationBudget = 5000,
	[ValidateRange(0,25)][int]$ApplyParetoIndex = 0,
	[int[]]$DisableGroupIndex = @(),
	[switch]$DiagnosticOnly,
	[switch]$ForceMainGemSocketMismatch,
	[string]$ResultJsonPath = "",
	[string]$ArchiveRoot = "",
	[string]$PlannerUserPath = "",
	[string]$StudyBuildsModuleOverridePath = "",
	[string]$RuntimeDirectory = (Join-Path $PSScriptRoot '../../runtime'),
	[string]$ProgramDirectory = (Join-Path $PSScriptRoot '../../src'),
	[string]$HeadlessWrapperPath = ""
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$runtimeRoot = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$runtimeRootLua = $runtimeRoot.Replace('\', '/')
$programRoot = (Resolve-Path -LiteralPath $ProgramDirectory).Path
$headlessWrapperPath = if (-not [string]::IsNullOrWhiteSpace($HeadlessWrapperPath)) {
	(Resolve-Path -LiteralPath $HeadlessWrapperPath).Path
} else {
	$packagedWrapper = Join-Path $programRoot 'HeadlessWrapper.lua'
	if (Test-Path -LiteralPath $packagedWrapper -PathType Leaf) {
		$packagedWrapper
	} else {
		Join-Path $repoRoot 'src/HeadlessWrapper.lua'
	}
}
$repoRuntimeRoot = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'runtime')).Path
$plannerUserRoot = if ([string]::IsNullOrWhiteSpace($PlannerUserPath)) { $repoRoot } else {
	(Resolve-Path -LiteralPath $PlannerUserPath).Path
}
$luaDll = Join-Path $runtimeRoot 'lua51.dll'
$xmlResolved = (Resolve-Path -LiteralPath $XmlPath).Path
if (-not (Test-Path -LiteralPath $luaDll -PathType Leaf)) { throw "PoB Lua runtime not found: $luaDll" }
if (-not (Test-Path -LiteralPath $headlessWrapperPath -PathType Leaf)) {
	throw "HeadlessWrapper harness file is unavailable: $headlessWrapperPath"
}
if ([IO.Path]::GetExtension($xmlResolved) -ne '.xml') { throw "Expected an XML build: $xmlResolved" }
$packagedProgram = Test-Path -LiteralPath (Join-Path $programRoot 'manifest.xml') -PathType Leaf

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PoBEmbeddedRoutePlannerHost {
	[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SetDllDirectory(string path);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr luaL_newstate();
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern void luaL_openlibs(IntPtr state);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)] public static extern int luaL_loadstring(IntPtr state, string code);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int lua_pcall(IntPtr state, int nargs, int nresults, int errorFunctionIndex);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr lua_tolstring(IntPtr state, int index, out UIntPtr length);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern void lua_close(IntPtr state);
}
'@
[void][PoBEmbeddedRoutePlannerHost]::SetDllDirectory($runtimeRoot)
$oldCwd = [Environment]::CurrentDirectory
$xmlLua = $xmlResolved.Replace('\', '/').Replace('"', '\"')
$headlessWrapperPathLua = $headlessWrapperPath.Replace('\', '/').Replace('"', '\"')
$repoPathLua = $repoRoot.Replace('\', '/')
$plannerUserPathLua = $plannerUserRoot.TrimEnd('\', '/').Replace('\', '/').Replace('"', '\"')
$specPathLua = (Join-Path $repoRoot 'spec').Replace('\', '/')
$archiveRootLua = $ArchiveRoot.Replace('\', '/').Replace('"', '\"')
$studyBuildsOverrideLua = ''
if (-not [string]::IsNullOrWhiteSpace($StudyBuildsModuleOverridePath)) {
	$studyBuildsOverrideLua = (Resolve-Path -LiteralPath $StudyBuildsModuleOverridePath).Path.Replace('\', '/').Replace('"', '\"')
}
$resolvedResultJsonPath = ''
if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
	$resolvedResultJsonPath = if ([IO.Path]::IsPathRooted($ResultJsonPath)) {
		[IO.Path]::GetFullPath($ResultJsonPath)
	} else {
		[IO.Path]::GetFullPath((Join-Path $repoRoot $ResultJsonPath))
	}
	$resultDirectory = [IO.Path]::GetDirectoryName($resolvedResultJsonPath)
	if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) {
		throw "Route report directory does not exist: $resultDirectory"
	}
}
$resultJsonPathLua = $resolvedResultJsonPath.Replace('\', '/').Replace('"', '\"')
$manifestPathLua = if ($packagedProgram) { 'manifest.xml' } else { '../manifest.xml' }
$fingerprintRootsLua = if ($packagedProgram) {
	'{ default = ".", program = ".", tree = ".", runtime = "." }'
} else {
	'{ default = "..", program = ".", tree = ".", runtime = "' + $runtimeRootLua + '" }'
}
$packagePathLua = if ($packagedProgram) {
	"./?.lua;./?/init.lua;./lua/?.lua;./lua/?/init.lua;$specPathLua/?.lua;$specPathLua/?/init.lua;"
} else {
	"./?.lua;./?/init.lua;$runtimeRootLua/lua/?.lua;$runtimeRootLua/lua/?/init.lua;../spec/?.lua;../spec/?/init.lua;"
}
$packageCPathLua = if ($packagedProgram) { './?.dll;./lua/?.dll;' } else { "./?.dll;$runtimeRootLua/?.dll;$runtimeRootLua/lua/?.dll;" }
$diagnosticLua = if ($DiagnosticOnly) { 'true' } else { 'false' }
$forceMainGemSocketMismatchLua = if ($ForceMainGemSocketMismatch) { 'true' } else { 'false' }
$applyParetoIndexLua = [int]$ApplyParetoIndex
$disableGroupLua = @($DisableGroupIndex | ForEach-Object { [int]$_ }) -join ', '
$lua = @"
local nativeLoadfile = loadfile
local routeSmokeStartedAt = os.clock()
local studyBuildsOverrideLoaded = false
function loadfile(path, ...)
	local normalizedPath = path:gsub("\\\\", "/"):gsub("^%./", "")
	if "$studyBuildsOverrideLua" ~= "" and normalizedPath == "Modules/Optimizer/StudyBuilds.lua" then
		studyBuildsOverrideLoaded = true
		return nativeLoadfile("$studyBuildsOverrideLua", ...)
	end
	if path:gsub("\\\\", "/") == "Modules/Main.lua" then
		local file = assert(io.open(path, "rb"))
		local source = file:read("*a")
		file:close()
		local translated, count = source:gsub("count %+= 1", "count = count + 1")
		assert(count <= 1, "Unexpected MAIN compatibility expression count")
		return loadstring(translated, "@" .. path)
	end
	return nativeLoadfile(path, ...)
end
local nativeGetenv = os.getenv
os.getenv = function(name)
	if name == "CI" then return "1" end
	if name == "POB_AI_BUILD_ARCHIVE_ROOT" and "$archiveRootLua" ~= "" then return "$archiveRootLua" end
	return nativeGetenv(name)
end
arg = {}
package.path = "$packagePathLua" .. package.path
package.cpath = "$packageCPathLua" .. package.cpath
if "$studyBuildsOverrideLua" ~= "" then
	local moduleName = "Modules.Optimizer.StudyBuilds"
	package.loaded[moduleName] = nil
	package.preload[moduleName] = function()
		studyBuildsOverrideLoaded = true
		return assert(nativeLoadfile("$studyBuildsOverrideLua"))()
	end
end
dofile("$headlessWrapperPathLua")
assert(not __mainObject__.promptMsg, "PoB startup returned an error")
__mainObject__.main.userPath = "$plannerUserPathLua/"
local Version = require("Modules.Optimizer.Version")
local Fingerprint = require("Modules.Optimizer.ContentFingerprint")
local manifest = assert(require("xml").LoadXMLFile("$manifestPathLua"), "manifest.xml is unavailable")
local inventoryFingerprint, manifestError = Version.ManifestFingerprint(manifest)
assert(inventoryFingerprint, "manifest inventory is invalid: " .. tostring(manifestError))
local rows, inventoryError = Fingerprint.BuildEntries(manifest)
assert(rows, "calculation file inventory is invalid: " .. tostring(inventoryError))
local fingerprint, fingerprintStatus, fingerprintFiles, fingerprintBytes, fingerprintError = Fingerprint.Compute(rows,
	$fingerprintRootsLua, inventoryFingerprint)
assert(fingerprint and fingerprintStatus == "verified", "PoB calculation fingerprint is unverified: " .. tostring(fingerprintError))
launch.manifestFingerprint, launch.manifestFingerprintStatus = fingerprint, fingerprintStatus
launch.manifestFingerprintFormat = "pob-calculation-content-v1"
local file = assert(io.open("$xmlLua", "rb"))
local xml = file:read("*a")
file:close()
loadBuildFromXML(xml, "QA Disposable XML Route Planner", true)
local activeMain = __mainObject__ and __mainObject__.main or nil
build = activeMain and activeMain.modes and activeMain.modes["BUILD"] or nil
assert(build and build.optimizerTab, "PoB did not load the XML build")
if activeMain.mode ~= "BUILD" then
	local loadJson = require("dkjson")
	local popup = activeMain.popups and activeMain.popups[1]
	local loadState = {
		activeMode = tostring(activeMain.mode or ""),
		pendingMode = tostring(activeMain.newMode or ""),
		buildName = tostring(build.buildName or ""),
		characterLevel = tonumber(build.characterLevel),
		className = tostring(build.spec and build.spec.curClassName or ""),
		treeVersion = tostring(build.spec and build.spec.treeVersion or ""),
		socketGroupCount = #(build.skillsTab and build.skillsTab.socketGroupList or { }),
		popupTitle = tostring(popup and (popup.title or popup.name) or ""),
		popupMessage = tostring(popup and (popup.message or popup.error) or ""),
	}
	print("QA_ROUTE_LOAD_FAILURE " .. loadJson.encode(loadState))
	error("PoB returned to " .. loadState.activeMode .. " while loading the XML; refusing to inspect a stale/default BUILD object")
end
local disabledGroupIndexes = { $disableGroupLua }
for _, groupIndex in ipairs(disabledGroupIndexes) do
	local group = build.skillsTab.socketGroupList[groupIndex]
	assert(group, "Requested disposable test group does not exist: " .. tostring(groupIndex))
	group.enabled = false
end
build.calcsTab:BuildOutput()
local Candidate = require("Modules.Optimizer.Candidate")
local RoutePlanner = require("Modules.Optimizer.RoutePlanner")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local Calcs = require("Modules.Calcs")
if $forceMainGemSocketMismatchLua then
	local groupIndex = tonumber(build.mainSocketGroup) or 1
	local group = build.skillsTab.socketGroupList[groupIndex]
	assert(group and group.slot and not group.source, "Forced socket QA requires a manually socketed Main Skill group")
	local activeGemIndex
	for gemIndex, gem in ipairs(group.gemList or {}) do
		local gemData = gem.gemData or (gem.gemId and build.data.gems[gem.gemId])
		if gem.enabled ~= false and SkillCatalog.IsActiveSkillGem(gemData) then
			assert(not activeGemIndex, "Forced socket QA requires one unambiguous active Main Skill gem")
			activeGemIndex = gemIndex
		end
	end
	assert(activeGemIndex, "Forced socket QA could not find the loaded Main Skill gem")
	local socketOffset = 0
	for currentIndex, currentGroup in ipairs(build.skillsTab.socketGroupList or {}) do
		if currentGroup.slot == group.slot then
			if currentIndex == groupIndex then break end
			socketOffset = socketOffset + #(currentGroup.gemList or {})
		end
	end
	local equipment = require("Modules.Optimizer.Equipment")
	local itemSet = equipment.ActiveItemSet(build.itemsTab)
	local selected = itemSet and itemSet[group.slot]
	local item = selected and build.itemsTab.items[tonumber(selected.selItemId)]
	local socket = item and item.sockets and item.sockets[socketOffset + activeGemIndex]
	assert(socket, "Forced socket QA could not map the Main Skill gem to a native item socket")
	socket.color = "R"
	group.displaySkillList = {}
end
if $diagnosticLua then
	local json = require("dkjson")
	local groupIndex = tonumber(build.mainSocketGroup) or 1
	local group = build.skillsTab.socketGroupList[groupIndex]
	local skillIndex = tonumber(group and group.mainActiveSkill) or 1
	local skill = group and group.displaySkillList and group.displaySkillList[skillIndex]
	local effect = skill and (skill.activeEffect or (skill.effectList and skill.effectList[1]))
	local evidence = SkillCatalog.SocketGroupEvidence(build, groupIndex, group)
	print("QA_ROUTE_SKILL_DEBUG " .. json.encode({groupIndex = groupIndex, groupExists = group ~= nil,
		groupEnabled = group and group.enabled, slotEnabled = group and group.slotEnabled,
		slot = group and group.slot, mainActiveSkill = group and group.mainActiveSkill,
		displaySkillCount = group and group.displaySkillList and #group.displaySkillList or 0,
		selectedSkill = skill and skill.activeEffect and skill.activeEffect.grantedEffect and skill.activeEffect.grantedEffect.id,
		firstEffect = effect and effect.grantedEffect and effect.grantedEffect.id,
		gemId = SkillCatalog.CurrentMainGemId(build, groupIndex, skillIndex), socketStatus = evidence.status,
		socketValid = evidence.valid, socketReason = evidence.reason}))
end
local defaultRunSpec, defaultRunSpecError = RoutePlanner.Prepare(build, {})
if not defaultRunSpec and $diagnosticLua then
	local json = require("dkjson")
	local _, _, context = RoutePlanner.GetMainSkill(build, false, true)
	local audit = context and context.socketRepairAudit or { }
	local groups = { }
	for index, group in ipairs(build.skillsTab.socketGroupList or { }) do
		groups[#groups + 1] = {
			index = index,
			slot = group.slot,
			enabled = group.enabled ~= false,
			slotEnabled = group.slotEnabled ~= false,
			gemCount = #(group.gemList or { }),
			label = group.displayLabel or group.label,
		}
	end
	local repairs = { }
	for _, repair in ipairs(context and context.socketRepairs or { }) do
		repairs[#repairs + 1] = {
			groupIndex = repair.groupIndex,
			groupIndices = repair.groupIndices,
			slot = repair.slot,
			socketCount = repair.socketCount,
			colors = repair.colors,
		}
	end
	local blockers = { }
	for _, blocker in ipairs(audit.blockers or { }) do
		blockers[#blockers + 1] = {
			groupIndex = blocker.groupIndex,
			group = blocker.group,
			slot = blocker.slot,
			reason = blocker.reason,
		}
	end
	print("QA_ROUTE_PREFLIGHT " .. json.encode({ready = false, runSpecError = tostring(defaultRunSpecError)}))
	print("QA_ROUTE_SOCKET_REPAIR_DIAGNOSTIC " .. json.encode({
		mainSocketGroup = build.mainSocketGroup,
		selectedGroupIndex = context and context.groupIndex,
		selectedSlot = context and context.skill and context.skill.slot,
		auditStatus = audit.status,
		repairCount = #repairs,
		repairs = repairs,
		blockers = blockers,
		groups = groups,
	}))
	return
end
assert(defaultRunSpec, defaultRunSpecError)
assert(defaultRunSpec.budget.maxExactEvaluations == 5000 and defaultRunSpec.budget.timeoutSeconds == 1800,
	"The default exact-evaluation profile must be 5,000 / 1,800 seconds")
local skill, skillError, context = RoutePlanner.GetMainSkill(build, false, true)
if not skill and context and context.socketRepair then skill = context.skill end
if not skill then
	if $diagnosticLua then
		local json = require("dkjson")
		print("QA_ROUTE_PREFLIGHT " .. json.encode({ready = false, mainSkillError = tostring(skillError), budget = defaultRunSpec.budget}))
		return
	end
	assert(skill, skillError)
end
local linked, socketEvidence = SkillCatalog.ValidateSocketGroup(build, skill.groupIndex)
if not linked and not (context and context.socketRepair) then
	if $diagnosticLua then
		local json = require("dkjson")
		print("QA_ROUTE_PREFLIGHT " .. json.encode({ready = false, mainSkillError = skillError,
			skill = skill.gemId, socketStatus = context and context.socketEvidence and context.socketEvidence.status,
			socketError = type(socketEvidence) == "string" and socketEvidence or nil,
			budget = defaultRunSpec.budget}))
		return
	end
	assert(linked or (context and context.socketRepair),
		type(socketEvidence) == "string" and socketEvidence or "Main Skill group is not linked")
end
assert(context and ((context.socketEvidence and context.socketEvidence.valid) or context.socketRepair),
	"Main Skill lacks native socket/link evidence or an exact legal item-repair plan")
local before = Candidate.BuildSignature(build)
local baseline = build.calcsTab.mainOutput or {}
local _, directCalculation = Calcs.getMiscCalculator(build)
local tab = build.optimizerTab
local values = tab.textValues or {}
tab.textValues = values
values.routePlannerModelMode = "deterministic_fallback"
values.routePlannerSearchMode = "SINGLE_SKILL_ONLY"
values.routePlannerCrossSkillMode = "SINGLE_SKILL_ONLY"
values.routePlannerDpsTier = "$DpsTier"
values.routePlannerEhpTier = "$EhpTier"
values.routePlannerElementalHitTier = "$ElementalHitTier"
values.routePlannerPhysicalHitTier = "$PhysicalHitTier"
values.routePlannerElementalResists = "CAP_EFFECTIVE"
values.routePlannerChaosResist = "POSITIVE_OR_CAP"
values.routePlannerAggressiveness = "BALANCED_LOCAL_SEARCH"
values.routePlannerGraphRadius = "4"
values.routePlannerProposalLimit = "$ProposalLimit"
values.routePlannerExactEvaluationBudget = "$ExactEvaluationBudget"
values.routePlannerUseNodePower = "true"
values.generationPhase = "combined"
values.searchSyntheticGear = "true"
values.damageFocus = "$DamageFocus"
values.defenseProfile = "$DefenseProfile"
values.rankingPriority = "$RankingPriority"
values.routePlannerConversionRoute = "$ConversionRoute"
values.routePlannerConversionMinimum = "$ConversionMinimum"
values.routePlannerScenario = "Current"
values.useImportedRouteMemory = "true"
values.scenarioEnemyPreset = "Active"
values.scenarioEnemyLevel = ""
local json = require("dkjson")
local fullGroupsValid, fullGroupProof = SkillCatalog.ValidateFullDPSSocketGroups(build)
local groupAudit = {}
for index, group in ipairs(build.skillsTab.socketGroupList or {}) do
	local evidence = SkillCatalog.SocketGroupEvidence(build, index, group)
	local gems = {}
	for _, gem in ipairs(group.gemList or {}) do
		gems[#gems + 1] = {name = gem.nameSpec or (gem.gemData and gem.gemData.name),
			gemId = gem.gemId or (gem.gemData and gem.gemData.id), enabled = gem.enabled}
	end
	groupAudit[#groupAudit + 1] = {index = index, slot = group.slot, enabled = group.enabled,
		slotEnabled = group.slotEnabled, mainActiveSkill = group.mainActiveSkill,
		main = group.mainSocketGroup == true, socketStatus = evidence.status,
		valid = evidence.valid, reason = evidence.reason, gems = gems}
end
local managedScriptPath, managedScriptFallback = GetScriptPath()
local managedRoot = type(managedScriptPath) == "string" and managedScriptPath ~= "" and managedScriptPath or nil
if not managedRoot and type(managedScriptFallback) == "string" and managedScriptFallback ~= "" then managedRoot = managedScriptFallback end
managedRoot = managedRoot or "."
local managedMarker = io.open(managedRoot .. "/AIPlannerManaged.release", "rb")
local managedMarkerPresent = managedMarker ~= nil
if managedMarker then managedMarker:close() end
assert((launch.managedRelease == true) == managedMarkerPresent,
	"PoB managed-release startup guard must match AIPlannerManaged.release")
print("QA_ROUTE_STARTUP " .. json.encode({ managedRelease = launch.managedRelease == true,
	managedMarkerPresent = managedMarkerPresent }))
print("QA_ROUTE_SEED " .. json.encode({class = build.spec.curClass.name,
	managedRelease = launch.managedRelease == true,
	ascendancy = build.spec.curAscendClass and build.spec.curAscendClass.name,
	level = build.characterLevel, tree = build.spec.treeVersion, skill = skill.gemId,
	slot = skill.slot, socketStatus = context.socketEvidence.status,
	socketRepair = context.socketRepair,
	baseline = {CombinedDPS = baseline.CombinedDPS, FullDPS = baseline.FullDPS,
		TotalEHP = baseline.TotalEHP, PhysicalMaximumHitTaken = baseline.PhysicalMaximumHitTaken,
		FireMaximumHitTaken = baseline.FireMaximumHitTaken, ColdMaximumHitTaken = baseline.ColdMaximumHitTaken,
		LightningMaximumHitTaken = baseline.LightningMaximumHitTaken,
		FireResist = baseline.FireResist, ColdResist = baseline.ColdResist,
		LightningResist = baseline.LightningResist, ChaosResist = baseline.ChaosResist},
	directMiscCalculation = {CombinedDPS = directCalculation.CombinedDPS,
		FullDPS = directCalculation.FullDPS, TotalEHP = directCalculation.TotalEHP,
		PhysicalMaximumHitTaken = directCalculation.PhysicalMaximumHitTaken,
		FireResist = directCalculation.FireResist, ColdResist = directCalculation.ColdResist,
			LightningResist = directCalculation.LightningResist,
			SkillEntityLimits = directCalculation.SkillEntityLimits},
	fullDpsGroupsValid = fullGroupsValid, fullDpsGroupViolations = fullGroupProof.violations,
	disabledGroupIndexes = disabledGroupIndexes, groupAudit = groupAudit}))
print("QA_ROUTE_INPUTS " .. json.encode({baseClassId = values.baseClassId,
	ascendancyId = values.ascendancyId, secondaryAscendancyId = values.secondaryAscendancyId,
	requiredNodeIds = values.requiredNodeIds, forbiddenNodeIds = values.forbiddenNodeIds,
	searchAllClasses = values.searchAllClasses, scenarioProfile = values.scenarioProfile,
	scenarioEnemyPreset = values.scenarioEnemyPreset, routePlannerScenario = values.routePlannerScenario,
	damageFocus = values.damageFocus, defenseProfile = values.defenseProfile,
	rankingPriority = values.rankingPriority, routePlannerProposalLimit = values.routePlannerProposalLimit,
		generationPhase = values.generationPhase, searchSyntheticGear = values.searchSyntheticGear,
	conversionRoute = values.routePlannerConversionRoute, conversionMinimum = values.routePlannerConversionMinimum,
	generationPhase = values.generationPhase, targetSkillGroupIndex = values.targetSkillGroupIndex,
	targetSkillIndex = values.targetSkillIndex, targetSkillGemId = values.targetSkillGemId}))
local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local appMain = __mainObject__ and __mainObject__.main or nil
local archiveSource, archiveSourceError = StudyBuilds.GetPlannerArchiveSource(appMain and appMain.userPath)
print("QA_ROUTE_ARCHIVE_SOURCE " .. json.encode({ hasMain = appMain ~= nil, hasUserPath = appMain and type(appMain.userPath) == "string",
	userPath = appMain and tostring(appMain.userPath) or nil,
	mode = archiveSource and archiveSource.mode, status = archiveSource and archiveSource.status,
	reason = archiveSource and archiveSource.reason or archiveSourceError }))
if $diagnosticLua then
	local archiveEvidence = StudyBuilds.NodeEvidence(appMain and appMain.userPath, build,
		skill.gemId, { skill.effectId }, 512, tonumber(build.spec.curClassId), archiveSource and archiveSource.root, "class_tree")
	archiveEvidence = archiveEvidence or {}
	print("QA_ROUTE_ARCHIVE_EVIDENCE " .. json.encode({ status = archiveEvidence.status,
		reason = archiveEvidence.reason, sourceMode = archiveSource and archiveSource.mode,
		sourceStatus = archiveSource and archiveSource.status,
		currentEngine = Version.Snapshot(build),
		studyBuildsOverrideLoaded = studyBuildsOverrideLoaded,
		launchFingerprintStatus = launch and launch.manifestFingerprintStatus or nil,
		launchFingerprintFormat = launch and launch.manifestFingerprintFormat or nil,
		launchFingerprintError = launch and launch.manifestFingerprintError or nil,
		launchFingerprintFiles = launch and launch.manifestFingerprintFileCount or nil,
		selectedSkillGemId = archiveEvidence.selectedSkillGemId, skillScope = archiveEvidence.skillScope,
		requestedSkillGemId = skill.gemId,
		requestedEffectId = skill.effectId, requestedClassId = tonumber(build.spec.curClassId),
		compatibleBuildCount = archiveEvidence.compatibleBuildCount or 0,
		scannedRows = archiveEvidence.scannedRows or 0,
		scannedBytes = archiveEvidence.scannedBytes or 0,
		malformedRows = archiveEvidence.malformedRows or 0,
		archiveTruncated = archiveEvidence.archiveTruncated == true,
		routePatternCount = archiveEvidence.routePatternCount or 0 }))
	local preflightMetrics = {}
	for _, key in ipairs({ "CombinedDPS", "FullDPS", "TotalEHP", "EnergyShield",
		"PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken",
		"LightningMaximumHitTaken", "FireResist", "ColdResist", "LightningResist", "ChaosResist" }) do
		preflightMetrics[key] = baseline[key]
	end
	-- Exercise the actual native setup popup as part of diagnostics. A valid
	-- socket-repair plan must leave the user's generation action enabled; a
	-- successful RunSpec alone is not enough to catch a UI-only dead end.
	tab:OpenRoutePlanner()
	local plannerPopup = appMain and appMain.popups and appMain.popups[1]
	local runControl = plannerPopup and plannerPopup.controls and plannerPopup.controls.run
	local runEnabled = runControl and type(runControl.enabled) == "function" and runControl.enabled() == true
	local skillLabel = plannerPopup and plannerPopup.controls and plannerPopup.controls.skill
		and plannerPopup.controls.skill:GetProperty("label") or nil
	local baselineLabel = plannerPopup and plannerPopup.controls and plannerPopup.controls.baseline
		and plannerPopup.controls.baseline:GetProperty("label") or nil
	print("QA_ROUTE_UI " .. json.encode({ runEnabled = runEnabled == true,
		socketRepairAvailable = context.socketRepair ~= nil,
		skillLabel = skillLabel and tostring(skillLabel) or nil,
		baselineLabel = baselineLabel and tostring(baselineLabel) or nil,
		buttonTooltip = runControl and runControl.tooltipText or nil }))
	if appMain and plannerPopup then appMain:ClosePopup() end
	assert(runEnabled, "AI Planner generation button is disabled despite an exact, legal native route-planning preflight")
	print("QA_ROUTE_PREFLIGHT " .. json.encode({ready = true, budget = defaultRunSpec.budget,
		mainSkill = skill.gemId, skillName = skill.name, slot = skill.slot,
		mainSkillIsMinion = defaultRunSpec.skill.isMinion == true,
		objectiveMetric = defaultRunSpec.objectiveMetric,
		objectiveBaseline = baseline[defaultRunSpec.objectiveMetric],
		objectiveFloor = defaultRunSpecError[defaultRunSpec.objectiveMetric],
		socketStatus = context.socketEvidence.status, fullDpsGroupsValid = fullGroupsValid,
		fullDpsGroupViolations = fullGroupProof.violations,
		baseline = preflightMetrics}))
	return
end
local originalStartOptimizer = tab.StartOptimizer
tab.StartOptimizer = function(self, matrix, control, options)
	control = control or { cancelled = false }
	control.recordPathLearning = false
	return originalStartOptimizer(self, matrix, control, options)
end
local started, startResult = tab:RunRoutePlanner()
tab.StartOptimizer = originalStartOptimizer
assert(started, startResult)
local ticks = 0
local lastReportedPhase, lastReportedExact = nil, 0
while tab.job and ticks < $MaxTicks do
	tab:Tick()
	ticks = ticks + 1
	local progress = tab.job and tab.job.progress or {}
	local progressPhase = tostring(progress.phase or "running")
	local progressExact = tonumber(progress.processed) or 0
	local shouldReport = progressPhase ~= lastReportedPhase
	if progressPhase == "Exact calculations" then
		shouldReport = shouldReport or progressExact == 1 or progressExact - lastReportedExact >= 25
	else
		shouldReport = shouldReport or ticks % 1000 == 0
	end
	if shouldReport then
		local bestRoute = progress.bestExactRoute or {}
		io.write(string.format("QA_ROUTE_PROGRESS ticks=%d phase=%s processed=%s total=%s attempts=%s/%s exact=%s/%s proposals=%s/%s/%s archive=%s direct/%s composed retained=%s/%s exact=%s/%s feasible=%s gateRepair=%s/%s/%s pareto=%s best=%s\n",
			ticks, tostring(progress.phase or "running"), tostring(progress.processed or 0), tostring(progress.total or 0),
			tostring(progress.candidatesExamined or 0), tostring(progress.candidateAttemptTotal or 0),
			tostring(progress.exactEvaluations or 0), tostring(progress.exactEvaluationBudget or values.routePlannerExactEvaluationBudget or "?"),
			tostring(progress.generatedProposals or 0), tostring(progress.uniqueProposals or 0),
			tostring(progress.retainedProposals or 0), tostring(progress.archiveRoutesGenerated or 0),
			tostring(progress.archiveCompositionsGenerated or 0), tostring(progress.archiveRoutesRetained or 0),
			tostring(progress.archiveCompositionsRetained or 0), tostring(progress.archiveDirectExact or 0),
			tostring(progress.archiveCompositionsExact or 0), tostring(progress.exactFeasibleMutations or 0),
			tostring(progress.archiveGateRepairsGenerated or 0), tostring(progress.archiveGateRepairsExact or 0),
			tostring(progress.archiveGateRepairsFeasible or 0),
			tostring(progress.paretoRoutes or 0),
			tostring(bestRoute.label or "none")))
		io.flush()
		lastReportedPhase = progressPhase
		if progressPhase == "Exact calculations" then lastReportedExact = progressExact end
	end
end
if tab.job then tab.job:Cancel() end
local result = tab.result or {}
local phase = (result.searchCoverage or {}).phase or {}
local equipmentCoverage = (result.searchCoverage or {}).equipment or {}
local syntheticGearCoverage = (result.searchCoverage or {}).syntheticGear or {}
local Equipment = require("Modules.Optimizer.Equipment")
local function assertNoFlaskMutation(candidate, context)
	assert(not Equipment.HasFlaskMutation(build, candidate), context .. " contains a flask-slot mutation")
end
assertNoFlaskMutation(result.candidate, "Route Planner winner")
for _, route in ipairs(result.paretoFront or {}) do
	assertNoFlaskMutation(route, "Pareto route")
end
for _, nearMiss in ipairs(result.nearMisses or {}) do
	assertNoFlaskMutation(nearMiss, "Exact near miss")
	assert(not Equipment.DescribesFlaskMutation(nearMiss.label),
		"Exact near-miss labels must not identify a flask as an improvement")
	for _, change in ipairs(nearMiss.changes or {}) do
		assert(not Equipment.DescribesFlaskMutation(change),
			"Exact near-miss change classification rejected: " .. tostring(change))
	end
end
local archiveEvidence = tab.nodeEvidence or {}
local archiveEvidenceSummary = {
	status = archiveEvidence.status,
	reason = archiveEvidence.reason,
	sourceMode = archiveEvidence.archiveSourceMode,
	sourceStatus = archiveEvidence.archiveSourceStatus,
	compatibleBuildCount = archiveEvidence.compatibleBuildCount or 0,
	scannedRows = archiveEvidence.scannedRows or 0,
	malformedRows = archiveEvidence.malformedRows or 0,
	archiveTruncated = archiveEvidence.archiveTruncated == true,
	routePatternCount = archiveEvidence.routePatternCount or 0,
}
local hasProgressiveNearMiss = false
local hasArchivedRouteNearMiss = false
for _, nearMiss in ipairs(result.nearMisses or {}) do
	if tostring(nearMiss.label or ""):find("Progressive passive routes", 1, true) then
		hasProgressiveNearMiss = true
	end
	if nearMiss.archiveDerivedPassiveRoute == true then hasArchivedRouteNearMiss = true end
	for _, violation in ipairs(nearMiss.violations or {}) do
		assert(violation.key ~= "passive_point_limit" and violation.key ~= "passive_point_cap",
			"Structurally illegal passive-point candidates must not be reported as near misses")
	end
end
local archivedRouteEvaluations = phase.archivedRoutePatterns or {}
if (archivedRouteEvaluations.exactEvaluations or 0) > (archivedRouteEvaluations.exactFeasible or 0) then
	assert(hasArchivedRouteNearMiss,
		"An exact archived passive route with unmet goals must remain visible as a non-deliverable near miss")
end
assert((archivedRouteEvaluations.adaptiveGateRepairGenerated or 0)
	<= (archivedRouteEvaluations.adaptiveGateRepairBudget or 0),
	"Adaptive archive repairs must remain within their exact-evaluation reserve")
assert((archivedRouteEvaluations.adaptiveGateRepairRetained or 0)
	<= (archivedRouteEvaluations.adaptiveGateRepairGenerated or 0),
	"Retained adaptive repairs cannot exceed the generated count")
assert((archivedRouteEvaluations.adaptiveGateRepairExactEvaluations or 0)
	<= (archivedRouteEvaluations.adaptiveGateRepairRetained or 0),
	"Adaptive archive repairs must reach exact PoB calculation before they count as evaluated")
assert((archivedRouteEvaluations.adaptiveGateRepairFeasible or 0)
	<= (archivedRouteEvaluations.adaptiveGateRepairExactEvaluations or 0),
	"Only exact adaptive repairs can pass the selected hard floors")
for _, summary in ipairs(phase.progressiveTreeEvaluationSummaries or {}) do
	if summary.feasible == false and phase.exactProgressiveTreeBundleEvaluations > 0 then
		assert(hasProgressiveNearMiss,
			"An exact progressive passive proposal with unmet goals must remain visible beside approved routes")
		break
	end
end
local routes = {}
local CandidateIdentity = require("Modules.Optimizer.CandidateIdentity")
local function plannerCandidateAudit(candidate)
	local gear = candidate.gearVariant or {}
	local gearItems, generatedItems = {}, {}
	local scalarFields = {}
	local candidateFieldHashes = {}
	local gearFieldValues, gearFieldKeys = {}, {}
	local gearItemMetadata, generatedItemMetadata = {}, {}
	for key, value in pairs(gear) do
		gearFieldKeys[#gearFieldKeys + 1] = tostring(key)
		local valueType = type(value)
		if valueType == "string" or valueType == "number" or valueType == "boolean" then
			gearFieldValues[tostring(key)] = value
		end
	end
	table.sort(gearFieldKeys)
	for key, value in pairs(candidate) do
		local valueType = type(value)
		if valueType == "string" or valueType == "number" or valueType == "boolean" then
			scalarFields[key] = value
		end
		if key ~= "evaluation" then
			local ok, hash, hashError = pcall(CandidateIdentity.HashCandidate,
				"route-candidate-audit-v1", { [key] = value })
			candidateFieldHashes[tostring(key)] = ok and hash or nil
			if not candidateFieldHashes[tostring(key)] then
				candidateFieldHashes[tostring(key)] = "unavailable: " .. tostring(ok and hashError or hash):sub(1, 120)
			end
		end
	end
	for _, item in ipairs(gear.items or {}) do
		local slot = item.slot or item.slotName
		local native = item.itemId and build.itemsTab and build.itemsTab.items[tonumber(item.itemId)]
		gearItems[#gearItems + 1] = { slot = slot, itemId = item.itemId,
			raw = native and native.raw, name = item.name, synthetic = item.synthetic }
		local metadata = {}
		for key, value in pairs(item) do
			if key ~= "itemId" and key ~= "tempId" then metadata[key] = value end
		end
		gearItemMetadata[#gearItemMetadata + 1] = metadata
	end
	for _, generated in ipairs(gear.generatedItems or {}) do
		local item = generated.item
		generatedItems[#generatedItems + 1] = { slot = generated.slotName or generated.slot,
			kind = generated.kind, raw = item and item.raw, name = generated.name,
			socketPlan = generated.socketPlan }
		local metadata = {}
		for key, value in pairs(generated) do
			if key ~= "item" and key ~= "tempId" and key ~= "itemId" then metadata[key] = value end
		end
		generatedItemMetadata[#generatedItemMetadata + 1] = metadata
	end
	local binding = gear.socketBinding
	return {
		canonicalHash = candidate.canonicalHash,
		composedIdentityHash = CandidateIdentity.HashComposedCandidate("route-candidate-audit-v1", candidate),
		candidateFieldHashes = candidateFieldHashes,
		gearFieldKeys = gearFieldKeys,
		gearFieldValues = gearFieldValues,
		proposalOrigins = candidate.proposalOrigins,
		nodeIds = candidate.nodeIds,
		removeNodeIds = candidate.removeNodeIds,
		gemVariants = candidate.gemVariants,
		gemVariant = candidate.gemVariant,
		classVariant = candidate.classVariant,
		ascendancyVariant = candidate.ascendancyVariant,
		jewelVariants = candidate.jewelVariants,
		masteryVariant = candidate.masteryVariant,
		tattooVariant = candidate.tattooVariant,
		timelessVariant = candidate.timelessVariant,
		anointVariants = candidate.anointVariants,
		configurationVariant = candidate.configurationVariant,
		jewelVariant = candidate.jewelVariant,
		gear = { changedSlots = gear.changedSlots, overrides = gear.overrides,
			items = gearItems, itemMetadata = gearItemMetadata,
			generatedItems = generatedItems, generatedItemMetadata = generatedItemMetadata,
			socketBinding = binding and { slotName = binding.slotName, groupIndex = binding.groupIndex,
				socketCount = binding.socketCount, linkGroup = binding.linkGroup } or nil },
		anointVariant = candidate.anointVariant,
		scalarFields = scalarFields,
	}
end
for index, route in ipairs(result.paretoFront or {}) do
	-- Keep the QA artifact aligned with the UI's maximum route selector size.
	if index > 25 then break end
	local evaluation = route.evaluation or {}
	local metrics = evaluation.metrics or {}
	local changedItems = {}
	local gear = route.gearVariant or {}
	local itemsBySlot, generatedItemsBySlot, changedSlots, seenSlots = {}, {}, {}, {}
	for _, item in ipairs(gear.items or {}) do
		local slot = type(item) == "table" and (item.slot or item.slotName)
		if type(slot) == "string" then itemsBySlot[slot] = item end
	end
	for _, generated in ipairs(gear.generatedItems or {}) do
		local slot = type(generated) == "table" and (generated.slotName or generated.slot)
		if type(slot) == "string" then generatedItemsBySlot[slot] = generated end
	end
	for _, slot in ipairs(gear.changedSlots or {}) do
		if type(slot) == "string" and not seenSlots[slot] then
			seenSlots[slot] = true
			changedSlots[#changedSlots + 1] = slot
		end
	end
	if #changedSlots == 0 then
		for _, item in ipairs(gear.items or {}) do
			local slot = type(item) == "table" and (item.slot or item.slotName)
			if type(slot) == "string" and not seenSlots[slot] then
				seenSlots[slot] = true
				changedSlots[#changedSlots + 1] = slot
			end
		end
	end
	for _, slot in ipairs(changedSlots) do
		local item = itemsBySlot[slot]
		local generated = generatedItemsBySlot[slot]
		if item or generated then
			local nativeItem = generated and generated.item
			if not nativeItem and item and build.itemsTab and build.itemsTab.items then
				nativeItem = build.itemsTab.items[tonumber(item.itemId)]
			end
			local affixes = {}
			local socketRepair = generated ~= nil and generated.kind == "socket_repair"
			if not socketRepair then
				for _, modLine in ipairs(nativeItem and nativeItem.explicitModLines or {}) do
					if type(modLine) == "table" and type(modLine.line) == "string" then affixes[#affixes + 1] = modLine.line end
				end
			end
			local nativeAffixCount = not socketRepair and nativeItem
				and (#(nativeItem.prefixes or {}) + #(nativeItem.suffixes or {})) or 0
			local affixCount
			if not socketRepair then
				affixCount = nativeAffixCount > 0 and nativeAffixCount
					or tonumber(item and item.affixCount) or tonumber(generated and generated.affixCount)
				if affixCount and affixCount <= 0 and #affixes > 0 then affixCount = nil end
			end
			changedItems[#changedItems + 1] = {
				slot = slot, itemId = item and item.itemId or generated and generated.tempId,
				name = item and item.name or generated and generated.name
					or nativeItem and (nativeItem.title or nativeItem.name or nativeItem.baseName),
				synthetic = item and item.synthetic == true or (generated ~= nil and generated.kind == nil),
				socketRepair = item and item.socketRepair == true or socketRepair,
				affixCount = affixCount,
				affixLineCount = #affixes,
				affixes = affixes,
			}
		end
	end
	local addedPassiveNodes = {}
	for _, nodeId in ipairs(route.nodeIds or {}) do
		local node = build.spec.nodes[nodeId]
		addedPassiveNodes[#addedPassiveNodes + 1] = {id = nodeId, name = tostring(node and (node.dn or node.name) or "Passive " .. tostring(nodeId))}
	end
	local removedPassiveNodes = {}
	for _, nodeId in ipairs(route.removeNodeIds or {}) do
		local node = build.spec.nodes[nodeId]
		removedPassiveNodes[#removedPassiveNodes + 1] = {id = nodeId, name = tostring(node and (node.dn or node.name) or "Passive " .. tostring(nodeId))}
	end
	routes[#routes + 1] = {label = evaluation.candidateLabel or route.label or ("Pareto route " .. index),
		candidateAudit = plannerCandidateAudit(route),
		changedItems = changedItems, addedPassiveNodes = addedPassiveNodes, removedPassiveNodes = removedPassiveNodes,
		CombinedDPS = metrics.CombinedDPS, FullDPS = metrics.FullDPS, FullDotDPS = metrics.FullDotDPS,
		Life = metrics.Life, EnergyShield = metrics.EnergyShield, Ward = metrics.Ward, TotalEHP = metrics.TotalEHP,
		Armour = metrics.Armour, Evasion = metrics.Evasion, BlockChance = metrics.BlockChance,
		SpellBlockChance = metrics.SpellBlockChance, SpellSuppressionChance = metrics.SpellSuppressionChance,
		PhysicalHitAverage = metrics.PhysicalHitAverage, FireHitAverage = metrics.FireHitAverage,
		ColdHitAverage = metrics.ColdHitAverage, LightningHitAverage = metrics.LightningHitAverage,
		ChaosHitAverage = metrics.ChaosHitAverage, ImpaleDPS = metrics.ImpaleDPS,
		BleedDPS = metrics.BleedDPS, PoisonDPS = metrics.PoisonDPS,
		PhysicalMaximumHitTaken = metrics.PhysicalMaximumHitTaken,
		FireMaximumHitTaken = metrics.FireMaximumHitTaken,
		ColdMaximumHitTaken = metrics.ColdMaximumHitTaken,
		LightningMaximumHitTaken = metrics.LightningMaximumHitTaken,
		FireResist = metrics.FireResist, ColdResist = metrics.ColdResist,
		LightningResist = metrics.LightningResist, ChaosResist = metrics.ChaosResist,
		feasible = evaluation.feasible == true}
end
local paretoIdentity = { exactHashes = 0, missingHashes = 0, duplicateHashes = 0 }
local seenParetoHashes = {}
for _, route in ipairs(result.paretoFront or {}) do
	local hash = route.canonicalHash
	if type(hash) == "string" and hash ~= "" then
		paretoIdentity.exactHashes = paretoIdentity.exactHashes + 1
		if seenParetoHashes[hash] then paretoIdentity.duplicateHashes = paretoIdentity.duplicateHashes + 1
		else seenParetoHashes[hash] = true end
	else
		paretoIdentity.missingHashes = paretoIdentity.missingHashes + 1
	end
end
assert(paretoIdentity.duplicateHashes == 0,
	"Pareto contains duplicate native proposal identities after route composition")
local after = Candidate.BuildSignature(build)
local routeApplicationTest
if $applyParetoIndexLua > 0 then
	local route = result.paretoFront[$applyParetoIndexLua]
	assert(route, "Requested route application test is outside the exact Pareto results")
	local previewSpec, previewSpecError = Candidate.BuildPassiveSpec(build, route.nodeIds, route.removeNodeIds, route)
	assert(previewSpec, "Could not reconstruct the exact passive projection before Apply: " .. tostring(previewSpecError))
	local function passiveAllocationSignature(spec)
		local nodeIds = { }
		for nodeId in pairs(spec.allocNodes or { }) do nodeIds[#nodeIds + 1] = tonumber(nodeId) end
		table.sort(nodeIds)
		return table.concat(nodeIds, ","), #nodeIds
	end
	local previewAllocationSignature, previewAllocatedNodeCount = passiveAllocationSignature(previewSpec)
	local applyBefore = Candidate.BuildSignature(build)
	local callOk, applied, applyError = pcall(Candidate.Apply, build, route)
	if not callOk then applyError, applied = tostring(applied), false end
	if applied then
		-- Mirror Build.Update's native invalidation/recalculation sequence so the
		-- smoke checks the metrics the full PoB UI will display after Apply.
		build.buildFlag = false
		if build.skillsTab and type(build.skillsTab.UpdateSocketGroups) == "function" then
			build.skillsTab:UpdateSocketGroups()
		end
		wipeGlobalCache()
		build.calcsTab:BuildOutput()
		local appliedLevel = build.characterLevel
		if type(build.RefreshStatList) == "function" then build:RefreshStatList() end
		if build.characterLevel ~= appliedLevel then
			if build.configTab and type(build.configTab.BuildModList) == "function" then build.configTab:BuildModList() end
			wipeGlobalCache()
			build.calcsTab:BuildOutput()
			if type(build.RefreshStatList) == "function" then build:RefreshStatList() end
		end
	end
	local appliedSignature = Candidate.BuildSignature(build)
	local output = build.calcsTab and build.calcsTab.mainOutput or {}
	local appliedAllocationSignature, appliedAllocatedNodeCount = passiveAllocationSignature(build.spec or { })
	local metricParity, metricsChecked, metricDifferences = true, 0, { }
	local previewMetrics = route.evaluation and route.evaluation.metrics or { }
	for _, key in ipairs({ "CombinedDPS", "FullDPS", "TotalEHP", "Life", "EnergyShield", "Ward", "Armour", "Evasion",
		"PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken",
		"ChaosMaximumHitTaken", "FireResist", "ColdResist", "LightningResist", "ChaosResist",
		"BlockChance", "SpellBlockChance", "SpellSuppressionChance" }) do
		local expected, actual = previewMetrics[key], output[key]
		if type(expected) == "number" then
			metricsChecked = metricsChecked + 1
			local tolerance = math.max(0.00000001, math.abs(expected) * 0.000000000001)
			if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
				metricParity = false
				metricDifferences[key] = { preview = expected, applied = actual }
			end
		end
	end
	routeApplicationTest = {
		index = $applyParetoIndexLua,
		label = tostring((route.evaluation and route.evaluation.candidateLabel) or route.label or ""),
		applied = applied == true,
		error = applied == true and nil or tostring(applyError or "Candidate.Apply returned false"),
		isolatedHeadlessBuild = true,
		changedBuildSignature = applyBefore ~= appliedSignature,
		previewCharacterLevel = route.evaluation and route.evaluation.characterLevel or nil,
		appliedCharacterLevel = build.characterLevel,
		previewAllocatedNodeCount = previewAllocatedNodeCount,
		appliedAllocatedNodeCount = appliedAllocatedNodeCount,
		treeAllocationMatchesPreview = previewAllocationSignature == appliedAllocationSignature,
		metricsChecked = metricsChecked,
		metricParity = metricParity,
		metricDifferences = metricDifferences,
		metrics = {
			CombinedDPS = output.CombinedDPS,
			TotalEHP = output.TotalEHP,
			Life = output.Life,
			EnergyShield = output.EnergyShield,
			Armour = output.Armour,
			Evasion = output.Evasion,
			PhysicalMaximumHitTaken = output.PhysicalMaximumHitTaken,
			FireMaximumHitTaken = output.FireMaximumHitTaken,
			ColdMaximumHitTaken = output.ColdMaximumHitTaken,
			LightningMaximumHitTaken = output.LightningMaximumHitTaken,
		},
	}
end
local bestMetrics = result.bestObservedMetrics or (result.evaluation and result.evaluation.metrics) or {}
local bestViolations = result.bestObservedViolations or {}
local bestViolationKeys = {}
local bestViolationDetails = {}
for index, violation in ipairs(bestViolations) do
	if index > 8 then break end
	bestViolationKeys[#bestViolationKeys + 1] = tostring(violation.key or violation.label or "hard_gate")
	bestViolationDetails[#bestViolationDetails + 1] = {
		key = tostring(violation.key or ""), label = tostring(violation.label or ""),
		reason = tostring(violation.reason or ""), actual = violation.actual,
		required = violation.required, deficit = violation.deficit,
	}
end
local nearMisses = result.nearMisses or {}
local previewRouteLabels = {}
for index, route in ipairs(routes) do
	if index > 25 then break end
	previewRouteLabels[#previewRouteLabels + 1] = route.label
end
local nearMissPreview = {}
for index, nearMiss in ipairs(nearMisses) do
	if index > 5 then break end
	local violationKeys = {}
	local violationDetails = {}
	for violationIndex, violation in ipairs(nearMiss.violations or {}) do
		if violationIndex > 8 then break end
		violationKeys[#violationKeys + 1] = tostring(violation.key or violation.label or "hard_gate")
		violationDetails[#violationDetails + 1] = {
			key = tostring(violation.key or ""), label = tostring(violation.label or ""),
			reason = tostring(violation.reason or ""), actual = violation.actual,
			required = violation.required, deficit = violation.deficit,
		}
	end
	nearMissPreview[#nearMissPreview + 1] = {
		label = tostring(nearMiss.label or "Exact candidate"),
		normalizedDeficit = nearMiss.normalizedDeficit,
		violationKeys = violationKeys, violations = violationDetails,
		changes = nearMiss.changes or {},
		metrics = nearMiss.metrics or {},
	}
end
local routeBaselineMetrics = result.searchBaseline and result.searchBaseline.exact == true
	and result.searchBaseline.metrics or (result.sourceBuildBaseline and result.sourceBuildBaseline.metrics or {})
for _, route in ipairs(routes) do
	route.delta = {}
	for metric, value in pairs(routeBaselineMetrics) do
		local routeValue = route[metric]
		if type(value) == "number" and type(routeValue) == "number" then
			route.delta[metric] = routeValue - value
		end
	end
end
local routeReport = {status = result.status or "unknown",
	message = tab.statusMessage, searchMessage = result.message,
	exactEvaluations = result.evaluations or 0, exactEvaluationBudget = values.routePlannerExactEvaluationBudget,
	evaluationBudgetReached = (result.evaluations or 0) >= (tonumber(values.routePlannerExactEvaluationBudget) or math.huge),
	elapsedCpuSeconds = os.clock() - routeSmokeStartedAt,
	searchInterrupted = result.searchInterrupted == true, searchTimedOut = result.searchTimedOut == true,
	terminationReason = result.terminationReason, ticks = ticks,
	baseline = { CombinedDPS = result.searchBaseline and result.searchBaseline.metrics and result.searchBaseline.metrics.CombinedDPS,
		FullDPS = result.searchBaseline and result.searchBaseline.metrics and result.searchBaseline.metrics.FullDPS,
		TotalEHP = result.searchBaseline and result.searchBaseline.metrics and result.searchBaseline.metrics.TotalEHP },
	sourceBuildBaseline = result.sourceBuildBaseline and { comparisonOnly = result.sourceBuildBaseline.comparisonOnly == true,
		label = result.sourceBuildBaseline.label, socketRepairRequired = result.sourceBuildBaseline.socketRepairRequired == true,
		metrics = result.sourceBuildBaseline.metrics } or nil,
	bestObserved = { CombinedDPS = bestMetrics.CombinedDPS, FullDPS = bestMetrics.FullDPS,
		TotalEHP = bestMetrics.TotalEHP, EnergyShield = bestMetrics.EnergyShield,
		PhysicalMaximumHitTaken = bestMetrics.PhysicalMaximumHitTaken,
		FireMaximumHitTaken = bestMetrics.FireMaximumHitTaken,
		ColdMaximumHitTaken = bestMetrics.ColdMaximumHitTaken,
		LightningMaximumHitTaken = bestMetrics.LightningMaximumHitTaken,
		FireResist = bestMetrics.FireResist, ColdResist = bestMetrics.ColdResist,
		LightningResist = bestMetrics.LightningResist, ChaosResist = bestMetrics.ChaosResist },
	bestViolationCount = #bestViolations, bestViolationKeys = bestViolationKeys,
	bestViolationDetails = bestViolationDetails,
	requestedTargets = { dps = values.routePlannerDpsTier, ehp = values.routePlannerEhpTier,
		elementalMaxHit = values.routePlannerElementalHitTier, physicalMaxHit = values.routePlannerPhysicalHitTier },
	generatedCandidates = phase.generatedCandidates or 0,
	uniqueCandidates = phase.uniqueCandidates or 0,
	identityDeduplication = {
		duplicatesDiscarded = phase.duplicateCandidatesDiscarded or 0,
		postCompositionUniqueCandidates = phase.postCompositionUniqueCandidates or 0,
		postCompositionDuplicatesDiscarded = phase.postCompositionDuplicatesDiscarded or 0,
		postCompositionCanonicalizationFallbacks = phase.postCompositionCanonicalizationFallbacks or 0,
	},
	cappedByProposalBudget = phase.discardedByProposalBudget or 0,
	retainedCandidates = phase.retainedCandidates or 0,
	exactQueue = {
		inputCandidates = phase.exactQueueInputCandidates or 0,
		retainedCandidates = phase.exactQueueRetainedCandidates or 0,
		limit = phase.exactQueueLimit or 0,
		discardedBeyondLimit = phase.exactQueueDiscardedCandidates or 0,
	},
	candidateAttempts = phase.candidateAttempts or 0,
	structuralCandidateRejections = phase.structuralCandidateRejections or 0,
	candidateReconstructionFailures = phase.candidateReconstructionFailures or 0,
	socketRepair = phase.socketRepair,
	syntheticGear = { possibleSlots = syntheticGearCoverage.possibleSlots or 0,
		possibleBases = syntheticGearCoverage.possibleBases or 0,
		generatedCandidates = syntheticGearCoverage.generatedCandidates or 0,
		generatedRouteCandidates = syntheticGearCoverage.generatedRouteCandidates or 0,
		priorityProfile = syntheticGearCoverage.priorityProfile,
		socketRepairOnlyCandidateGenerated = syntheticGearCoverage.socketRepairOnlyCandidateGenerated == true,
		socketRepairOnlyCandidateReason = syntheticGearCoverage.socketRepairOnlyCandidateReason,
		structuralRejections = syntheticGearCoverage.structuralRejections or 0,
		lastCraftRejection = syntheticGearCoverage.lastCraftRejection,
		lastStructuralRejection = syntheticGearCoverage.lastStructuralRejection },
	proposalLimit = values.routePlannerProposalLimit, exactEvaluationBudget = values.routePlannerExactEvaluationBudget,
	damageFocus = values.damageFocus,
	defenseProfile = values.defenseProfile, rankingPriority = values.rankingPriority,
	requestedConversionRoute = values.routePlannerConversionRoute,
	requestedConversionMinimum = values.routePlannerConversionMinimum,
	flaskSlotsExcluded = equipmentCoverage.excludedFlaskSlots or 0,
	flaskMutationCandidatesRejected = phase.flaskMutationCandidatesRejected or 0,
	generatedTreeCandidates = phase.generatedTreeCandidates or 0,
	generatedProgressiveTreeBundles = phase.generatedProgressiveTreeBundles or 0,
	proposedProgressiveTreeBundles = phase.proposedProgressiveTreeBundles or 0,
	retainedProgressiveTreeBundles = phase.retainedProgressiveTreeBundles or 0,
	maxProgressiveRouteCount = phase.maxProgressiveRouteCount or 0,
	progressiveTreeAscendancyReservationStatus = phase.progressiveTreeAscendancyReservationStatus,
	progressiveTreeAscendancyReservationPosition = phase.progressiveTreeAscendancyReservationPosition,
	structuralTreeRejections = phase.structuralTreeRejections or 0,
	structuralProgressiveTreeBundleRejections = phase.structuralProgressiveTreeBundleRejections or 0,
	firstProgressiveTreeStructuralRejection = phase.firstProgressiveTreeStructuralRejection,
	hasArchivedRouteNearMiss = hasArchivedRouteNearMiss,
	archiveEvidence = archiveEvidenceSummary,
	proposalFamilyCountsAfter = phase.proposalFamilyCountsAfter,
	exactEvaluationPlan = { status = phase.exactEvaluationPlan and phase.exactEvaluationPlan.status,
		candidateCount = phase.exactEvaluationPlan and phase.exactEvaluationPlan.candidateCount,
		retainedCandidateCount = phase.exactEvaluationPlan and phase.exactEvaluationPlan.retainedCandidateCount,
		exactQueueLimit = phase.exactEvaluationPlan and phase.exactEvaluationPlan.exactQueueLimit,
		discardedBeyondRetentionLimit = phase.exactEvaluationPlan and phase.exactEvaluationPlan.discardedBeyondRetentionLimit,
		windowFamilyCounts = phase.exactEvaluationPlan and phase.exactEvaluationPlan.windowFamilyCounts,
		windowFamilyDiversity = phase.exactEvaluationPlan and phase.exactEvaluationPlan.windowFamilyDiversity },
	exactEvaluationsByFamily = phase.exactEvaluationsByFamily,
	pointBudget = phase.pointBudget,
	nearMissCount = #nearMisses, nearMissPreview = nearMissPreview,
	exactProgressiveTreeBundleEvaluations = phase.exactProgressiveTreeBundleEvaluations or 0,
	archivedRoutePatterns = { compatibleBuildCount = phase.archivedRoutePatterns and phase.archivedRoutePatterns.compatibleBuildCount or 0,
		availablePatterns = phase.archivedRoutePatterns and phase.archivedRoutePatterns.availablePatterns or 0,
		generatedCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.generatedCandidates or 0,
		generatedComposedCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.generatedComposedCandidates or 0,
		retainedDirectCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.retainedDirectCandidates or 0,
		retainedComposedCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.retainedComposedCandidates or 0,
		reservedExactEvaluationQuota = phase.archivedRoutePatterns and phase.archivedRoutePatterns.reservedExactEvaluationQuota or 0,
		reservedDirectCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.reservedDirectCandidates or 0,
		reservedComposedCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.reservedComposedCandidates or 0,
		exactEvaluations = phase.archivedRoutePatterns and phase.archivedRoutePatterns.exactEvaluations or 0,
		exactDirectEvaluations = phase.archivedRoutePatterns and phase.archivedRoutePatterns.exactDirectEvaluations or 0,
		exactDirectFeasible = phase.archivedRoutePatterns and phase.archivedRoutePatterns.exactDirectFeasible or 0,
		exactComposedEvaluations = phase.archivedRoutePatterns and phase.archivedRoutePatterns.exactComposedEvaluations or 0,
		exactComposedFeasible = phase.archivedRoutePatterns and phase.archivedRoutePatterns.exactComposedFeasible or 0,
		adaptiveGateRepairBudget = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairBudget or 0,
		adaptiveGateRepairGenerated = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairGenerated or 0,
		adaptiveGateRepairRetained = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairRetained or 0,
		adaptiveGateRepairExactEvaluations = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairExactEvaluations or 0,
		adaptiveGateRepairFeasible = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairFeasible or 0,
		adaptiveGateRepairStructuralRejections = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairStructuralRejections or 0,
		adaptiveGateRepairStructuralRejectionReasons = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairStructuralRejectionReasons or { },
		adaptiveGateRepairDuplicateCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairDuplicateCandidates or 0,
		adaptiveGateRepairProposalCapRejections = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairProposalCapRejections or 0,
		adaptiveGateRepairSources = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairSources or 0,
		adaptiveGateRepairActionableSources = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairActionableSources or 0,
		adaptiveGateRepairExactViolationRows = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairExactViolationRows or 0,
		adaptiveGateRepairNeedRows = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairNeedRows or 0,
		adaptiveGateRepairInventoryCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairInventoryCandidates or 0,
		adaptiveGateRepairSyntheticCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairSyntheticCandidates or 0,
		adaptiveGateRepairInputSample = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairInputSample,
		adaptiveGateRepairExactPreview = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairExactPreview or { },
		adaptiveGateRepairRankedCandidates = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairRankedCandidates or 0,
		adaptiveGateRepairGeneratedBeforeDeduplication = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairGeneratedBeforeDeduplication or 0,
		adaptiveGateRepairStatuses = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairStatuses or { },
		adaptiveGateRepairCanonicalizationFallbacks = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairCanonicalizationFallbacks or 0,
		adaptiveGateRepairCanonicalizationContextError = phase.archivedRoutePatterns and phase.archivedRoutePatterns.adaptiveGateRepairCanonicalizationContextError,
		canonicalizationFallbacks = phase.canonicalizationFallbacks or 0,
		canonicalizationContextError = phase.canonicalizationContextError,
		exactFeasible = phase.archivedRoutePatterns and phase.archivedRoutePatterns.exactFeasible or 0 },
	paretoCount = #(result.paretoFront or {}), paretoIdentity = paretoIdentity,
	routeLabels = previewRouteLabels, routePreviews = routes,
	routeApplicationTest = routeApplicationTest,
	sourceBuildUnchanged = before == after, routeMemoryWritesDisabled = true,
	completed = tab.job == nil}
local routeReportJson = json.encode(routeReport)
if "$resultJsonPathLua" ~= "" then
	local resultFile, resultFileError = io.open("$resultJsonPathLua", "wb")
	assert(resultFile, "Could not create route report: " .. tostring(resultFileError))
	resultFile:write(routeReportJson, "\n")
	resultFile:close()
end
print("QA_ROUTE_RESULT " .. json.encode({
	status = routeReport.status, proposalLimit = routeReport.proposalLimit,
	generatedCandidates = routeReport.generatedCandidates, uniqueCandidates = routeReport.uniqueCandidates,
	retainedCandidates = routeReport.retainedCandidates, exactEvaluations = routeReport.exactEvaluations,
	exactEvaluationBudget = routeReport.exactEvaluationBudget, paretoCount = routeReport.paretoCount,
	routeLabels = routeReport.routeLabels, sourceBuildUnchanged = routeReport.sourceBuildUnchanged,
	searchTimedOut = routeReport.searchTimedOut, routeApplicationTest = routeReport.routeApplicationTest,
}))
assert(before == after, "Route search changed the imported source build")
assert(tab.job == nil, "Route search exceeded its tick budget")
assert(not routeApplicationTest or routeApplicationTest.applied,
	"Disposable exact Pareto route application failed: " .. tostring(routeApplicationTest and routeApplicationTest.error))
assert(not routeApplicationTest or routeApplicationTest.treeAllocationMatchesPreview,
	"Applied passive-tree allocation differs from the native exact projection")
assert(not routeApplicationTest or (routeApplicationTest.metricsChecked > 0 and routeApplicationTest.metricParity),
	"Metrics changed between the exact route preview and its applied passive-tree variation")
"@

$oldPath = $env:PATH
$env:PATH = $runtimeRoot + ';' + $repoRuntimeRoot + ';' + $env:PATH
$simpleGraphicDefinition = Join-Path $programRoot '_SimpleGraphic.def.lua'
$sourceSimpleGraphicDefinition = Join-Path $repoRoot 'src/_SimpleGraphic.def.lua'
$temporarySimpleGraphicDefinition = $false
try {
	# The official full-release package omits this test-only HeadlessWrapper shim.
	# Provide it only for the smoke process and remove it in finally below.
	if (-not (Test-Path -LiteralPath $simpleGraphicDefinition -PathType Leaf)) {
		Copy-Item -LiteralPath $sourceSimpleGraphicDefinition -Destination $simpleGraphicDefinition
		$temporarySimpleGraphicDefinition = $true
	}
	[Environment]::CurrentDirectory = $programRoot
	$state = [IntPtr]::Zero
	try {
		$state = [PoBEmbeddedRoutePlannerHost]::luaL_newstate()
		if ($state -eq [IntPtr]::Zero) { throw 'luaL_newstate returned null' }
		[PoBEmbeddedRoutePlannerHost]::luaL_openlibs($state)
		$status = [PoBEmbeddedRoutePlannerHost]::luaL_loadstring($state, $lua)
		if ($status -ne 0) {
			$length = [UIntPtr]::Zero
			$errorPointer = [PoBEmbeddedRoutePlannerHost]::lua_tolstring($state, -1, [ref]$length)
			throw ('Lua bootstrap error: ' + [Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPointer))
		}
		$status = [PoBEmbeddedRoutePlannerHost]::lua_pcall($state, 0, -1, 0)
		if ($status -ne 0) {
			$length = [UIntPtr]::Zero
			$errorPointer = [PoBEmbeddedRoutePlannerHost]::lua_tolstring($state, -1, [ref]$length)
			throw ('PoB Route Planner smoke failed: ' + [Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPointer))
		}
	} finally {
		if ($state -ne [IntPtr]::Zero) { [PoBEmbeddedRoutePlannerHost]::lua_close($state) }
	}
} finally {
	[Environment]::CurrentDirectory = $oldCwd
	$env:PATH = $oldPath
	if ($temporarySimpleGraphicDefinition -and (Test-Path -LiteralPath $simpleGraphicDefinition -PathType Leaf)) {
		Remove-Item -LiteralPath $simpleGraphicDefinition -Force -ErrorAction Stop
	}
}
