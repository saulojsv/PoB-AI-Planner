[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$CatalogCsvPath,
	[string]$BuildsIndexPath = (Join-Path $env:USERPROFILE 'Documents/Path of Building/OptimizerStudies/Builds/builds.jsonl'),
	[string]$OutputDirectory = (Join-Path $env:USERPROFILE 'Documents/Path of Building/OptimizerStudies/BuildIngestion'),
	[string]$ValidationEvidencePath,
	[Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$SnapshotId,
	[ValidateRange(1, 100)][int]$TargetPerIdentity = 10,
	[ValidateRange(0, 1000000)][int]$InitialMissingPositions = 5914
)

$ErrorActionPreference = 'Stop'

foreach ($path in @($CatalogCsvPath, $BuildsIndexPath, $OutputDirectory)) {
	if (-not (Test-Path -LiteralPath $path)) { throw "Required path does not exist: $path" }
}

$catalogRows = @(Import-Csv -LiteralPath $CatalogCsvPath)
if ($catalogRows.Count -ne 627) { throw "Expected 627 3.29 catalog identities; found $($catalogRows.Count)." }
$catalogByKey = @{}
foreach ($row in $catalogRows) {
	if ([string]$row.patch -ne '3.29' -or [string]::IsNullOrWhiteSpace([string]$row.variantKey)) {
		throw 'The catalog snapshot must contain exact 3.29 variant keys.'
	}
	if ($catalogByKey.ContainsKey([string]$row.variantKey)) { throw "Duplicate catalog identity: $($row.variantKey)" }
	$catalogByKey[[string]$row.variantKey] = $row
}

$lineagesByIdentity = @{}
$globalLineageHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$completeProfileCount = 0
$excludedProfileCount = 0
$unmappedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$acceptedReadiness = @('native_profile_complete', 'native_active_profile_complete_source_xml_preserved')
$validationEvidenceByLineage = @{}
$revalidatedLineages = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
if (-not [string]::IsNullOrWhiteSpace($ValidationEvidencePath)) {
	if (-not (Test-Path -LiteralPath $ValidationEvidencePath -PathType Leaf)) { throw "Validation evidence does not exist: $ValidationEvidencePath" }
	$validationEvidence = Get-Content -LiteralPath $ValidationEvidencePath -Raw | ConvertFrom-Json -ErrorAction Stop
	if ($validationEvidence.schema -ne 'pob-ai-planner-native-coverage-revalidation' -or
		[int]$validationEvidence.schemaVersion -ne 1 -or
		@($validationEvidence.records).Count -eq 0) {
		throw 'Validation evidence has an unsupported schema or no records.'
	}
	foreach ($evidence in $validationEvidence.records) {
		$lineage = [string]$evidence.lineageSha256
		if ($lineage -notmatch '^[0-9a-fA-F]{64}$' -or $validationEvidenceByLineage.ContainsKey($lineage)) {
			throw "Validation evidence has an invalid or duplicate lineage: $lineage"
		}
		if ([string]$evidence.validationMethod -ne 'local_xml_native_revalidation' -or
			[bool]$evidence.sourceXmlSha256Matched -ne $true -or
			[string]$evidence.validationResultStatus -notin @('archived', 'already_archived', 'already_archived_duplicate_lineage') -or
			[string]$evidence.mainSkillStatus -ne 'identified' -or
			[string]$evidence.mainSkillResolutionStatus -ne 'selected_main_skill_identified' -or
			[string]$evidence.archiveReadinessStatus -notin $acceptedReadiness -or
			[string]$evidence.nativeTreeVersion -ne '3_29' -or
			[string]$evidence.mainSkillKey -notmatch '^Metadata/.+\|[^|]+$' -or
			[string]$evidence.sourceXmlSha256 -notmatch '^[0-9a-fA-F]{64}$') {
			throw "Validation evidence does not meet native profile requirements for lineage $lineage."
		}
		$validationEvidenceByLineage[$lineage] = $evidence
	}
}

foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $BuildsIndexPath).Path)) {
	if ([string]::IsNullOrWhiteSpace($line)) { continue }
	$record = ConvertFrom-Json -InputObject $line -ErrorAction Stop
	$profile = $record.profile
	if (-not $profile -or [string]$profile.activeSpec.treeVersion -ne '3_29') { continue }
	$profileIsComplete = [string]$profile.archiveReadinessStatus -in $acceptedReadiness -and
		[string]$profile.mainSkillStatus -eq 'identified' -and
		[string]$profile.mainSkillResolutionStatus -eq 'selected_main_skill_identified'
	if (-not $profileIsComplete) {
		$lineage = [string]$record.lineageSha256
		$evidence = $null
		if ($validationEvidenceByLineage.ContainsKey($lineage)) { $evidence = $validationEvidenceByLineage[$lineage] }
		$profileSkill = $profile.mainSkill
		$profileSkillKey = if ($profileSkill -and $profileSkill.gameId -and $profileSkill.variantId) { [string]$profileSkill.gameId + '|' + [string]$profileSkill.variantId } else { '' }
		$recordSourceHash = [string]$record.source.sourceXmlSha256
		if ($evidence -and
			$profileSkillKey -eq [string]$evidence.mainSkillKey -and
			$recordSourceHash -match '^[0-9a-fA-F]{64}$' -and
			$recordSourceHash.Equals([string]$evidence.sourceXmlSha256, [StringComparison]::OrdinalIgnoreCase)) {
			$profileIsComplete = $true
			[void]$revalidatedLineages.Add($lineage)
		}
	}
	if (-not $profileIsComplete) {
		$excludedProfileCount++
		continue
	}
	$mainSkill = $profile.mainSkill
	if (-not $mainSkill -or [string]::IsNullOrWhiteSpace([string]$mainSkill.gameId) -or
		[string]::IsNullOrWhiteSpace([string]$mainSkill.variantId) -or
		[string]::IsNullOrWhiteSpace([string]$record.lineageSha256)) {
		$excludedProfileCount++
		continue
	}
	$completeProfileCount++
	$identityKey = [string]$mainSkill.gameId + '|' + [string]$mainSkill.variantId
	if (-not $catalogByKey.ContainsKey($identityKey)) {
		[void]$unmappedKeys.Add($identityKey)
		continue
	}
	if (-not $lineagesByIdentity.ContainsKey($identityKey)) {
		$lineagesByIdentity[$identityKey] = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
	}
	$lineageHash = [string]$record.lineageSha256
	[void]$globalLineageHashes.Add($lineageHash)
	$identityLineages = $lineagesByIdentity[$identityKey]
	if (-not $identityLineages.ContainsKey($lineageHash)) {
		$identityLineages[$lineageHash] = [pscustomobject]@{
			observationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
			sourceReferences = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
		}
	}
	$lineageRecord = $identityLineages[$lineageHash]
	if (-not [string]::IsNullOrWhiteSpace([string]$record.observationId)) { [void]$lineageRecord.observationIds.Add([string]$record.observationId) }
	$sourceReference = [string]$record.source.reference
	if ([string]::IsNullOrWhiteSpace($sourceReference)) { $sourceReference = [string]$record.source.sourceUrl }
	if (-not [string]::IsNullOrWhiteSpace($sourceReference)) { [void]$lineageRecord.sourceReferences.Add($sourceReference) }
}

