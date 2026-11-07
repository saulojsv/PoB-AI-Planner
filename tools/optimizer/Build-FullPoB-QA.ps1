<#
Create a disposable full-release QA package with the current PoB program/tree
files. The official release binaries in the clean base are preserved.
#>
[CmdletBinding()]
param(
	[string]$BaseDirectory = (Join-Path $PSScriptRoot '../../runtime/AIPlanner-2.67.2-Full-QA-Clean'),
	[string]$OutputDirectory = (Join-Path $PSScriptRoot '../../runtime/AIPlanner-2.67.2-Full-QA-20261031-R2'),
	[string]$SourceRoot = (Join-Path $PSScriptRoot '../..')
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$sourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'runtime')).TrimEnd('\')
$base = (Resolve-Path -LiteralPath $BaseDirectory).Path
$outputCandidate = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repoRoot $OutputDirectory }
$output = [System.IO.Path]::GetFullPath($outputCandidate)
$runtimePrefix = $runtimeRoot + '\'
if (-not $output.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw "QA output must be a new directory inside $runtimeRoot"
}
$pathsOverlap = (
	$output.StartsWith($base.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
	$base.StartsWith($output.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
	$output.TrimEnd('\').Equals($base.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
)
if ($pathsOverlap) {
	throw 'Output and base must be separate directories'
}
if (Test-Path -LiteralPath $output) { throw "Refusing to overwrite an existing QA package: $output" }
$manifestPath = Join-Path $sourceRoot 'manifest.xml'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Missing current manifest: $manifestPath" }
[xml]$manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
$baseManifestPath = Join-Path $base 'manifest.xml'
if (-not (Test-Path -LiteralPath $baseManifestPath -PathType Leaf)) { throw "Clean full-release base is missing manifest.xml: $baseManifestPath" }
[xml]$baseManifest = [System.IO.File]::ReadAllText($baseManifestPath, [System.Text.Encoding]::UTF8)
$sourceVersion = $manifest.PoBVersion.Version
$releaseVersion = $baseManifest.PoBVersion.Version
if (-not $sourceVersion -or -not $releaseVersion -or
	[string]$sourceVersion.number -ne [string]$releaseVersion.number) {
	throw 'Source and full-release base PoB versions do not match'
}
foreach ($attribute in @('branch', 'platform')) {
	$value = [string]$releaseVersion.GetAttribute($attribute)
	# Official update_manifest.py emits only Version/@number. Preserve optional
	# release metadata when the clean base provides it, but do not reject a valid
	# official full-release manifest solely because those optional attributes are
	# absent.
	if (-not [string]::IsNullOrWhiteSpace($value)) { $sourceVersion.SetAttribute($attribute, $value) }
}
if ([string]::IsNullOrWhiteSpace([string]$sourceVersion.GetAttribute('platform'))) {
	# This builder produces Windows full-release packages even when the clean
	# upstream base omits the installer-only platform attribute.
	$sourceVersion.SetAttribute('platform', 'win32')
}
$rows = @($manifest.PoBVersion.File)
if ($rows.Count -lt 1000) { throw "Manifest inventory is incomplete: $($rows.Count) files" }

$unexpectedManifestText = @($manifest.PoBVersion.ChildNodes | Where-Object {
	$_.NodeType -eq [System.Xml.XmlNodeType]::Text -and -not [string]::IsNullOrWhiteSpace($_.Value)
})
if ($unexpectedManifestText.Count -gt 0) {
	throw "Manifest contains $($unexpectedManifestText.Count) malformed text node(s) outside File entries"
}
$manifestProgramNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $rows) {
	if ([string]$row.part -eq 'program') { [void]$manifestProgramNames.Add([string]$row.name) }
}
$requiredOptimizerFiles = @(
	Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'src/Modules/Optimizer') -File -Filter '*.lua' |
		ForEach-Object { 'Modules/Optimizer/' + $_.Name }
)
$requiredOptimizerFiles += 'Classes/OptimizerTab.lua'
$unlistedOptimizerFiles = @($requiredOptimizerFiles | Where-Object { -not $manifestProgramNames.Contains($_) })
if ($unlistedOptimizerFiles.Count -gt 0) {
	throw ('Optimizer files are missing from manifest.xml: ' + ($unlistedOptimizerFiles -join ', '))
}

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

$exeName = 'Path of Building.exe'
$exePath = Join-Path $base $exeName
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "Clean full-release base is missing $exeName" }
$baseExeHash = Get-CanonicalSha1 $exePath
Copy-Item -LiteralPath $base -Destination $output -Recurse
$installedConfigPath = Join-Path $output 'installed.cfg'
if (-not (Test-Path -LiteralPath $installedConfigPath -PathType Leaf)) {
	# The install script checks for this marker before deploying a staged package.
	# Some clean upstream archives omit it; installed user targets retain their
	# own file, so a zero-byte package marker is sufficient and carries no path.
	[System.IO.File]::WriteAllText($installedConfigPath, [string]::Empty)
}

