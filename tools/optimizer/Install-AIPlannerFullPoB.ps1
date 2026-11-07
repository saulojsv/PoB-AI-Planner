<#
Install a validated PoB AI Planner full release over the existing official PoB
program files while preserving the installed executable and all user data.
#>
[CmdletBinding()]
param(
	[string]$PackageDirectory = (Join-Path $PSScriptRoot '../../runtime/AIPlanner-2.67.2-Full-Release'),
	[string]$InstallDirectory = (Join-Path $env:APPDATA 'Path of Building Community'),
	[string]$BackupDirectory = (Join-Path $env:LOCALAPPDATA ('Path of Building Community/Backups/AIPlannerFullRelease-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)
$ErrorActionPreference = 'Stop'

function Get-CanonicalSha1([string]$Path) {
	[byte[]]$bytes = [System.IO.File]::ReadAllBytes($Path)
	if ($bytes -notcontains [byte]0) {
		$text = [System.Text.Encoding]::UTF8.GetString($bytes)
		$text = [regex]::Replace($text, "`r`n|`r|`n", "`r`n")
		$bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
	}
	$sha = [System.Security.Cryptography.SHA1]::Create()
	try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
	finally { $sha.Dispose() }
}

function Get-TreeDigest([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 'missing' }
	$parts = [System.Collections.Generic.List[string]]::new()
	$rootPrefix = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
	foreach ($file in (Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName)) {
		$relative = $file.FullName.Substring($rootPrefix.Length).Replace('\', '/')
		$parts.Add($relative + '|' + $file.Length + '|' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
	}
	$text = [string]::Join("`n", $parts)
	$bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
	$sha = [System.Security.Cryptography.SHA256]::Create()
	try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
	finally { $sha.Dispose() }
}

$package = (Resolve-Path -LiteralPath $PackageDirectory).Path
$install = (Resolve-Path -LiteralPath $InstallDirectory).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'runtime')).TrimEnd('\') + '\'
if (-not $package.StartsWith($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw "Release package must be staged under $runtimeRoot"
}
if ($package.TrimEnd('\').Equals($install.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
	throw 'Package and installation paths must be different'
}

$exeName = 'Path of Building.exe'
$installExe = [System.IO.Path]::GetFullPath((Join-Path $install $exeName))
$packageExe = Join-Path $package $exeName
if (-not (Test-Path -LiteralPath $installExe -PathType Leaf) -or -not (Test-Path -LiteralPath $packageExe -PathType Leaf)) {
	throw 'The official PoB executable is missing from the package or installation'
}
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
	$_.Path -and [System.IO.Path]::GetFullPath($_.Path).Equals($installExe, [System.StringComparison]::OrdinalIgnoreCase)
})
if ($running.Count -gt 0) { throw 'Close the Path of Building process from the installation folder before updating it' }
if (-not (Test-Path -LiteralPath (Join-Path $install 'installed.cfg') -PathType Leaf)) {
	throw 'The target is not the existing full PoB installation (installed.cfg is missing)'
}
if (-not (Test-Path -LiteralPath (Join-Path $package 'installed.cfg') -PathType Leaf)) {
	throw 'The validated full-release package must retain installed.cfg for native user-data paths'
}

[xml]$manifest = [System.IO.File]::ReadAllText((Join-Path $package 'manifest.xml'), [System.Text.Encoding]::UTF8)
$version = $manifest.PoBVersion.Version
if ([string]$version.number -ne '2.67.2' -or [string]$version.platform -ne 'win32') {
	throw 'The package is not the expected PoB 2.67.2 Windows full release'
}
$packageExeHash = Get-FileHash -LiteralPath $packageExe -Algorithm SHA256
$installExeHash = Get-FileHash -LiteralPath $installExe -Algorithm SHA256
if ($packageExeHash.Hash -ne $installExeHash.Hash) {
	throw 'The release package executable differs from the official installed executable'
}

$changes = [System.Collections.Generic.List[object]]::new()
$runtimeRows = [System.Collections.Generic.List[object]]::new()
$packageProgramKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$packagePrefix = [System.IO.Path]::GetFullPath($package).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$installPrefix = [System.IO.Path]::GetFullPath($install).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
foreach ($row in $manifest.PoBVersion.File) {
	$relative = ([string]$row.name).Replace('{space}', ' ').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
	$source = [System.IO.Path]::GetFullPath((Join-Path $package $relative))
	$destination = [System.IO.Path]::GetFullPath((Join-Path $install $relative))
	if (-not $source.StartsWith($packagePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or -not $destination.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
		throw "Manifest path escaped its root: $relative"
	}
	if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Package file is missing: $relative" }
	$expected = ([string]$row.sha1).ToLowerInvariant()
	if ((Get-CanonicalSha1 $source) -ne $expected) { throw "Package hash mismatch: $relative" }
	if ([string]$row.part -eq 'runtime') {
		$installedRuntimeHash = if (Test-Path -LiteralPath $destination -PathType Leaf) { Get-CanonicalSha1 $destination } else { $null }
		if ($installedRuntimeHash -ne $expected) {
			throw "Installed native runtime differs from the validated package: $relative"
		}
		$runtimeRows.Add([pscustomobject]@{ path = $relative; sha1 = $expected })
		continue
	}
	if ([string]$row.part -notin @('default', 'program', 'tree')) { throw "Unsupported manifest part: $($row.part)" }
	[void]$packageProgramKeys.Add(([string]$row.part + '|' + $relative))
	$currentHash = if (Test-Path -LiteralPath $destination -PathType Leaf) { Get-CanonicalSha1 $destination } else { $null }
	if ($currentHash -ne $expected) {
		$changes.Add([pscustomobject]@{ path = $relative; source = $source; destination = $destination; remove = $false; existed = $null -ne $currentHash; previousSha1 = $currentHash })
	}
}

# Remove only program files that the currently installed manifest owns and the
# incoming package no longer contains. Each file is backed up before deletion;
# user data and unlisted files are never traversed or removed.
$installedManifestPath = Join-Path $install 'manifest.xml'
if (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) {
	[xml]$installedManifest = [System.IO.File]::ReadAllText($installedManifestPath, [System.Text.Encoding]::UTF8)
	foreach ($row in $installedManifest.PoBVersion.File) {
		$part = [string]$row.part
		if ($part -notin @('default', 'program', 'tree')) { continue }
		$relative = ([string]$row.name).Replace('{space}', ' ').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
		$destination = [System.IO.Path]::GetFullPath((Join-Path $install $relative))
		if (-not $destination.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
			throw "Installed manifest path escaped its root: $relative"
		}
		if ($packageProgramKeys.Contains($part + '|' + $relative)) { continue }
		if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { continue }
		$previousHash = Get-CanonicalSha1 $destination
		$changes.Add([pscustomobject]@{ path = $relative; source = $null; destination = $destination; remove = $true; existed = $true; previousSha1 = $previousHash })
	}
}

foreach ($metadataName in @('manifest.xml', 'manifest.cfg')) {
	$source = Join-Path $package $metadataName
	$destination = Join-Path $install $metadataName
	if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Package metadata is missing: $metadataName" }
	$currentHash = if (Test-Path -LiteralPath $destination -PathType Leaf) { Get-CanonicalSha1 $destination } else { $null }
	$expectedHash = Get-CanonicalSha1 $source
	if ($currentHash -ne $expectedHash) {
		$changes.Add([pscustomobject]@{ path = $metadataName; source = $source; destination = $destination; remove = $false; existed = $null -ne $currentHash; previousSha1 = $currentHash })
	}
}

$backupCandidate = [System.IO.Path]::GetFullPath($BackupDirectory)
$backupRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Path of Building Community/Backups')).TrimEnd('\') + '\'
if (-not $backupCandidate.StartsWith($backupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw "Backup must be created under $backupRoot"
}
if (Test-Path -LiteralPath $backupCandidate) { throw "Refusing to reuse an existing backup directory: $backupCandidate" }
New-Item -ItemType Directory -Path $backupCandidate -Force | Out-Null
$backupFiles = Join-Path $backupCandidate 'files'
$shortcutBackup = Join-Path $backupCandidate 'shortcuts'
New-Item -ItemType Directory -Path $backupFiles -Force | Out-Null
New-Item -ItemType Directory -Path $shortcutBackup -Force | Out-Null

$installedCfgHashBefore = Get-FileHash -LiteralPath (Join-Path $install 'installed.cfg') -Algorithm SHA256
$userDataPaths = @('OptimizerStudies', 'Path of Building')
$userDataDigestsBefore = @{ }
foreach ($name in $userDataPaths) { $userDataDigestsBefore[$name] = Get-TreeDigest (Join-Path $install $name) }
# The public build archive lives under Documents, outside this install transaction.
# The ingestion worker may append to it concurrently; this installer never writes it.
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PoB AI Planner.lnk'
$startShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Path of Building Community.lnk'
$shortcutPaths = @($desktopShortcut, $startShortcut)
$shortcutStates = [System.Collections.Generic.List[object]]::new()
$shell = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in $shortcutPaths) {
	$exists = Test-Path -LiteralPath $shortcutPath -PathType Leaf
	if ($exists) { Copy-Item -LiteralPath $shortcutPath -Destination (Join-Path $shortcutBackup ([IO.Path]::GetFileName($shortcutPath))) }
	$shortcutStates.Add([pscustomobject]@{ path = $shortcutPath; existed = $exists })
}

$markerPath = Join-Path $install 'AIPlannerManaged.release'
$markerExisted = Test-Path -LiteralPath $markerPath -PathType Leaf
if ($markerExisted) { Copy-Item -LiteralPath $markerPath -Destination (Join-Path $backupCandidate 'AIPlannerManaged.release') }
$markerCreated = $false
$shortcutsUpdated = $false
try {
	foreach ($change in $changes) {
		if ($change.existed) {
			$relativeBackup = [IO.Path]::GetFullPath((Join-Path $backupFiles $change.path))
			New-Item -ItemType Directory -Path (Split-Path -Parent $relativeBackup) -Force | Out-Null
			Copy-Item -LiteralPath $change.destination -Destination $relativeBackup -Force
		}
	}
	$metadata = [pscustomobject]@{
		package = $package
		install = $install
		version = [string]$version.number
		backupCreatedAt = (Get-Date).ToString('o')
		changedFiles = @($changes | ForEach-Object { [pscustomobject]@{ path = $_.path; removed = [bool]$_.remove; existed = $_.existed; previousSha1 = $_.previousSha1 } })
	}
	$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backupCandidate 'deployment.json') -Encoding UTF8

	foreach ($change in $changes) {
		if ($change.remove) {
			Remove-Item -LiteralPath $change.destination -Force
			continue
		}
		$parent = Split-Path -Parent $change.destination
		if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
		Copy-Item -LiteralPath $change.source -Destination $change.destination -Force
	}

	$markerText = @(
		'Release=PoB AI Planner'
		('PoBVersion=' + [string]$version.number)
		('InstalledAt=' + (Get-Date).ToString('o'))
		'UpstreamUpdates=disabled'
	) -join "`r`n"
	[System.IO.File]::WriteAllText($markerPath, $markerText + "`r`n", [System.Text.UTF8Encoding]::new($false))
	$markerCreated = $true

	foreach ($row in $manifest.PoBVersion.File) {
		if ([string]$row.part -eq 'runtime') { continue }
		$relative = ([string]$row.name).Replace('{space}', ' ').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
		$destination = Join-Path $install $relative
		$installedFileHash = if (Test-Path -LiteralPath $destination -PathType Leaf) { Get-CanonicalSha1 $destination } else { $null }
		if ($installedFileHash -ne ([string]$row.sha1).ToLowerInvariant()) {
			throw "Installed program/tree verification failed: $relative"
		}
	}
	foreach ($metadataName in @('manifest.xml', 'manifest.cfg')) {
		if ((Get-CanonicalSha1 (Join-Path $install $metadataName)) -ne (Get-CanonicalSha1 (Join-Path $package $metadataName))) {
			throw "Installed metadata verification failed: $metadataName"
		}
	}
	if ((Get-FileHash -LiteralPath $installExe -Algorithm SHA256).Hash -ne $installExeHash.Hash) { throw 'The official PoB executable changed' }
	if ((Get-FileHash -LiteralPath (Join-Path $install 'installed.cfg') -Algorithm SHA256).Hash -ne $installedCfgHashBefore.Hash) {
		throw 'installed.cfg changed unexpectedly'
	}
	foreach ($name in $userDataPaths) {
		if ((Get-TreeDigest (Join-Path $install $name)) -ne $userDataDigestsBefore[$name]) { throw "User data changed unexpectedly: $name" }
	}
	foreach ($shortcutPath in $shortcutPaths) {
		$shortcut = $shell.CreateShortcut($shortcutPath)
		$shortcut.TargetPath = $installExe
		$shortcut.WorkingDirectory = $install
		$shortcut.IconLocation = $installExe + ',0'
		$shortcut.Save()
	}
	$shortcutsUpdated = $true

	[pscustomobject]@{
		status = 'installed'
		version = [string]$version.number
		installDirectory = $install
		changedFiles = $changes.Count
		removedFiles = @($changes | Where-Object remove | ForEach-Object path)
		runtimeFilesVerified = $runtimeRows.Count
		backupDirectory = $backupCandidate
		desktopShortcut = $desktopShortcut
		startMenuShortcut = $startShortcut
		userDataPreserved = $userDataPaths
		executableSha256 = $installExeHash.Hash
	} | ConvertTo-Json -Depth 4
}
catch {
	if ($shortcutsUpdated) {
		foreach ($state in $shortcutStates) {
			if ($state.existed) {
				$source = Join-Path $shortcutBackup ([IO.Path]::GetFileName($state.path))
				if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $state.path -Force }
			} elseif (Test-Path -LiteralPath $state.path) { Remove-Item -LiteralPath $state.path -Force }
		}
	}
	foreach ($change in $changes) {
		$backupPath = Join-Path $backupFiles $change.path
		if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
			$parent = Split-Path -Parent $change.destination
			if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
			Copy-Item -LiteralPath $backupPath -Destination $change.destination -Force
		} elseif (-not $change.existed -and (Test-Path -LiteralPath $change.destination -PathType Leaf)) {
			Remove-Item -LiteralPath $change.destination -Force
		}
	}
	foreach ($metadataName in @('manifest.xml', 'manifest.cfg')) {
		$backupPath = Join-Path $backupFiles $metadataName
		$destination = Join-Path $install $metadataName
		if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Copy-Item -LiteralPath $backupPath -Destination $destination -Force }
	}
	if ($markerCreated) {
		$markerBackup = Join-Path $backupCandidate 'AIPlannerManaged.release'
		if ($markerExisted -and (Test-Path -LiteralPath $markerBackup -PathType Leaf)) {
			Copy-Item -LiteralPath $markerBackup -Destination $markerPath -Force
		} else {
			Remove-Item -LiteralPath $markerPath -Force
		}
	}
	throw
}
finally {
	if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}
