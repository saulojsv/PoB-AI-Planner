<#
Rebuild the dashboard's bounded JSONL result history from immutable ingestion
batch reports, paired-review sidecars and archive quality-audit states. This is
a local file operation only; it never calls a provider or modifies build XML.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[string]$UserDataPath = (Join-Path $env:USERPROFILE 'Documents/Path of Building')
)
$ErrorActionPreference = 'Stop'
$userPath = (Resolve-Path -LiteralPath $UserDataPath).Path
$root = Join-Path $userPath 'OptimizerStudies/BuildIngestion'
$batchesRoot = Join-Path $root 'Batches'
$reviewAuditsRoot = Join-Path $root 'Reviews'
$archivePath = Join-Path $userPath 'OptimizerStudies/Builds/builds.jsonl'
$resultsPath = Join-Path $root 'latest-results.jsonl'
$supportedPatches = @('3.24', '3.25', '3.26', '3.27', '3.28', '3.29')
if (-not (Test-Path -LiteralPath $batchesRoot -PathType Container)) { throw 'Ingestion batch directory is missing.' }
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw 'Build archive index is missing.' }
$batchFiles = @(Get-ChildItem -LiteralPath $batchesRoot -File -Filter 'batch-*.json' | Sort-Object Name)
if ($batchFiles.Count -eq 0) { throw 'No immutable ingestion batch reports are available.' }
$events = [Collections.Generic.List[object]]::new()
$auditEvents = [Collections.Generic.List[object]]::new()
$reviewedIds = @{ }
$reviewedCodeHashes = @{ }
$batchTimeById = @{ }
$batchTimeByFile = @{ }
$batchStatusesByFile = @{ }
$eventSequence = 0
$statusAllowlist = @(
	'archived', 'already_archived', 'target_gate_rejected', 'native_load_failed',
	'native_load_unconfirmed', 'native_tree_load_unconfirmed', 'profile_failed',
	'archive_failed', 'ingestion_exception', 'archive_source_lookup_failed',
	'lineage_failed', 'already_reviewed', 'reviewed', 'review_failed',
	'review_catalog_unavailable', 'archive_snapshot_unresolved', 'not_found',
	'request_failed', 'request_blocked'
)

function Get-NativePatch($Result, $Request) {
	$treeVersion = [string]$Result.nativeTreeLoadRecovery.treeVersion
	if (-not $treeVersion) {
		$treeEvidence = $Result.nativeTreeEvidence
		$sourceSpecs = @($treeEvidence.sourceTreeSpecs)
		$activeSourceIndex = [int]$treeEvidence.activeSpecIndex
		if ($sourceSpecs.Count -gt 0 -and $activeSourceIndex -ge 1 -and $activeSourceIndex -le $sourceSpecs.Count) {
			$treeVersion = [string]$sourceSpecs[$activeSourceIndex - 1].treeVersion
		} elseif ($treeEvidence.treeLoadRecorderStatus -ne 'already_installed' -and $Result.status -notin @('native_tree_load_unconfirmed', 'native_load_unconfirmed', 'native_load_failed')) {
			# Only trust the loaded Spec list when this result did not reuse the
			# previous build's runtime state after a failed source-tree load.
			$specs = @($treeEvidence.specs)
			if ($specs.Count -gt 0) { $treeVersion = [string]$specs[0].treeVersion }
		}
	}
	if ($treeVersion -match '^3_(24|25|26|27|28|29)$') { return $treeVersion.Replace('_', '.') }
	$claim = [string]$Request.claimedPatch
	if ($claim -in $supportedPatches) { return $claim }
	return $null
}

function New-ResultRow($Id, $Status, $Patch, $Result, $Reason) {
	if ([string]$Status -notin $statusAllowlist) { return $null }
	if ([string]$Id -notmatch '^[A-Za-z0-9_-]{3,64}$') { return $null }
	$row = [ordered]@{
		schema = 'pob-ai-planner-ingestion-result'
		schemaVersion = 1
		id = [string]$Id
		status = [string]$Status
		patch = if ([string]$Patch -in $supportedPatches) { [string]$Patch } else { $null }
	}
	if ($Result.mainSkill.name) { $row.skill = [string]$Result.mainSkill.name }
	if ($Result.mainSkill.category -in @('normal', 'transfigured', 'unknown')) { $row.category = [string]$Result.mainSkill.category }
	if ($Result.character.ascendancy) { $row.ascendancy = [string]$Result.character.ascendancy }
	if ($Reason) { $row.reason = [string]$Reason }
	if ($Result -and $Result.reviewAudit) { $row['reviewAudit'] = $Result.reviewAudit }
	return $row
}

