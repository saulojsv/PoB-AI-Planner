[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[Parameter(Mandatory)][string]$BuildsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $BuildsRoot).Path
$indexPath = Join-Path $root 'builds.jsonl'
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw ('Build archive index not found: ' + $indexPath) }
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$backupPath = $indexPath + '.before-main-skill-backfill-' + $timestamp + '.bak'
$tempPath = $indexPath + '.tmp-' + [guid]::NewGuid().ToString('N')
$reportPath = Join-Path $root ('main-skill-backfill-' + $timestamp + '.json')
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Get-MainSkillCategory([string]$GameId, [string]$VariantId) {
	if ($VariantId -match '^Vaal' -or $GameId.Contains('SkillGemVaal')) { return 'vaal' }
	if ($VariantId -match 'Alt[XYZ]$' -or $VariantId.Contains('Transfigured')) { return 'transfigured' }
	if ($GameId -and $VariantId) { return 'normal' }
	return 'unknown'
}

function Get-SafeField([object]$Value, [string]$Name) {
	if ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { return $Value.$Name }
	return $null
}

function Set-SafeField([object]$Value, [string]$Name, [object]$FieldValue) {
	if ($Value.PSObject.Properties[$Name]) { $Value.$Name = $FieldValue }
	else { $Value | Add-Member -NotePropertyName $Name -NotePropertyValue $FieldValue }
}

function Resolve-ArchivedMainSkill([object]$Profile) {
	$groups = Get-SafeField $Profile 'skillGroups'
	if ($null -eq $groups) { return $null }
	$selectedGroups = @($groups | Where-Object { (Get-SafeField $_ 'selectedMainGroup') -eq $true })
	if ($selectedGroups.Count -ne 1) { return $null }
	$group = $selectedGroups[0]
	if ((Get-SafeField $group 'enabled') -ne $true -or (Get-SafeField $group 'slotEnabled') -ne $true) { return $null }
	$selectedSkills = @((Get-SafeField $group 'skills') | Where-Object { (Get-SafeField $_ 'selectedMainSkill') -eq $true })
	if ($selectedSkills.Count -ne 1) { return $null }
	$skill = $selectedSkills[0]
	if ((Get-SafeField $skill 'enabled') -eq $false) { return $null }
	$selectedEffects = @((Get-SafeField $skill 'effects') | Where-Object { (Get-SafeField $_ 'selected') -eq $true })
	if ($selectedEffects.Count -ne 1) { return $null }
	$effect = $selectedEffects[0]
	$gemId = [string](Get-SafeField $effect 'gemId')
	if (-not $gemId) { return $null }
	$sourceGems = @((Get-SafeField $group 'gems') | Where-Object { [string](Get-SafeField $_ 'gemId') -eq $gemId })
	if ($sourceGems.Count -ne 1) { return $null }
	$gem = $sourceGems[0]
	if ((Get-SafeField $gem 'enabled') -ne $true -or (Get-SafeField $gem 'isSupport') -ne $false) { return $null }
	$gameId = [string](Get-SafeField $effect 'gameId')
	$variantId = [string](Get-SafeField $effect 'variantId')
	$effectId = [string](Get-SafeField $effect 'effectId')
	if (-not $gameId -or -not $variantId -or -not $effectId -or
		[string](Get-SafeField $gem 'gameId') -ne $gameId -or [string](Get-SafeField $gem 'variantId') -ne $variantId) { return $null }
	$name = [string](Get-SafeField $gem 'name')
	if (-not $name) { $name = [string](Get-SafeField $skill 'name') }
	if (-not $name) { $name = [string](Get-SafeField $effect 'name') }
	return [ordered]@{
		gemId = $gemId
		gameId = $gameId
		variantId = $variantId
		skillId = [string](Get-SafeField $gem 'skillId')
		effectId = $effectId
		name = $name
		category = Get-MainSkillCategory $gameId $variantId
	}
}

