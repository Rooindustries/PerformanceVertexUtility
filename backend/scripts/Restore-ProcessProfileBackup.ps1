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
        currentControlState = Get-RooProcessControlState $processId $null
        currentPath = $currentPath
        blockedReason = if ($nameMatches -and $pathMatches) { $null } else { 'Live process identity does not match the backup snapshot.' }
    }
}

function New-RestoreSkippedItem {
    param(
        [object]$Entry,
        [string]$Reason,
        [object[]]$ControlChanges = @(),
        [string]$Category = 'skipped'
    )
    return [pscustomobject]@{
        processId = Get-RooPropertyValue $Entry 'processId' 0
        processName = Get-RooPropertyValue $Entry 'processName' ''
        controlChanges = @(Get-RooArray $ControlChanges)
        category = $Category
        reason = $Reason
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
    $originalAffinityMask = Get-RooPropertyValue $Snapshot 'originalAffinityMask' $null
    $originalIoPriority = Get-RooPropertyValue $Snapshot 'originalIoPriority' $null
    $originalGpuPriority = Get-RooPropertyValue $Snapshot 'originalGpuPriority' $null
    $currentState = Get-RooPropertyValue $Candidate 'currentControlState' $null
    $currentPriority = if ($currentState) { Get-RooPropertyValue $currentState 'priorityClass' $Candidate.currentPriorityClass } else { $Candidate.currentPriorityClass }
    $currentAffinityMask = if ($currentState) { Get-RooPropertyValue $currentState 'affinityMask' $null } else { $null }
    $currentIoPriority = if ($currentState) { Get-RooPropertyValue $currentState 'ioPriority' $null } else { $null }
    $currentGpuPriority = if ($currentState) { Get-RooPropertyValue $currentState 'gpuPriority' $null } else { $null }
    $blocked = (-not $Candidate.exists) -or (-not $Candidate.matches) -or (-not (Test-RooPriorityAllowed $originalPriority))
    $reason = if ($blocked) {
        if (-not (Test-RooPriorityAllowed $originalPriority)) {
            "Original priority class '$originalPriority' is outside the allow-list."
        } else {
            [string]$Candidate.blockedReason
        }
    } else {
        'Restore original process controls captured before apply.'
    }
    $controlChanges = New-Object System.Collections.Generic.List[object]
    if (-not $blocked) {
        if (-not [string]::IsNullOrWhiteSpace($originalPriority) -and (Test-RooPriorityAllowed $originalPriority) -and [string]$currentPriority -ne [string]$originalPriority) {
            $controlChanges.Add((New-RooControlChange 'priorityClass' $currentPriority $originalPriority 'restorePriority' 'Restore original process priority.')) | Out-Null
        }
        if ($null -ne $originalAffinityMask -and (Test-RooAffinityMaskAllowed $originalAffinityMask) -and [string]$currentAffinityMask -ne [string]$originalAffinityMask) {
            $controlChanges.Add((New-RooControlChange 'affinityMask' $currentAffinityMask ([int64]$originalAffinityMask) 'restoreAffinity' 'Restore original CPU affinity.')) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$originalIoPriority) -and (Test-RooIoPriorityAllowed $originalIoPriority) -and [string]$currentIoPriority -ne [string]$originalIoPriority) {
            $controlChanges.Add((New-RooControlChange 'ioPriority' $currentIoPriority $originalIoPriority 'restoreIoPriority' 'Restore original I/O priority.')) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$originalGpuPriority) -and (Test-RooGpuPriorityAllowed $originalGpuPriority) -and [string]$currentGpuPriority -ne [string]$originalGpuPriority) {
            if ([bool](Get-RooPropertyValue $currentState 'gpuPriorityAvailable' $false)) {
                $controlChanges.Add((New-RooControlChange 'gpuPriority' $currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'Restore original GPU scheduling priority.')) | Out-Null
            } else {
                $blocked = $true
                $reason = 'GPU scheduling priority is unavailable for this restore target.'
                $controlChanges.Add((New-RooControlChange 'gpuPriority' $currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'GPU scheduling priority is unavailable for this restore target.' $true $reason)) | Out-Null
            }
        }
        if ($controlChanges.Count -eq 0) {
            $reason = 'Process already matches the process profile backup.'
        }
    }
    $restorePlan = Get-RooApplicableProcessControlChanges @($controlChanges.ToArray()) $currentState
    $applicableControlChanges = @(Get-RooPropertyArray $restorePlan 'changes')
    $proposedAction = if ($blocked -or $applicableControlChanges.Count -eq 0) { 'noChange' } elseif ($applicableControlChanges.Count -eq 1 -and [string](Get-RooPropertyValue $applicableControlChanges[0] 'control' '') -eq 'priorityClass') { 'restorePriority' } else { 'restoreProcessControls' }

    return [pscustomobject]@{
        previewId = ("rollback-$processName-$processId").ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = if ($controlChanges.Count -gt 1) { 'processControlsRollback' } else { 'processPriorityRollback' }
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooPropertyValue $Snapshot 'executablePath' $null
        currentPriorityClass = $currentPriority
        proposedPriorityClass = if ($blocked) { $currentPriority } else { $originalPriority }
        currentAffinityMask = $currentAffinityMask
        proposedAffinityMask = if ($blocked) { $currentAffinityMask } else { $originalAffinityMask }
        currentIoPriority = $currentIoPriority
        proposedIoPriority = if ($blocked) { $currentIoPriority } else { $originalIoPriority }
        currentGpuPriority = $currentGpuPriority
        proposedGpuPriority = if ($blocked) { $currentGpuPriority } else { $originalGpuPriority }
        gpuPriorityAvailable = Get-RooPropertyValue $currentState 'gpuPriorityAvailable' $false
        gpuPriorityStatus = Get-RooPropertyValue $currentState 'gpuPriorityStatus' $null
        proposedAction = $proposedAction
        controlChanges = @($controlChanges.ToArray())
        ruleId = [string](Get-RooPropertyValue $Snapshot 'ruleId' '')
        reason = $reason
        reasonCodes = if ($blocked) { @('ROLLBACK_SKIPPED') } else { @('ROLLBACK_PROCESS_CONTROLS_RESTORE') }
        classification = 'rollbackCandidate'
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = 'low'
        confidence = 'medium'
        protected = $false
        requiresConfirmation = ($applicableControlChanges.Count -gt 0 -and -not $blocked)
        rollbackSupported = ($applicableControlChanges.Count -gt 0 -and -not $blocked)
        currentState = [pscustomobject]@{
            priorityClass = $currentPriority
            affinityMask = $currentAffinityMask
            ioPriority = $currentIoPriority
            gpuPriority = $currentGpuPriority
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked) { $currentPriority } else { $originalPriority }
            affinityMask = if ($blocked) { $currentAffinityMask } else { $originalAffinityMask }
            ioPriority = if ($blocked) { $currentIoPriority } else { $originalIoPriority }
            gpuPriority = if ($blocked) { $currentGpuPriority } else { $originalGpuPriority }
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
            type = 'processControls'
            target = "$([string](Get-RooPropertyValue $snap 'processName' ''))`:$([int](Get-RooPropertyValue $snap 'processId' 0))"
            originalState = [pscustomobject]@{
                priorityClass = Get-RooPropertyValue $snap 'originalPriorityClass' $null
                affinityMask = Get-RooPropertyValue $snap 'originalAffinityMask' $null
                ioPriority = Get-RooPropertyValue $snap 'originalIoPriority' $null
                gpuPriority = Get-RooPropertyValue $snap 'originalGpuPriority' $null
                proposedPriorityClass = Get-RooPropertyValue $snap 'proposedPriorityClass' $null
                proposedAffinityMask = Get-RooPropertyValue $snap 'proposedAffinityMask' $null
                proposedIoPriority = Get-RooPropertyValue $snap 'proposedIoPriority' $null
                proposedGpuPriority = Get-RooPropertyValue $snap 'proposedGpuPriority' $null
            }
        }) | Out-Null
    }

    return [pscustomobject]@{
        backupId = [string](Get-RooPropertyValue $Backup 'backupId' '')
        scope = 'process-profile-process-controls'
        createdAtUtc = [string](Get-RooPropertyValue $Backup 'createdAtUtc' '')
        location = $ResolvedBackupPath
        restorePoint = [pscustomobject]@{
            requested = $false
            status = 'not-required-for-process-controls'
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
                $skipped.Add((New-RestoreSkippedItem $entry (Get-RooPropertyValue $entry 'blockedReason' 'Rollback entry is blocked.') @(Get-RooPreviewControlChanges $entry) 'blocked')) | Out-Null
                continue
            }

            $processId = [int](Get-RooPropertyValue $entry 'processId' 0)
            $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -eq $live) {
                $skipped.Add((New-RestoreSkippedItem $entry 'Process exited before rollback.' @(Get-RooPreviewControlChanges $entry) 'exited')) | Out-Null
                continue
            }

            $entryControlChanges = @(Get-RooPreviewControlChanges $entry | Where-Object { -not [bool](Get-RooPropertyValue $_ 'blocked' $false) })
            if ($entryControlChanges.Count -eq 0) { continue }
            $appliedControls = New-Object System.Collections.Generic.List[object]
            $failedControls = New-Object System.Collections.Generic.List[string]
            try {
                foreach ($change in $entryControlChanges) {
                    try {
                        Invoke-RooProcessControlChange $live $change
                        $appliedControls.Add($change) | Out-Null
                    } catch {
                        $failedControls.Add("$([string](Get-RooPropertyValue $change 'control' 'unknown')): $($_.Exception.Message)") | Out-Null
                    }
                }
                if ($appliedControls.Count -gt 0) {
                    $afterControls = Get-RooProcessControlState $processId $null
                    $changed.Add([pscustomobject]@{
                        processId = $processId
                        processName = Get-RooPropertyValue $entry 'processName' ''
                        restoredPriorityClass = $afterControls.priorityClass
                        restoredAffinityMask = $afterControls.affinityMask
                        restoredIoPriority = $afterControls.ioPriority
                        restoredGpuPriority = $afterControls.gpuPriority
                        restoredControls = @($appliedControls.ToArray())
                        ruleId = Get-RooPropertyValue $entry 'ruleId' ''
                    }) | Out-Null
                }
                if ($failedControls.Count -gt 0) {
                    $skipped.Add((New-RestoreSkippedItem $entry ($failedControls -join '; ') $entryControlChanges 'restore-failed')) | Out-Null
                }
            } catch {
                $skipped.Add((New-RestoreSkippedItem $entry $_.Exception.Message $entryControlChanges 'restore-failed')) | Out-Null
            }
        }
    } else {
        foreach ($entry in @($previewEntries.ToArray())) {
            if ([bool](Get-RooPropertyValue $entry 'blocked' $false)) {
                $skipped.Add((New-RestoreSkippedItem $entry (Get-RooPropertyValue $entry 'blockedReason' 'Rollback entry is blocked.') @(Get-RooPreviewControlChanges $entry) 'blocked')) | Out-Null
            }
        }
    }

    $status = if ($ConfirmApply) { 'success' } else { 'preview' }
    if ($ConfirmApply -and $changed.Count -eq 0 -and $skipped.Count -gt 0) { $status = 'failed' }
    if ($ConfirmApply -and $changed.Count -gt 0 -and $skipped.Count -gt 0) { $status = 'partial' }

    $summary = if ($ConfirmApply) {
        "Rollback completed with $($changed.Count) restored process(es) and $($skipped.Count) skipped item(s)."
    } else {
        "Rollback preview completed. No process control changes were applied."
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
