<#
Import manually captured public PoB codes without making network requests.
The manifest records provenance and rights state; each code is hash-verified,
then passed through PoB's native decoder, loader, calculator, archive and local
Scout/Critic review pair.
#>
[CmdletBinding()]
param(
	[string]$ManifestPath = (Join-Path $PSScriptRoot '../../docs/optimizer/local-build-code-intake-2026-10-24.json'),
	[string]$LuaJit = (Join-Path $env:LOCALAPPDATA 'Temp/pob-luajit/extracted/LuaJIT/bin/luajit.exe'),
	[string]$UserDataPath = (Join-Path $env:USERPROFILE 'Documents/Path of Building'),
	[string]$EvidenceDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('pob-local-build-ingest-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
	[switch]$ReviewOnly
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$manifest = Get-Content -LiteralPath (Resolve-Path -LiteralPath $ManifestPath).Path -Raw | ConvertFrom-Json
$luaExecutable = (Resolve-Path -LiteralPath $LuaJit).Path
$userPath = (Resolve-Path -LiteralPath $UserDataPath).Path
$archiveRoot = (Resolve-Path -LiteralPath (Join-Path $userPath 'OptimizerStudies/Builds')).Path
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $archiveRoot 'source-codes')).Path
$ingestionRoot = Join-Path $userPath 'OptimizerStudies/BuildIngestion/Batches'
$evidenceRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) ''
$null = New-Item -ItemType Directory -Path $evidenceRoot -Force
$null = New-Item -ItemType Directory -Path $ingestionRoot -Force

if ($manifest.schema -ne 'pob-ai-planner-local-build-code-intake' -or $manifest.schemaVersion -ne 1) {
	throw 'Unsupported local build-code intake manifest.'
}
if (-not $manifest.builds -or $manifest.builds.Count -eq 0) { throw 'The intake manifest has no builds.' }
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$stagedPath = Join-Path $evidenceRoot 'staged-builds.jsonl'
$staged = [Collections.Generic.List[string]]::new()
$sourceEvidence = [Collections.Generic.List[object]]::new()
$seenIds = @{}
$sourceRootPrefix = $sourceRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar

foreach ($entry in $manifest.builds) {
	$id = [string]$entry.id
	if ($id -notmatch '^[A-Za-z0-9_-]{3,64}$' -or $seenIds.ContainsKey($id)) { throw ('Invalid or duplicate intake id: ' + $id) }
	$seenIds[$id] = $true
	foreach ($required in @('providerId', 'sourceUrl', 'reference', 'codePath', 'codeSha256', 'title')) {
		if ([string]::IsNullOrWhiteSpace([string]$entry.$required)) { throw ('Missing required field ' + $required + ' for ' + $id) }
	}
	if ($entry.sourceUrl -notmatch '^https://[A-Za-z0-9.-]+/') { throw ('Source URL must be HTTPS for ' + $id) }
	if ($entry.reference -notmatch '^https://[A-Za-z0-9.-]+/') { throw ('PoB code reference must be HTTPS for ' + $id) }
	if ($entry.rightsStatus -notin @('permission_granted', 'public_domain', 'licensed') -or
		[string]::IsNullOrWhiteSpace([string]$entry.rightsEvidenceUrl)) {
		throw ('Persistent local build intake requires explicit creator/license evidence before import: ' + $id)
	}
	if ($entry.codePath -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted([string]$entry.codePath)) {
		throw ('Code path must be relative and traversal-free for ' + $id)
	}
	$relativePath = ([string]$entry.codePath).Replace('/', [IO.Path]::DirectorySeparatorChar)
	$filePath = (Resolve-Path -LiteralPath (Join-Path $archiveRoot $relativePath)).Path
	if (-not $filePath.StartsWith($sourceRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
		throw ('Code path must remain under the reserved source-codes directory for ' + $id)
	}
	$code = [IO.File]::ReadAllText($filePath).Trim()
	if ($code.Length -lt 32 -or $code.Length -gt 16777216 -or $code -notmatch '^[A-Za-z0-9+/_-]+={0,2}$') {
		throw ('Invalid or oversized PoB code for ' + $id)
	}
	$actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8NoBom.GetBytes($code))).ToLowerInvariant()
	if ($actualHash -ne ([string]$entry.codeSha256).ToLowerInvariant()) { throw ('PoB code SHA-256 mismatch for ' + $id) }
	$relativeArchivePath = $relativePath.Replace('\', '/')
	$record = [ordered]@{
		id = $id; code = $code; providerId = [string]$entry.providerId
		reference = [string]$entry.reference; sourceUrl = [string]$entry.sourceUrl
		title = [string]$entry.title; creator = [string]$entry.creator; label = [string]$entry.label
		locale = [string]$entry.locale; claimedLeague = [string]$entry.claimedLeague; claimedPatch = [string]$entry.claimedPatch
		rightsStatus = [string]$entry.rightsStatus; rightsEvidenceUrl = [string]$entry.rightsEvidenceUrl
		acquisitionMethod = [string]$entry.acquisitionMethod; acquiredAt = [string]$entry.acquiredAt
		codeSha256 = $actualHash; codePath = $relativeArchivePath
	}
	$staged.Add(($record | ConvertTo-Json -Depth 8 -Compress))
	$sourceEvidence.Add([pscustomobject]@{
		id = $id; providerId = $entry.providerId; reference = $entry.reference; sourceUrl = $entry.sourceUrl
		title = $entry.title; codeSha256 = $actualHash; codePath = $relativeArchivePath
		codeCharacters = $code.Length; rightsStatus = $entry.rightsStatus
		acquisitionMethod = [string]$entry.acquisitionMethod; retrieval = 'local_source_file_sha256_verified'
	})
}
[IO.File]::WriteAllLines($stagedPath, $staged, $utf8NoBom)

$luaScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'ingest_public_builds.lua')).Path
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = $luaExecutable
$info.Arguments = '"' + $luaScript + '"'
$info.WorkingDirectory = Join-Path $repoRoot 'src'
$info.UseShellExecute = $false; $info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
$info.EnvironmentVariables['CI'] = '1'
$info.EnvironmentVariables['POB_PUBLIC_INGEST_BATCH'] = $stagedPath
$info.EnvironmentVariables['POB_PUBLIC_INGEST_USER_PATH'] = $userPath
$info.EnvironmentVariables['POB_PUBLIC_INGEST_REVIEW_ONLY'] = if ($ReviewOnly) { '1' } else { '0' }
$info.EnvironmentVariables['LUA_PATH'] = '.\?.lua;.\?\init.lua;..\runtime\lua\?.lua;..\runtime\lua\?\init.lua'
$info.EnvironmentVariables['LUA_CPATH'] = '.\?.dll;..\runtime\?.dll;..\runtime\lua\?.dll'
$process = [Diagnostics.Process]::new(); $process.StartInfo = $info
$null = $process.Start()
$stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(900000)) { $process.Kill(); $process.WaitForExit(); throw 'Native PoB ingestion exceeded 15 minutes and was stopped.' }
$stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult()
$luaExitCode = $process.ExitCode
[IO.File]::WriteAllText((Join-Path $evidenceRoot 'headless.stdout.log'), $stdout, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $evidenceRoot 'headless.stderr.log'), $stderr, $utf8NoBom)
$importResults = @([regex]::Matches($stdout, '(?m)^INGEST_RESULT (.+)$') | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
$missingResultCount = [Math]::Max(0, $sourceEvidence.Count - $importResults.Count)
$batchReport = [ordered]@{
	schema = 'pob-ai-planner-local-build-ingestion-batch'; schemaVersion = 1
	startedBy = 'PathOfBuilding-AIPlanner local intake'; generatedAt = [DateTime]::UtcNow.ToString('o')
	mode = if ($ReviewOnly) { 'review_only' } else { 'archive_and_review' }
	sourceMethod = [string]$manifest.method; collectionPolicy = $manifest.collectionPolicy
	policy = 'No network requests; local source file SHA-256 verified; rights state is retained without assuming permission.'
	sourceEvidence = @($sourceEvidence); importResults = $importResults; luaExitCode = $luaExitCode
	missingResultCount = $missingResultCount; stdoutLog = Join-Path $evidenceRoot 'headless.stdout.log'
	stderrLog = Join-Path $evidenceRoot 'headless.stderr.log'
}
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$batchPath = Join-Path $ingestionRoot ('local-batch-' + $timestamp + '.json')
[IO.File]::WriteAllText($batchPath, ($batchReport | ConvertTo-Json -Depth 16), $utf8NoBom)
$process.Dispose()
Write-Output ('Archive: ' + $archiveRoot)
Write-Output ('Batch report: ' + $batchPath)
Write-Output ('Execution logs: ' + $evidenceRoot)
$successCount = if ($ReviewOnly) { @($importResults | Where-Object status -in @('reviewed', 'already_reviewed')).Count } else { @($importResults | Where-Object status -eq 'archived').Count }
$failedCount = @($importResults | Where-Object status -notin @('archived', 'reviewed', 'already_reviewed')).Count
Write-Output ('Local codes ready: ' + $sourceEvidence.Count + '; completed: ' + $successCount + '; failed: ' + $failedCount + '; missing results: ' + $missingResultCount)
if ($luaExitCode -ne 0 -or $missingResultCount -gt 0 -or $failedCount -gt 0) { exit 1 }
