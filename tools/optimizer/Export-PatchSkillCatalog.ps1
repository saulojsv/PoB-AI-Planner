<#
Build a versioned PoE 1 active-skill and standard-ascendancy inventory from
local, official Path of Building Community release tags. This exports catalog
metadata only; it does not collect or train on public builds.
#>
[CmdletBinding()]
param(
	[string]$LuaJit = (Join-Path $env:LOCALAPPDATA 'Temp/pob-luajit/extracted/LuaJIT/bin/luajit.exe'),
	[string]$UserDataPath = (Join-Path $env:USERPROFILE 'Documents/Path of Building')
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$luaExecutable = (Resolve-Path -LiteralPath $LuaJit).Path
$userPath = (Resolve-Path -LiteralPath $UserDataPath).Path
$archiveRoot = [IO.Path]::GetFullPath((Join-Path $userPath 'OptimizerStudies/Builds'))
$catalogDirectory = Join-Path $archiveRoot 'catalog'
$catalogPath = Join-Path $catalogDirectory 'skill-catalog.json'
$patches = @(
	[pscustomobject]@{ patch = '3.24'; pobTag = 'v2.42.0'; sourceRef = 'v2.42.0'; sourceLabel = '3.24 release baseline'; treeVersion = '3_24' },
	[pscustomobject]@{ patch = '3.25'; pobTag = 'v2.47.0'; sourceRef = 'v2.47.0'; sourceLabel = '3.25 release baseline'; treeVersion = '3_25' },
	[pscustomobject]@{ patch = '3.26'; pobTag = 'v2.54.0'; sourceRef = 'v2.54.0'; sourceLabel = '3.26.0 release baseline'; treeVersion = '3_26' },
	[pscustomobject]@{ patch = '3.27'; pobTag = 'v2.58.0'; sourceRef = 'v2.58.0'; sourceLabel = '3.27.0 release baseline'; treeVersion = '3_27' },
	[pscustomobject]@{ patch = '3.28'; pobTag = 'v2.61.0'; sourceRef = 'v2.61.0'; sourceLabel = '3.28.0 release baseline'; treeVersion = '3_28' },
	[pscustomobject]@{ patch = '3.29'; pobTag = 'v2.67.2'; sourceRef = '16de4b82d57f1c0de6eb40f37143c32d4da36a02'; sourceLabel = '3.29 upstream dev HEAD (2026-09-08) with 3.29.1 tree data'; treeVersion = '3_29' }
)
$expectedPatches = @('3.24', '3.25', '3.26', '3.27', '3.28', '3.29')
$skillGroups = @('act_dex', 'act_int', 'act_str', 'glove', 'minion', 'other', 'spectre', 'sup_dex', 'sup_int', 'sup_str')

function Invoke-GitText([string[]]$GitArguments) {
	$info = [Diagnostics.ProcessStartInfo]::new()
	$info.FileName = 'git'
	$info.WorkingDirectory = $repoRoot
	$info.UseShellExecute = $false
	$info.CreateNoWindow = $true
	$info.RedirectStandardOutput = $true
	$info.RedirectStandardError = $true
	foreach ($argument in $GitArguments) { $info.ArgumentList.Add($argument) }
	$process = [Diagnostics.Process]::new()
	$process.StartInfo = $info
	$null = $process.Start()
	$stdoutTask = $process.StandardOutput.ReadToEndAsync()
	$stderrTask = $process.StandardError.ReadToEndAsync()
	if (-not $process.WaitForExit(120000)) { $process.Kill(); $process.WaitForExit(); throw 'Official PoB tag read timed out.' }
	$stdout = $stdoutTask.GetAwaiter().GetResult()
	$stderr = $stderrTask.GetAwaiter().GetResult()
	$exitCode = $process.ExitCode
	$process.Dispose()
	if ($exitCode -ne 0) { throw ('git ' + ($GitArguments -join ' ') + ' failed: ' + $stderr.Trim()) }
	return $stdout
}

function Get-GitFile([string]$Tag, [string]$RelativePath, [string]$Destination) {
	$text = Invoke-GitText @('show', ($Tag + ':' + $RelativePath))
	[IO.File]::WriteAllText($Destination, $text, [Text.UTF8Encoding]::new($false))
	return (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
}

if (-not (Test-Path -LiteralPath $catalogDirectory)) {
	New-Item -ItemType Directory -Path $catalogDirectory -Force | Out-Null
}
$tempRoot = Join-Path $catalogDirectory ('.skill-catalog-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$inputs = [Collections.Generic.List[object]]::new()
$inputPath = Join-Path $tempRoot 'input.json'
$generatedPath = Join-Path $tempRoot 'skill-catalog.json'
try {
	foreach ($patch in $patches) {
		$commit = (Invoke-GitText @('rev-parse', '--verify', ($patch.sourceRef + '^{commit}'))).Trim()
		if ($commit -notmatch '^[0-9a-f]{40}$') { throw ('Official tag did not resolve to a commit: ' + $patch.pobTag) }
		$gemsPath = Join-Path $tempRoot ($patch.patch.Replace('.', '_') + '-Gems.lua')
		$treePath = Join-Path $tempRoot ($patch.patch.Replace('.', '_') + '-tree.lua')
		$dataPath = Join-Path $tempRoot ($patch.patch.Replace('.', '_') + '-Data.lua')
		$gemsHash = Get-GitFile $patch.sourceRef 'src/Data/Gems.lua' $gemsPath
		$treeHash = Get-GitFile $patch.sourceRef ('src/TreeData/' + $patch.treeVersion + '/tree.lua') $treePath
		$dataHash = Get-GitFile $patch.sourceRef 'src/Modules/Data.lua' $dataPath
		$skillPaths = [ordered]@{}
		$skillHashes = [ordered]@{}
		foreach ($skillGroup in $skillGroups) {
			$skillPath = Join-Path $tempRoot ($patch.patch.Replace('.', '_') + '-Skills-' + $skillGroup + '.lua')
			$skillHashes[$skillGroup] = Get-GitFile $patch.sourceRef ('src/Data/Skills/' + $skillGroup + '.lua') $skillPath
			$skillPaths[$skillGroup] = $skillPath
		}
		$inputs.Add([ordered]@{
			patch = $patch.patch; pobTag = $patch.pobTag; sourceRef = $patch.sourceRef
			sourceLabel = $patch.sourceLabel; treeVersion = $patch.treeVersion; commit = $commit
			gemsPath = $gemsPath; treePath = $treePath; gemsSha256 = $gemsHash; treeSha256 = $treeHash
			dataPath = $dataPath; dataSha256 = $dataHash; skillPaths = $skillPaths; skillHashes = $skillHashes
		})
	}
	$input = [ordered]@{ schema = 'pob-ai-planner-patch-skill-source-input'; schemaVersion = 2; patches = @($inputs) }
	[IO.File]::WriteAllText($inputPath, ($input | ConvertTo-Json -Depth 8), $utf8NoBom)

	$info = [Diagnostics.ProcessStartInfo]::new()
	$info.FileName = $luaExecutable
	$info.Arguments = '"' + (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Export-PatchSkillCatalog.lua')).Path + '"'
	$info.WorkingDirectory = Join-Path $repoRoot 'src'
	$info.UseShellExecute = $false
	$info.CreateNoWindow = $true
	$info.RedirectStandardOutput = $true
	$info.RedirectStandardError = $true
	$info.EnvironmentVariables['POB_PATCH_SKILL_INPUT'] = $inputPath
	$info.EnvironmentVariables['POB_PATCH_SKILL_OUTPUT'] = $generatedPath
	$info.EnvironmentVariables['LUA_PATH'] = '.\?.lua;.\?\init.lua;..\runtime\lua\?.lua;..\runtime\lua\?\init.lua'
	$info.EnvironmentVariables['LUA_CPATH'] = '.\?.dll;..\runtime\?.dll;..\runtime\lua\?.dll'
	$process = [Diagnostics.Process]::new()
	$process.StartInfo = $info
	$null = $process.Start()
	$stdoutTask = $process.StandardOutput.ReadToEndAsync()
	$stderrTask = $process.StandardError.ReadToEndAsync()
	if (-not $process.WaitForExit(180000)) { $process.Kill(); $process.WaitForExit(); throw 'LuaJIT patch catalog export exceeded three minutes.' }
	$stdout = $stdoutTask.GetAwaiter().GetResult()
	$stderr = $stderrTask.GetAwaiter().GetResult()
	$luaExitCode = $process.ExitCode
	$process.Dispose()
	if ($luaExitCode -ne 0) { throw ('LuaJIT catalog export failed: ' + $stderr.Trim()) }
	if (-not (Test-Path -LiteralPath $generatedPath)) { throw 'LuaJIT did not produce the versioned catalog.' }
	$catalog = Get-Content -LiteralPath $generatedPath -Raw | ConvertFrom-Json
	if ($catalog.schema -ne 'pob-ai-planner-patch-skill-catalog' -or $catalog.schemaVersion -ne 5 -or @($catalog.patches).Count -ne $expectedPatches.Count) {
		throw 'Generated patch catalog failed schema or six-patch coverage validation.'
	}
	if ((@($catalog.patches.patch) -join ',') -ne ($expectedPatches -join ',')) { throw 'Generated patch order or coverage differs from 3.24–3.29.' }
	foreach ($patch in $catalog.patches) {
		if ($patch.counts.normal -le 0 -or $patch.counts.transfigured -le 0 -or $patch.counts.standardAscendancies -le 0 -or
			$null -eq $patch.counts.supportGrantedEffects -or $null -eq $patch.counts.vaalAlternateVariants -or
			$null -eq $patch.bloodlineNodeIds) {
			throw ('Patch catalog is unexpectedly incomplete for ' + $patch.patch)
		}
	}
	$replacement = Join-Path $catalogDirectory 'skill-catalog.json.new'
	[IO.File]::Copy($generatedPath, $replacement, $true)
	Move-Item -LiteralPath $replacement -Destination $catalogPath -Force
	Write-Output $stdout.Trim()
	Write-Output ('Catalog: ' + $catalogPath)
	Write-Output ('Catalog bytes: ' + (Get-Item -LiteralPath $catalogPath).Length)
}
finally {
	foreach ($file in (Get-ChildItem -LiteralPath $tempRoot -File -ErrorAction SilentlyContinue)) {
		Remove-Item -LiteralPath $file.FullName -Force
	}
	Remove-Item -LiteralPath $tempRoot -Force
}
