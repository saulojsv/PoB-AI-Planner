<#
Import user-selected local PoB XML files through the isolated native HeadlessWrapper.
The original XML is hash-verified and retained as source evidence. This command
does not fetch builds, assert training rights, or write GNN dataset rows.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$InputDirectory,
	[switch]$Recurse,
	[string]$LuaJit = (Join-Path $env:LOCALAPPDATA 'Temp/pob-luajit/extracted/LuaJIT/bin/luajit.exe'),
	[string]$UserDataPath = (Join-Path $env:USERPROFILE 'Documents/Path of Building'),
	[string]$EvidenceDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('pob-local-xml-ingest-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$inputRoot = (Resolve-Path -LiteralPath $InputDirectory).Path.TrimEnd('\', '/')
$luaExecutable = (Resolve-Path -LiteralPath $LuaJit).Path
$userPath = (Resolve-Path -LiteralPath $UserDataPath).Path
$evidenceRoot = [IO.Path]::GetFullPath($EvidenceDirectory)
$null = New-Item -ItemType Directory -Path $evidenceRoot -Force
$studiesRoot = Join-Path $userPath 'OptimizerStudies'
$null = New-Item -ItemType Directory -Path $studiesRoot -Force
$null = New-Item -ItemType Directory -Path (Join-Path $studiesRoot 'Builds') -Force

$sourcePrefix = $inputRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($Recurse) {
	$files = @(Get-ChildItem -LiteralPath $inputRoot -Filter '*.xml' -File -Recurse)
} else {
	$files = @(Get-ChildItem -LiteralPath $inputRoot -Filter '*.xml' -File)
}
if ($files.Count -eq 0) { throw 'No .xml files were found in the selected input directory.' }

$maxXmlBytes = 16MB
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$stagedPath = Join-Path $evidenceRoot 'staged-local-xml.jsonl'
$stagedRows = [Collections.Generic.List[string]]::new()
$sourceEvidence = [Collections.Generic.List[object]]::new()
$seenHashes = @{}
$duplicateInputs = [Collections.Generic.List[object]]::new()
$index = 0
foreach ($file in ($files | Sort-Object FullName)) {
	$resolvedFile = (Resolve-Path -LiteralPath $file.FullName).Path
	if (-not $resolvedFile.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
		throw ('XML input escaped the selected directory: ' + $file.Name)
	}
	$attributes = [IO.File]::GetAttributes($resolvedFile)
	if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
		throw ('Symbolic links and reparse points are not accepted as XML inputs: ' + $file.Name)
	}
	$length = [long](Get-Item -LiteralPath $resolvedFile).Length
	if ($length -lt 1 -or $length -gt $maxXmlBytes) {
		throw ('XML must be 1–16 MiB for native archive intake: ' + $file.Name)
	}
	$hash = (Get-FileHash -LiteralPath $resolvedFile -Algorithm SHA256).Hash.ToLowerInvariant()
	if ($seenHashes.ContainsKey($hash)) {
		$duplicateInputs.Add([pscustomobject]@{ name = $file.Name; sourceXmlSha256 = $hash; duplicateOf = $seenHashes[$hash] })
		continue
	}
	$seenHashes[$hash] = $file.Name
	$index++
	$id = 'localxml-' + $hash.Substring(0, 24)
	$title = $file.BaseName
	if ($title.Length -gt 120) { $title = $title.Substring(0, 120) }
	$record = [ordered]@{
		sourceFormat = 'pob_xml'
		id = $id
		providerId = 'LocalXML'
		reference = 'local-xml://sha256/' + $hash
		sourceUrl = ''
		title = $title
		label = $title
		creator = ''
		locale = ''
		claimedLeague = ''
		claimedPatch = ''
		rightsStatus = 'unverified'
		rightsEvidenceUrl = ''
		acquisitionMethod = 'user_selected_local_xml'
		acquiredAt = [DateTime]::UtcNow.ToString('o')
		sourceXmlPath = $resolvedFile
		sourceXmlSha256 = $hash
	}
	$stagedRows.Add(($record | ConvertTo-Json -Depth 8 -Compress))
	$sourceEvidence.Add([pscustomobject]@{
		id = $id; name = $file.Name; sourceXmlSha256 = $hash; bytes = $length
		rightsStatus = 'unverified'; acquisitionMethod = 'user_selected_local_xml'
	})
}
if ($stagedRows.Count -eq 0) { throw 'All XML files were duplicate byte-identical inputs; nothing new was staged.' }
[IO.File]::WriteAllLines($stagedPath, $stagedRows, $utf8NoBom)

$luaScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'ingest_public_builds.lua')).Path
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = $luaExecutable
$info.Arguments = '"' + $luaScript + '"'
$info.WorkingDirectory = Join-Path $repoRoot 'src'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['CI'] = '1'
$info.EnvironmentVariables['POB_PUBLIC_INGEST_BATCH'] = $stagedPath
$info.EnvironmentVariables['POB_PUBLIC_INGEST_USER_PATH'] = $userPath
$info.EnvironmentVariables['POB_PUBLIC_INGEST_REVIEW_ONLY'] = '0'
$info.EnvironmentVariables['LUA_PATH'] = '.\?.lua;.\?\init.lua;..\runtime\lua\?.lua;..\runtime\lua\?\init.lua'
$info.EnvironmentVariables['LUA_CPATH'] = '.\?.dll;..\runtime\?.dll;..\runtime\lua\?.dll'
$process = [Diagnostics.Process]::new()
$process.StartInfo = $info
$null = $process.Start()
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(900000)) {
	$process.Kill(); $process.WaitForExit()
	throw 'Native PoB XML ingestion exceeded 15 minutes and was stopped.'
}
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
$luaExitCode = $process.ExitCode
[IO.File]::WriteAllText((Join-Path $evidenceRoot 'headless.stdout.log'), $stdout, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $evidenceRoot 'headless.stderr.log'), $stderr, $utf8NoBom)
$results = @([regex]::Matches($stdout, '(?m)^INGEST_RESULT (.+)$') | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
$missingCount = [Math]::Max(0, $sourceEvidence.Count - $results.Count)
$batchReport = [ordered]@{
	schema = 'pob-ai-planner-local-xml-ingestion-batch'; schemaVersion = 1
	generatedAt = [DateTime]::UtcNow.ToString('o')
	mode = 'isolated_native_xml_import_and_exact_calculation'
	policy = 'No network requests; original local XML hash-verified; rights remain unverified; no GNN training rows are created by this intake.'
	sourceEvidence = @($sourceEvidence); duplicateInputs = @($duplicateInputs)
	quarantinedIncompleteOrCorruptCount = @($results | Where-Object status -eq 'source_incomplete_or_corrupt').Count
	importResults = $results; luaExitCode = $luaExitCode; missingResultCount = $missingCount
	stdoutLog = Join-Path $evidenceRoot 'headless.stdout.log'
	stderrLog = Join-Path $evidenceRoot 'headless.stderr.log'
}
$batchPath = Join-Path $evidenceRoot 'local-xml-batch.json'
[IO.File]::WriteAllText($batchPath, ($batchReport | ConvertTo-Json -Depth 16), $utf8NoBom)
$null = Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
$process.Dispose()

$sourceRetainedCount = @($results | Where-Object {
	$_.PSObject.Properties['sourceXmlPath'] -and $_.sourceXmlPath -and
	$_.PSObject.Properties['sourceXmlSha256'] -and $_.sourceXmlSha256
}).Count
$nativeArchiveCount = @($results | Where-Object {
	$_.PSObject.Properties['status'] -and $_.status -in @('archived', 'already_archived', 'already_archived_duplicate_lineage')
}).Count
$duplicateLineageCount = @($results | Where-Object {
	$_.PSObject.Properties['status'] -and $_.status -eq 'already_archived_duplicate_lineage'
}).Count
$ineligibleCount = @($results | Where-Object { $_.PSObject.Properties['status'] -and $_.status -eq 'target_gate_rejected' }).Count
$quarantinedCount = @($results | Where-Object { $_.PSObject.Properties['status'] -and $_.status -eq 'source_incomplete_or_corrupt' }).Count
$errorCount = @($results | Where-Object {
	-not $_.PSObject.Properties['status'] -or $_.status -notin @('archived', 'already_archived', 'already_archived_duplicate_lineage', 'target_gate_rejected', 'source_incomplete_or_corrupt')
}).Count
Write-Output ('Batch report: ' + $batchPath)
Write-Output ('Evidence and logs: ' + $evidenceRoot)
Write-Output ('Original XML retained: ' + $sourceRetainedCount + '/' + $sourceEvidence.Count)
Write-Output ('Native build archive or duplicate safely skipped: ' + $nativeArchiveCount + '; duplicate lineages skipped: ' + $duplicateLineageCount + '; quarantined incomplete/corrupt XML: ' + $quarantinedCount + '; legacy target-gate rejected: ' + $ineligibleCount + '; technical errors: ' + $errorCount)
if ($luaExitCode -ne 0 -or $missingCount -gt 0 -or $errorCount -gt 0 -or $sourceRetainedCount -lt $sourceEvidence.Count) { exit 1 }
