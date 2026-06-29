param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,
    [string]$OutputPath = '',
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Get-RestoreCandidate {
    param([object]$Snapshot)
    $processId = [int](Get-RooPropertyValue $Snapshot 'processId' 0)
    $expectedName = [string](Get-RooPropertyValue $Snapshot 'processName' '')
    $expectedPath = Get-RooPropertyValue $Snapshot 'executablePath' $null
    $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $live) {
        return [pscustomobject]@{
            exists = $false
            matches = $false
            process = $null
            currentPriorityClass = $null
            currentPath = $null
            blockedReason = 'Process is no longer running.'
        }
    }

    $currentPath = $null
    try { $currentPath = $live.Path } catch { $currentPath = $null }
    $nameMatches = Test-RooProcessNameEquals $live.ProcessName $expectedName
    $pathMatches = $true
    if (-not [string]::IsNullOrWhiteSpace([string]$expectedPath) -and -not [string]::IsNullOrWhiteSpace([string]$currentPath)) {
        $pathMatches = ([string]$expectedPath -eq [string]$currentPath)
    }

    return [pscustomobject]@{
        exists = $true
        matches = ($nameMatches -and $pathMatches)
        process = $live
        currentPriorityClass = [string]$live.PriorityClass
        currentPath = $currentPath
        blockedReason = if ($nameMatches -and $pathMatches) { $null } else { 'Live process identity does not match the backup snapshot.' }
    }
}

function New-RollbackPreviewEntry {
    param(
        [object]$Snapshot,
        [object]$Candidate
    )

    $processId = [int](Get-RooPropertyValue $Snapshot 'processId' 0)
    $processName = [string](Get-RooPropertyValue $Snapshot 'processName' '')
    $originalPriority = [string](Get-RooPropertyValue $Snapshot 'originalPriorityClass' '')
    $blocked = (-not $Candidate.exists) -or (-not $Candidate.matches) -or (-not (Test-RooPriorityAllowed $originalPriority))
    $reason = if ($blocked) {
        if (-not (Test-RooPriorityAllowed $originalPriority)) {
            "Original priority class '$originalPriority' is outside the MVP allow-list."
        } else {
            [string]$Candidate.blockedReason
        }
    } else {
        'Restore the original process priority class captured before apply.'
    }

    return [pscustomobject]@{
        previewId = ("rollback-$processName-$processId").ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = 'processPriorityRollback'
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooPropertyValue $Snapshot 'executablePath' $null
        currentPriorityClass = $Candidate.currentPriorityClass
        proposedPriorityClass = if ($blocked) { $Candidate.currentPriorityClass } else { $originalPriority }
        proposedAction = if ($blocked) { 'noChange' } else { 'restorePriority' }
        ruleId = [string](Get-RooPropertyValue $Snapshot 'ruleId' '')
        reason = $reason
        reasonCodes = if ($blocked) { @('ROLLBACK_SKIPPED') } else { @('ROLLBACK_PRIORITY_RESTORE') }
        classification = 'rollbackCandidate'
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = 'low'
        confidence = 'medium'
        protected = $false
        requiresConfirmation = (-not $blocked)
        rollbackSupported = (-not $blocked)
        currentState = [pscustomobject]@{
            priorityClass = $Candidate.currentPriorityClass
        }
        proposedState = [pscustomobject]@{
            action = if ($blocked) { 'noChange' } else { 'restorePriority' }
            priorityClass = if ($blocked) { $Candidate.currentPriorityClass } else { $originalPriority }
            reason = $reason
        }
        impact = [pscustomobject]@{
            expectedMemoryEffectBytes = 0
            expectedCpuWakeupEffect = 'neutral'
            targetMetrics = @('rollback-safety')
        }
        rollback = $null
    }
}

function New-BackupEnvelopeMetadata {
    param(
        [object]$Backup,
        [string]$ResolvedBackupPath
    )
    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($snap in @(Get-RooPropertyArray $Backup 'snapshots')) {
        $snapshots.Add([pscustomobject]@{
            type = 'processPriority'
            target = "$([string](Get-RooPropertyValue $snap 'processName' ''))`:$([int](Get-RooPropertyValue $snap 'processId' 0))"
            originalState = [pscustomobject]@{
                priorityClass = Get-RooPropertyValue $snap 'originalPriorityClass' $null
                proposedPriorityClass = Get-RooPropertyValue $snap 'proposedPriorityClass' $null
            }
        }) | Out-Null
    }

    return [pscustomobject]@{
        backupId = [string](Get-RooPropertyValue $Backup 'backupId' '')
        scope = 'process-priority-profile'
        createdAtUtc = [string](Get-RooPropertyValue $Backup 'createdAtUtc' '')
        location = $ResolvedBackupPath
        restorePoint = [pscustomobject]@{
            requested = $false
            status = 'not-required-for-process-priority'
            id = $null
        }
        snapshots = @($snapshots.ToArray())
        rollbackActionId = 'performance.rollbackProfile'
        rollbackSupported = $true
        retentionPolicy = [pscustomobject]@{
            keepLatestCount = 10
            minimumDays = 14
        }
    }
}