$rows = [Collections.Generic.List[string]]::new()
$counts = [ordered]@{ observations = 0; enriched = 0; alreadyComplete = 0; unresolved = 0; conflictsPreserved = 0; nonBuildRecords = 0 }
foreach ($line in [IO.File]::ReadLines($indexPath)) {
	if ([string]::IsNullOrWhiteSpace($line)) { continue }
	try { $row = $line | ConvertFrom-Json -ErrorAction Stop }
	catch { throw ('Malformed build archive JSONL; no changes were written: ' + $_.Exception.Message) }
	if ([string](Get-SafeField $row 'recordType') -ne 'build_archive_observation' -or $null -eq (Get-SafeField $row 'profile')) {
		$counts.nonBuildRecords++
		$rows.Add($line)
		continue
	}
	$counts.observations++
	$profile = Get-SafeField $row 'profile'
	$derived = Resolve-ArchivedMainSkill $profile
	$changed = $false
	$direct = Get-SafeField $profile 'mainSkill'
	if ($null -eq $direct) {
		if ($derived) {
			Set-SafeField $profile 'mainSkill' $derived
			Set-SafeField $profile 'mainSkillStatus' 'identified'
			$counts.enriched++
			$changed = $true
		} else {
			if (-not (Get-SafeField $profile 'mainSkillStatus')) { Set-SafeField $profile 'mainSkillStatus' 'unidentified'; $changed = $true }
			$counts.unresolved++
		}
	} else {
		$directComplete = [string](Get-SafeField $direct 'gameId') -and [string](Get-SafeField $direct 'variantId') -and [string](Get-SafeField $direct 'effectId')
		$identityConflict = $false
		if ($derived) {
			foreach ($field in @('gemId', 'gameId', 'variantId', 'skillId', 'effectId')) {
				$existingValue = [string](Get-SafeField $direct $field)
				$derivedValue = [string](Get-SafeField $derived $field)
				if ($existingValue -and $derivedValue -and $existingValue -ne $derivedValue) { $identityConflict = $true; break }
			}
		}
		if ($identityConflict) {
			if ((Get-SafeField $profile 'mainSkillStatus') -ne 'conflict') { Set-SafeField $profile 'mainSkillStatus' 'conflict'; $changed = $true }
			$counts.conflictsPreserved++
		} else {
			if ($derived) {
				foreach ($field in @('gemId', 'gameId', 'variantId', 'skillId', 'effectId', 'name', 'category')) {
					if (-not [string](Get-SafeField $direct $field) -and [string](Get-SafeField $derived $field)) {
						$direct | Add-Member -NotePropertyName $field -NotePropertyValue (Get-SafeField $derived $field) -Force
						$changed = $true
					}
				}
				if ([string](Get-SafeField $direct 'gameId') -and [string](Get-SafeField $direct 'variantId') -and [string](Get-SafeField $direct 'effectId')) {
					if ((Get-SafeField $profile 'mainSkillStatus') -ne 'identified') { Set-SafeField $profile 'mainSkillStatus' 'identified'; $changed = $true }
					if ($changed) { $counts.enriched++ } else { $counts.alreadyComplete++ }
				} else {
					if ((Get-SafeField $profile 'mainSkillStatus') -ne 'partial') { Set-SafeField $profile 'mainSkillStatus' 'partial'; $changed = $true }
					$counts.unresolved++
				}
			} elseif ($directComplete) {
				if ((Get-SafeField $profile 'mainSkillStatus') -ne 'identified') { Set-SafeField $profile 'mainSkillStatus' 'identified'; $changed = $true }
				$counts.alreadyComplete++
			} else {
				if ((Get-SafeField $profile 'mainSkillStatus') -ne 'partial') { Set-SafeField $profile 'mainSkillStatus' 'partial'; $changed = $true }
				$counts.unresolved++
			}
		}
	}
	if ($changed) { $rows.Add(($row | ConvertTo-Json -Depth 100 -Compress)) }
	else { $rows.Add($line) }
}

if ($counts.enriched -eq 0 -and $counts.unresolved -eq 0 -and $counts.conflictsPreserved -eq 0) {
	Write-Output ('No changes required. Observations: ' + $counts.observations)
	return
}
if (-not $PSCmdlet.ShouldProcess($indexPath, 'Backfill exact main-skill metadata from the archived selected PoB skill group')) {
	Write-Output ($counts | ConvertTo-Json -Compress)
	return
}
[IO.File]::Copy($indexPath, $backupPath, $false)
try {
	[IO.File]::WriteAllLines($tempPath, $rows, $utf8NoBom)
	# Verify every emitted JSONL row before replacing the original index.
	foreach ($outputLine in [IO.File]::ReadLines($tempPath)) {
		if ([string]::IsNullOrWhiteSpace($outputLine)) { continue }
		$null = $outputLine | ConvertFrom-Json -ErrorAction Stop
	}
	[IO.File]::Move($tempPath, $indexPath, $true)
} catch {
	if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
	throw ('Main-skill metadata backfill failed; original index is preserved and backup is at ' + $backupPath + '. ' + $_.Exception.Message)
}
$report = [ordered]@{
	schema = 'pob-ai-planner-main-skill-backfill-report'
	schemaVersion = 1
	generatedAt = [DateTime]::UtcNow.ToString('o')
	buildsRoot = $root
	index = $indexPath
	backup = $backupPath
	counts = $counts
}
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), $utf8NoBom)
Write-Output ('Main-skill metadata backfill: ' + ($counts | ConvertTo-Json -Compress))
Write-Output ('Backup: ' + $backupPath)
Write-Output ('Report: ' + $reportPath)