if ($unmappedKeys.Count -gt 0) {
	throw "Found $($unmappedKeys.Count) exact native skill identities outside the supplied catalog: $(@($unmappedKeys) -join ', ')"
}

$coverageRows = [Collections.Generic.List[object]]::new()
$queueRows = [Collections.Generic.List[object]]::new()
$missingRows = [Collections.Generic.List[object]]::new()
$ledgerRows = [Collections.Generic.List[object]]::new()
$positionTarget = 0
$positionsRemaining = 0
$identitiesAtTarget = 0
$identitiesWithBuilds = 0
$distinctLineageAssignments = 0

foreach ($catalogRow in $catalogRows) {
	$identityKey = [string]$catalogRow.variantKey
	$lineages = @{}
	if ($lineagesByIdentity.ContainsKey($identityKey)) { $lineages = $lineagesByIdentity[$identityKey] }
	$distinctCount = $lineages.Count
	$remaining = [Math]::Max(0, $TargetPerIdentity - $distinctCount)
	$positionTarget += $TargetPerIdentity
	$positionsRemaining += $remaining
	$distinctLineageAssignments += $distinctCount
	if ($distinctCount -gt 0) { $identitiesWithBuilds++ }
	if ($remaining -eq 0) { $identitiesAtTarget++ }
	$coverageRows.Add([pscustomobject][ordered]@{
		patch = [string]$catalogRow.patch
		category = [string]$catalogRow.category
		skill = [string]$catalogRow.skill
		gameId = [string]$catalogRow.gameId
		variantId = [string]$catalogRow.variantId
		variantKey = $identityKey
		distinctLineages = $distinctCount
		inPlannerTarget = [string]$catalogRow.inPlannerTarget
		target = $TargetPerIdentity
		remaining = $remaining
	})
	if ($remaining -gt 0) {
		$queueRows.Add([pscustomobject][ordered]@{
			patch = [string]$catalogRow.patch
			category = [string]$catalogRow.category
			skill = [string]$catalogRow.skill
			gameId = [string]$catalogRow.gameId
			variantId = [string]$catalogRow.variantId
			variantKey = $identityKey
			distinctLineages = $distinctCount
			inPlannerTarget = [string]$catalogRow.inPlannerTarget
			target = $TargetPerIdentity
			remaining = $remaining
		})
		for ($ordinal = $distinctCount + 1; $ordinal -le $TargetPerIdentity; $ordinal++) {
			$missingRows.Add([pscustomobject][ordered]@{
				patch = [string]$catalogRow.patch
				category = [string]$catalogRow.category
				skill = [string]$catalogRow.skill
				gameId = [string]$catalogRow.gameId
				variantId = [string]$catalogRow.variantId
				variantKey = $identityKey
				currentDistinctLineages = $distinctCount
				positionNumber = $ordinal
				inPlannerTarget = [string]$catalogRow.inPlannerTarget
			})
		}
	}
	foreach ($lineageHash in $lineages.Keys) {
		$lineageRecord = $lineages[$lineageHash]
		$ledgerRows.Add([pscustomobject][ordered]@{
			patch = [string]$catalogRow.patch
			category = [string]$catalogRow.category
			skill = [string]$catalogRow.skill
			gameId = [string]$catalogRow.gameId
			variantId = [string]$catalogRow.variantId
			variantKey = $identityKey
			lineageSha256 = $lineageHash
			sourceObservationCount = $lineageRecord.observationIds.Count
			sourceReferences = (@($lineageRecord.sourceReferences) | Sort-Object) -join ';'
		})
	}
}