foreach ($batchFile in $batchFiles) {
	$batch = Get-Content -LiteralPath $batchFile.FullName -Raw | ConvertFrom-Json
	if ($batch.schema -ne 'pob-ai-planner-public-build-ingestion-batch' -or $batch.schemaVersion -ne 1) {
		throw ('Unsupported or invalid ingestion batch: ' + $batchFile.Name)
	}
	$batchTime = if ($batch.generatedAt) { [DateTimeOffset]$batch.generatedAt } else { $batchFile.LastWriteTimeUtc }
	$batchTimeByFile[$batchFile.Name] = $batchTime
	$batchStatuses = @{ }
	$requestById = @{ }
	foreach ($request in @($batch.providerRequests)) {
		if ($request.id) { $requestById[[string]$request.id] = $request }
	}
	$seenInBatch = @{ }
	foreach ($result in @($batch.importResults)) {
		if (-not $result.id) { continue }
		$id = [string]$result.id
		$batchTimeById[$id] = $batchTime
		$batchStatuses[$id] = [string]$result.status
		$request = $requestById[$id]
		$patch = Get-NativePatch $result $request
		$reason = [string]$result.reason
		$row = New-ResultRow $id ([string]$result.status) $patch $result $reason
		if ($row) {
			$events.Add([pscustomobject]@{ time = $batchTime; order = $eventSequence; row = $row })
			$eventSequence++
			$seenInBatch[$id] = $true
			if ($result.reviewAudit) {
				$reviewRow = New-ResultRow $id 'reviewed' $patch $null $null
				if ($reviewRow) {
					$reviewAudit = [ordered]@{ }
					foreach ($property in $result.reviewAudit.PSObject.Properties) { $reviewAudit[$property.Name] = $property.Value }
					$reviewAudit['pairedReviewCompleted'] = $true
					$reviewAudit['sourceStatus'] = [string]$result.status
					$reviewRow['reviewAudit'] = $reviewAudit
					if ($result.mainSkill.name) { $reviewRow.skill = [string]$result.mainSkill.name }
					if ($result.mainSkill.category -in @('normal', 'transfigured', 'unknown')) { $reviewRow.category = [string]$result.mainSkill.category }
					if ($result.character.ascendancy) { $reviewRow.ascendancy = [string]$result.character.ascendancy }
					$auditEvents.Add([pscustomobject]@{ time = $batchTime; order = $eventSequence; row = $reviewRow })
					$eventSequence++
					$reviewedIds[$id] = $true
				}
			}
		}
	}
	$batchStatusesByFile[$batchFile.Name] = $batchStatuses
	foreach ($request in @($batch.providerRequests)) {
		if (-not $request.id -or $seenInBatch.ContainsKey([string]$request.id)) { continue }
		$status = [string]$request.status
		if ($status -in @('downloaded', 'reused_local_source_code')) { $status = 'native_load_unconfirmed' }
		$row = New-ResultRow ([string]$request.id) $status ([string]$request.claimedPatch) $null ([string]$request.error)
		if ($row) {
			$events.Add([pscustomobject]@{ time = $batchTime; order = $eventSequence; row = $row })
			$eventSequence++
		}
	}
}

