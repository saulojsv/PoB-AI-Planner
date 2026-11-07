Set-StrictMode -Version Latest

function Write-PoBRequestCoordinatorState {
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Hosts,
		[Parameter(Mandatory)][long]$LastAnyRequestUnixMs
	)
	$payload = [ordered]@{
		schema = 'pob-ai-planner-public-request-coordinator'
		schemaVersion = 1
		updatedAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
		lastAnyRequestUnixMs = $LastAnyRequestUnixMs
		hosts = $Hosts
	}
	$tempPath = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
	try {
		[IO.File]::WriteAllText($tempPath, ($payload | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
		if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Move($tempPath, $Path, $true) }
		else { [IO.File]::Move($tempPath, $Path) }
	} catch {
		if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
		throw
	}
}

function Read-PoBRequestCoordinatorState {
	param([Parameter(Mandatory)][string]$Path)
	$hosts = [ordered]@{}
	$lastAnyRequestUnixMs = [long]0
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return [pscustomobject]@{ Hosts = $hosts; LastAnyRequestUnixMs = $lastAnyRequestUnixMs }
	}
	try { $state = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop }
	catch { throw ('Shared public request cadence ledger is malformed and was preserved: ' + $Path) }
	if ($state.schema -ne 'pob-ai-planner-public-request-coordinator' -or $state.schemaVersion -ne 1) {
		throw ('Shared public request cadence ledger has an unsupported schema and was preserved: ' + $Path)
	}
	if ($null -eq $state.PSObject.Properties['hosts'] -or $null -eq $state.hosts) {
		throw ('Shared public request cadence ledger has no host map and was preserved: ' + $Path)
	}
	if ($state.PSObject.Properties['lastAnyRequestUnixMs']) { $lastAnyRequestUnixMs = [long]$state.lastAnyRequestUnixMs }
	foreach ($entry in $state.hosts.PSObject.Properties) {
		$timestamp = [long]$entry.Value.lastRequestUnixMs
		if ($timestamp -gt 0) {
			$hosts[[string]$entry.Name.ToLowerInvariant()] = [ordered]@{ lastRequestUnixMs = $timestamp }
			# Older coordinator ledgers may omit the global marker. Recover it from
			# the newest per-host timestamp so compatibility telemetry stays monotonic.
			if ($timestamp -gt $lastAnyRequestUnixMs) { $lastAnyRequestUnixMs = $timestamp }
		}
	}
	return [pscustomobject]@{ Hosts = $hosts; LastAnyRequestUnixMs = $lastAnyRequestUnixMs }
}

function Invoke-PoBSerializedPublicRequest {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$CoordinatorRoot,
		[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9.-]+$')][string]$HostName,
		[Parameter(Mandatory)][ValidateRange(0, 86400)][int]$MinimumHostDelaySeconds,
		# The global gap applies across hosts; the host gap may be raised by robots.txt.
		[ValidateRange(0, 86400)][int]$MinimumGlobalDelaySeconds = 180,
		[long]$KnownLastRequestUnix = 0,
		[long]$KnownLastAnyRequestUnixMs = 0,
		[Parameter(Mandatory)][scriptblock]$Request,
		[scriptblock]$OnRequestStarting
	)
	$root = [IO.Path]::GetFullPath($CoordinatorRoot)
	$null = New-Item -ItemType Directory -Path $root -Force
	$rootItem = Get-Item -LiteralPath $root -Force
	if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Refusing a linked public request coordinator directory: ' + $root) }
	$statePath = Join-Path $root 'public-request-coordinator.json'
	$lockPath = Join-Path $root 'public-request-coordinator.lock'
	foreach ($protectedPath in @($statePath, $lockPath)) {
		if (Test-Path -LiteralPath $protectedPath -PathType Leaf) {
			$protectedItem = Get-Item -LiteralPath $protectedPath -Force
			if (($protectedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
				throw ('Refusing a linked public request coordination file: ' + $protectedPath)
			}
		}
	}
	$hostKey = $HostName.ToLowerInvariant()
	while ($true) {
		$lockStream = $null
		try {
			$lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
		} catch [IO.IOException] {
			Start-Sleep -Milliseconds 200
			continue
		}
		try {
			$state = Read-PoBRequestCoordinatorState $statePath
			$hosts = $state.Hosts
			$lastAnyRequestUnixMs = [long]$state.LastAnyRequestUnixMs
			if ($KnownLastAnyRequestUnixMs -gt $lastAnyRequestUnixMs) { $lastAnyRequestUnixMs = $KnownLastAnyRequestUnixMs }
			$lastHostRequestUnixMs = [long]$KnownLastRequestUnix * 1000
			if ($hosts.Contains($hostKey)) {
				$persistedHostRequestUnixMs = [long]$hosts[$hostKey].lastRequestUnixMs
				if ($persistedHostRequestUnixMs -gt $lastHostRequestUnixMs) { $lastHostRequestUnixMs = $persistedHostRequestUnixMs }
			}
			$nowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
			$requiredHostGapMilliseconds = [long]$MinimumHostDelaySeconds * 1000L
			$waitForHostMilliseconds = [Math]::Max([long]0, ($requiredHostGapMilliseconds - ([long]$nowUnixMs - [long]$lastHostRequestUnixMs)))
			$requiredGlobalGapMilliseconds = [long]$MinimumGlobalDelaySeconds * 1000L
			$waitForGlobalMilliseconds = [Math]::Max([long]0, ($requiredGlobalGapMilliseconds - ([long]$nowUnixMs - [long]$lastAnyRequestUnixMs)))
			$waitMilliseconds = [Math]::Max($waitForHostMilliseconds, $waitForGlobalMilliseconds)
			if ($waitMilliseconds -gt 0) {
				if ($lastHostRequestUnixMs -gt 0 -and (-not $hosts.Contains($hostKey) -or [long]$hosts[$hostKey].lastRequestUnixMs -lt $lastHostRequestUnixMs)) {
					$hosts[$hostKey] = [ordered]@{ lastRequestUnixMs = $lastHostRequestUnixMs }
					Write-PoBRequestCoordinatorState $statePath $hosts $lastAnyRequestUnixMs
				}
				$lockStream.Dispose()
				$lockStream = $null
				Start-Sleep -Milliseconds ([int][Math]::Min(1000, [Math]::Max(100, $waitMilliseconds)))
				continue
			}

			$requestStartedUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
			$requestStartedAt = [DateTimeOffset]::FromUnixTimeMilliseconds($requestStartedUnixMs)
			$hosts[$hostKey] = [ordered]@{ lastRequestUnixMs = $requestStartedUnixMs }
			Write-PoBRequestCoordinatorState $statePath $hosts $requestStartedUnixMs
			if ($null -ne $OnRequestStarting) { $null = & $OnRequestStarting $requestStartedAt }
			return (& $Request $requestStartedAt)
		} finally {
			if ($null -ne $lockStream) { $lockStream.Dispose() }
		}
	}
}