try {
    $resolvedBackupPath = Resolve-RooPath $BackupPath $BackupPath
    $backup = Read-RooJsonFile $resolvedBackupPath

    $previewEntries = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @(Get-RooPropertyArray $backup 'snapshots')) {
        $candidate = Get-RestoreCandidate $snapshot
        $previewEntries.Add((New-RollbackPreviewEntry $snapshot $candidate)) | Out-Null
    }

    $changed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]

    if ($ConfirmApply) {
        foreach ($entry in @($previewEntries.ToArray())) {
            if ([bool](Get-RooPropertyValue $entry 'blocked' $false)) {
                $skipped.Add([pscustomobject]@{
                    processId = Get-RooPropertyValue $entry 'processId' 0
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = Get-RooPropertyValue $entry 'blockedReason' 'Rollback entry is blocked.'
                }) | Out-Null
                continue
            }

            $processId = [int](Get-RooPropertyValue $entry 'processId' 0)
            $desiredPriority = [string](Get-RooPropertyValue $entry 'proposedPriorityClass' '')
            $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -eq $live) {
                $skipped.Add([pscustomobject]@{
                    processId = $processId
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = 'Process exited before rollback.'
                }) | Out-Null
                continue
            }

            try {
                $live.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$desiredPriority
                $changed.Add([pscustomobject]@{
                    processId = $processId
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    restoredPriorityClass = $desiredPriority
                    ruleId = Get-RooPropertyValue $entry 'ruleId' ''
                }) | Out-Null
            } catch {
                $skipped.Add([pscustomobject]@{
                    processId = $processId
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = $_.Exception.Message
                }) | Out-Null
            }
        }
    } else {
        foreach ($entry in @($previewEntries.ToArray())) {
            if ([bool](Get-RooPropertyValue $entry 'blocked' $false)) {
                $skipped.Add([pscustomobject]@{
                    processId = Get-RooPropertyValue $entry 'processId' 0
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = Get-RooPropertyValue $entry 'blockedReason' 'Rollback entry is blocked.'
                }) | Out-Null
            }
        }
    }

    $status = if ($ConfirmApply) { 'success' } else { 'preview' }
    if ($ConfirmApply -and $changed.Count -eq 0 -and ($previewEntries.Count -gt 0 -or $skipped.Count -gt 0)) { $status = 'failed' }
    if ($ConfirmApply -and $changed.Count -gt 0 -and $skipped.Count -gt 0) { $status = 'partial' }

    $summary = if ($ConfirmApply) {
        "Rollback completed with $($changed.Count) restored process(es) and $($skipped.Count) skipped item(s)."
    } else {
        "Rollback preview completed. No process priority changes were applied."
    }

    $result = New-RooActionResult `
        -ResultId ("rollback-" + (Get-RooFileStamp)) `
        -Status $status `
        -Summary $summary `
        -ChangedItems @($changed.ToArray()) `
        -SkippedItems @($skipped.ToArray()) `
        -Artifacts @([pscustomobject]@{ type = 'processProfileBackup'; path = $resolvedBackupPath })

    $warnings = New-Object System.Collections.Generic.List[object]
    if (-not $ConfirmApply) {
        $warnings.Add((New-RooIssue 'ROLLBACK_PREVIEW_ONLY' 'Rollback preview did not change any process because -ConfirmApply was omitted.' 'info' 'performance.rollback' $resolvedBackupPath $false 'Rerun with -ConfirmApply only after reviewing the rollback preview.' $null)) | Out-Null
    }

    $envelope = New-RooActionEnvelope `
        -ActionId 'performance.rollbackProfile' `
        -DryRun (-not $ConfirmApply) `
        -Risk 'low' `
        -RequiresElevation $false `
        -Status $status `
        -Preview @($previewEntries.ToArray()) `
        -Backup (New-BackupEnvelopeMetadata $backup $resolvedBackupPath) `
        -Result $result `
        -Warnings @($warnings.ToArray()) `
        -Errors @() `
        -Logs @((New-RooLog $summary))

    Write-RooJsonOutput $envelope $OutputPath
} catch {
    $envelope = New-RooActionEnvelope `
        -ActionId 'performance.rollbackProfile' `
        -DryRun (-not $ConfirmApply) `
        -Risk 'low' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIssue 'PROCESS_PROFILE_ROLLBACK_FAILED' $_.Exception.Message 'error' 'performance.rollback' $BackupPath $true 'Check the backup path and retry.' $null)) `
        -Logs @((New-RooLog 'Rollback failed.' 'error'))
    Write-RooJsonOutput $envelope $OutputPath
    exit 1
}
