<#
Read the native PoB StudyBuilds coverage summary without modifying the archive.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$LuaJit,
	[string]$LuaModuleOverrideDirectory = '',
	[string]$UserDataPath = (Join-Path $env:USERPROFILE 'Documents/Path of Building'),
	[string]$CsvPath = '',
	[ValidateRange(10, 3600)][int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$sourceRoot = Join-Path $repoRoot 'src'
$luaPath = (Resolve-Path -LiteralPath $LuaJit).Path
$userPath = (Resolve-Path -LiteralPath $UserDataPath).Path
$runner = Join-Path $PSScriptRoot 'read_build_coverage_summary.lua'
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = $luaPath
$info.ArgumentList.Add($runner)
$info.WorkingDirectory = $sourceRoot
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['CI'] = '1'
$info.EnvironmentVariables['POB_USER_DATA'] = $userPath
$luaModulePath = '.\?.lua;.\?\init.lua;..\runtime\lua\?.lua;..\runtime\lua\?\init.lua'
if (-not [string]::IsNullOrWhiteSpace($LuaModuleOverrideDirectory)) {
	$luaModuleRoot = (Resolve-Path -LiteralPath $LuaModuleOverrideDirectory -ErrorAction Stop).Path.TrimEnd('\')
	$luaModulePath = $luaModuleRoot + '\?.lua;' + $luaModuleRoot + '\?\init.lua;' + $luaModulePath
}
$info.EnvironmentVariables['LUA_PATH'] = $luaModulePath
$info.EnvironmentVariables['LUA_CPATH'] = '.\?.dll;..\runtime\?.dll;..\runtime\lua\?.dll'

$process = [Diagnostics.Process]::new()
$process.StartInfo = $info
[void]$process.Start()
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
	$process.Kill()
	$process.WaitForExit()
	throw "Native coverage summary timed out after $TimeoutSeconds seconds."
}
$output = $stdout.GetAwaiter().GetResult()
$errorOutput = $stderr.GetAwaiter().GetResult()
if ($process.ExitCode -ne 0) { throw "Native coverage summary failed: $($errorOutput.Trim())" }
$line = [regex]::Match($output, '(?m)^BUILD_COVERAGE_SUMMARY (.+)$')
if (-not $line.Success) { throw 'HeadlessWrapper did not return a coverage summary.' }
$summary = $line.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
$targetPatches = @('3.24', '3.25', '3.26', '3.27', '3.28', '3.29')
$selectedPatches = @($summary.patches | Where-Object { $_.patch -in $targetPatches } | Sort-Object patch)
if ($selectedPatches.Count -ne $targetPatches.Count -or (@($selectedPatches.patch) -join ',') -ne ($targetPatches -join ',')) {
	throw 'Native coverage summary must include patches 3.24–3.29 in order.'
}
$expectedRowCount = 0
foreach ($patch in $selectedPatches) {
	$patchTargetCount = [int]$patch.counts.targetSkills
	if (@($patch.skills).Count -ne $patchTargetCount) { throw "Native target count does not match skill rows for patch $($patch.patch)." }
	$expectedRowCount += $patchTargetCount
}
$exportedCsv = $null
if ($CsvPath) {
	$targetPath = [IO.Path]::GetFullPath($CsvPath)
	if (Test-Path -LiteralPath $targetPath) { throw "Refusing to overwrite coverage snapshot: $targetPath" }
	$rows = [Collections.Generic.List[object]]::new()
	$snapshotUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
	$culture = [Globalization.CultureInfo]::InvariantCulture
	foreach ($patch in $selectedPatches) {
		foreach ($skill in @($patch.skills)) {
		$ratio = if ([int]$skill.sampleTarget -gt 0) { [double]$skill.uniqueBuilds / [double]$skill.sampleTarget } else { 0 }
			$rows.Add([pscustomobject][ordered]@{
				snapshotUtc = $snapshotUtc
				patch = [string]$patch.patch
				treeVersion = ([string]$patch.patch).Replace('.', '_')
				category = [string]$skill.category
				name = [string]$skill.name
				variantId = ([string]$skill.variantKey).Split('|')[-1]
				effectId = [string]$skill.effectId
				gameId = [string]$skill.gameId
				gemId = [string]$skill.gemId
				uniqueBuilds = [int]$skill.uniqueBuilds
				targetBuilds = [int]$skill.sampleTarget
				remaining = [int]$skill.remainingToTarget
				targetReached = [bool]$skill.targetReached
				coverageRatio = $ratio.ToString('0.0000', $culture)
			})
		}
	}
	if ($rows.Count -ne $expectedRowCount) { throw "Expected $expectedRowCount skill×patch rows for 3.24–3.29, received $($rows.Count)." }
	$parent = Split-Path -Parent $targetPath
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Coverage snapshot directory is missing: $parent" }
	$rows | Export-Csv -LiteralPath $targetPath -NoTypeInformation -Encoding utf8
	$exportedCsv = $targetPath
}
$result = [ordered]@{
	storage = $summary.storage
	catalog = $summary.catalog
	patches = @($selectedPatches | ForEach-Object { [ordered]@{ patch = $_.patch; counts = $_.counts } })
	targetSkillRows = $expectedRowCount
	penanceBrand329Normal = $summary.penanceBrand329Normal
	penanceBrand329Transfigured = $summary.penanceBrand329Transfigured
	model = $summary.model
	csvPath = $exportedCsv
}
$result | ConvertTo-Json -Depth 8