$copied = 0
foreach ($row in $rows) {
	$part = [string]$row.part
	$manifestRelative = [string]$row.name
	$relative = $manifestRelative.Replace('{space}', ' ').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
	$partSourceRoot = switch ($part) {
		'default' { $sourceRoot; break }
		'program' { Join-Path $sourceRoot 'src'; break }
		'tree' { Join-Path $sourceRoot 'src'; break }
		'runtime' { $null; break }
		default { throw "Unknown manifest part '$part' for $relative" }
	}
	if ($null -eq $partSourceRoot) { continue }
	$sourcePath = [System.IO.Path]::GetFullPath((Join-Path $partSourceRoot $relative))
	$sourcePrefix = [System.IO.Path]::GetFullPath($partSourceRoot).TrimEnd('\') + '\'
	if (-not $sourcePath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
		throw "Manifest source escapes its mapped root: $relative"
	}
	if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Manifest source is missing: $sourcePath" }
	$destinationPath = [System.IO.Path]::GetFullPath((Join-Path $output $relative))
	if (-not $destinationPath.StartsWith($output.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
		throw "Manifest destination escapes package: $relative"
	}
	$destinationParent = Split-Path -Parent $destinationPath
	if (-not (Test-Path -LiteralPath $destinationParent)) { New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null }
	Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
	$copied++
}
$packageManifestPath = Join-Path $output 'manifest.xml'
$writerSettings = [System.Xml.XmlWriterSettings]::new()
$writerSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
$writerSettings.Indent = $true
$manifestWriter = [System.Xml.XmlWriter]::Create($packageManifestPath, $writerSettings)
try { $manifest.Save($manifestWriter) }
finally { $manifestWriter.Dispose() }
Copy-Item -LiteralPath (Join-Path $sourceRoot 'manifest.cfg') -Destination (Join-Path $output 'manifest.cfg') -Force

$missing = [System.Collections.Generic.List[string]]::new()
$mismatched = [System.Collections.Generic.List[string]]::new()
foreach ($row in $rows) {
	$relative = ([string]$row.name).Replace('{space}', ' ').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
	$packagePath = Join-Path $output $relative
	if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { $missing.Add($relative); continue }
	$actual = Get-CanonicalSha1 $packagePath
	if ($actual -ne ([string]$row.sha1).ToLowerInvariant()) { $mismatched.Add($relative) }
}
if ($missing.Count -gt 0 -or $mismatched.Count -gt 0) {
	throw "QA package manifest check failed: missing=$($missing.Count), mismatched=$($mismatched.Count)"
}
$outputExeHash = Get-CanonicalSha1 (Join-Path $output $exeName)
if ($outputExeHash -ne $baseExeHash) { throw 'The official release executable changed while packaging' }
"QA package: $output"
"Program/tree/default files copied: $copied; manifest entries verified: $($rows.Count)"
"Official release executable SHA-1 preserved: $outputExeHash"
