[CmdletBinding()]
param(
	[string]$LuaJit = (Join-Path $env:LOCALAPPDATA 'Temp/pob-luajit/extracted/LuaJIT/bin/luajit.exe'),
	[string]$DriveArchiveRoot = 'G:\O meu disco\00 - Projetos\PoB - IA\08_Exported_Builds_XML'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$luaExecutable = (Resolve-Path -LiteralPath $LuaJit).Path
$luaExporter = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Export-PatchSkillCatalog.lua')).Path
$archiveRoot = (Resolve-Path -LiteralPath $DriveArchiveRoot).Path
$catalogDirectory = Join-Path $archiveRoot 'OptimizerStudies\Builds\catalog'
$manifestDirectory = Join-Path $archiveRoot 'Manifests'
$catalogPath = Join-Path $catalogDirectory 'skill-catalog-3.24-3.29.json'
$targetPath = Join-Path $manifestDirectory 'attack-skill-targets-3.24-3.29-normal-transfigured.json'

if (-not (Test-Path -LiteralPath $catalogDirectory -PathType Container)) { throw "Catalog directory is missing: $catalogDirectory" }
if (-not (Test-Path -LiteralPath $manifestDirectory -PathType Container)) { throw "Manifest directory is missing: $manifestDirectory" }
if (Test-Path -LiteralPath $targetPath) { throw ('Refusing to overwrite an existing target matrix: ' + $targetPath) }

$patches = @(
	[pscustomobject]@{ patch = '3.24'; pobTag = 'v2.42.0'; sourceRef = 'v2.42.0'; sourceLabel = '3.24 release baseline'; treeVersion = '3_24' },
	[pscustomobject]@{ patch = '3.25'; pobTag = 'v2.47.0'; sourceRef = 'v2.47.0'; sourceLabel = '3.25 release baseline'; treeVersion = '3_25' },
	[pscustomobject]@{ patch = '3.26'; pobTag = 'v2.54.0'; sourceRef = 'v2.54.0'; sourceLabel = '3.26 release baseline'; treeVersion = '3_26' },
	[pscustomobject]@{ patch = '3.27'; pobTag = 'v2.58.0'; sourceRef = 'v2.58.0'; sourceLabel = '3.27 release baseline'; treeVersion = '3_27' },
	[pscustomobject]@{ patch = '3.28'; pobTag = 'v2.61.0'; sourceRef = 'v2.61.0'; sourceLabel = '3.28 release baseline'; treeVersion = '3_28' },
	[pscustomobject]@{ patch = '3.29'; pobTag = 'v2.67.2'; sourceRef = '16de4b82d57f1c0de6eb40f37143c32d4da36a02'; sourceLabel = '3.29 upstream dev HEAD (2026-09-08) with 3.29.1 tree data'; treeVersion = '3_29' }
)
$skillGroups = @('act_dex', 'act_int', 'act_str', 'glove', 'minion', 'other', 'spectre', 'sup_dex', 'sup_int', 'sup_str')
$expectedPatches = @('3.24', '3.25', '3.26', '3.27', '3.28', '3.29')

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

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempParent ('pob-attack-skill-targets-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$utf8NoBom = [Text.UTF8Encoding]::new($false)

try {
	$inputs = [Collections.Generic.List[object]]::new()
	$inputPath = Join-Path $tempRoot 'input.json'
	$generatedPath = Join-Path $tempRoot 'skill-catalog.json'
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
	$info.Arguments = '"' + $luaExporter + '"'
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

	$targets = @(
		foreach ($patch in $catalog.patches) {
			foreach ($skill in $patch.skills) {
				if ($skill.tags -match '(^|\s)attack(\s|$)' -and $skill.category -in @('normal', 'transfigured')) {
					[ordered]@{
						target_id = ($patch.patch + '|' + $skill.variantKey)
						patch = $patch.patch
						tree_version = $patch.treeVersion
						skill_name = $skill.name
						category = $skill.category
						game_id = $skill.gameId
						variant_id = $skill.variantId
						granted_effect_id = $skill.grantedEffectId
						variant_key = $skill.variantKey
						tags = $skill.tags
						required_unique_lineages = 10
						current_valid_lineages = $null
						coverage_status = 'not_audited'
						catalog_fingerprint = $patch.catalogFingerprint
					}
				}
			}
		}
	)
	if ($targets.Count -ne 1028 -or @($targets.target_id | Select-Object -Unique).Count -ne $targets.Count) {
		throw ('Expected 1,028 unique normal/transfigured attack targets; generated ' + $targets.Count + '.')
	}

	$counts = @(
		foreach ($patchName in $expectedPatches) {
			$rows = @($targets | Where-Object patch -eq $patchName)
			[ordered]@{
				patch = $patchName
				target_variants = $rows.Count
				required_examples = ($rows.Count * 10)
				normal = @($rows | Where-Object category -eq 'normal').Count
				transfigured = @($rows | Where-Object category -eq 'transfigured').Count
				vaal = @($rows | Where-Object category -eq 'vaal').Count
			}
		}
	)
	$targetManifest = [ordered]@{
		schema = 'pob-ai-attack-skill-target-matrix'
		schema_version = 1
		generated_at_utc = [DateTime]::UtcNow.ToString('o')
		game = 'Path of Exile 1'
		target_scope = 'normal_transfigured_attack_skills'
		source_catalog_schema = $catalog.schema
		source_catalog_schema_version = $catalog.schemaVersion
		source_catalog = 'OptimizerStudies/Builds/catalog/skill-catalog-3.24-3.29.json'
		target_rule = '10 unique validated build lineages per (patch, main attack skill variant); only normal and transfigured attack skills are targets. Vaal variants are excluded.'
		exclusions = @('support_granted_effect', 'non-attack skills', 'Vaal skills', 'non-standard alternate ascendancy trees', 'Bloodline or secondary alternate ascendancy allocations')
		standard_tree_only = $true
		training_eligibility = 'none; source rights review and independent quality gates remain required'
		summary = [ordered]@{
			target_variants = $targets.Count
			required_examples = ($targets.Count * 10)
			by_patch = $counts
		}
		targets = $targets
	}

	$stagedCatalog = Join-Path $tempRoot 'skill-catalog-3.24-3.29.json'
	$stagedTargets = Join-Path $tempRoot 'attack-skill-targets-3.24-3.29-normal-transfigured.json'
	[IO.File]::Copy($generatedPath, $stagedCatalog, $false)
	[IO.File]::WriteAllText($stagedTargets, ($targetManifest | ConvertTo-Json -Depth 12), $utf8NoBom)
	$installedCatalog = $false
	if (Test-Path -LiteralPath $catalogPath) {
		$existingCatalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
		if ($existingCatalog.schema -ne $catalog.schema -or $existingCatalog.schemaVersion -ne $catalog.schemaVersion -or
			@($existingCatalog.patches).Count -ne $expectedPatches.Count -or
			(@($existingCatalog.patches.patch) -join ',') -ne ($expectedPatches -join ',')) {
			throw 'Existing six-patch Drive catalog has a different schema or patch range; it was preserved.'
		}
		for ($index = 0; $index -lt $expectedPatches.Count; $index++) {
			$existingPatch = $existingCatalog.patches[$index]
			$generatedPatch = $catalog.patches[$index]
			if ($existingPatch.catalogFingerprint -ne $generatedPatch.catalogFingerprint -or
				$existingPatch.commit -ne $generatedPatch.commit -or
				$existingPatch.sourceHashes.gems -ne $generatedPatch.sourceHashes.gems -or
				$existingPatch.sourceHashes.tree -ne $generatedPatch.sourceHashes.tree -or
				$existingPatch.sourceHashes.skills -ne $generatedPatch.sourceHashes.skills -or
				$existingPatch.sourceHashes.data -ne $generatedPatch.sourceHashes.data) {
				throw ('Existing Drive catalog fingerprint differs from the pinned official source for ' + $expectedPatches[$index] + '; it was preserved.')
			}
		}
	} else {
		[IO.File]::Move($stagedCatalog, $catalogPath)
		$installedCatalog = $true
	}
	try {
		[IO.File]::Move($stagedTargets, $targetPath)
	} catch {
		if ($installedCatalog) { Remove-Item -LiteralPath $catalogPath -Force -ErrorAction SilentlyContinue }
		throw
	}

	$catalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$targetHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
	[pscustomobject]@{
		patches = ($expectedPatches -join ',')
		targetScope = 'normal_transfigured_attack_skills'
		targetVariants = $targets.Count
		requiredExamples = $targets.Count * 10
		countsByPatch = $counts
		catalogPath = $catalogPath
		catalogSha256 = $catalogHash
		targetManifestPath = $targetPath
		targetManifestSha256 = $targetHash
	} | ConvertTo-Json -Depth 5
}
finally {
	$resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
	if ($resolvedTempRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTempRoot) -match '^pob-attack-skill-targets-[0-9a-f]{32}$') {
		Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}
}
