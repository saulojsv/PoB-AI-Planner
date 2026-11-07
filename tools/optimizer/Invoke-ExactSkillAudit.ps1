<#
Run the opt-in exact calculator audit over PoB's loaded PoE 1 active-skill gem catalog.
Each batch launches a fresh native HeadlessWrapper process. The audit uses only
PoB's local data/calculator and a synthetic unlinked diagnostic profile; it is
not a playable-build, support-combination, training, or ranking evaluation.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$LuaJit,
	[ValidateRange(1, 64)][int]$BatchSize = 32,
	[ValidateRange(10, 3600)][int]$BatchTimeoutSeconds = 600,
	[string]$EvidenceDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('pob-exact-skill-audit-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$luaPath = (Resolve-Path -LiteralPath $LuaJit).Path
$luaDirectory = Split-Path -Parent $luaPath
$luaName = [IO.Path]::GetFileName($luaPath)
if ($luaName -notin @('luajit.exe', 'luajit')) { throw 'LuaJIT executable path must end in luajit.exe or luajit.' }

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$outputRoot = [IO.Path]::GetFullPath($EvidenceDirectory)
if (-not $outputRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
	throw 'Exact skill audit output must stay below the current Windows TEMP directory.'
}
if (Test-Path -LiteralPath $outputRoot) { throw "Evidence directory already exists: $outputRoot" }
[void](New-Item -ItemType Directory -Path $outputRoot)
$outputRoot = (Resolve-Path -LiteralPath $outputRoot).Path
$batchDirectory = Join-Path $outputRoot 'batches'
[void](New-Item -ItemType Directory -Path $batchDirectory)

$mainPath = Join-Path $repoRoot 'src/Modules/Main.lua'
$manifestPath = Join-Path $repoRoot 'manifest.xml'
$runnerPath = Join-Path $repoRoot 'tools/optimizer/contract_runner.lua'
$specPath = Join-Path $repoRoot 'spec/System/TestExactSkillAudit_spec.lua'
$mainHashBefore = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash
$manifestHashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$runnerHash = (Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash
$specHash = (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash

$allResults = [Collections.Generic.List[object]]::new()
$seenGemIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$batchRecords = [Collections.Generic.List[object]]::new()
$countFields = @(
	'gemVariantsAttempted', 'seedCreated', 'seedRejected', 'declaredEffectPairs',
	'declaredEffectResults', 'declaredEffectsExactCalculated', 'effectsBlockedBySeed',
	'effectsDiscovered', 'exactCalculated', 'notExposedByNativeSkillGroup',
	'calculationErrors', 'identityMismatches', 'sourceSkillSetsPreserved'
)
$totals = [ordered]@{}
foreach ($field in $countFields) { $totals[$field] = 0 }

$catalogGemCount = $null
$catalogEffectCount = $null
$expectedVersion = $null
$expectedProfile = $null
$startIndex = 1
$batchNumber = 0

while ($null -eq $catalogGemCount -or $startIndex -le $catalogGemCount) {
	$batchNumber++
	$batchLimit = if ($null -eq $catalogGemCount) { $BatchSize } else { [Math]::Min($BatchSize, $catalogGemCount - $startIndex + 1) }
	$batchName = '{0:D3}' -f $batchNumber
	$batchReportPath = Join-Path $batchDirectory ("batch-$batchName.json")
	$batchEvidencePath = Join-Path $batchDirectory ("run-$batchName")
	[void](New-Item -ItemType Directory -Path $batchEvidencePath)
	$stdoutPath = Join-Path $batchDirectory ("batch-$batchName.log")
	$stderrPath = Join-Path $batchDirectory ("batch-$batchName.stderr.log")

	$info = [Diagnostics.ProcessStartInfo]::new()
	$info.FileName = $luaPath
	$info.Arguments = '"' + $runnerPath + '"'
	$info.WorkingDirectory = Join-Path $repoRoot 'src'
	$info.UseShellExecute = $false
	$info.CreateNoWindow = $true
	$info.RedirectStandardOutput = $true
	$info.RedirectStandardError = $true
	$info.EnvironmentVariables['CI'] = '1'
	$info.EnvironmentVariables['POB_TEST_SPEC'] = '../spec/System/TestExactSkillAudit_spec.lua'
	$info.EnvironmentVariables['POB_EXACT_SKILL_START'] = [string]$startIndex
	$info.EnvironmentVariables['POB_EXACT_SKILL_LIMIT'] = [string]$batchLimit
	$info.EnvironmentVariables['POB_EXACT_SKILL_AUDIT_PATH'] = $batchReportPath
	$info.EnvironmentVariables['LUA_PATH'] = '.\?.lua;.\?\init.lua;..\runtime\lua\?.lua;..\runtime\lua\?\init.lua'
	$info.EnvironmentVariables['LUA_CPATH'] = '.\?.dll;..\runtime\?.dll;..\runtime\lua\?.dll'

	$process = [Diagnostics.Process]::new()
	$process.StartInfo = $info
	$watch = [Diagnostics.Stopwatch]::StartNew()
	[void]$process.Start()
	$stdoutTask = $process.StandardOutput.ReadToEndAsync()
	$stderrTask = $process.StandardError.ReadToEndAsync()
	$timedOut = -not $process.WaitForExit($BatchTimeoutSeconds * 1000)
	if ($timedOut) {
		$process.Kill()
		$process.WaitForExit()
	}
	$stdoutText = $stdoutTask.GetAwaiter().GetResult()
	$stderrText = $stderrTask.GetAwaiter().GetResult()
	$watch.Stop()
	[IO.File]::WriteAllText($stdoutPath, $stdoutText)
	[IO.File]::WriteAllText($stderrPath, $stderrText)
	$exitCode = $process.ExitCode
	$process.Dispose()

	$resultMatch = [regex]::Match($stdoutText, '(?m)^RESULT (\d+)/(\d+) passed;')
	$caseMatch = [regex]::Match($stdoutText, '(?m)^QA_CASE (.+)$')
	if ($timedOut -or $exitCode -ne 0 -or -not $resultMatch.Success -or $resultMatch.Groups[1].Value -ne $resultMatch.Groups[2].Value) {
		throw "Exact skill audit batch $batchName failed or timed out. Inspect $stdoutPath and $stderrPath."
	}
	if (-not (Test-Path -LiteralPath $batchReportPath)) { throw "Audit batch $batchName did not write its report." }
	$batchReport = Get-Content -LiteralPath $batchReportPath -Raw | ConvertFrom-Json
	if ($batchReport.batch.start -ne $startIndex -or $batchReport.batch.finish -ne ($startIndex + $batchLimit - 1)) {
		throw "Audit batch $batchName returned an unexpected range."
	}
	if ($batchReport.counts.gemVariantsAttempted -ne $batchLimit -or $batchReport.results.Count -ne $batchLimit) {
		throw "Audit batch $batchName did not account for every requested gem variant."
	}
	if ($caseMatch.Success) { $case = $caseMatch.Groups[1].Value | ConvertFrom-Json } else { $case = $null }
	$engineMatch = [regex]::Match($stdoutText, '(?m)^QA_ENGINE (.+)$')
	$engine = if ($engineMatch.Success) { $engineMatch.Groups[1].Value | ConvertFrom-Json } else { $null }
	$contractReport = [ordered]@{
		runner = 'minimal_busted_adapter'
		officialBusted = $false
		engine = $engine
		generatedAt = [DateTime]::UtcNow.ToString('o')
		suites = @([ordered]@{
			suite = 'TestExactSkillAudit_spec.lua'
			passed = [int]$resultMatch.Groups[1].Value
			total = [int]$resultMatch.Groups[2].Value
			success = $true
			exitCode = $exitCode
			timedOut = $false
			seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
			log = "../batch-$batchName.log"
			stderr = "../batch-$batchName.stderr.log"
			cases = @($case)
		})
	}
	$contractReport | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $batchEvidencePath 'results.json') -Encoding UTF8

	if ($null -eq $catalogGemCount) {
		$catalogGemCount = [int]$batchReport.catalog.declaredActiveGemVariants
		$catalogEffectCount = [int]$batchReport.catalog.declaredSupportedActiveEffects
		$expectedVersion = $batchReport.version
		$expectedProfile = $batchReport.calculationProfile
		if ($startIndex + $batchLimit - 1 -gt $catalogGemCount) { throw 'First batch exceeded the loaded active-gem catalog.' }
	} else {
		if ([int]$batchReport.catalog.declaredActiveGemVariants -ne $catalogGemCount) { throw "Active-gem catalog count changed during batch $batchName." }
		if ([int]$batchReport.catalog.declaredSupportedActiveEffects -ne $catalogEffectCount) { throw "Active-effect catalog count changed during batch $batchName." }
		if ($batchReport.version.pobVersion -ne $expectedVersion.pobVersion) { throw "PoB version changed during batch $batchName." }
		if ($batchReport.version.dataVersion -ne $expectedVersion.dataVersion) { throw "PoE data version changed during batch $batchName." }
		if ($batchReport.version.treeVersion -ne $expectedVersion.treeVersion) { throw "Passive-tree version changed during batch $batchName." }
		if ($batchReport.version.manifestInventoryFingerprint -ne $expectedVersion.manifestInventoryFingerprint) { throw "Manifest inventory changed during batch $batchName." }
	}

	foreach ($row in $batchReport.results) {
		if (-not $seenGemIds.Add([string]$row.gemId)) { throw "Duplicate gem variant in audit: $($row.gemId)" }
		$allResults.Add($row)
	}
	foreach ($field in $countFields) { $totals[$field] += [int]$batchReport.counts.$field }
	$batchRecords.Add([pscustomobject]@{
		batch = $batchName
		start = [int]$batchReport.batch.start
		finish = [int]$batchReport.batch.finish
		seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
		stdout = "batches/batch-$batchName.log"
		log = "batches/batch-$batchName.log"
		report = "batches/batch-$batchName.json"
		contractResults = "batches/run-$batchName/results.json"
		caseSummary = $case
	})

	Write-Output ("Batch {0}: gems {1}-{2}/{3}; exact effects {4}/{5}; seed rejections {6}; calc errors {7}; {8}s" -f `
		$batchName, $startIndex, ($startIndex + $batchLimit - 1), $catalogGemCount,
		$batchReport.counts.exactCalculated, $batchReport.counts.declaredEffectPairs,
		$batchReport.counts.seedRejected, $batchReport.counts.calculationErrors, [math]::Round($watch.Elapsed.TotalSeconds, 2))
	$startIndex += $batchLimit
}

$mainHashAfter = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash
$manifestHashAfter = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
if ($mainHashBefore -ne $mainHashAfter -or $manifestHashBefore -ne $manifestHashAfter) {
	throw 'Main.lua or manifest.xml changed while the exact skill audit was running.'
}
if ($allResults.Count -ne $catalogGemCount -or $seenGemIds.Count -ne $catalogGemCount) {
	throw 'Audit did not cover each loaded active-gem variant exactly once.'
}
if ($totals.declaredEffectPairs -ne $totals.declaredEffectResults) {
	throw 'Some declared gem/effect pairs lack a result or a precise rejection reason.'
}

$allEffectsExactlyCalculated = $totals.declaredEffectsExactCalculated -eq $totals.declaredEffectPairs
$auditStatus = if ($allEffectsExactlyCalculated -and $totals.identityMismatches -eq 0 -and $totals.calculationErrors -eq 0) {
	'all_declared_effects_exactly_calculated'
} else {
	'completed_with_exact_calculation_gaps'
}
$aggregate = [ordered]@{
	schema = 'pob-exact-skill-audit'
	schemaVersion = 1
	game = 'Path of Exile 1'
	version = $expectedVersion
	catalog = [ordered]@{
		declaredActiveGemVariants = $catalogGemCount
		declaredSupportedActiveEffects = $catalogEffectCount
	}
	calculationProfile = $expectedProfile
	trainingEligible = $false
	playabilityCertified = $false
	combinationsEvaluated = $false
	complete = $true
	allDeclaredEffectsExactlyCalculated = $allEffectsExactlyCalculated
	auditStatus = $auditStatus
	counts = $totals
	results = @($allResults)
	batches = @($batchRecords)
	verification = [ordered]@{
		runner = 'minimal_busted_adapter'
		officialBusted = $false
		sourceMainSHA256Before = $mainHashBefore
		sourceMainSHA256After = $mainHashAfter
		manifestSHA256Before = $manifestHashBefore
		manifestSHA256After = $manifestHashAfter
		contractRunnerSHA256 = $runnerHash
		auditSpecSHA256 = $specHash
		luaJitSHA256 = (Get-FileHash -LiteralPath $luaPath -Algorithm SHA256).Hash
		generatedAt = [DateTime]::UtcNow.ToString('o')
	}
}
$aggregatePath = Join-Path $outputRoot 'catalog-exact-audit-v1.json'
$aggregateJson = $aggregate | ConvertTo-Json -Depth 40
[IO.File]::WriteAllText($aggregatePath, $aggregateJson, [Text.UTF8Encoding]::new($false))
$summary = [pscustomobject]@{
	status = $aggregate.auditStatus
	game = $aggregate.game
	pobVersion = $expectedVersion.pobVersion
	dataVersion = $expectedVersion.dataVersion
	activeGemVariants = $catalogGemCount
	declaredEffects = $catalogEffectCount
	seedCreated = $totals.seedCreated
	seedRejected = $totals.seedRejected
	effectsExactlyCalculated = $totals.declaredEffectsExactCalculated
	effectsNotExposed = $totals.notExposedByNativeSkillGroup
	effectsBlockedBySeed = $totals.effectsBlockedBySeed
	calculationErrors = $totals.calculationErrors
	identityMismatches = $totals.identityMismatches
	sourceSkillSetsPreserved = $totals.sourceSkillSetsPreserved
	trainingEligible = $false
	report = $aggregatePath
}
$summary | ConvertTo-Json -Depth 8 | Write-Output
Write-Output ("Evidence directory: {0}" -f $outputRoot)
