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
    $processId = [int](Get-RooIndustriesPropertyValue $Snapshot 'processId' 0)
    $expectedName = [string](Get-RooIndustriesPropertyValue $Snapshot 'processName' '')
    $expectedPath = Get-RooIndustriesPropertyValue $Snapshot 'executablePath' $null
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
    $nameMatches = Test-RooIndustriesProcessNameEquals $live.ProcessName $expectedName
    $pathMatches = $true
    if (-not [string]::IsNullOrWhiteSpace([string]$expectedPath)) {
        $pathMatches = ([string]$expectedPath -eq [string]$currentPath)
    }
    $controlState = Get-RooIndustriesProcessControlState $processId $null -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $Snapshot)
    $startMatches = Test-RooIndustriesProcessStartTime (Get-RooIndustriesPropertyValue $Snapshot 'processStartTimeUtc' $null) $controlState.startTimeUtc

    return [pscustomobject]@{
        exists = $true
        matches = ($nameMatches -and $pathMatches -and $startMatches)
        process = $live
        currentPriorityClass = [string]$live.PriorityClass
        currentControlState = $controlState
        currentPath = $currentPath
        blockedReason = if (-not $startMatches) { 'This app was restarted, or its start time could not be verified. Nothing was restored.' } elseif ($nameMatches -and $pathMatches) { $null } else { 'Live process identity does not match the backup snapshot.' }
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
        processId = Get-RooIndustriesPropertyValue $Entry 'processId' 0
        processName = Get-RooIndustriesPropertyValue $Entry 'processName' ''
        controlChanges = @(Get-RooIndustriesArray $ControlChanges)
        category = $Category
        reason = $Reason
    }
}

