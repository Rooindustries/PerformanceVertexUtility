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
            instanceEnded = $true
            blockedReason = 'This app was already closed. Nothing remains to restore.'
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
    $savedStart = Get-RooIndustriesPropertyValue $Snapshot 'processStartTimeUtc' $null
    $startMatches = Test-RooIndustriesProcessStartTime $savedStart $controlState.startTimeUtc
    $savedTime = [datetime]::MinValue
    $currentTime = [datetime]::MinValue
    $knownStartMismatch = [datetime]::TryParse([string]$savedStart, [ref]$savedTime) -and [datetime]::TryParse([string]$controlState.startTimeUtc, [ref]$currentTime) -and -not $startMatches
    $knownPathMismatch = -not $pathMatches -and -not [string]::IsNullOrWhiteSpace([string]$currentPath)
    $instanceEnded = -not $nameMatches -or $knownPathMismatch -or $knownStartMismatch

    return [pscustomobject]@{
        exists = $true
        matches = ($nameMatches -and $pathMatches -and $startMatches)
        process = $live
        currentPriorityClass = $controlState.priorityClass
        currentControlState = $controlState
        currentPath = $currentPath
        instanceEnded = $instanceEnded
        blockedReason = if ($instanceEnded) { 'This app was already closed or restarted. Nothing remains to restore for the saved instance.' } elseif (-not $startMatches) { 'This app was restarted, or its start time could not be verified. Nothing was restored.' } elseif ($nameMatches -and $pathMatches) { $null } else { 'Live process identity does not match the backup snapshot.' }
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
    $leftAsSet = @()
    $alreadyOriginal = @()
    $controlChanges = New-Object System.Collections.Generic.List[object]
    if (-not $blocked) {
        if (($restoresAll -or $recorded -contains 'priorityClass') -and -not [string]::IsNullOrWhiteSpace($originalPriority) -and (Test-RooIndustriesPriorityAllowed $originalPriority -Restoring)) {
            $controlChanges.Add((New-RooIndustriesControlChange 'priorityClass' $currentPriority $originalPriority 'restorePriority' 'Restore original process priority.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'affinityMask') -and $null -ne $originalAffinityMask -and (Test-RooIndustriesAffinityMaskAllowed $originalAffinityMask)) {
            $controlChanges.Add((New-RooIndustriesControlChange 'affinityMask' $currentAffinityMask ([int64]$originalAffinityMask) 'restoreAffinity' 'Restore original CPU affinity.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'ioPriority') -and -not [string]::IsNullOrWhiteSpace([string]$originalIoPriority) -and (Test-RooIndustriesIoPriorityAllowed $originalIoPriority -Restoring)) {
            $controlChanges.Add((New-RooIndustriesControlChange 'ioPriority' $currentIoPriority $originalIoPriority 'restoreIoPriority' 'Restore original I/O priority.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'memoryPriority') -and -not [string]::IsNullOrWhiteSpace([string]$originalMemoryPriority) -and (Test-RooIndustriesMemoryPriorityAllowed $originalMemoryPriority)) {
            $controlChanges.Add((New-RooIndustriesControlChange 'memoryPriority' $currentMemoryPriority $originalMemoryPriority 'restoreMemoryPriority' 'Restore original memory priority.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'gpuPriority') -and -not [string]::IsNullOrWhiteSpace([string]$originalGpuPriority) -and (Test-RooIndustriesGpuPriorityAllowed $originalGpuPriority)) {
            if ([bool](Get-RooIndustriesPropertyValue $currentState 'gpuPriorityAvailable' $false)) {
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'Restore original GPU scheduling priority.')) | Out-Null
            } else {
                $gpuReason = 'GPU scheduling priority is unavailable for this restore target.'
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'GPU scheduling priority is unavailable for this restore target.' $true $gpuReason)) | Out-Null
            }
        }
        $split = Split-RooIndustriesLeftAsSetRestoreChanges $Snapshot @($controlChanges.ToArray()) $currentState
        $leftAsSet = @($split.leftAsSet)
        $alreadyOriginal = @($split.alreadyOriginal)
        $controlChanges = New-Object System.Collections.Generic.List[object]
        foreach ($change in @($split.changes)) { $controlChanges.Add($change) | Out-Null }
        foreach ($left in $leftAsSet) {
            switch ([string]$left.control) {
                'priorityClass' { $originalPriority = [string]$left.currentValue }
                'affinityMask' { $originalAffinityMask = $left.currentValue }
                'ioPriority' { $originalIoPriority = $left.currentValue }
                'memoryPriority' { $originalMemoryPriority = $left.currentValue }
                'gpuPriority' { $originalGpuPriority = $left.currentValue }
            }
        }
        if ($controlChanges.Count -eq 0) {
            $reason = if ($leftAsSet.Count -gt 0) { $script:RooIndustriesLeftAsSet } else { 'Process already matches the process profile backup.' }
        }
    }
    $applicableControlChanges = @($controlChanges.ToArray() | Where-Object { -not $_.blocked })
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
        leftAsSet = @($leftAsSet)
        alreadyOriginal = @($alreadyOriginal)
        ruleId = [string](Get-RooIndustriesPropertyValue $Snapshot 'ruleId' '')
        reason = $reason
        instanceEnded = [bool](Get-RooIndustriesPropertyValue $Candidate 'instanceEnded' $false)
        reasonCodes = @(if ($blocked) { 'ROLLBACK_SKIPPED' } else { 'ROLLBACK_PROCESS_CONTROLS_RESTORE' })
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
    $leftAsSetItems = New-Object System.Collections.Generic.List[object]

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
            $entryControlChanges = @(Get-RooIndustriesPreviewControlChanges $entry)
            $appliedControls = New-Object System.Collections.Generic.List[object]
            $failedControls = New-Object System.Collections.Generic.List[string]
            foreach ($check in (@(Get-RooIndustriesPropertyArray $entry 'alreadyOriginal') + @(Get-RooIndustriesPropertyArray $entry 'leftAsSet'))) {
                $verification = Confirm-RooIndustriesRestoreControl $live $check
                if (-not $verification.confirmed) { $failedControls.Add([string]$check.control + ': ' + $verification.reason) | Out-Null }
                elseif ($null -ne $verification.leftAsSet) { $leftAsSetItems.Add((New-RooIndustriesLeftAsSetItem $entry $verification.leftAsSet)) | Out-Null }
            }
            if ($entryControlChanges.Count -eq 0 -and $failedControls.Count -eq 0) { continue }
            try {
                foreach ($change in $entryControlChanges) {
                    if ([bool](Get-RooIndustriesPropertyValue $change 'blocked' $false)) {
                        $failedControls.Add([string]$change.control + ': ' + [string]$change.blockedReason) | Out-Null
                        continue
                    }
                    try {
                        Invoke-RooIndustriesProcessControlChange $live $change
                        $appliedControls.Add($change) | Out-Null
                    } catch {
                        $failureMessage = $_.Exception.Message
                        $verification = Get-RooIndustriesRestoreLeftAsSet $live $change $failureMessage
                        if ($null -ne $verification) {
                            if ($verification.confirmed) {
                                if ($null -ne $verification.leftAsSet) { $leftAsSetItems.Add((New-RooIndustriesLeftAsSetItem $entry $verification.leftAsSet)) | Out-Null }
                                continue
                            }
                            $failureMessage = $verification.reason
                        }
                        $failedControls.Add("$([string](Get-RooIndustriesPropertyValue $change 'control' 'unknown')): $failureMessage") | Out-Null
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

    $pending = New-Object System.Collections.Generic.List[object]
    $alreadyClosed = New-Object System.Collections.Generic.List[object]
    if ($ConfirmApply) {
        foreach ($snapshot in @(Get-RooIndustriesPropertyArray $backup 'snapshots')) {
            $candidate = Get-RestoreCandidate $snapshot
            if ($candidate.instanceEnded) {
                $alreadyClosed.Add((New-RestoreSkippedItem $snapshot $candidate.blockedReason @() 'alreadyClosed')) | Out-Null
                continue
            }
            $remaining = New-RollbackPreviewEntry $snapshot $candidate
            $restoreFailed = @($skipped | Where-Object { $_.processId -eq (Get-RooIndustriesPropertyValue $snapshot 'processId' 0) -and $_.category -eq 'restore-failed' }).Count -gt 0
            if ($restoreFailed -or $remaining.blocked -or @(Get-RooIndustriesPreviewControlChanges $remaining).Count -gt 0) {
                $pending.Add($remaining) | Out-Null
            }
        }
    }
    $status = if ($ConfirmApply) { 'success' } else { 'preview' }
    if ($ConfirmApply -and $pending.Count -gt 0) { $status = if ($changed.Count -gt 0) { 'partial' } else { 'failed' } }

    $summary = if ($ConfirmApply) {
        $closedText = if ($alreadyClosed.Count -gt 0) { ' Already closed or restarted: ' + (($alreadyClosed | ForEach-Object { $_.processName + ' (PID ' + $_.processId + ')' }) -join ', ') + '.' } else { '' }
        $leftText = Format-RooIndustriesLeftAsSetText @($leftAsSetItems.ToArray())
        $finishedCount = @(Get-RooIndustriesPropertyArray $backup 'snapshots').Count - $pending.Count - $alreadyClosed.Count
        if ($status -eq 'success') {
            "Restore completed for $finishedCount app(s)." + $leftText + $closedText
        } else {
            $attention = ($pending | ForEach-Object {
                $entry = $_
                $failedReasons = @($skipped | Where-Object { $_.processId -eq $entry.processId } | ForEach-Object reason)
                $details = if ($failedReasons.Count -gt 0) { $failedReasons -join '; ' } else { $entry.reason }
                $entry.processName + ' (PID ' + $entry.processId + '): ' + $details
            }) -join '; '
            "Restore finished for $finishedCount app(s). $($pending.Count) app(s) still need attention: $attention." + $leftText + $closedText
        }
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

    $result | Add-Member -NotePropertyName restorePendingCount -NotePropertyValue $pending.Count
    $result | Add-Member -NotePropertyName pendingItems -NotePropertyValue @($pending.ToArray())
    $result | Add-Member -NotePropertyName alreadyClosedItems -NotePropertyValue @($alreadyClosed.ToArray())
    $result | Add-Member -NotePropertyName leftAsSetItems -NotePropertyValue @($leftAsSetItems.ToArray())

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
