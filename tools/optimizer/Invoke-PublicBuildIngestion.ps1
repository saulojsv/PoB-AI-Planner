<#
 Import only user-directed, manually selected public PoB share codes for local
 study, then validate them through isolated native PoB HeadlessWrapper. This
 importer does not search the web or run continuously. PoBBin HTML is parsed
 only to read the share code from a specific link selected during manual review.
 PoE Ninja profile/PoB endpoints stay blocked under its published API policy;
 Maxroll automated extraction remains excluded under its published terms.
#>
[CmdletBinding()]
param(
	[string]$ManifestPath = (Join-Path $PSScriptRoot '../../docs/optimizer/public-build-intake-2026-10-24.json'),
	[string]$LuaJit = (Join-Path $env:LOCALAPPDATA 'Temp/pob-luajit/extracted/LuaJIT/bin/luajit.exe'),
	[string]$LuaModuleOverrideDirectory = '',
	[string]$UserDataPath = (Join-Path $env:USERPROFILE 'Documents/Path of Building'),
	[string]$RequestCoordinatorRoot = '',
	[string]$EvidenceDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('pob-public-build-ingest-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
	[string]$LatestResultsPath = '',
	[string]$ProgressPath = '',
	[ValidateRange(1, 3600)][int]$MinimumDelaySeconds = 5,
	[ValidateRange(300, 3600)][int]$MinimumPoeNinjaDelaySeconds = 300,
	[switch]$RefreshSources,
	[switch]$ReviewOnly,
	[switch]$UserDirectedLocalStudy
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$manifest = Get-Content -LiteralPath (Resolve-Path -LiteralPath $ManifestPath).Path -Raw | ConvertFrom-Json
if ($manifest.schema -ne 'pob-ai-planner-public-build-intake' -or $manifest.schemaVersion -ne 1) { throw 'Unsupported build-intake manifest.' }
$blockedMaxrollIds = @($manifest.builds | Where-Object {
	[string]$_.providerId -eq 'Maxroll' -or
	[string]$_.sourceUrl -match '(?i)^https://(?:[a-z0-9-]+\.)*maxroll\.gg(?:/|$)'
} | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($blockedMaxrollIds.Count -gt 0) {
	throw ('Automated Maxroll extraction is disabled: its published robots policy/terms prohibit automated collection and AI/ML use without written permission. Excluded IDs: ' + ($blockedMaxrollIds -join ', '))
}
$luaExecutable = (Resolve-Path -LiteralPath $LuaJit).Path
$userPath = (Resolve-Path -LiteralPath $UserDataPath).Path
$evidenceRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) ''
$archiveRoot = Join-Path $userPath 'OptimizerStudies/Builds'
$buildCodeRoot = Join-Path $archiveRoot 'source-codes'
$buildIngestionRoot = Join-Path $userPath 'OptimizerStudies/BuildIngestion'
$requestCoordinatorRoot = if ([string]::IsNullOrWhiteSpace($RequestCoordinatorRoot)) { $buildIngestionRoot } else { [IO.Path]::GetFullPath($RequestCoordinatorRoot) }
$ingestionRoot = Join-Path $buildIngestionRoot 'Batches'
$null = New-Item -ItemType Directory -Path $evidenceRoot -Force
$null = New-Item -ItemType Directory -Path $buildCodeRoot -Force
$null = New-Item -ItemType Directory -Path $ingestionRoot -Force

# Keep the configured global gap intact. A site's robots.txt Crawl-delay may
# raise the effective host-specific cooldown above this shared minimum.
$MinimumDelaySeconds = [Math]::Max(1, $MinimumDelaySeconds)
if ($manifest.collectionPolicy.concurrency -ne 1) { throw 'Public build requests must remain sequential.' }
Import-Module -Name (Join-Path $PSScriptRoot 'PublicBuildImportSupport.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'PublicBuildRequestScheduler.psm1') -Force

function Get-OptionalString([object]$Object, [string]$Name) {
	$property = if ($null -ne $Object) { $Object.PSObject.Properties[$Name] } else { $null }
	if ($null -ne $property -and $null -ne $property.Value) { return [string]$property.Value }
	return ''
}

function Get-Field([object]$Value, [string]$Name, [object]$Default = $null) {
	$property = if ($null -ne $Value) { $Value.PSObject.Properties[$Name] } else { $null }
	if ($null -ne $property) { return $property.Value }
	return $Default
}

function Read-SharedTextLines([string]$Path) {
	$stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
	$reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
	try {
		while ($null -ne ($line = $reader.ReadLine())) { $line }
	} finally {
		$reader.Dispose()
		$stream.Dispose()
	}
}

$webCrawlEntries = @($manifest.builds | Where-Object { [string]$_.providerId -eq 'WebCrawl' })
if ($webCrawlEntries.Count -gt 0) {
	throw 'Automatic web discovery is removed. Select a public PoB share manually, check it against the local index, then import that share ID.'
}
$providerRegistry = @{
	PoBCodes = [pscustomobject]@{
		pageHost = 'pob.codes'; pagePrefix = 'https://pob.codes/b/'; pagePathPrefix = '/b/'
		rawHost = 'api.pob.codes'; rawPrefix = 'https://api.pob.codes/'; rawPathPrefix = '/'; rawSuffix = '/raw'
		codeFolder = 'PoBCodes'; providerId = 'PoBCodes'
	}
	PoEDB = [pscustomobject]@{
		pageHost = 'poedb.tw'; pagePrefix = 'https://poedb.tw/pob/'; pagePathPrefix = '/pob/'
		rawHost = 'poedb.tw'; rawPrefix = 'https://poedb.tw/pob/'; rawPathPrefix = '/pob/'; rawSuffix = '/raw'
		codeFolder = 'PoEDB'; providerId = 'PoEDB'
	}
	PoBBinPage = [pscustomobject]@{
		pageHost = 'pobb.in'; pagePrefix = 'https://pobb.in/'; pagePathPrefix = '/'
		rawHost = 'pobb.in'; rawPrefix = ''; rawPathPrefix = ''; rawSuffix = ''
		codeFolder = 'PoBBinPage'; providerId = 'PoBBinPage'
	}
	PoBKR = [pscustomobject]@{
		pageHost = 'pob.co.kr'; pagePrefix = 'https://pob.co.kr/board/'; pagePathPrefix = '/board/'
		rawHost = 'pob.co.kr'; rawPrefix = 'https://pob.co.kr/board/'; rawPathPrefix = '/board/'; rawSuffix = ''
		codeFolder = 'PoBKR'; providerId = 'PoBKR'
	}
	PoeNinja = [pscustomobject]@{
		pageHost = 'poe.ninja'; pagePrefix = 'https://poe.ninja/poe1/pob/'; pagePathPrefix = '/poe1/pob/'
		rawHost = 'poe.ninja'; rawPrefix = 'https://poe.ninja/poe1/pob/raw/'; rawPathPrefix = '/poe1/pob/raw/'; rawSuffix = ''
		codeFolder = 'PoeNinja'; providerId = 'PoeNinja'
	}
}
$providersInBatch = [Collections.Generic.List[object]]::new()
foreach ($entry in $manifest.builds) {
	$providerId = if ($entry.providerId) { [string]$entry.providerId } else { 'PoBCodes' }
	if (-not $providerRegistry.ContainsKey($providerId)) { throw ('Unsupported build-code provider: ' + $providerId) }
	if (-not @($providersInBatch | Where-Object providerId -eq $providerId).Count) { $providersInBatch.Add($providerRegistry[$providerId]) }
}

# poe.ninja's official API documentation classifies PoB/build endpoints as
# internal, unsupported and unavailable for third-party use. Reuse captures
# already in the user's archive, but do not automate new raw-share requests.
# https://poe.ninja/docs/api
$blockedPoeNinjaIds = [Collections.Generic.List[string]]::new()
foreach ($entry in $manifest.builds) {
	if ([string]$entry.providerId -ne 'PoeNinja') { continue }
	$poeNinjaCodeRoot = Join-Path $buildCodeRoot 'PoeNinja'
	$cachedPoeNinjaCode = $null
	if (-not $RefreshSources -and (Test-Path -LiteralPath $poeNinjaCodeRoot -PathType Container)) {
		$cachedPoeNinjaCode = Get-ChildItem -LiteralPath $poeNinjaCodeRoot -File -Filter ([string]$entry.id + '-*.pob') |
			Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
	}
	if (-not $cachedPoeNinjaCode) { $blockedPoeNinjaIds.Add([string]$entry.id) }
}
if ($blockedPoeNinjaIds.Count -gt 0) {
	$blockedPoeNinjaMessage = 'Automated poe.ninja raw PoB retrieval is disabled by its official API policy. These IDs have no local archived code: ' + ($blockedPoeNinjaIds -join ', ') + '. Capture an allowed local export and use Invoke-LocalPobCodeIngestion.ps1.'
	throw $blockedPoeNinjaMessage
}
if (@($manifest.builds | Where-Object { [string]$_.providerId -eq 'PoeNinja' }).Count -gt 0) {
	# All PoE Ninja entries that pass the guard are local cache replays. Exclude
	# that provider from robots and request scheduling so replay is offline.
	[void]$providersInBatch.Remove($providerRegistry['PoeNinja'])
}

foreach ($entry in $manifest.builds) {
	$rightsVerified = $entry.rightsStatus -in @('permission_granted', 'public_domain', 'licensed') -and
		-not [string]::IsNullOrWhiteSpace([string]$entry.rightsEvidenceUrl)
	if (-not $rightsVerified -and -not $UserDirectedLocalStudy) {
		throw ('Unverified source status requires -UserDirectedLocalStudy; it remains observation-only: ' + [string]$entry.id)
	}
	if ($UserDirectedLocalStudy -and $entry.rightsStatus -and
		$entry.rightsStatus -notin @('permission_granted', 'public_domain', 'licensed', 'unverified')) {
		throw ('Unsupported rights status for user-directed local study: ' + [string]$entry.id)
	}
}

Add-Type -AssemblyName System.Net.Http
$handler = [System.Net.Http.HttpClientHandler]::new()
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(45)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('PathOfBuilding-AIPlanner/0.1 (https://github.com/PathOfBuildingCommunity/PathOfBuilding; contact: https://github.com/PathOfBuildingCommunity/PathOfBuilding/issues)')
$client.DefaultRequestHeaders.Accept.ParseAdd('text/plain')
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$stagedPath = Join-Path $evidenceRoot 'staged-builds.jsonl'
$sourceIndexPath = Join-Path $buildIngestionRoot 'source-index.jsonl'
$sourceValidationPath = Join-Path $buildIngestionRoot 'source-validation-index.jsonl'
$staged = [Collections.Generic.List[string]]::new()
$downloadEvidence = [Collections.Generic.List[object]]::new()
$verifiedCodeHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Test-VerifiedSourceCodeResultStatus([string]$Status) {
	return $Status -in @('archived', 'already_archived', 'already_archived_duplicate_lineage', 'reviewed', 'already_reviewed', 'already_verified_duplicate_code', 'duplicate_code_same_batch')
}

if (Test-Path -LiteralPath $sourceValidationPath -PathType Leaf) {
	foreach ($line in (Read-SharedTextLines $sourceValidationPath)) {
		if ([string]::IsNullOrWhiteSpace($line)) { continue }
		try { $validation = $line | ConvertFrom-Json -ErrorAction Stop } catch { throw ('Malformed source-validation history; preserving it and stopping: ' + $sourceValidationPath) }
		$hash = [string]$validation.codeSha256
		if ($hash -match '^[0-9a-fA-F]{64}$' -and (Test-VerifiedSourceCodeResultStatus ([string]$validation.resultStatus))) { $null = $verifiedCodeHashes.Add($hash) }
	}
}
$batchCodeHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Get-DiscoveryLastRequest([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
	$state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
	if ($state.schema -ne 'pob-ai-web-discovery-state' -or $state.schemaVersion -ne 1) {
		throw ('Discovery cadence state has an unsupported schema: ' + $Path)
	}
	$nowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$latestUnixMs = [long]0
	if ($state.PSObject.Properties['lastAnyRequestUnixMs']) {
		$candidateUnixMs = [long]$state.lastAnyRequestUnixMs
		if ($candidateUnixMs -gt 0 -and $candidateUnixMs -le $nowUnixMs) { $latestUnixMs = $candidateUnixMs }
	}
	if ($state.PSObject.Properties['hostLastRequestUnix']) {
		foreach ($hostEntry in $state.hostLastRequestUnix.PSObject.Properties) {
			try { $candidateUnixMs = [long]$hostEntry.Value * 1000 } catch { continue }
			if ($candidateUnixMs -gt 0 -and $candidateUnixMs -le $nowUnixMs -and $candidateUnixMs -gt $latestUnixMs) {
				$latestUnixMs = $candidateUnixMs
			}
		}
	}
	if ($latestUnixMs -le 0) { return $null }
	return [DateTimeOffset]::FromUnixTimeMilliseconds($latestUnixMs)
}

$workerLockPath = Join-Path $buildIngestionRoot 'worker.lock'
$workerLockStream = $null
$workerLockToken = [guid]::NewGuid().ToString('N')
$workerLockWaitLogged = $false
while ($null -eq $workerLockStream) {
	try {
		$workerLockStream = [IO.File]::Open($workerLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
	} catch [IO.IOException] {
		if (-not $workerLockWaitLogged) {
			Write-Host 'Outro worker está usando o ledger global; este worker vai aguardar para evitar colisão.' -ForegroundColor Yellow
			$workerLockWaitLogged = $true
		}
		Start-Sleep -Seconds 2
	}
}
$workerLockRecord = [ordered]@{ schema = 'pob-ai-planner-ingestion-worker-lock'; schemaVersion = 1; pid = $PID; token = $workerLockToken; startedAt = [DateTime]::UtcNow.ToString('o') }
$workerLockBytes = $utf8NoBom.GetBytes(($workerLockRecord | ConvertTo-Json -Compress))
$workerLockStream.SetLength(0)
$workerLockStream.Write($workerLockBytes, 0, $workerLockBytes.Length)
$workerLockStream.Flush($true)

$lastHostRequest = @{}
$script:lastAnyRequest = $null
$discoveryCadencePath = Join-Path $userPath 'Discovery/state.json'
$discoveryLastRequest = Get-DiscoveryLastRequest $discoveryCadencePath
if ($null -ne $discoveryLastRequest) { $script:lastAnyRequest = $discoveryLastRequest }
$seenIds = [Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::Ordinal)
$hostCadencePath = Join-Path $ingestionRoot 'host-cadence.json'
$hostCadenceTempPath = $hostCadencePath + '.tmp-' + $workerLockToken
$hasHostCadenceLedger = Test-Path -LiteralPath $hostCadencePath
if ($hasHostCadenceLedger) {
	$hostCadence = Get-Content -LiteralPath $hostCadencePath -Raw | ConvertFrom-Json
	if ($hostCadence.schema -ne 'pob-ai-planner-host-cadence' -or $hostCadence.schemaVersion -ne 1) {
		throw 'The persisted host-cadence ledger has an unsupported schema; no requests were sent.'
	}
	foreach ($hostEntry in $hostCadence.hosts.PSObject.Properties) {
		$unixTime = [long]$hostEntry.Value.lastRequestUnix
		if ($unixTime -gt 0 -and $unixTime -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
			$lastHostRequest[$hostEntry.Name] = [DateTimeOffset]::FromUnixTimeSeconds($unixTime)
		}
	}
	if ($hostCadence.PSObject.Properties['lastAnyRequestUnixMs']) {
		$lastAnyUnixMs = [long]$hostCadence.lastAnyRequestUnixMs
		if ($lastAnyUnixMs -gt 0 -and $lastAnyUnixMs -le [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
			$ledgerLastRequest = [DateTimeOffset]::FromUnixTimeMilliseconds($lastAnyUnixMs)
			if ($null -eq $script:lastAnyRequest -or $ledgerLastRequest -gt $script:lastAnyRequest) { $script:lastAnyRequest = $ledgerLastRequest }
		}
	}
	foreach ($hostRequestTime in $lastHostRequest.Values) {
		if ($null -eq $script:lastAnyRequest -or $hostRequestTime -gt $script:lastAnyRequest) { $script:lastAnyRequest = $hostRequestTime }
	}
} else {
	# Seed the first persistent ledger conservatively from the last completed
	# build batch; this prevents an immediate second invocation bypassing cadence.
	$previousBatchFile = Get-ChildItem -LiteralPath $ingestionRoot -File -Filter 'batch-*.json' |
		Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
	if ($previousBatchFile) {
		try {
			$previousBatch = Get-Content -LiteralPath $previousBatchFile.FullName -Raw | ConvertFrom-Json
			if (@($previousBatch.providerRequests).Count -gt 0 -and $previousBatch.generatedAt) {
				$lastCompletedBatchAt = ([DateTimeOffset]$previousBatch.generatedAt).ToUniversalTime()
				$lastHostRequest['pob.codes'] = $lastCompletedBatchAt
				$lastHostRequest['api.pob.codes'] = $lastCompletedBatchAt
				if ($null -eq $script:lastAnyRequest -or $lastCompletedBatchAt -gt $script:lastAnyRequest) { $script:lastAnyRequest = $lastCompletedBatchAt }
			}
		} catch { throw 'Could not seed the cross-run request cadence from the last completed batch; no requests were sent.' }
	}
}

# Merge legacy crawler timestamps into the shared serial request scheduler.
# The newest timestamp preserves the approved 180-second gap across all hosts.
if (Test-Path -LiteralPath $discoveryCadencePath -PathType Leaf) {
	$discoveryState = Get-Content -LiteralPath $discoveryCadencePath -Raw | ConvertFrom-Json -ErrorAction Stop
	if ($discoveryState.PSObject.Properties['hostLastRequestUnix']) {
		foreach ($hostEntry in $discoveryState.hostLastRequestUnix.PSObject.Properties) {
			try { $requestUnix = [long]$hostEntry.Value } catch { continue }
			if ($requestUnix -le 0 -or $requestUnix -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { continue }
			$hostName = ([string]$hostEntry.Name).ToLowerInvariant()
			$requestAt = [DateTimeOffset]::FromUnixTimeSeconds($requestUnix)
			if (-not $lastHostRequest.ContainsKey($hostName) -or $lastHostRequest[$hostName] -lt $requestAt) { $lastHostRequest[$hostName] = $requestAt }
			if ($null -eq $script:lastAnyRequest -or $script:lastAnyRequest -lt $requestAt) { $script:lastAnyRequest = $requestAt }
		}
	}
}

function Save-HostCadence {
	$hosts = [ordered]@{}
	foreach ($hostName in $lastHostRequest.Keys) {
		$hosts[$hostName] = [ordered]@{ lastRequestUnix = $lastHostRequest[$hostName].ToUnixTimeSeconds() }
	}
	$lastAnyRequestUnixMs = if ($null -ne $script:lastAnyRequest) { $script:lastAnyRequest.ToUnixTimeMilliseconds() } else { $null }
	$ledger = [ordered]@{ schema = 'pob-ai-planner-host-cadence'; schemaVersion = 1; hosts = $hosts; lastAnyRequestUnixMs = $lastAnyRequestUnixMs }
	[IO.File]::WriteAllText($hostCadenceTempPath, ($ledger | ConvertTo-Json -Depth 4 -Compress), $utf8NoBom)
	if (Test-Path -LiteralPath $hostCadencePath) { [IO.File]::Move($hostCadenceTempPath, $hostCadencePath, $true) }
	else { [IO.File]::Move($hostCadenceTempPath, $hostCadencePath) }
}
$progressPath = Join-Path $buildIngestionRoot 'status.json'
$globalProgressPath = $progressPath
$progressPath = if ([string]::IsNullOrWhiteSpace($ProgressPath)) { $globalProgressPath } else { [IO.Path]::GetFullPath($ProgressPath) }
$progressTempPath = $progressPath + '.tmp-' + $workerLockToken
$globalProgressTempPath = $globalProgressPath + '.tmp-' + $workerLockToken
$latestResultsPath = if ($LatestResultsPath) { [IO.Path]::GetFullPath($LatestResultsPath) } else { Join-Path $buildIngestionRoot 'latest-results.jsonl' }
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $latestResultsPath) -Force
# Keep results across intake runs; the dashboard reads a bounded tail of this
# append-only history, while each full batch remains in its own report file.
$ingestionProgress = [ordered]@{
	schema = 'pob-ai-planner-build-ingestion-progress'; schemaVersion = 1
	state = 'running'; stage = 'preflight'; runId = [guid]::NewGuid().ToString('N')
	updatedAtUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
	totalCount = @($manifest.builds).Count; processedCount = 0; requestCount = 0
	archivedCount = 0; rejectedCount = 0; quarantinedIncompleteOrCorruptCount = 0; failedCount = 0; notFoundCount = 0
	downloadedCodeCount = 0; reusedCodeCount = 0; duplicateVerifiedCount = 0; duplicateBatchCount = 0
	minimumDelaySeconds = $MinimumDelaySeconds; minimumDelayScope = 'global_between_requests'; robotsCrawlDelayOverridesBaseline = $true; concurrency = 1; currentId = ''; currentProvider = ''; currentTitle = ''
	ambiguousSourceCount = 0
}

function Write-IngestionProgress {
	$ingestionProgress.updatedAtUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
	$payload = $ingestionProgress | ConvertTo-Json -Depth 4 -Compress
	$progressTargets = [Collections.Generic.List[object]]::new()
	$progressTargets.Add([pscustomobject]@{ Path = $progressPath; Temp = $progressTempPath })
	if (-not [string]::Equals($progressPath, $globalProgressPath, [StringComparison]::OrdinalIgnoreCase)) {
		$progressTargets.Add([pscustomobject]@{ Path = $globalProgressPath; Temp = $globalProgressTempPath })
	}
	foreach ($target in $progressTargets) {
		[IO.File]::WriteAllText($target.Temp, $payload, $utf8NoBom)
		if (Test-Path -LiteralPath $target.Path) { [IO.File]::Move($target.Temp, $target.Path, $true) }
		else { [IO.File]::Move($target.Temp, $target.Path) }
	}
}
function Write-LatestIngestionResult([object]$Entry, [string]$Status, [string]$Reason = '') {
	$patch = [string]$Entry.claimedPatch
	if ($patch -notin @('3.24', '3.25', '3.26', '3.27', '3.28', '3.29')) { $patch = $null }
	$row = [ordered]@{
		schema = 'pob-ai-planner-ingestion-result'; schemaVersion = 1
		id = [string]$Entry.id; status = $Status; patch = $patch
	}
	if ($Reason) { $row.reason = $Reason }
	[IO.File]::AppendAllText($latestResultsPath, (($row | ConvertTo-Json -Depth 3 -Compress) + "`n"), $utf8NoBom)
}

function Register-DuplicateSourceCode([object]$Entry, [string]$ProviderId, [string]$Reference,
	[string]$CodeHash, [string]$Status, [string]$Reason) {
	$observedAt = [DateTime]::UtcNow.ToString('o')
	$sourceRow = [ordered]@{
		schema = 'pob-ai-planner-source-observation'; schemaVersion = 1; observedAt = $observedAt
		providerId = $ProviderId; id = [string]$Entry.id; reference = $Reference
		sourceUrl = [string]$Entry.sourceUrl; title = [string]$Entry.title; creator = [string]$Entry.creator
		locale = [string]$Entry.locale; sourceSiteId = Get-OptionalString $Entry 'sourceSiteId'
		sourceSiteName = Get-OptionalString $Entry 'sourceSiteName'; sourceSeedUrl = Get-OptionalString $Entry 'sourceSeedUrl'
		discoveryPageUrl = Get-OptionalString $Entry 'discoveryPageUrl'; discoveredBuildUrl = Get-OptionalString $Entry 'discoveredBuildUrl'
		acquisitionMethod = Get-OptionalString $Entry 'acquisitionMethod'; claimedPatch = [string]$Entry.claimedPatch
		codeSha256 = $CodeHash; codePath = $null; validationStatus = $Status
	}
	$validationRow = [ordered]@{
		schema = 'pob-ai-planner-source-validation'; schemaVersion = 1; validatedAt = $observedAt
		providerId = $ProviderId; id = [string]$Entry.id; codeSha256 = $CodeHash; resultStatus = $Status; reason = $Reason
	}
	[IO.File]::AppendAllText($sourceIndexPath, (($sourceRow | ConvertTo-Json -Depth 6 -Compress) + "`n"), $utf8NoBom)
	[IO.File]::AppendAllText($sourceValidationPath, (($validationRow | ConvertTo-Json -Depth 6 -Compress) + "`n"), $utf8NoBom)
}

function Get-ExceptionDetail([Exception]$Exception) {
	$parts = [Collections.Generic.List[string]]::new()
	$current = $Exception
	while ($null -ne $current) {
		if (-not [string]::IsNullOrWhiteSpace($current.Message) -and -not $parts.Contains($current.Message)) { $parts.Add($current.Message) }
		$current = $current.InnerException
	}
	return [string]::Join(' | ', $parts)
}

function Normalize-ClaimedMainSkill([object]$Entry) {
	$claim = $Entry.claimedMainSkill
	if ($null -eq $claim) { return }
	if ($claim -is [string]) {
		# A label from a public page is unverified text, not the structured identity
		# claim consumed by the native archive. Preserve it separately and let PoB
		# determine the actual main skill from the imported build.
		$Entry | Add-Member -MemberType NoteProperty -Name claimedMainSkillLabel -Value $claim -Force
		$Entry.claimedMainSkill = $null
		return
	}
	foreach ($field in @('gemId', 'gameId', 'variantId', 'effectId')) {
		$value = $claim.$field
		if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
			throw ('Invalid claimedMainSkill.' + $field + ' in manifest entry ' + $Entry.id)
		}
	}
}

function Get-UniqueProviderHosts([object[]]$Providers) {
	return @($Providers | ForEach-Object { $_.pageHost; $_.rawHost } | Where-Object { $_ } | Sort-Object -Unique)
}

$progressFailureHandled = $false
$retrievalFailureCount = 0
trap {
	if (-not $progressFailureHandled -and $null -ne $ingestionProgress -and $ingestionProgress.state -eq 'running') {
		$progressFailureHandled = $true
		$ingestionProgress.state = 'failed'
		$ingestionProgress.stage = 'failed'
		$ingestionProgress.failedCount = [int]$ingestionProgress.failedCount + 1
		try { Write-IngestionProgress } catch { }
	}
	if ($null -ne $workerLockStream) { try { $workerLockStream.Dispose() } catch { } }
	throw $_.Exception
}
Write-IngestionProgress

function Register-PublicRequestStart([string]$HostKey, [string]$Url, [DateTimeOffset]$RequestStartedAt) {
	$lastHostRequest[$HostKey.ToLowerInvariant()] = $RequestStartedAt
	if ($null -eq $script:lastAnyRequest -or $RequestStartedAt -gt $script:lastAnyRequest) { $script:lastAnyRequest = $RequestStartedAt }
	Save-HostCadence
	if ($Url -notmatch '/robots\.txt$') {
		$ingestionProgress.requestCount++
		Write-IngestionProgress
	}
}

function Invoke-PoliteGet([string]$Url, [string]$HostKey, [double]$RobotsDelaySeconds = 0) {
	$minimumDelayForRequest = [int][Math]::Ceiling([Math]::Max([double]$MinimumDelaySeconds, $RobotsDelaySeconds))
	if ($HostKey.Equals('poe.ninja', [StringComparison]::OrdinalIgnoreCase)) {
		$minimumDelayForRequest = [Math]::Max($minimumDelayForRequest, $MinimumPoeNinjaDelaySeconds)
	}
	$knownLastRequestUnix = if ($lastHostRequest.ContainsKey($HostKey.ToLowerInvariant())) { [long]$lastHostRequest[$HostKey.ToLowerInvariant()].ToUnixTimeSeconds() } else { [long]0 }
	$knownLastAnyRequestUnixMs = if ($null -ne $script:lastAnyRequest) { [long]$script:lastAnyRequest.ToUnixTimeMilliseconds() } else { [long]0 }
	$httpClient = $client
	$requestUrl = $Url
	$requestAction = {
		param([DateTimeOffset]$RequestStartedAt)
		$request = $httpClient.GetAsync($requestUrl).GetAwaiter().GetResult()
		$content = $request.Content.ReadAsStringAsync().GetAwaiter().GetResult()
		[pscustomobject]@{ Response = $request; Content = $content }
	}.GetNewClosure()
	$startAction = {
		param([DateTimeOffset]$RequestStartedAt)
		Register-PublicRequestStart -HostKey $HostKey -Url $Url -RequestStartedAt $RequestStartedAt
	}
	return Invoke-PoBSerializedPublicRequest -CoordinatorRoot $requestCoordinatorRoot -HostName $HostKey -MinimumHostDelaySeconds $minimumDelayForRequest -MinimumGlobalDelaySeconds $MinimumDelaySeconds -KnownLastRequestUnix $knownLastRequestUnix -KnownLastAnyRequestUnixMs $knownLastAnyRequestUnixMs -Request $requestAction -OnRequestStarting $startAction
}

function Get-RobotsRulesForAgent([string]$Content, [string]$ProductToken) {
	$groups = [Collections.Generic.List[object]]::new()
	$current = $null
	foreach ($line in ($Content -split "`r?`n")) {
		$clean = ($line -split '#', 2)[0].Trim()
		if (-not $clean) { continue }
		if ($clean -match '^User-agent:\s*(.+)$') {
			if ($null -eq $current -or $current.Rules.Count -gt 0) {
				$current = [pscustomobject]@{ Agents = [Collections.Generic.List[string]]::new(); Rules = [Collections.Generic.List[object]]::new() }
				$groups.Add($current)
			}
			$current.Agents.Add($Matches[1].Trim())
			continue
		}
		if ($null -ne $current -and $clean -match '^(Allow|Disallow):\s*(.*)$') {
			$current.Rules.Add([pscustomobject]@{ Kind = $Matches[1]; Rule = $Matches[2].Trim() })
		}
	}
	$matching = [Collections.Generic.List[object]]::new()
	foreach ($group in $groups) {
		if (@($group.Agents | Where-Object { $_ -eq '*' -or $_.Equals($ProductToken, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
			foreach ($rule in $group.Rules) { $matching.Add($rule) }
		}
	}
	return @($matching)
}

function Test-RobotsPathAllowed([object[]]$Rules, [string]$Path) {
	$matches = @($Rules | Where-Object {
		if (-not $_.Rule) { return $false }
		$escaped = [regex]::Escape($_.Rule).Replace('\*', '.*')
		$anchored = '^' + $escaped
		if ($_.Rule.EndsWith('$')) { $anchored = '^' + $escaped.Substring(0, $escaped.Length - 2) + '$' }
		$Path -match $anchored
	} | Sort-Object { $_.Rule.Length } -Descending)
	if ($matches.Count -eq 0) { return $true }
	$mostSpecificLength = $matches[0].Rule.Length
	$mostSpecific = @($matches | Where-Object { $_.Rule.Length -eq $mostSpecificLength })
	return @($mostSpecific | Where-Object Kind -eq 'Allow').Count -gt 0
}

# Verify each fixed provider host before using its page or build-code route.
# RFC 9309 treats a 404 robots file as unavailable; other failures stop intake.
$robotsByHost = @{}
$robotsDelayByHost = @{}
$robotsEvidence = [Collections.Generic.List[object]]::new()
$robotsHosts = Get-UniqueProviderHosts $providersInBatch
foreach ($hostName in $robotsHosts) {
	$ingestionProgress.stage = 'checking_source'
	Write-IngestionProgress
	$robotsUrl = 'https://' + $hostName + '/robots.txt'
	$robotsResponse = Invoke-PoliteGet $robotsUrl $hostName
	$robotsStatus = [int]$robotsResponse.Response.StatusCode
	if (-not $robotsResponse.Response.IsSuccessStatusCode -and $robotsStatus -ne 404) {
		throw ('Could not verify robots policy for ' + $hostName + ' (HTTP ' + $robotsStatus + '); intake stopped.')
	}
	$robotsPolicy = if ($robotsStatus -eq 404) {
		[pscustomobject]@{ Rules = @(); CrawlDelaySeconds = 0.0; SitemapUrls = @() }
	} else {
		Get-PoBImportRobotsPolicy -Content $robotsResponse.Content -ProductToken 'PathOfBuilding-AIPlanner'
	}
	$robotsByHost[$hostName] = @($robotsPolicy.Rules)
	$robotsDelayByHost[$hostName] = [double]$robotsPolicy.CrawlDelaySeconds
	$robotsEvidence.Add([pscustomobject]@{ host = $hostName; url = $robotsUrl; httpStatus = $robotsStatus; crawlDelaySeconds = [double]$robotsPolicy.CrawlDelaySeconds; text = $robotsResponse.Content })
}

foreach ($entry in $manifest.builds) {
	$providerId = if ($entry.providerId) { [string]$entry.providerId } else { 'PoBCodes' }
	$provider = $providerRegistry[$providerId]
	$sourceIdentity = $providerId + ':' + [string]$entry.id
	if ($seenIds.ContainsKey($sourceIdentity)) { continue }
	$ingestionProgress.stage = 'fetching_code'
	$ingestionProgress.currentId = [string]$entry.id
	$ingestionProgress.currentProvider = $providerId
	$ingestionProgress.currentTitle = [string]$entry.title
	Write-IngestionProgress
	$idPattern = if ($providerId -eq 'PoBKR') { '^[0-9]{1,10}$' } else { '^[A-Za-z0-9_-]{3,64}$' }
	if ($entry.id -notmatch $idPattern) { throw ('Invalid public build id: ' + $entry.id) }
	Normalize-ClaimedMainSkill $entry
	$codeUrl = $null
	$reference = $provider.pagePrefix + $entry.id
	$pagePath = $provider.pagePathPrefix + $entry.id
	if (-not (Test-RobotsPathAllowed $robotsByHost[$provider.pageHost] $pagePath)) {
		throw ('robots.txt disallows ' + $pagePath + ' on ' + $provider.pageHost + '; intake stopped.')
	}
	$rawPath = if ($providerId -eq 'PoBBinPage') { $pagePath } else { $provider.rawPathPrefix + $entry.id + $provider.rawSuffix }
	if (-not (Test-RobotsPathAllowed $robotsByHost[$provider.rawHost] $rawPath)) {
		throw ('robots.txt disallows code retrieval path ' + $rawPath + ' on ' + $provider.rawHost + '; intake stopped.')
	}
	$providerCodeRoot = Join-Path $buildCodeRoot $provider.codeFolder
	$null = New-Item -ItemType Directory -Path $providerCodeRoot -Force
	$cachedFile = if (-not $RefreshSources) {
		Get-ChildItem -LiteralPath $providerCodeRoot -File -Filter ($entry.id + '-*.pob') | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
	} else { $null }
	if ($cachedFile) {
		$code = [IO.File]::ReadAllText($cachedFile.FullName).Trim()
		$status = $null
		$retrievalStatus = 'reused_local_source_code'
	} else {
		$codeUrl = if ($providerId -eq 'PoBBinPage') { $reference } else { $provider.rawPrefix + $entry.id + $provider.rawSuffix }
		if ($providerId -eq 'PoBBinPage' -and $codeUrl -notmatch '^https://pobb\.in/[A-Za-z0-9_-]{3,64}$') {
			throw ('PoBBinPage retrieval is restricted to a single public share page: ' + $entry.id)
		}
		$rawHostDelay = if ($robotsDelayByHost.ContainsKey([string]$provider.rawHost)) { [double]$robotsDelayByHost[[string]$provider.rawHost] } else { 0.0 }
		try { $result = Invoke-PoliteGet $codeUrl $provider.rawHost $rawHostDelay }
		catch {
			$requestError = Get-ExceptionDetail $_.Exception
			$downloadEvidence.Add([pscustomobject]@{
				providerId = $provider.providerId; host = $provider.rawHost; id = $entry.id
				title = $entry.title; creator = $entry.creator; locale = $entry.locale
				sourceUrl = $entry.sourceUrl; claimedPatch = $entry.claimedPatch
				reference = $reference; requestUrl = $codeUrl; status = 'request_failed'
				codeBytes = 0; codeSha256 = $null; codePath = $null; httpStatus = $null; error = $requestError
			})
			Write-LatestIngestionResult $entry 'request_failed' $requestError
			$ingestionProgress.processedCount++; $ingestionProgress.failedCount++; $retrievalFailureCount++
			$ingestionProgress.stage = 'provider_request_failed'
			Write-IngestionProgress
			break
		}
		$status = [int]$result.Response.StatusCode
		if ($status -eq 403 -or $status -eq 429) {
			$requestError = $providerId + ' returned HTTP ' + $status + '; intake paused without retry.'
			$downloadEvidence.Add([pscustomobject]@{
				providerId = $provider.providerId; host = $provider.rawHost; id = $entry.id
				title = $entry.title; creator = $entry.creator; locale = $entry.locale
				sourceUrl = $entry.sourceUrl; claimedPatch = $entry.claimedPatch
				reference = $reference; requestUrl = $codeUrl; status = 'request_blocked'
				codeBytes = 0; codeSha256 = $null; codePath = $null; httpStatus = $status; error = $requestError
			})
			Write-LatestIngestionResult $entry 'request_blocked' $requestError
			$ingestionProgress.processedCount++; $ingestionProgress.failedCount++; $retrievalFailureCount++
			$ingestionProgress.stage = 'provider_request_blocked'
			Write-IngestionProgress
			break
		}
		if ($status -eq 404) {
			$downloadEvidence.Add([pscustomobject]@{
				providerId = $provider.providerId; host = $provider.rawHost; id = $entry.id
				title = $entry.title; creator = $entry.creator; locale = $entry.locale
				sourceUrl = $entry.sourceUrl; claimedPatch = $entry.claimedPatch
				reference = $reference; requestUrl = $codeUrl; status = 'not_found'
				codeBytes = 0; codeSha256 = $null; codePath = $null; httpStatus = $status
			})
			Write-LatestIngestionResult $entry 'not_found'
			$ingestionProgress.processedCount++
			$ingestionProgress.notFoundCount++
			$ingestionProgress.stage = 'candidate_not_found'
			Write-IngestionProgress
			continue
		}
		if ($status -ne 200) {
			$requestError = 'Provider returned HTTP ' + $status + ' for ' + $entry.id + '; intake paused without retry.'
			$downloadEvidence.Add([pscustomobject]@{
				providerId = $provider.providerId; host = $provider.rawHost; id = $entry.id
				title = $entry.title; creator = $entry.creator; locale = $entry.locale
				sourceUrl = $entry.sourceUrl; claimedPatch = $entry.claimedPatch
				reference = $reference; requestUrl = $codeUrl; status = 'request_failed'
				codeBytes = 0; codeSha256 = $null; codePath = $null; httpStatus = $status; error = $requestError
			})
			Write-LatestIngestionResult $entry 'request_failed' $requestError
			$ingestionProgress.processedCount++; $ingestionProgress.failedCount++; $retrievalFailureCount++
			$ingestionProgress.stage = 'provider_request_failed'
			Write-IngestionProgress
			break
		}
		if ($providerId -eq 'PoBBinPage') {
			$pageCandidates = Get-PoBImportCandidatesFromHtml -Html ([string]$result.Content) -PageUrl $codeUrl -PageTitle ([string]$entry.title)
			$embeddedCodes = @($pageCandidates.Candidates | Where-Object { $_.providerId -eq 'ManualInlineCode' })
			if ($embeddedCodes.Count -ne 1) {
				$ambiguityStatus = if ($embeddedCodes.Count -eq 0) { 'no_inline_code' } else { 'ambiguous_inline_codes' }
				$ambiguityMessage = 'PoBBin page skipped without selecting a code; expected exactly one inline PoB code and found ' + $embeddedCodes.Count + ' for ' + $entry.id
				$downloadEvidence.Add([pscustomobject]@{
					providerId = $provider.providerId; host = $provider.rawHost; id = $entry.id
					title = $entry.title; creator = $entry.creator; locale = $entry.locale
					sourceUrl = $entry.sourceUrl; claimedPatch = $entry.claimedPatch
					reference = $reference; requestUrl = $codeUrl; status = $ambiguityStatus
					codeBytes = 0; codeSha256 = $null; codePath = $null; httpStatus = $status
					inlineCodeCount = $embeddedCodes.Count; error = $ambiguityMessage
				})
				Write-LatestIngestionResult $entry 'ambiguous_source_skipped' $ambiguityMessage
				$ingestionProgress.processedCount++
				$ingestionProgress.ambiguousSourceCount++
				$ingestionProgress.stage = 'ambiguous_source_skipped'
				Write-IngestionProgress
				continue
			}
			$code = [string]$embeddedCodes[0].inlineCode
		} elseif ($providerId -eq 'PoBKR') {
			# PoB KR post pages are HTML, not raw PoB exports. Select only the
			# explicitly labeled full Web PoB link; the separate /edit#build link
			# is a simplified variant and must not be mixed into the archive.
			$sourceHtml = [string]$result.Content
			$canonicalCodes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
			$anchorPattern = '(?is)<a\b[^>]*href=(?:"(?<q>[^"]+)"|''(?<s>[^'']+)'')[^>]*>(?<body>.*?)</a\s*>'
			foreach ($anchor in [regex]::Matches($sourceHtml, $anchorPattern)) {
				$href = if ($anchor.Groups['q'].Success) { $anchor.Groups['q'].Value } else { $anchor.Groups['s'].Value }
				$href = [Net.WebUtility]::HtmlDecode($href.Trim())
				$hrefMatch = [regex]::Match($href, '^(?:https?://pob\.co\.kr)?/pob#build=(?<code>eN[A-Za-z0-9+/_-]{254,16777214}={0,2})$')
				if (-not $hrefMatch.Success) { continue }
				$anchorText = [Net.WebUtility]::HtmlDecode(($anchor.Groups['body'].Value -replace '(?is)<[^>]+>', ' ')).Trim()
				if ($anchorText -notmatch '(?i)웹\s*PoB로\s*열기') { continue }
				$null = $canonicalCodes.Add($hrefMatch.Groups['code'].Value)
			}
			if ($canonicalCodes.Count -eq 0) {
				# Some posts publish the full export in their page state instead of
				# a direct /pob link. Accept that fallback only when the existing
				# parser finds exactly one distinct PoB code in the selected page.
				$fallbackPage = Get-PoBImportCandidatesFromHtml -Html $sourceHtml -PageUrl $codeUrl -PageTitle ([string]$entry.title)
				$fallbackCodes = @($fallbackPage.Candidates | Where-Object { $_.providerId -eq 'ManualInlineCode' })
				foreach ($fallbackCode in $fallbackCodes) {
					$null = $canonicalCodes.Add([string]$fallbackCode.inlineCode)
				}
			}
			if ($canonicalCodes.Count -ne 1) {
				$ambiguityStatus = if ($canonicalCodes.Count -eq 0) { 'no_inline_code' } else { 'ambiguous_inline_codes' }
				$ambiguityMessage = 'PoB KR post skipped without selecting a full export; expected exactly one labeled Web PoB code and found ' + $canonicalCodes.Count + ' for ' + $entry.id
				$downloadEvidence.Add([pscustomobject]@{
					providerId = $provider.providerId; host = $provider.rawHost; id = $entry.id
					title = $entry.title; creator = $entry.creator; locale = $entry.locale
					sourceUrl = $entry.sourceUrl; claimedPatch = $entry.claimedPatch
					reference = $reference; requestUrl = $codeUrl; status = $ambiguityStatus
					codeBytes = 0; codeSha256 = $null; codePath = $null; httpStatus = $status
					inlineCodeCount = $canonicalCodes.Count; error = $ambiguityMessage
				})
				Write-LatestIngestionResult $entry 'ambiguous_source_skipped' $ambiguityMessage
				$ingestionProgress.processedCount++
				$ingestionProgress.ambiguousSourceCount++
				$ingestionProgress.stage = 'ambiguous_source_skipped'
				Write-IngestionProgress
				continue
			}
			$code = @($canonicalCodes)[0]
		} else {
			$code = $result.Content.Trim()
		}
		$retrievalStatus = 'downloaded'
	}
	if ($code.Length -lt 32 -or $code.Length -gt 16777216 -or $code -notmatch '^[A-Za-z0-9+/_-]+={0,2}$') {
		throw ('Provider returned an invalid or oversized PoB code for ' + $entry.id)
	}
	if ($retrievalStatus -eq 'downloaded') { $ingestionProgress.downloadedCodeCount++ }
	else { $ingestionProgress.reusedCodeCount++ }
	Write-IngestionProgress
	$codeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8NoBom.GetBytes($code))).ToLowerInvariant()
	if ($verifiedCodeHashes.Contains($codeHash)) {
		$reason = 'Exact PoB export SHA-256 already has a terminal native PoB result; skipped before another native import.'
		$downloadEvidence.Add([pscustomobject]@{ providerId = $provider.providerId; host = $provider.rawHost; id = $entry.id; title = $entry.title; sourceUrl = $entry.sourceUrl; reference = $reference; status = 'already_verified_duplicate_code'; codeBytes = $code.Length; codeSha256 = $codeHash; httpStatus = $status })
		Register-DuplicateSourceCode $entry $providerId $reference $codeHash 'already_verified_duplicate_code' $reason
		Write-LatestIngestionResult $entry 'already_verified_duplicate_code' $reason
		$ingestionProgress.processedCount++
		$ingestionProgress.duplicateVerifiedCount = [int]$ingestionProgress.duplicateVerifiedCount + 1
		$ingestionProgress.stage = 'duplicate_verified_code_skipped'
		Write-IngestionProgress
		continue
	}
	if (-not $batchCodeHashes.Add($codeHash)) {
		$reason = 'Exact PoB export SHA-256 was already staged from another candidate in this batch; native import is performed once.'
		$downloadEvidence.Add([pscustomobject]@{ providerId = $provider.providerId; host = $provider.rawHost; id = $entry.id; title = $entry.title; sourceUrl = $entry.sourceUrl; reference = $reference; status = 'duplicate_code_same_batch'; codeBytes = $code.Length; codeSha256 = $codeHash; httpStatus = $status })
		Register-DuplicateSourceCode $entry $providerId $reference $codeHash 'duplicate_code_same_batch' $reason
		Write-LatestIngestionResult $entry 'duplicate_code_same_batch' $reason
		$ingestionProgress.processedCount++
		$ingestionProgress.duplicateBatchCount = [int]$ingestionProgress.duplicateBatchCount + 1
		$ingestionProgress.stage = 'duplicate_in_batch_skipped'
		Write-IngestionProgress
		continue
	}
	$codeFileName = if ($cachedFile) { $cachedFile.Name } else { $entry.id + '-' + $codeHash.Substring(0, 16) + '.pob' }
	$codePath = 'source-codes/' + $provider.codeFolder + '/' + $codeFileName
	if ($codePath -notmatch ('^source-codes/' + [regex]::Escape($provider.codeFolder) + '/[A-Za-z0-9_-]+-[0-9a-f]{16}\.pob$')) {
		throw ('Refusing to persist a source code to an unexpected archive path for ' + $entry.id)
	}
	$sourceCodeDestination = Join-Path $archiveRoot $codePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
	if (Test-Path -LiteralPath $sourceCodeDestination) {
		$existingCode = [IO.File]::ReadAllText($sourceCodeDestination).Trim()
		$existingHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8NoBom.GetBytes($existingCode))).ToLowerInvariant()
		if ($existingHash -ne $codeHash) { throw ('An existing source-code archive object failed its SHA-256 check for ' + $entry.id) }
	} else {
		$sourceCodeTempPath = $sourceCodeDestination + '.tmp-' + [guid]::NewGuid().ToString('N')
		try {
			[IO.File]::WriteAllText($sourceCodeTempPath, $code, $utf8NoBom)
			[IO.File]::Move($sourceCodeTempPath, $sourceCodeDestination)
		} catch {
			if (Test-Path -LiteralPath $sourceCodeTempPath) { Remove-Item -LiteralPath $sourceCodeTempPath -Force }
			throw
		}
		$storedCode = [IO.File]::ReadAllText($sourceCodeDestination).Trim()
		$storedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8NoBom.GetBytes($storedCode))).ToLowerInvariant()
		if ($storedHash -ne $codeHash) { throw ('New source-code archive object failed its SHA-256 check for ' + $entry.id) }
	}
	$sourceIndexRow = [ordered]@{
		schema = 'pob-ai-planner-source-observation'; schemaVersion = 1
		observedAt = [DateTime]::UtcNow.ToString('o'); providerId = $provider.providerId
		id = [string]$entry.id; reference = $reference; sourceUrl = [string]$entry.sourceUrl
		title = [string]$entry.title; creator = [string]$entry.creator; locale = [string]$entry.locale
		sourceSiteId = Get-OptionalString $entry 'sourceSiteId'; sourceSiteName = Get-OptionalString $entry 'sourceSiteName'
		sourceSeedUrl = Get-OptionalString $entry 'sourceSeedUrl'
		discoveryPageUrl = Get-OptionalString $entry 'discoveryPageUrl'; discoveredBuildUrl = Get-OptionalString $entry 'discoveredBuildUrl'
		acquisitionMethod = Get-OptionalString $entry 'acquisitionMethod'
		claimedPatch = [string]$entry.claimedPatch; codeSha256 = $codeHash; codePath = $codePath
		validationStatus = 'pending_native_xml_patch_skill_and_ascendancy_gates'
	}
	[IO.File]::AppendAllText($sourceIndexPath, (($sourceIndexRow | ConvertTo-Json -Depth 6 -Compress) + "`n"), $utf8NoBom)
	$record = [ordered]@{
		id = $entry.id
		code = $code
		providerId = $provider.providerId
		reference = $reference
		sourceUrl = [string]$entry.sourceUrl
		sourceSiteId = Get-OptionalString $entry 'sourceSiteId'
		sourceSiteName = Get-OptionalString $entry 'sourceSiteName'
		sourceSeedUrl = Get-OptionalString $entry 'sourceSeedUrl'
		discoveryPageUrl = Get-OptionalString $entry 'discoveryPageUrl'
		discoveredBuildUrl = Get-OptionalString $entry 'discoveredBuildUrl'
		title = [string]$entry.title
		creator = [string]$entry.creator
		label = ($entry.creator + ' | ' + $entry.title + ' | ' + $provider.providerId)
		locale = [string]$entry.locale
		claimedLeague = if ($entry.claimedLeague) { [string]$entry.claimedLeague } else { [string]$manifest.catalogClaimedLeague }
		creatorUrl = [string]$entry.creatorUrl
		claimedMainSkill = $entry.claimedMainSkill
		rightsStatus = if ($entry.rightsStatus) { [string]$entry.rightsStatus } else { 'unverified' }
		rightsEvidenceUrl = [string]$entry.rightsEvidenceUrl
		acquisitionMethod = if ($entry.acquisitionMethod) { [string]$entry.acquisitionMethod } elseif ($UserDirectedLocalStudy) { 'user_directed_local_analysis_known_id_raw_request' } else { 'curated_known_id_raw_request' }
		localStudyMode = [bool]$UserDirectedLocalStudy
		trainingEligibility = 'pending_native_patch_skill_ascendancy_and_quality_labels'
		acquiredAt = [DateTime]::UtcNow.ToString('o')
		codeSha256 = $codeHash
		codePath = $codePath
	}
	$staged.Add(($record | ConvertTo-Json -Depth 8 -Compress))
	$downloadEvidence.Add([pscustomobject]@{ providerId = $provider.providerId; host = $provider.rawHost; id = $entry.id; title = $entry.title; creator = $entry.creator; locale = $entry.locale; sourceUrl = $entry.sourceUrl; claimedPatch = $entry.claimedPatch; reference = $reference; requestUrl = if ($cachedFile) { $null } else { $codeUrl }; status = $retrievalStatus; codeBytes = $code.Length; codeSha256 = $codeHash; codePath = $codePath; httpStatus = $status })
	$seenIds[$sourceIdentity] = $true
	$ingestionProgress.processedCount++
	$ingestionProgress.stage = 'source_code_staged'
	Write-IngestionProgress
}

[IO.File]::WriteAllLines($stagedPath, $staged, $utf8NoBom)
$ingestionProgress.stage = 'native_import'
Write-IngestionProgress
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
$info.EnvironmentVariables['POB_PUBLIC_INGEST_LATEST_RESULTS'] = $latestResultsPath
$info.EnvironmentVariables['POB_PUBLIC_INGEST_REVIEW_ONLY'] = if ($ReviewOnly) { '1' } else { '0' }
$luaModulePath = '.\?.lua;.\?\init.lua;..\runtime\lua\?.lua;..\runtime\lua\?\init.lua'
if (-not [string]::IsNullOrWhiteSpace($LuaModuleOverrideDirectory)) {
	$luaModuleRoot = (Resolve-Path -LiteralPath $LuaModuleOverrideDirectory -ErrorAction Stop).Path.TrimEnd('\')
	$luaModulePath = $luaModuleRoot + '\?.lua;' + $luaModuleRoot + '\?\init.lua;' + $luaModulePath
}
$info.EnvironmentVariables['LUA_PATH'] = $luaModulePath
$info.EnvironmentVariables['LUA_CPATH'] = '.\?.dll;..\runtime\?.dll;..\runtime\lua\?.dll'
$process = [Diagnostics.Process]::new()
$process.StartInfo = $info
$null = $process.Start()
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(900000)) { $process.Kill(); $process.WaitForExit(); throw 'Native PoB ingestion exceeded 15 minutes and was stopped.' }
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
$luaExitCode = $process.ExitCode
[IO.File]::WriteAllText((Join-Path $evidenceRoot 'headless.stdout.log'), $stdout, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $evidenceRoot 'headless.stderr.log'), $stderr, $utf8NoBom)
$importResults = @([regex]::Matches($stdout, '(?m)^INGEST_RESULT (.+)$') | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
$importableCodeCount = @($downloadEvidence | Where-Object { $_.status -in @('downloaded', 'reused_local_source_code', 'discovered_inline_code') }).Count
$missingResultCount = [Math]::Max(0, $importableCodeCount - $importResults.Count)
$resultById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($result in $importResults) { if ($result.id) { $resultById[[string]$result.id] = $result } }
foreach ($recordJson in [IO.File]::ReadAllLines($stagedPath)) {
	if ([string]::IsNullOrWhiteSpace($recordJson)) { continue }
	$record = $recordJson | ConvertFrom-Json
	$result = $resultById[[string]$record.id]
	if (-not $providerRegistry.ContainsKey([string]$record.providerId)) {
		throw ('Refusing to persist a source code from an unsupported provider for ' + $record.id)
	}
	$folder = [regex]::Escape([string]$providerRegistry[[string]$record.providerId].codeFolder)
	if ($record.codePath -notmatch ('^source-codes/' + $folder + '/[A-Za-z0-9_-]+-[0-9a-f]{16}\.pob$')) {
		throw ('Refusing to persist a source code to an unexpected archive path for ' + $record.id)
	}
	$destination = Join-Path $archiveRoot $record.codePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
	if (-not (Test-Path -LiteralPath $destination)) { throw ('Verified source code disappeared before batch finalization for ' + $record.id) }
	$storedCode = [IO.File]::ReadAllText($destination).Trim()
	$storedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8NoBom.GetBytes($storedCode))).ToLowerInvariant()
	if ($storedHash -ne [string]$record.codeSha256) { throw ('Source-code archive hash changed before batch finalization for ' + $record.id) }
	$sourceValidationRow = [ordered]@{
		schema = 'pob-ai-planner-source-validation'; schemaVersion = 1
		validatedAt = [DateTime]::UtcNow.ToString('o'); id = [string]$record.id
		providerId = [string]$record.providerId; codeSha256 = [string]$record.codeSha256
		resultStatus = if ($result) { [string]$result.status } else { 'native_result_missing' }
		lineageSha256 = if ($result) { [string](Get-Field $result 'lineageSha256' (Get-Field (Get-Field $result 'archive') 'lineageSha256' '')) } else { '' }
		sourceDisposition = if ($result) { [string]$result.sourceDisposition } else { $null }
		sourceXmlPath = if ($result) { $result.sourceXmlPath } else { $null }
		sourceXmlSha256 = if ($result) { $result.sourceXmlSha256 } else { $null }
		nativeBuildVersionConversionApplied = if ($result) { $result.nativeBuildVersionConversionApplied } else { $null }
		nativeTreeLoadRecovery = if ($result) { $result.nativeTreeLoadRecovery } else { $null }
		nativeImportStatus = if ($result) { $result.nativeImportStatus } else { $null }
		targetScopeStatus = if ($result) { $result.targetScopeStatus } else { $null }
		targetScopeReason = if ($result) { $result.targetScopeReason } else { $null }
		mainSkillStatus = if ($result) { $result.mainSkillStatus } else { $null }
		mainSkillResolutionStatus = if ($result) { $result.mainSkillResolutionStatus } else { $null }
		mainSkillCandidateCount = if ($result) { $result.mainSkillCandidateCount } else { $null }
		archiveReadinessStatus = if ($result) { $result.archiveReadinessStatus } else { $null }
		nativeSerializationStatus = if ($result) { $result.nativeSerializationStatus } else { $null }
		mainSkillKey = if ($result) { $result.mainSkillKey } else { $null }
		mainSkillName = if ($result) { $result.mainSkillName } else { $null }
		reason = if ($result) { [string](Get-Field $result 'reason' (Get-Field $result 'error' '')) } else { $null }
	}
	[IO.File]::AppendAllText($sourceValidationPath, (($sourceValidationRow | ConvertTo-Json -Depth 6 -Compress) + "`n"), $utf8NoBom)
}
$null = Remove-Item -LiteralPath $stagedPath -Force
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$batchPath = Join-Path $ingestionRoot ('batch-' + $timestamp + '.json')
$batchReport = [ordered]@{
	schema = 'pob-ai-planner-public-build-ingestion-batch'; schemaVersion = 1
	startedBy = 'PathOfBuilding-AIPlanner local intake'; generatedAt = [DateTime]::UtcNow.ToString('o')
	collectionScope = [string](Get-Field $manifest 'collectionScope' 'unspecified')
	archiveAdmission = [string](Get-Field $manifest 'archiveAdmission' 'native PoB load and serialization')
	mode = if ($ReviewOnly) { 'review_only' } elseif ($UserDirectedLocalStudy) { 'user_directed_local_study_archive_and_review' } else { 'archive_and_review' }
	localStudyAuthorization = if ($UserDirectedLocalStudy) { 'User authorized private local analysis of publicly shared builds; source provenance is retained and the imported profile must pass native labels before learning.' } else { $null }
	collectionPolicy = $manifest.collectionPolicy; sourceCatalog = $manifest.catalogSource
	robotsEvidence = @($robotsEvidence)
	minimumDelaySecondsEnforced = $MinimumDelaySeconds; minimumDelayScope = 'global_between_requests'; robotsCrawlDelayOverridesBaseline = $true; concurrency = 1; cadenceLedger = $hostCadencePath
	minimumPoeNinjaDelaySecondsEnforced = $MinimumPoeNinjaDelaySeconds
	providerRequests = $downloadEvidence
	duplicateVerifiedCodeCount = @($downloadEvidence | Where-Object status -eq 'already_verified_duplicate_code').Count
	duplicateWithinBatchCount = @($downloadEvidence | Where-Object status -eq 'duplicate_code_same_batch').Count
	providerRequestFailureCount = $retrievalFailureCount
	importResults = $importResults; luaExitCode = $luaExitCode; missingResultCount = $missingResultCount
	stdoutLog = Join-Path $evidenceRoot 'headless.stdout.log'; stderrLog = Join-Path $evidenceRoot 'headless.stderr.log'
}
[IO.File]::WriteAllText($batchPath, ($batchReport | ConvertTo-Json -Depth 16), $utf8NoBom)
$process.Dispose(); $client.Dispose(); $handler.Dispose()
Write-Output ('Archive: ' + $archiveRoot)
Write-Output ('Batch report: ' + $batchPath)
Write-Output ('Execution logs: ' + $evidenceRoot)
$successCount = if ($ReviewOnly) { @($importResults | Where-Object status -in @('reviewed', 'already_reviewed')).Count } else { @($importResults | Where-Object status -in @('archived', 'already_archived', 'already_archived_duplicate_lineage')).Count }
$duplicateLineageCount = @($importResults | Where-Object status -eq 'already_archived_duplicate_lineage').Count
$rejectedCount = @($importResults | Where-Object status -eq 'target_gate_rejected').Count
$quarantinedCount = @($importResults | Where-Object status -eq 'source_incomplete_or_corrupt').Count
$failedCount = @($importResults | Where-Object status -notin @('archived', 'reviewed', 'already_reviewed', 'already_archived', 'already_archived_duplicate_lineage', 'target_gate_rejected', 'source_incomplete_or_corrupt')).Count
Write-Output ('Source codes screened: ' + $downloadEvidence.Count + '; completed: ' + $successCount + '; duplicate lineages skipped: ' + $duplicateLineageCount + '; quarantined incomplete/corrupt sources: ' + $quarantinedCount + '; already verified duplicates skipped: ' + @($downloadEvidence | Where-Object status -eq 'already_verified_duplicate_code').Count + '; duplicates in this batch skipped: ' + @($downloadEvidence | Where-Object status -eq 'duplicate_code_same_batch').Count + '; legacy target-scope rejections: ' + $rejectedCount + '; ambiguous/no-code shares skipped: ' + @($downloadEvidence | Where-Object status -in @('no_inline_code', 'ambiguous_inline_codes')).Count + '; not found: ' + @($downloadEvidence | Where-Object status -eq 'not_found').Count + '; failed: ' + $failedCount + '; missing results: ' + $missingResultCount)
$ingestionProgress.archivedCount = if ($ReviewOnly) { @($importResults | Where-Object status -in @('reviewed', 'already_reviewed')).Count } else { @($importResults | Where-Object status -in @('archived', 'already_archived', 'already_archived_duplicate_lineage')).Count }
$ingestionProgress.rejectedCount = $rejectedCount
$ingestionProgress.quarantinedIncompleteOrCorruptCount = $quarantinedCount
$ingestionProgress.ambiguousSourceCount = @($downloadEvidence | Where-Object status -in @('no_inline_code', 'ambiguous_inline_codes')).Count
$ingestionProgress.failedCount = $retrievalFailureCount + $failedCount + $missingResultCount
$ingestionProgress.notFoundCount = @($downloadEvidence | Where-Object status -eq 'not_found').Count
$ingestionProgress.state = if ($retrievalFailureCount -gt 0 -or $luaExitCode -ne 0 -or $missingResultCount -gt 0 -or $failedCount -gt 0) { 'failed' } else { 'completed' }
$ingestionProgress.stage = if ($ingestionProgress.state -eq 'failed') { 'failed' } else { 'completed' }
Write-IngestionProgress
$workerLockStream.Dispose()
$workerLockStream = $null
if ($retrievalFailureCount -gt 0 -or $luaExitCode -ne 0 -or $missingResultCount -gt 0 -or $failedCount -gt 0) { exit 1 }
exit 0