# Keep ingestion batches immutable. Pair-reviewed observations, including
# target-gate rejections that have no canonical archive row, live in bounded
# review sidecars linked to the source batch and content-addressed code hash.
if (Test-Path -LiteralPath $reviewAuditsRoot -PathType Container) {
	if ((Get-Item -LiteralPath $reviewAuditsRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
		throw 'Refusing linked build-review audit directory.'
	}
	$reviewFiles = @(Get-ChildItem -LiteralPath $reviewAuditsRoot -File -Filter 'review-audit-*.json' | Sort-Object Name)
	foreach ($reviewFile in $reviewFiles) {
		if ((Get-Item -LiteralPath $reviewFile.FullName -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
			throw ('Refusing linked build-review sidecar: ' + $reviewFile.Name)
		}
		$ledger = Get-Content -LiteralPath $reviewFile.FullName -Raw | ConvertFrom-Json
		if ($ledger.schema -ne 'pob-ai-planner-build-review-ledger' -or $ledger.schemaVersion -ne 1) {
			throw ('Unsupported build-review ledger: ' + $reviewFile.Name)
		}
		foreach ($review in @($ledger.reviews)) {
			$id = [string]$review.id
			$batchName = [string]$review.batchFile
			$sourceStatus = [string]$review.sourceStatus
			if ($id -notmatch '^[A-Za-z0-9_-]{3,64}$' -or $batchName -notmatch '^batch-\d{8}-\d{6}\.json$' -or -not $batchTimeByFile.ContainsKey($batchName) -or -not $statusAllowlist.Contains($sourceStatus)) {
				throw ('Invalid build-review identity or source-batch reference in ' + $reviewFile.Name)
			}
			$sourceBatchStatuses = $batchStatusesByFile[$batchName]
			if (-not $sourceBatchStatuses -or -not $sourceBatchStatuses.ContainsKey($id) -or $sourceBatchStatuses[$id] -ne $sourceStatus) {
				throw ('Build-review source status does not match its immutable batch for ' + $id)
			}
			if ($reviewedIds.ContainsKey($id)) { throw ('Duplicate paired-review audit for ' + $id) }
			if ($null -eq $review.reviewAudit -or $review.reviewAudit.trainingEligible -ne $false -or $review.reviewAudit.reviewers -notcontains 'Scout' -or $review.reviewAudit.reviewers -notcontains 'Critic') {
				throw ('Build-review sidecar lacks the independent pair or no-training gate for ' + $id)
			}
			$codeHash = [string]$review.codeSha256
			if ($codeHash -and $codeHash -notmatch '^[0-9a-fA-F]{64}$') { throw ('Invalid source-code fingerprint for ' + $id) }
			$row = New-ResultRow $id 'reviewed' ([string]$review.patch) $null ([string]$review.reason)
			if (-not $row) { throw ('Could not project paired-review row for ' + $id) }
			$skill = [string]$review.skill
			$category = [string]$review.category
			$ascendancy = [string]$review.ascendancy
			if ($skill.Length -gt 72 -or $skill -match '[\r\n\x00]' -or $ascendancy.Length -gt 40 -or $ascendancy -match '[\r\n\x00]') {
				throw ('Unbounded build identity in paired-review sidecar for ' + $id)
			}
			if ($skill) { $row.skill = $skill }
			if ($category -in @('normal', 'transfigured', 'unknown')) { $row.category = $category }
			if ($ascendancy) { $row.ascendancy = $ascendancy }
			$audit = [ordered]@{ }
			foreach ($property in $review.reviewAudit.PSObject.Properties) { $audit[$property.Name] = $property.Value }
			$audit['pairedReviewCompleted'] = $true
			$audit['sourceStatus'] = $sourceStatus
			$row['reviewAudit'] = $audit
			$auditEvents.Add([pscustomobject]@{ time = $batchTimeByFile[$batchName]; order = $eventSequence; row = $row })
			$eventSequence++
			$reviewedIds[$id] = $true
			if ($codeHash) { $reviewedCodeHashes[$codeHash.ToLowerInvariant()] = $true }
		}
	}
}

# Quality reviews are stored on archive rows, so reconstruct their current
# dashboard state even when the last-run sidecar had already been replaced.
$archiveRows = Get-Content -LiteralPath $archivePath | ForEach-Object { $_ | ConvertFrom-Json }
foreach ($archiveRow in $archiveRows) {
	$audit = $archiveRow.source.buildQualityAudit
	if (-not $audit -or -not $archiveRow.source.codePath) { continue }
	$id = [IO.Path]::GetFileNameWithoutExtension([string]$archiveRow.source.codePath) -replace '-[0-9a-f]{16}$', ''
	$archiveCodeHash = [string]$archiveRow.source.codeSha256
	if ($id -notmatch '^[A-Za-z0-9_-]{3,64}$' -or $reviewedIds.ContainsKey($id) -or ($archiveCodeHash -match '^[0-9a-fA-F]{64}$' -and $reviewedCodeHashes.ContainsKey($archiveCodeHash.ToLowerInvariant()))) { continue }
	$treeVersion = [string]$archiveRow.profile.activeSpec.treeVersion
	$patch = if ($treeVersion -match '^3_(24|25|26|27|28|29)$') { $treeVersion.Replace('_', '.') } else { $null }
	$row = New-ResultRow $id 'reviewed' $patch $null $(if ($audit.status -eq 'quarantined') { 'source_build_quality_quarantined' } else { $null })
	if (-not $row) { continue }
	if ($archiveRow.profile.mainSkill.name) { $row.skill = [string]$archiveRow.profile.mainSkill.name }
	if ($archiveRow.profile.mainSkill.category -in @('normal', 'transfigured', 'unknown')) { $row.category = [string]$archiveRow.profile.mainSkill.category }
	if ($archiveRow.profile.character.ascendancy) { $row.ascendancy = [string]$archiveRow.profile.character.ascendancy }
	$row['reviewAudit'] = [ordered]@{
		reviewers = @($audit.reviewerRoles)
		summary = [string]$audit.reviewerSummary
		reportPath = [string]$audit.reportPath
		validationScope = [string]$audit.validationScope
		mainSkillCoverageEligible = $audit.mainSkillCoverageEligible -eq $true
		fullBuildStatus = [string]$audit.fullBuildStatus
		trainingEligible = $audit.trainingEligible -eq $true
		ideas = @($audit.reviewerIdeas)
		pairedReviewCompleted = $true
		sourceStatus = 'archived'
	}
	$reviewedIds[$id] = $true
	# Use the original intake batch timestamp when available. Unmatched archive
	# audits sort first because they have no reliable review timestamp, so they
	# cannot crowd recent source and paired-review events out of the dashboard.
	$reviewTime = if ($batchTimeById.ContainsKey($id)) { $batchTimeById[$id] } else { [DateTimeOffset]::MinValue }
	$auditEvents.Add([pscustomobject]@{ time = $reviewTime; order = $eventSequence; row = $row })
	$eventSequence++
}

$allRows = [Collections.Generic.List[object]]::new()
foreach ($event in $events) { $allRows.Add($event) }
foreach ($event in $auditEvents) { $allRows.Add($event) }
$orderedEvents = @($allRows | Sort-Object @{ Expression = 'time' }, @{ Expression = 'order' })
$lines = [Collections.Generic.List[string]]::new()
foreach ($event in $orderedEvents) {
	$encoded = $event.row | ConvertTo-Json -Depth 4 -Compress
	if ($encoded.Length -gt 4096) { throw 'A reconstructed dashboard result exceeds the per-row size limit.' }
	$lines.Add($encoded)
}

if ($PSCmdlet.ShouldProcess($resultsPath, ('rebuild ' + $lines.Count + ' dashboard history rows'))) {
	$utf8NoBom = [Text.UTF8Encoding]::new($false)
	$backupPath = $resultsPath + '.before-history-rebuild-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
	if (Test-Path -LiteralPath $resultsPath) { Copy-Item -LiteralPath $resultsPath -Destination $backupPath }
	$tempPath = $resultsPath + '.tmp-' + [guid]::NewGuid().ToString('N')
	[IO.File]::WriteAllText($tempPath, ([string]::Join("`n", $lines) + "`n"), $utf8NoBom)
	if (Test-Path -LiteralPath $resultsPath) { Move-Item -LiteralPath $tempPath -Destination $resultsPath -Force }
	else { Move-Item -LiteralPath $tempPath -Destination $resultsPath }
	$written = @(Get-Content -LiteralPath $resultsPath | ForEach-Object { $_ | ConvertFrom-Json })
	if ($written.Count -ne $lines.Count -or @($written | Where-Object { $_.schema -ne 'pob-ai-planner-ingestion-result' -or $_.schemaVersion -ne 1 }).Count -gt 0) {
		throw 'Rebuilt dashboard history did not pass its read-back validation.'
	}
	Write-Output ('History rows: ' + $written.Count)
	if (Test-Path -LiteralPath $backupPath) { Write-Output ('Previous history backup: ' + $backupPath) }
} else {
	Write-Output ('Would write history rows: ' + $lines.Count)
}
