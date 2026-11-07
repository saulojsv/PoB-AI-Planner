<#
Install a staged full PoB AI Planner package after the user closes the currently
running target application. It never closes or saves a PoB window itself.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$PackageDirectory,
	[Parameter(Mandatory = $true)][string]$InstallDirectory,
	[Parameter(Mandatory = $true)][string]$BackupDirectory,
	[ValidateRange(1, 30)][int]$MaximumWaitDays = 30
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$package = (Resolve-Path -LiteralPath $PackageDirectory).Path
$install = [System.IO.Path]::GetFullPath($InstallDirectory)
$installer = Join-Path $PSScriptRoot 'Install-AIPlannerFullPoB.ps1'
$targetExe = [System.IO.Path]::GetFullPath((Join-Path $install 'Path of Building.exe'))
$targetTag = (Split-Path -Leaf $install) -replace '[^A-Za-z0-9._-]', '_'
$packageTag = (Split-Path -Leaf $package) -replace '[^A-Za-z0-9._-]', '_'
$stateStem = 'AIPlanner-' + $targetTag + '-' + $packageTag + '-DeferredInstall'
$statePath = Join-Path $repoRoot ('.project-planner/' + $stateStem + '.json')
$logPath = Join-Path $repoRoot ('.project-planner/' + $stateStem + '.log')
$waitDeadline = (Get-Date).AddDays($MaximumWaitDays)
$stableEmptyPolls = 0
$script:lastLoggedStateKey = $null

function Write-State([string]$Status, [string]$Detail = '') {
	$state = [pscustomobject]@{
		status = $Status
		updatedAt = (Get-Date).ToString('o')
		packageDirectory = $package
		installDirectory = $install
		targetExecutable = $targetExe
		stableEmptyPolls = $stableEmptyPolls
		detail = $Detail
	}
	$stateJson = $state | ConvertTo-Json -Depth 4
	$stateDirectory = Split-Path -Parent $statePath
	$stateFileName = [System.IO.Path]::GetFileName($statePath)
	$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
	$stateWritten = $false
	for ($attempt = 1; $attempt -le 8 -and -not $stateWritten; $attempt++) {
		$temporaryName = '.' + $stateFileName + '.' + $PID + '.' + [System.Guid]::NewGuid().ToString('N') + '.tmp'
		$temporaryPath = Join-Path $stateDirectory $temporaryName
		try {
			[System.IO.File]::WriteAllText($temporaryPath, $stateJson, $utf8WithoutBom)
			if ([System.IO.File]::Exists($statePath)) {
				# Windows PowerShell 5.1 uses .NET Framework, which has no
				# File.Move(source, destination, overwrite) overload. File.Replace
				# performs a same-volume atomic replacement on Windows.
				try {
					[System.IO.File]::Replace($temporaryPath, $statePath, $null)
				} catch {
					# Some synchronized or non-NTFS folders do not implement Replace.
					# PowerShell's native move supports replacing an existing file there.
					Move-Item -LiteralPath $temporaryPath -Destination $statePath -Force -ErrorAction Stop
				}
			} else {
				[System.IO.File]::Move($temporaryPath, $statePath)
			}
			$stateWritten = $true
		} catch {
			Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
			if ($attempt -lt 8) { Start-Sleep -Milliseconds (100 * $attempt) }
		}
	}
	# Status persistence is advisory. A transient reader/sync lock must not stop
	# the deferred installer; the next polling cycle will retry this state write.
	if (-not $stateWritten) { return }
	$stateKey = $Status + "|" + $Detail
	if ($stateKey -ne $script:lastLoggedStateKey) {
		try {
			Add-Content -LiteralPath $logPath -Value ("{0} {1} {2}" -f $state.updatedAt, $Status, $Detail) -Encoding UTF8 -ErrorAction Stop
			$script:lastLoggedStateKey = $stateKey
		} catch {
			# A locked log file is retried on the next state update.
		}
	}
}

Write-State 'waiting_for_target_app_to_close'
while ((Get-Date) -lt $waitDeadline) {
	$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
		$_.Path -and [System.IO.Path]::GetFullPath($_.Path).Equals($targetExe, [System.StringComparison]::OrdinalIgnoreCase)
	})
	if ($running.Count -eq 0) {
		$stableEmptyPolls++
	} else {
		$stableEmptyPolls = 0
	}
	if ($stableEmptyPolls -ge 6) { break }
	Write-State 'waiting_for_target_app_to_close' ("matchingProcesses=" + $running.Count)
	Start-Sleep -Seconds 5
}

if ($stableEmptyPolls -lt 6) {
	Write-State 'expired_without_install' 'The target application remained open for the configured wait period.'
	exit 2
}

Write-State 'installing'
try {
	$installOutput = & $installer -PackageDirectory $package -InstallDirectory $install -BackupDirectory $BackupDirectory 2>&1
	$installOutput | Out-File -LiteralPath $logPath -Append -Encoding utf8
	Write-State 'installed' 'The full package installer verified the updated files and preserved user data.'
} catch {
	Write-State 'install_failed' ($_.Exception.Message)
	throw
}