if ($coverageRows.Count -ne 627 -or $positionTarget -ne 6270 -or $missingRows.Count -ne $positionsRemaining) {
	throw 'Coverage row, target-position, and missing-position totals failed reconciliation.'
}

$stamp = $SnapshotId
$prefix = "ManualCoverage-3.29-AllCatalog-current-$stamp"
$paths = [ordered]@{
	coverage = Join-Path $OutputDirectory "$prefix.csv"
	queue = Join-Path $OutputDirectory "ManualCoverageQueue-3.29-AllCatalog-current-$stamp.csv"
	missing = Join-Path $OutputDirectory "ManualCoverageMissingPositions-3.29-AllCatalog-current-$stamp.csv"
	ledger = Join-Path $OutputDirectory "ManualCoverageLineageLedger-3.29-AllCatalog-current-$stamp.csv"
	summary = Join-Path $OutputDirectory "ManualCoverageSummary-3.29-AllCatalog-current-$stamp.json"
}
foreach ($outputPath in $paths.Values) {
	if (Test-Path -LiteralPath $outputPath) { throw "Refusing to overwrite an existing snapshot: $outputPath" }
}

$coverageRows | Sort-Object category,skill,variantId | Export-Csv -LiteralPath $paths.coverage -NoTypeInformation -Encoding utf8
$queueRows | Sort-Object -Property @{ Expression = 'remaining'; Ascending = $true }, @{ Expression = 'distinctLineages'; Descending = $true }, skill, variantId | Export-Csv -LiteralPath $paths.queue -NoTypeInformation -Encoding utf8
$missingRows | Sort-Object -Property category,skill,variantId,positionNumber | Export-Csv -LiteralPath $paths.missing -NoTypeInformation -Encoding utf8
$ledgerRows | Sort-Object category,skill,variantId,lineageSha256 | Export-Csv -LiteralPath $paths.ledger -NoTypeInformation -Encoding utf8

$summary = [ordered]@{
	schema = 'pob-ai-planner-manual-coverage-reconciliation'
	schemaVersion = 1
	generatedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
	patch = '3.29'
	countingRule = 'distinct native lineageSha256 per exact main-skill gameId|variantId; active native tree 3_29; native-complete profile and selected Main Skill resolved by PoB'
	collectionScope = 'broad native archive coverage; event and nonstandard ascendancy profiles count here, while strict AI Planner coverage is reported separately'
	targetPerIdentity = $TargetPerIdentity
	catalogIdentities = $coverageRows.Count
	totalTargetPositions = $positionTarget
	identitiesWithBuilds = $identitiesWithBuilds
	identitiesAtTarget = $identitiesAtTarget
	identitiesBelowTarget = $coverageRows.Count - $identitiesAtTarget
	totalDistinctNativeLineages = $globalLineageHashes.Count
	totalVariantLineagePairs = $distinctLineageAssignments
	rawSlotsRemaining = $positionsRemaining
	reportedInitialSlots = $InitialMissingPositions
	rawSlotsFilledSinceInitial = $InitialMissingPositions - $positionsRemaining
	profilesWithNativeComplete3_29TreeAndResolvedMain = $completeProfileCount
	profilesExcludedByCompletenessOrResolution = $excludedProfileCount
	profilesCompletedByNativeRevalidationEvidence = $revalidatedLineages.Count
	validationEvidence = if ([string]::IsNullOrWhiteSpace($ValidationEvidencePath)) { $null } else { (Resolve-Path -LiteralPath $ValidationEvidencePath).Path }
	unmappedSkillKeys = 0
	allCatalogCoverageCsv = $paths.coverage
	priorityQueueCsv = $paths.queue
	missingPositionsCsv = $paths.missing
	lineageLedgerCsv = $paths.ledger
	sourceArchiveIndex = (Resolve-Path -LiteralPath $BuildsIndexPath).Path
	priorCoverageCatalog = (Resolve-Path -LiteralPath $CatalogCsvPath).Path
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $paths.summary -Encoding utf8

[pscustomobject]$summary | ConvertTo-Json -Depth 8
