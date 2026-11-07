<#
Run the opt-in native eligibility census for every loaded PoE 1 active effect
against every loaded support-gem variant. Pair classification calls PoB's own
canGrantedEffectSupportActiveSkill function. It does not calculate pair damage,
reservation, legal equipment links, two-support interactions, or training labels.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$LuaJit,
	[ValidateRange(1, 32)][int]$BatchSize = 16,
	[ValidateRange(10, 3600)][int]$BatchTimeoutSeconds = 600,
	[string]$EvidenceDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('pob-native-skill-support-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$luaPath = (Resolve-Path -LiteralPath $LuaJit).Path
if ([IO.Path]::GetFileName($luaPath) -notin @('luajit.exe', 'luajit')) { throw 'LuaJIT executable path must end in luajit.exe or luajit.' }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$outputRoot = [IO.Path]::GetFullPath($EvidenceDirectory)
if (-not $outputRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
	throw 'Native skill-support audit output must stay below the current Windows TEMP directory.'
}
if (Test-Path -LiteralPath $outputRoot) { throw "Evidence directory already exists: $outputRoot" }
[void](New-Item -ItemType Directory -Path $outputRoot)
$outputRoot = (Resolve-Path -LiteralPath $outputRoot).Path
$batchDirectory = Join-Path $outputRoot 'batches'
[void](New-Item -ItemType Directory -Path $batchDirectory)

$mainPath = Join-Path $repoRoot 'src/Modules/Main.lua'
$manifestPath = Join-Path $repoRoot 'manifest.xml'
$runnerPath = Join-Path $repoRoot 'tools/optimizer/contract_runner.lua'
$specPath = Join-Path $repoRoot 'spec/System/TestNativeSkillSupportCompatibility_spec.lua'
$mainHashBefore = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash
$manifestHashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$runnerHash = (Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash
$specHash = (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash

$countFields = @(
	'activeGemVariantsAttempted', 'seedCreated', 'seedRejected', 'declaredEffectPairs',
	'effectResults', 'effectsMatched', 'effectsNotExposed', 'identityMismatches',
	'nativeEligibilityChecks', 'nativeCompatiblePairs', 'nativeIncompatiblePairs',
	'nativeCheckErrors', 'sourceSkillSetsPreserved'
)
$totals = [ordered]@{}
foreach ($field in $countFields) { $totals[$field] = 0 }
$allRows = [Collections.Generic.List[object]]::new()
$batchRecords = [Collections.Generic.List[object]]::new()
$seenGemIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$seenEffectPairs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$catalogGemCount = $null
$catalogEffectCount = $null
$supportCount = $null
$expectedVersion = $null
$expectedSupportIds = $null
$startIndex = 1
$batchNumber = 0

while ($null -eq $catalogGemCount -or $startIndex -le $catalogGemCount) {
	$batchNumber++
	$batchLimit = if ($null -eq $catalogGemCount) { $BatchSize } else { [Math]::Min($BatchSize, $catalogGemCount - $startIndex + 1) }
	$batchName = '{0:D3}' -f $batchNumber
	$reportPath = Join-Path $batchDirectory "batch-$batchName.json"
	$stdoutPath = Join-Path $batchDirectory "batch-$batchName.log"
	$stderrPath = Join-Path $batchDirectory "batch-$batchName.stderr.log"

	$info = [Diagnostics.ProcessStartInfo]::new()
	$info.FileName = $luaPath
	$info.Arguments = '"' + $runnerPath + '"'
	$info.WorkingDirectory = Join-Path $repoRoot 'src'
	$info.UseShellExecute = $false
	$info.CreateNoWindow = $true
	$info.RedirectStandardOutput = $true
	$info.RedirectStandardError = $true
	$info.EnvironmentVariables['CI'] = '1'
	$info.EnvironmentVariables['POB_TEST_SPEC'] = '../spec/System/TestNativeSkillSupportCompatibility_spec.lua'
	$info.EnvironmentVariables['POB_SUPPORT_AUDIT_START'] = [string]$startIndex
	$info.EnvironmentVariables['POB_SUPPORT_AUDIT_LIMIT'] = [string]$batchLimit
	$info.EnvironmentVariables['POB_SUPPORT_AUDIT_PATH'] = $reportPath
	$info.EnvironmentVariables['LUA_PATH'] = '.\?.lua;.\?\init.lua;..\runtime\lua\?.lua;..\runtime\lua\?\init.lua'
	$info.EnvironmentVariables['LUA_CPATH'] = '.\?.dll;..\runtime\?.dll;..\runtime\lua\?.dll'

	$process = [Diagnostics.Process]::new()
	$process.StartInfo = $info
	$watch = [Diagnostics.Stopwatch]::StartNew()
	[void]$process.Start()
	$stdoutTask = $process.StandardOutput.ReadToEndAsync()
	$stderrTask = $process.StandardError.ReadToEndAsync()
	$timedOut = -not $process.WaitForExit($BatchTimeoutSeconds * 1000)
	if ($timedOut) { $process.Kill(); $process.WaitForExit() }
	$stdoutText = $stdoutTask.GetAwaiter().GetResult()
	$stderrText = $stderrTask.GetAwaiter().GetResult()
	$watch.Stop()
	[IO.File]::WriteAllText($stdoutPath, $stdoutText)
	[IO.File]::WriteAllText($stderrPath, $stderrText)
	$exitCode = $process.ExitCode
	$process.Dispose()
	$match = [regex]::Match($stdoutText, '(?m)^RESULT (\d+)/(\d+) passed;')
	if ($timedOut -or $exitCode -ne 0 -or -not $match.Success -or $match.Groups[1].Value -ne $match.Groups[2].Value) {
		throw "Native skill-support batch $batchName failed or timed out. Inspect $stdoutPath and $stderrPath."
	}
	if (-not (Test-Path -LiteralPath $reportPath)) { throw "Native skill-support batch $batchName did not write its report." }
	$batch = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
	if ($batch.batch.start -ne $startIndex -or $batch.batch.finish -ne ($startIndex + $batchLimit - 1)) {
		throw "Native skill-support batch $batchName returned an unexpected range."
	}
	if ($batch.counts.activeGemVariantsAttempted -ne $batchLimit -or @($batch.results).Count -ne $batchLimit) {
		throw "Native skill-support batch $batchName did not account for every requested active gem."
	}
	if ([int]$batch.counts.seedRejected -ne 0 -or [int]$batch.counts.effectsNotExposed -ne 0 -or
		[int]$batch.counts.identityMismatches -ne 0 -or [int]$batch.counts.nativeCheckErrors -ne 0) {
		throw "Native skill-support batch $batchName reported incomplete or invalid native checks."
	}
	if ([int]$batch.counts.nativeEligibilityChecks -ne ([int]$batch.counts.effectsMatched * [int]$batch.catalog.supportGemVariants)) {
		throw "Native skill-support batch $batchName did not check every effect against every support variant."
	}

	$supportIds = @($batch.supportVariants | ForEach-Object { [string]$_.id })
	if ($null -eq $catalogGemCount) {
		$catalogGemCount = [int]$batch.catalog.activeGemVariants
		$catalogEffectCount = [int]$batch.catalog.activeEffects
		$supportCount = [int]$batch.catalog.supportGemVariants
		$expectedVersion = $batch.version
		$expectedSupportIds = $supportIds -join "`n"
		if ($startIndex + $batchLimit - 1 -gt $catalogGemCount) { throw 'First native audit batch exceeded the active-gem catalog.' }
	} else {
		if ([int]$batch.catalog.activeGemVariants -ne $catalogGemCount -or [int]$batch.catalog.activeEffects -ne $catalogEffectCount -or
			[int]$batch.catalog.supportGemVariants -ne $supportCount) { throw "PoB gem catalog changed during batch $batchName." }
		if ($batch.version.pobVersion -ne $expectedVersion.pobVersion -or $batch.version.dataVersion -ne $expectedVersion.dataVersion -or
			$batch.version.treeVersion -ne $expectedVersion.treeVersion -or
			$batch.version.manifestInventoryFingerprint -ne $expectedVersion.manifestInventoryFingerprint) {
			throw "PoB version or manifest identity changed during batch $batchName."
		}
		if (($supportIds -join "`n") -ne $expectedSupportIds) { throw "Support catalog identity changed during batch $batchName." }
	}

	foreach ($row in @($batch.results)) {
		if (-not $seenGemIds.Add([string]$row.gemId)) { throw "Duplicate active gem in native audit: $($row.gemId)" }
		foreach ($effect in @($row.effects)) {
			$key = [string]$row.gemId + "`t" + [string]$effect.effectId
			if (-not $seenEffectPairs.Add($key)) { throw "Duplicate active effect in native audit: $key" }
		}
		$allRows.Add($row)
	}
	foreach ($field in $countFields) { $totals[$field] += [int]$batch.counts.$field }
	$batchRecords.Add([pscustomobject]@{
		batch = $batchName; start = $startIndex; finish = $startIndex + $batchLimit - 1
		seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
		log = "batches/batch-$batchName.log"; report = "batches/batch-$batchName.json"
	})
	Write-Output ("Batch {0}: skills {1}-{2}/{3}; effects {4}; native checks {5}; compatible {6}; {7}s" -f `
		$batchName, $startIndex, ($startIndex + $batchLimit - 1), $catalogGemCount,
		$batch.counts.effectsMatched, $batch.counts.nativeEligibilityChecks,
		$batch.counts.nativeCompatiblePairs, [math]::Round($watch.Elapsed.TotalSeconds, 2))
	$startIndex += $batchLimit
}

$mainHashAfter = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash
$manifestHashAfter = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
if ($mainHashBefore -ne $mainHashAfter -or $manifestHashBefore -ne $manifestHashAfter) {
	throw 'Main.lua or manifest.xml changed while the native skill-support audit was running.'
}
if ($seenGemIds.Count -ne $catalogGemCount -or $seenEffectPairs.Count -ne $catalogEffectCount) {
	throw 'Native skill-support audit did not cover every loaded active gem and effect exactly once.'
}
if ($totals.nativeEligibilityChecks -ne ($catalogEffectCount * $supportCount) -or
	$totals.nativeCompatiblePairs + $totals.nativeIncompatiblePairs -ne $totals.nativeEligibilityChecks) {
	throw 'Native skill-support audit pair counts are not complete.'
}

$aggregate = [ordered]@{
	schema = 'pob-native-skill-support-compatibility'; schemaVersion = 1
	game = 'Path of Exile 1'; version = $expectedVersion
	catalog = [ordered]@{
		activeGemVariants = $catalogGemCount; activeEffects = $catalogEffectCount
		supportGemVariants = $supportCount; effectSupportVariantPairs = $catalogEffectCount * $supportCount
	}
	fixture = [ordered]@{
		characterLevel = 100; attributes = 'PoB custom mods: +1000 Strength, +1000 Dexterity, +1000 Intelligence'
		equipment = 'empty; native eligibility is context-sensitive for weapon-restricted supports'
		links = 'unlinked diagnostic skill groups'; eligibilityFunction = 'calcLib.canGrantedEffectSupportActiveSkill'
		eligibilityContext = 'Independent support eligibility against native base skill types and the unarmed fixture actor.'
		fullDamageCalculationPerPair = $false; pairwiseSupportInteractions = $false
		trainingEligible = $false; playabilityCertified = $false
	}
	complete = $true
	coverageStatus = 'all_loaded_skill_effect_support_variant_pairs_checked_by_native_eligibility'
	counts = $totals
	supportVariants = @($batch.supportVariants)
	results = @($allRows)
	batches = @($batchRecords)
	verification = [ordered]@{
		runner = 'minimal_busted_adapter'; officialBusted = $false
		mainSHA256Before = $mainHashBefore; mainSHA256After = $mainHashAfter
		manifestSHA256Before = $manifestHashBefore; manifestSHA256After = $manifestHashAfter
		contractRunnerSHA256 = $runnerHash; auditSpecSHA256 = $specHash
		generatedAt = [DateTime]::UtcNow.ToString('o')
	}
}
$aggregatePath = Join-Path $outputRoot 'native-skill-support-audit-v1.json'
[IO.File]::WriteAllText($aggregatePath, ($aggregate | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
$summary = [pscustomobject]@{
	status = $aggregate.coverageStatus; pobVersion = $expectedVersion.pobVersion
	dataVersion = $expectedVersion.dataVersion; treeVersion = $expectedVersion.treeVersion
	activeGemVariants = $catalogGemCount; activeEffects = $catalogEffectCount
	supportGemVariants = $supportCount; checkedPairs = $totals.nativeEligibilityChecks
	compatiblePairs = $totals.nativeCompatiblePairs; incompatiblePairs = $totals.nativeIncompatiblePairs
	seedRejected = $totals.seedRejected; nativeCheckErrors = $totals.nativeCheckErrors
	trainingEligible = $false; report = $aggregatePath
}
$summary | ConvertTo-Json -Depth 8 | Write-Output