function New-RollbackPreviewEntry {
    param(
        [object]$Snapshot,
        [object]$Candidate
    )

    $processId = [int](Get-RooIndustriesPropertyValue $Snapshot 'processId' 0)
    $processName = [string](Get-RooIndustriesPropertyValue $Snapshot 'processName' '')
    $originalPriority = [string](Get-RooIndustriesPropertyValue $Snapshot 'originalPriorityClass' '')
    $originalAffinityMask = Get-RooIndustriesPropertyValue $Snapshot 'originalAffinityMask' $null
    $originalIoPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalIoPriority' $null
    $originalMemoryPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalMemoryPriority' $null
    $originalGpuPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalGpuPriority' $null
    $recorded = @(Get-RooIndustriesRestorableProcessControls $Snapshot (Get-RooIndustriesPropertyValue $Candidate 'currentControlState' $null) | ForEach-Object { [string](Get-RooIndustriesPropertyValue $_ 'control' '') })
    $restoresAll = $null -eq $Snapshot.PSObject.Properties['controlChanges']
    $currentState = Get-RooIndustriesPropertyValue $Candidate 'currentControlState' $null
    $currentPriority = if ($currentState) { Get-RooIndustriesPropertyValue $currentState 'priorityClass' $Candidate.currentPriorityClass } else { $Candidate.currentPriorityClass }
    $currentAffinityMask = if ($currentState) { Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null } else { $null }
    $currentIoPriority = if ($currentState) { Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null } else { $null }
    $currentMemoryPriority = if ($currentState) { Get-RooIndustriesPropertyValue $currentState 'memoryPriority' $null } else { $null }
    $currentGpuPriority = if ($currentState) { Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null } else { $null }
    $blocked = (-not $Candidate.exists) -or (-not $Candidate.matches) -or (-not (Test-RooIndustriesPriorityAllowed $originalPriority -Restoring))
    $reason = if ($blocked) {
        if (-not (Test-RooIndustriesPriorityAllowed $originalPriority -Restoring)) {
            "Original priority class '$originalPriority' is outside the allow-list."
        } else {
            [string]$Candidate.blockedReason
        }
    } else {
        'Restore original process controls captured before apply.'
    }
    $controlChanges = New-Object System.Collections.Generic.List[object]
    if (-not $blocked) {
        if (($restoresAll -or $recorded -contains 'priorityClass') -and -not [string]::IsNullOrWhiteSpace($originalPriority) -and (Test-RooIndustriesPriorityAllowed $originalPriority -Restoring) -and [string]$currentPriority -ne [string]$originalPriority) {
            $controlChanges.Add((New-RooIndustriesControlChange 'priorityClass' $currentPriority $originalPriority 'restorePriority' 'Restore original process priority.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'affinityMask') -and $null -ne $originalAffinityMask -and (Test-RooIndustriesAffinityMaskAllowed $originalAffinityMask) -and [string]$currentAffinityMask -ne [string]$originalAffinityMask) {
            $controlChanges.Add((New-RooIndustriesControlChange 'affinityMask' $currentAffinityMask ([int64]$originalAffinityMask) 'restoreAffinity' 'Restore original CPU affinity.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'ioPriority') -and -not [string]::IsNullOrWhiteSpace([string]$originalIoPriority) -and (Test-RooIndustriesIoPriorityAllowed $originalIoPriority -Restoring) -and [string]$currentIoPriority -ne [string]$originalIoPriority) {
            $controlChanges.Add((New-RooIndustriesControlChange 'ioPriority' $currentIoPriority $originalIoPriority 'restoreIoPriority' 'Restore original I/O priority.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'memoryPriority') -and -not [string]::IsNullOrWhiteSpace([string]$originalMemoryPriority) -and (Test-RooIndustriesMemoryPriorityAllowed $originalMemoryPriority) -and [string]$currentMemoryPriority -ne [string]$originalMemoryPriority) {
            $controlChanges.Add((New-RooIndustriesControlChange 'memoryPriority' $currentMemoryPriority $originalMemoryPriority 'restoreMemoryPriority' 'Restore original memory priority.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'gpuPriority') -and -not [string]::IsNullOrWhiteSpace([string]$originalGpuPriority) -and (Test-RooIndustriesGpuPriorityAllowed $originalGpuPriority) -and [string]$currentGpuPriority -ne [string]$originalGpuPriority) {
            if ([bool](Get-RooIndustriesPropertyValue $currentState 'gpuPriorityAvailable' $false)) {
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'Restore original GPU scheduling priority.')) | Out-Null
            } else {
                $blocked = $true
                $reason = 'GPU scheduling priority is unavailable for this restore target.'
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'GPU scheduling priority is unavailable for this restore target.' $true $reason)) | Out-Null
            }
        }
        if ($controlChanges.Count -eq 0) {
            $reason = 'Process already matches the process profile backup.'
        }
    }
    $restorePlan = Get-RooIndustriesApplicableProcessControlChanges @($controlChanges.ToArray()) $currentState
    $applicableControlChanges = @(Get-RooIndustriesPropertyArray $restorePlan 'changes')
    $proposedAction = if ($blocked -or $applicableControlChanges.Count -eq 0) { 'noChange' } elseif ($applicableControlChanges.Count -eq 1 -and [string](Get-RooIndustriesPropertyValue $applicableControlChanges[0] 'control' '') -eq 'priorityClass') { 'restorePriority' } else { 'restoreProcessControls' }

    return [pscustomobject]@{
        previewId = ("rollback-$processName-$processId").ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = if ($controlChanges.Count -gt 1) { 'processControlsRollback' } else { 'processPriorityRollback' }
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooIndustriesPropertyValue $Snapshot 'executablePath' $null
        processStartTimeUtc = Get-RooIndustriesPropertyValue $Snapshot 'processStartTimeUtc' $null
        currentPriorityClass = $currentPriority
        proposedPriorityClass = if ($blocked) { $currentPriority } else { $originalPriority }
        currentAffinityMask = $currentAffinityMask
        proposedAffinityMask = if ($blocked) { $currentAffinityMask } else { $originalAffinityMask }
        currentIoPriority = $currentIoPriority
        currentMemoryPriority = $currentMemoryPriority
        proposedIoPriority = if ($blocked) { $currentIoPriority } else { $originalIoPriority }
        proposedMemoryPriority = if ($blocked) { $currentMemoryPriority } else { $originalMemoryPriority }
        currentGpuPriority = $currentGpuPriority
        proposedGpuPriority = if ($blocked) { $currentGpuPriority } else { $originalGpuPriority }
        gpuPriorityAvailable = Get-RooIndustriesPropertyValue $currentState 'gpuPriorityAvailable' $false
        gpuPriorityStatus = Get-RooIndustriesPropertyValue $currentState 'gpuPriorityStatus' $null
        proposedAction = $proposedAction
        controlChanges = @($controlChanges.ToArray())
        ruleId = [string](Get-RooIndustriesPropertyValue $Snapshot 'ruleId' '')
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
            memoryPriority = $currentMemoryPriority
            gpuPriority = $currentGpuPriority
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked) { $currentPriority } else { $originalPriority }
            affinityMask = if ($blocked) { $currentAffinityMask } else { $originalAffinityMask }
            ioPriority = if ($blocked) { $currentIoPriority } else { $originalIoPriority }
            memoryPriority = if ($blocked) { $currentMemoryPriority } else { $originalMemoryPriority }
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
    foreach ($snap in @(Get-RooIndustriesPropertyArray $Backup 'snapshots')) {
        $snapshots.Add([pscustomobject]@{
            type = 'processControls'
            target = "$([string](Get-RooIndustriesPropertyValue $snap 'processName' ''))`:$([int](Get-RooIndustriesPropertyValue $snap 'processId' 0))"
            originalState = [pscustomobject]@{
                priorityClass = Get-RooIndustriesPropertyValue $snap 'originalPriorityClass' $null
                affinityMask = Get-RooIndustriesPropertyValue $snap 'originalAffinityMask' $null
                ioPriority = Get-RooIndustriesPropertyValue $snap 'originalIoPriority' $null
                memoryPriority = Get-RooIndustriesPropertyValue $snap 'originalMemoryPriority' $null
                gpuPriority = Get-RooIndustriesPropertyValue $snap 'originalGpuPriority' $null
                proposedPriorityClass = Get-RooIndustriesPropertyValue $snap 'proposedPriorityClass' $null
                proposedAffinityMask = Get-RooIndustriesPropertyValue $snap 'proposedAffinityMask' $null
                proposedIoPriority = Get-RooIndustriesPropertyValue $snap 'proposedIoPriority' $null
                proposedMemoryPriority = Get-RooIndustriesPropertyValue $snap 'proposedMemoryPriority' $null
                proposedGpuPriority = Get-RooIndustriesPropertyValue $snap 'proposedGpuPriority' $null
            }
        }) | Out-Null
    }

    return [pscustomobject]@{
        backupId = [string](Get-RooIndustriesPropertyValue $Backup 'backupId' '')
        scope = 'process-profile-process-controls'
        createdAtUtc = [string](Get-RooIndustriesPropertyValue $Backup 'createdAtUtc' '')
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
    $resolvedBackupPath = Resolve-RooIndustriesPath $BackupPath $BackupPath
    $backup = Read-RooIndustriesJsonFile $resolvedBackupPath

    $previewEntries = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @(Get-RooIndustriesPropertyArray $backup 'snapshots')) {
        $candidate = Get-RestoreCandidate $snapshot
        $previewEntries.Add((New-RollbackPreviewEntry $snapshot $candidate)) | Out-Null
    }

    $changed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]

    if ($ConfirmApply) {
        foreach ($entry in @($previewEntries.ToArray())) {
            if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
                $skipped.Add((New-RestoreSkippedItem $entry (Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Rollback entry is blocked.') @(Get-RooIndustriesPreviewControlChanges $entry) 'blocked')) | Out-Null
                continue
            }

            $processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
            $identity = Get-RestoreCandidate $entry
            $live = $identity.process
            if (-not $identity.exists -or -not $identity.matches) {
                $skipped.Add((New-RestoreSkippedItem $entry $identity.blockedReason @(Get-RooIndustriesPreviewControlChanges $entry) 'exited')) | Out-Null
                continue
            }

            $entryControlChanges = @(Get-RooIndustriesPreviewControlChanges $entry | Where-Object { -not [bool](Get-RooIndustriesPropertyValue $_ 'blocked' $false) })
            if ($entryControlChanges.Count -eq 0) { continue }
            $appliedControls = New-Object System.Collections.Generic.List[object]
            $failedControls = New-Object System.Collections.Generic.List[string]
            try {
                foreach ($change in $entryControlChanges) {
                    try {
                        Invoke-RooIndustriesProcessControlChange $live $change
                        $appliedControls.Add($change) | Out-Null
                    } catch {
                        $failedControls.Add("$([string](Get-RooIndustriesPropertyValue $change 'control' 'unknown')): $($_.Exception.Message)") | Out-Null
                    }
                }
                if ($appliedControls.Count -gt 0) {
                    $afterControls = Get-RooIndustriesProcessControlState $processId $null -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $entry)
                    $changed.Add([pscustomobject]@{
                        processId = $processId
                        processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                        restoredPriorityClass = $afterControls.priorityClass
                        restoredAffinityMask = $afterControls.affinityMask
                        restoredIoPriority = $afterControls.ioPriority
                        restoredMemoryPriority = $afterControls.memoryPriority
                        restoredGpuPriority = $afterControls.gpuPriority
                        restoredControls = @($appliedControls.ToArray())
                        ruleId = Get-RooIndustriesPropertyValue $entry 'ruleId' ''
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
            if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
                $skipped.Add((New-RestoreSkippedItem $entry (Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Rollback entry is blocked.') @(Get-RooIndustriesPreviewControlChanges $entry) 'blocked')) | Out-Null
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

    $result = New-RooIndustriesActionResult `
        -ResultId ("rollback-" + (Get-RooIndustriesFileStamp)) `
        -Status $status `
        -Summary $summary `
        -ChangedItems @($changed.ToArray()) `
        -SkippedItems @($skipped.ToArray()) `
        -Artifacts @([pscustomobject]@{ type = 'processProfileBackup'; path = $resolvedBackupPath })

    $warnings = New-Object System.Collections.Generic.List[object]
    if (-not $ConfirmApply) {
        $warnings.Add((New-RooIndustriesIssue 'ROLLBACK_PREVIEW_ONLY' 'Rollback preview did not change any process because -ConfirmApply was omitted.' 'info' 'performance.rollback' $resolvedBackupPath $false 'Rerun with -ConfirmApply only after reviewing the rollback preview.' $null)) | Out-Null
    }

    $envelope = New-RooIndustriesActionEnvelope `
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
        -Logs @((New-RooIndustriesLog $summary))

    Write-RooIndustriesJsonOutput $envelope $OutputPath
} catch {
    $envelope = New-RooIndustriesActionEnvelope `
        -ActionId 'performance.rollbackProfile' `
        -DryRun (-not $ConfirmApply) `
        -Risk 'low' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIndustriesIssue 'PROCESS_PROFILE_ROLLBACK_FAILED' $_.Exception.Message 'error' 'performance.rollback' $BackupPath $true 'Check the backup path and retry.' $null)) `
        -Logs @((New-RooIndustriesLog 'Rollback failed.' 'error'))
    Write-RooIndustriesJsonOutput $envelope $OutputPath
    exit 1
}