function Get-PoBSharedHostWaitSeconds {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$CoordinatorRoot,
		[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9.-]+$')][string]$HostName,
		[Parameter(Mandatory)][ValidateRange(0, 86400)][int]$MinimumHostDelaySeconds,
		# The returned wait is the larger of the global and host-specific cooldowns.
		[ValidateRange(0, 86400)][int]$MinimumGlobalDelaySeconds = 180,
		[long]$KnownLastRequestUnix = 0,
		[long]$KnownLastAnyRequestUnixMs = 0
	)
	$root = [IO.Path]::GetFullPath($CoordinatorRoot)
	$statePath = Join-Path $root 'public-request-coordinator.json'
	if (Test-Path -LiteralPath $statePath -PathType Leaf) {
		$stateItem = Get-Item -LiteralPath $statePath -Force
		if (($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Refusing a linked public request cadence ledger: ' + $statePath) }
	}
	$lastHostRequestUnixMs = [long]$KnownLastRequestUnix * 1000
	$lastAnyRequestUnixMs = [long]$KnownLastAnyRequestUnixMs
	if (Test-Path -LiteralPath $statePath -PathType Leaf) {
		$state = Read-PoBRequestCoordinatorState $statePath
		$hostKey = $HostName.ToLowerInvariant()
		if ([long]$state.LastAnyRequestUnixMs -gt $lastAnyRequestUnixMs) { $lastAnyRequestUnixMs = [long]$state.LastAnyRequestUnixMs }
		if ($state.Hosts.Contains($hostKey)) {
			$persistedHostRequestUnixMs = [long]$state.Hosts[$hostKey].lastRequestUnixMs
			if ($persistedHostRequestUnixMs -gt $lastHostRequestUnixMs) { $lastHostRequestUnixMs = $persistedHostRequestUnixMs }
		}
	}
	$nowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$requiredHostGapMilliseconds = [long]$MinimumHostDelaySeconds * 1000L
	$waitForHostMilliseconds = [Math]::Max([long]0, ($requiredHostGapMilliseconds - ([long]$nowUnixMs - [long]$lastHostRequestUnixMs)))
	$requiredGlobalGapMilliseconds = [long]$MinimumGlobalDelaySeconds * 1000L
	$waitForGlobalMilliseconds = [Math]::Max([long]0, ($requiredGlobalGapMilliseconds - ([long]$nowUnixMs - [long]$lastAnyRequestUnixMs)))
	return [Math]::Max(0, [int][Math]::Ceiling([Math]::Max($waitForHostMilliseconds, $waitForGlobalMilliseconds) / 1000.0))
}

Export-ModuleMember -Function Invoke-PoBSerializedPublicRequest, Get-PoBSharedHostWaitSeconds
