param(
    [string]$SessionId = '',
    [string]$SessionPath = '',
    [string]$BackupPath = '',
    [string]$StateRoot = '',
    [string]$OutputPath = '',
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessGovernor.Common.ps1')
$script:GovernorAlreadyClosed = 'This app was already closed or restarted. Its limits ended with it, so nothing remains to restore.'

function New-GovernorAlreadyClosedItem {
    param([object]$Entry)
    return [pscustomobject]@{
        processId = Get-RooIndustriesPropertyValue $Entry 'processId' 0
        processName = Get-RooIndustriesPropertyValue $Entry 'processName' ''
        reason = $script:GovernorAlreadyClosed
        outcome = 'alreadyClosed'
        skippedAtUtc = Get-RooIndustriesUtcStamp
    }
}

# A control another program changed is left as that program set it, and from then on it is no longer
# this run's: its ownership is saved as closed before Restore moves on.
function Get-GovernorKeptControl {
    param([object]$Entry,[System.Diagnostics.Process]$Process,[string]$Control,[object]$Applied,[object]$Original,[object]$Snapshot,[object]$Backup,[string]$BackupPath)
    try { $now = Get-RooIndustriesProcessControlReadback $Process $Control } catch { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$now) -or (Test-RooIndustriesControlValueEqual $Control $now $Applied)) { return $null }
    $newer = Get-RooIndustriesProcessGovernorNewerRunReason $script:GovernorSessionDirectory $Entry $Control
    if (-not [string]::IsNullOrWhiteSpace($newer)) { return $newer }
    $owner = Get-RooIndustriesRestoreControlOwnershipReason $Process $Control
    if (-not [string]::IsNullOrWhiteSpace($owner)) { return $owner }
    Close-RooIndustriesGovernorControlOwnership $Snapshot @($Control)
    Write-RooIndustriesProcessGovernorJsonFile $Backup $BackupPath
    return New-RooIndustriesLeftAsSetItem $Entry ([pscustomobject]@{ control = $Control; currentValue = $now; appliedValue = $Applied; originalValue = $Original })
}

function New-GovernorRestorePreview {
    param(
        [object]$Snapshot,
        [object]$Candidate
    )
    $processId = [int](Get-RooIndustriesPropertyValue $Snapshot 'processId' 0)
    $processName = [string](Get-RooIndustriesPropertyValue $Snapshot 'processName' '')
    $originalPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalPriorityClass' $null
    $originalAffinity = Get-RooIndustriesPropertyValue $Snapshot 'originalAffinityMask' $null
    $originalIoPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalIoPriority' $null
    $originalMemoryPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalMemoryPriority' $null
    $originalGpuPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalGpuPriority' $null
    $blocked = (-not $Candidate.exists) -or (-not $Candidate.matches)
    $ended = $blocked -and [bool](Get-RooIndustriesPropertyValue $Candidate 'instanceEnded' $false)
    $reason = if ($ended) {
        $script:GovernorAlreadyClosed
    } elseif ($blocked) {
        [string]$Candidate.reason
    } else {
        'Restore original process controls from process governor backup.'
    }
    $currentState = if ($blocked) {
        [pscustomobject]@{ priorityClass = $null; affinityMask = $null; ioPriority = $null; memoryPriority = $null; memoryPriorityAvailable = $false; gpuPriority = $null; gpuPriorityAvailable = $false }
    } else {
        $Candidate.currentControlState
    }
    $selectedChanges = if ($blocked) { @() } else { @(Get-RooIndustriesGovernorRestoreChanges $Snapshot $currentState) }
    $controlChanges = @($selectedChanges)
    if (-not $blocked) {
        $held = @($controlChanges | Where-Object { $_.blocked })
        if ($controlChanges.Count -eq 0) { $reason = 'Process already matches the process governor backup.' }
        elseif (@($held | Where-Object { [string]$_.blockedReason -ceq $script:RooIndustriesChangedExternally }).Count -gt 0) { $reason = 'A recorded control changed externally; its current value was preserved.' }
        elseif ($held.Count -gt 0) { $reason = [string]$held[0].blockedReason }
    }
    $selectedControls=@($selectedChanges|ForEach-Object {$_.control})
    if($selectedControls -notcontains 'priorityClass'){$originalPriority=Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null}
    if($selectedControls -notcontains 'affinityMask'){$originalAffinity=Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null}
    if($selectedControls -notcontains 'ioPriority'){$originalIoPriority=Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null}
    if($selectedControls -notcontains 'memoryPriority'){$originalMemoryPriority=Get-RooIndustriesPropertyValue $currentState 'memoryPriority' $null}
    if($selectedControls -notcontains 'gpuPriority'){$originalGpuPriority=Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null}
    $applicableControlChanges = @(Get-RooIndustriesGovernorApplicableControlChanges $controlChanges)
    $proposedAction = if ($blocked -or $applicableControlChanges.Count -eq 0) { 'noChange' } elseif ($applicableControlChanges.Count -eq 1 -and [string](Get-RooIndustriesPropertyValue $applicableControlChanges[0] 'control' '') -eq 'priorityClass') { 'restorePriority' } else { 'restoreProcessControls' }
    return [pscustomobject]@{
        previewId = ("process-governor-restore-$processName-$processId").ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = 'processGovernorRestore'
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooIndustriesPropertyValue $Snapshot 'executablePath' $null
        processStartTimeUtc = Get-RooIndustriesPropertyValue $Snapshot 'processStartTimeUtc' $null
        currentPriorityClass = Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null
        proposedPriorityClass = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null } else { $originalPriority }
        currentAffinityMask = Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null
        proposedAffinityMask = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null } else { $originalAffinity }
        currentIoPriority = Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null
        currentMemoryPriority = Get-RooIndustriesPropertyValue $currentState 'memoryPriority' $null
        proposedIoPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null } else { $originalIoPriority }
        proposedMemoryPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'memoryPriority' $null } else { $originalMemoryPriority }
        currentGpuPriority = Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null
        proposedGpuPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null } else { $originalGpuPriority }
        gpuPriorityAvailable = Get-RooIndustriesPropertyValue $currentState 'gpuPriorityAvailable' $false
        gpuPriorityStatus = Get-RooIndustriesPropertyValue $currentState 'gpuPriorityStatus' $null
        proposedAction = $proposedAction
        controlChanges = $controlChanges
        ruleId = [string](Get-RooIndustriesPropertyValue $Snapshot 'ruleId' '')
        reason = $reason
        reasonCodes = if ($ended) { @('PROCESS_GOVERNOR_ALREADY_CLOSED') } elseif ($blocked) { @('PROCESS_GOVERNOR_RESTORE_SKIPPED') } else { @('PROCESS_GOVERNOR_RESTORE') }
        classification = 'rollbackCandidate'
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = 'low'
        confidence = 'medium'
        protected = $false
        requiresConfirmation = ($applicableControlChanges.Count -gt 0 -and -not $blocked)
        rollbackSupported = ($applicableControlChanges.Count -gt 0 -and -not $blocked)
        currentState = [pscustomobject]@{
            priorityClass = Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null
            affinityMask = Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null
            ioPriority = Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null
            memoryPriority = Get-RooIndustriesPropertyValue $currentState 'memoryPriority' $null
            gpuPriority = Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null } else { $originalPriority }
            affinityMask = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null } else { $originalAffinity }
            ioPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null } else { $originalIoPriority }
            memoryPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'memoryPriority' $null } else { $originalMemoryPriority }
            gpuPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null } else { $originalGpuPriority }
            reason = $reason
        }
        impact = [pscustomobject]@{
            expectedMemoryEffectBytes = 0
            expectedCpuWakeupEffect = 'neutral'
            targetMetrics = @('process-governor-restore-safety')
        }
        rollback = $null
    }
}

function Write-GovernorStopBusyEnvelope {
    $message = 'Another Background limits run is still going, so Restore did not change anything. Try again once it finishes.'
    $busy = [pscustomobject]@{
        actionId = 'performance.governor.stopSession'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        correlationId = $SessionId
        sessionId = if ([string]::IsNullOrWhiteSpace($SessionId)) { $null } else { $SessionId }
        dryRun = $false
        profileId = $null
        status = 'failed'
        sessionStatus = 'failed'
        startedAtUtc = $null
        completedAtUtc = Get-RooIndustriesUtcStamp
        sessionPath = $SessionPath
        backupManifestPath = $BackupPath
        restorable = $true
        preview = @()
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        backup = $null
        result = $null
        warnings = @()
        errors = @((New-RooIndustriesIssue 'PROCESS_GOVERNOR_RUN_BUSY' $message 'warning' 'performance.governor' $BackupPath $true 'Try again once the other Background limits run finishes.' $null))
        logs = @((New-RooIndustriesLog $message 'warning'))
    }
    Write-RooIndustriesJsonOutput $busy $OutputPath
}

try {
    Invoke-RooIndustriesProcessGovernorRun -ConfirmApply:$ConfirmApply -Wait ([TimeSpan]::FromSeconds(20)) -Busy ${function:Write-GovernorStopBusyEnvelope} -Action {
        $session = $null
        $resolvedSessionPath = $null
        if (-not [string]::IsNullOrWhiteSpace($SessionId) -or -not [string]::IsNullOrWhiteSpace($SessionPath)) {
            $resolvedSessionPath = Resolve-RooIndustriesProcessGovernorSessionFile $SessionId $SessionPath $StateRoot
            if ([string]::IsNullOrWhiteSpace($resolvedSessionPath) -or -not (Test-Path -LiteralPath $resolvedSessionPath)) {
                throw 'The selected process governor session file was not found.'
            }
            $session = Read-RooIndustriesProcessGovernorJson $resolvedSessionPath
        }
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            if ($null -eq $session) {
                $resolvedSessionPath = Resolve-RooIndustriesProcessGovernorSessionFile $SessionId $SessionPath $StateRoot
            }
            if ($resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
                if ($null -eq $session) { $session = Read-RooIndustriesProcessGovernorJson $resolvedSessionPath }
                $BackupPath = [string](Get-RooIndustriesPropertyValue $session 'backupManifestPath' '')
            }
        }
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            throw 'No process governor backup path was provided or found for the selected session.'
        }
        $resolvedBackupPath = Resolve-RooIndustriesPath $BackupPath $BackupPath
        $backup = Read-RooIndustriesProcessGovernorJson $resolvedBackupPath
        $backupDryRun = Get-RooIndustriesPropertyValue $backup 'dryRun' $null
        if ([string](Get-RooIndustriesPropertyValue $backup 'actionId' '') -cne 'performance.governor.startSession' -or $backupDryRun -isnot [bool] -or $backupDryRun) {
            throw 'The process governor backup is not a confirmed backup for this session type.'
        }
        $sessionIdValue = [string](Get-RooIndustriesPropertyValue $backup 'sessionId' '')
        $profileId = [string](Get-RooIndustriesPropertyValue $backup 'profileId' '')
        if ([string]::IsNullOrWhiteSpace($sessionIdValue) -or [string]::IsNullOrWhiteSpace($profileId)) {
            throw 'The process governor backup identity is incomplete.'
        }
        if (-not [string]::IsNullOrWhiteSpace($SessionId) -and $SessionId -cne $sessionIdValue) {
            throw 'The process governor session ID does not match the selected backup.'
        }
        if ($null -eq $session) {
            $candidateSessionPath = Resolve-RooIndustriesProcessGovernorSessionFile $sessionIdValue '' $StateRoot
            if ($candidateSessionPath -and (Test-Path -LiteralPath $candidateSessionPath)) {
                $resolvedSessionPath = $candidateSessionPath
                $session = Read-RooIndustriesProcessGovernorJson $resolvedSessionPath
            }
        }
        if ($null -ne $session) {
            $sessionBackupPath = [string](Get-RooIndustriesPropertyValue $session 'backupManifestPath' '')
            $recordedSessionPath = [string](Get-RooIndustriesPropertyValue $session 'sessionPath' '')
            if ([string](Get-RooIndustriesPropertyValue $session 'sessionId' '') -cne $sessionIdValue -or
                [string](Get-RooIndustriesPropertyValue $session 'profileId' '') -cne $profileId -or
                [string]::IsNullOrWhiteSpace($sessionBackupPath) -or
                -not [string]::Equals((Resolve-RooIndustriesPath $sessionBackupPath $sessionBackupPath), $resolvedBackupPath, [StringComparison]::OrdinalIgnoreCase) -or
                (-not [string]::IsNullOrWhiteSpace($recordedSessionPath) -and -not [string]::Equals((Get-RooIndustriesProcessGovernorSessionFileFromPath $recordedSessionPath), $resolvedSessionPath, [StringComparison]::OrdinalIgnoreCase))) {
                throw 'The process governor session and backup identity do not match.'
            }
        }
        $startedAtUtc = Get-RooIndustriesUtcStamp
        $script:GovernorSessionDirectory = Split-Path $(if ($resolvedSessionPath) { $resolvedSessionPath } else { $resolvedBackupPath }) -Parent

        $preview = New-Object System.Collections.Generic.List[object]
        $previewSnapshots = New-Object System.Collections.Generic.List[object]
        foreach ($snapshot in @(Get-RooIndustriesProcessGovernorLatestSnapshots $backup)) {
            $preview.Add((New-GovernorRestorePreview $snapshot (Get-RooIndustriesProcessGovernorSnapshotIdentity $snapshot))) | Out-Null
            $previewSnapshots.Add($snapshot) | Out-Null
        }

        $changed = New-Object System.Collections.Generic.List[object]
        $skipped = New-Object System.Collections.Generic.List[object]
        $alreadyClosed = New-Object System.Collections.Generic.List[object]
        $restored = New-Object System.Collections.Generic.List[object]
        $leftAsSet = New-Object System.Collections.Generic.List[object]
        if ($ConfirmApply) {
            for ($index = 0; $index -lt $preview.Count; $index++) {
                $entry = $preview[$index]
                if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
                    if (@(Get-RooIndustriesPropertyArray $entry 'reasonCodes') -contains 'PROCESS_GOVERNOR_ALREADY_CLOSED') {
                        $alreadyClosed.Add((New-GovernorAlreadyClosedItem $entry)) | Out-Null
                        continue
                    }
                    $skip = [pscustomobject]@{
                        processId = Get-RooIndustriesPropertyValue $entry 'processId' 0
                        processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                        reason = Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Restore entry is blocked.'
                        skippedAtUtc = Get-RooIndustriesUtcStamp
                    }
                    $skipped.Add($skip) | Out-Null
                    continue
                }
                $processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
                $identity = Get-RooIndustriesProcessGovernorLiveIdentity $entry
                if (-not $identity.exists -or -not $identity.matches) {
                    if ($identity.instanceEnded) {
                        $alreadyClosed.Add((New-GovernorAlreadyClosedItem $entry)) | Out-Null
                        continue
                    }
                    $skipped.Add([pscustomobject]@{
                        processId = $processId
                        processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                        reason = $identity.reason
                        skippedAtUtc = Get-RooIndustriesUtcStamp
                    }) | Out-Null
                    continue
                }
                $live = $identity.process
                $snapshot = $previewSnapshots[$index]
                $entrySkipStart = $skipped.Count
                $entryLeftStart = $leftAsSet.Count
                if (Close-RooIndustriesGovernorSettledControls $snapshot (Get-RooIndustriesProcessControlState $processId $null -Process $live -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $snapshot))) {
                    Write-RooIndustriesProcessGovernorJsonFile $backup $resolvedBackupPath
                }
                foreach ($control in @(Get-RooIndustriesPreviewControlChanges $entry | Where-Object { $_.blocked })) {
                    $reason = $control.blockedReason
                    if (Test-RooIndustriesGovernorChangeLeftAsSet $control) {
                        $kept = Get-GovernorKeptControl $entry $live ([string]$control.control) (Get-RooIndustriesPropertyValue $control 'appliedValue' $null) $control.proposedValue $snapshot $backup $resolvedBackupPath
                        if ($kept -is [string]) { $reason = $kept }
                        elseif ($null -ne $kept) { $leftAsSet.Add($kept) | Out-Null; continue }
                    }
                    $skipped.Add([pscustomobject]@{ processId = $processId; processName = $entry.processName; control = $control.control; reason = $reason; skippedAtUtc = Get-RooIndustriesUtcStamp }) | Out-Null
                }
                $entryControlChanges = @(Get-RooIndustriesGovernorApplicableControlChanges @(Get-RooIndustriesPreviewControlChanges $entry))
                if ($entryControlChanges.Count -eq 0) { continue }
                $appliedControls = New-Object System.Collections.Generic.List[object]
                $failedControls = New-Object System.Collections.Generic.List[string]
                foreach ($change in $entryControlChanges) {
                    $name = [string](Get-RooIndustriesPropertyValue $change 'control' '')
                    $newer = Get-RooIndustriesProcessGovernorNewerRunReason $script:GovernorSessionDirectory $entry $name
                    if (-not [string]::IsNullOrWhiteSpace($newer)) {
                        $failedControls.Add($name + ': ' + $newer) | Out-Null
                        continue
                    }
                    $owner = Get-RooIndustriesRestoreControlOwnershipReason $live $name
                    if (-not [string]::IsNullOrWhiteSpace($owner)) {
                        $failedControls.Add($name + ': ' + $owner) | Out-Null
                        continue
                    }
                    try {
                        Invoke-RooIndustriesGovernorControlRestore $live $snapshot $change $backup $resolvedBackupPath
                        $appliedControls.Add($change) | Out-Null
                    } catch {
                        $failure = $_.Exception.Message
                        if ($failure -ceq $script:RooIndustriesChangedExternally) {
                            $kept = Get-GovernorKeptControl $entry $live $name (Get-RooIndustriesPropertyValue $change 'currentValue' $null) $change.proposedValue $snapshot $backup $resolvedBackupPath
                            if ($kept -is [string]) { $failure = $kept }
                            elseif ($null -ne $kept) { $leftAsSet.Add($kept) | Out-Null; continue }
                        }
                        $failedControls.Add("$([string](Get-RooIndustriesPropertyValue $change 'control' 'unknown')): $failure") | Out-Null
                        continue
                    }
                }
                if ($appliedControls.Count -gt 0) {
                    $afterControls = Get-RooIndustriesProcessControlState $processId $null -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $entry)
                    $restoreItem = [pscustomobject]@{
                        processId = $processId
                        processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                        restoredPriorityClass = $afterControls.priorityClass
                        restoredAffinityMask = $afterControls.affinityMask
                        restoredIoPriority = $afterControls.ioPriority
                        restoredMemoryPriority = $afterControls.memoryPriority
                        restoredGpuPriority = $afterControls.gpuPriority
                        restoredControls = @($appliedControls.ToArray())
                        ruleId = Get-RooIndustriesPropertyValue $entry 'ruleId' ''
                        restoredAtUtc = Get-RooIndustriesUtcStamp
                    }
                    $restored.Add($restoreItem) | Out-Null
                    $changed.Add($restoreItem) | Out-Null
                }
                $exitedDuringRestore = $false
                if ($failedControls.Count -gt 0 -or $skipped.Count -gt $entrySkipStart) {
                    try { $exitedDuringRestore = $live.HasExited } catch { $exitedDuringRestore = $false }
                }
                if ($exitedDuringRestore) {
                    while ($skipped.Count -gt $entrySkipStart) { $skipped.RemoveAt($skipped.Count - 1) }
                    while ($leftAsSet.Count -gt $entryLeftStart) { $leftAsSet.RemoveAt($leftAsSet.Count - 1) }
                    if ($failedControls.Count -gt 0) { $alreadyClosed.Add((New-GovernorAlreadyClosedItem $entry)) | Out-Null }
                    continue
                }
                if ($failedControls.Count -gt 0) {
                    $skipped.Add([pscustomobject]@{
                        processId = $processId
                        processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                        reason = $failedControls -join '; '
                        skippedAtUtc = Get-RooIndustriesUtcStamp
                    }) | Out-Null
                }
            }
        } else {
            foreach ($entry in @($preview.ToArray())) {
                if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
                    if (@(Get-RooIndustriesPropertyArray $entry 'reasonCodes') -contains 'PROCESS_GOVERNOR_ALREADY_CLOSED') {
                        $alreadyClosed.Add((New-GovernorAlreadyClosedItem $entry)) | Out-Null
                        continue
                    }
                    $skipped.Add([pscustomobject]@{
                        processId = Get-RooIndustriesPropertyValue $entry 'processId' 0
                        processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                        reason = Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Restore entry is blocked.'
                        skippedAtUtc = Get-RooIndustriesUtcStamp
                    }) | Out-Null
                }
            }
        }

        $status = if ($ConfirmApply) {
            if ($restored.Count -gt 0 -and $skipped.Count -gt 0) { 'partial' }
            elseif ($restored.Count -gt 0) { 'completed' }
            elseif ($skipped.Count -gt 0) { 'failed' }
            else { 'completed' }
        } else {
            'preview'
        }
        $sessionStatus = if ($status -eq 'partial') { 'completed' } else { $status }
        $warnings = New-Object System.Collections.Generic.List[object]
        if (-not $ConfirmApply) {
            $warnings.Add((New-RooIndustriesIssue 'PROCESS_GOVERNOR_RESTORE_PREVIEW_ONLY' 'Governor restore preview did not change any process because -ConfirmApply was omitted.' 'info' 'performance.governor' $resolvedBackupPath $false 'Rerun with -ConfirmApply only after reviewing the restore preview.' $null)) | Out-Null
        }
        $closedText = if ($alreadyClosed.Count -gt 0) { ' Already closed or restarted, so nothing remained to restore: ' + (($alreadyClosed | ForEach-Object { $_.processName + ' (PID ' + $_.processId + ')' }) -join ', ') + '.' } else { '' }
        $skippedOut = @($skipped.ToArray()) + @($alreadyClosed.ToArray())
        $leftOut = @($leftAsSet.ToArray())
        $summary = if ($ConfirmApply) {
            "Process governor restore completed with $($restored.Count) restored item(s) and $($skipped.Count) skipped item(s)." + $closedText + (Format-RooIndustriesLeftAsSetText $leftOut)
        } else {
            'Process governor restore preview completed. No process changes were applied.'
        }
        $backupMetadata = New-RooIndustriesProcessGovernorBackupMetadata $backup $resolvedBackupPath
        $result = [pscustomobject]@{
            resultId = "process-governor-restore-$(Get-RooIndustriesFileStamp)"
            status = if ($status -eq 'completed' -and $ConfirmApply) { 'rolledBack' } elseif ($status -eq 'preview') { 'preview' } else { $status }
            startedAtUtc = $startedAtUtc
            completedAtUtc = Get-RooIndustriesUtcStamp
            summary = $summary
            changedItems = @($changed.ToArray())
            skippedItems = $skippedOut
            restoredItems = @($restored.ToArray())
            leftAsSetItems = $leftOut
            artifacts = @([pscustomobject]@{ type = 'processGovernorSessionBackup'; path = $resolvedBackupPath })
        }
        $envelope = [pscustomobject]@{
            actionId = 'performance.governor.stopSession'
            schemaVersion = 1
            productName = $script:RooIndustriesProcessProductName
            correlationId = $sessionIdValue
            sessionId = $sessionIdValue
            dryRun = (-not $ConfirmApply)
            profileId = $profileId
            status = $status
            sessionStatus = $sessionStatus
            startedAtUtc = $startedAtUtc
            completedAtUtc = Get-RooIndustriesUtcStamp
            sessionPath = $resolvedSessionPath
            backupManifestPath = $resolvedBackupPath
            restorable = (-not $ConfirmApply -or $status -in @('partial', 'failed') -or $leftOut.Count -gt 0)
            preview = @($preview.ToArray())
            changedItems = @($changed.ToArray())
            skippedItems = $skippedOut
            restoredItems = @($restored.ToArray())
            leftAsSetItems = $leftOut
            backup = $backupMetadata
            result = $result
            warnings = @($warnings.ToArray())
            errors = @()
            logs = @((New-RooIndustriesLog $summary))
        }

        if ($ConfirmApply -and $resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
            $session = Read-RooIndustriesProcessGovernorJson $resolvedSessionPath
            $session.sessionStatus = $sessionStatus
            $session.status = $sessionStatus
            $session.restorable = ($status -in @('partial', 'failed') -or $leftOut.Count -gt 0)
            $session.activeRestraints = @()
            $session.restoredItems = @($restored.ToArray())
            $session.skippedItems = $skippedOut
            $session | Add-Member -NotePropertyName leftAsSetItems -NotePropertyValue $leftOut -Force
            $session.completedAtUtc = Get-RooIndustriesUtcStamp
            Write-RooIndustriesProcessGovernorJsonFile $session $resolvedSessionPath
            Add-RooIndustriesProcessGovernorLogFileEntry (Split-Path $resolvedSessionPath -Parent) (New-RooIndustriesLog $summary)
        }

        Write-RooIndustriesJsonOutput $envelope $OutputPath
    }
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.governor.stopSession'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        correlationId = $SessionId
        sessionId = if ([string]::IsNullOrWhiteSpace($SessionId)) { $null } else { $SessionId }
        dryRun = (-not $ConfirmApply)
        profileId = $null
        status = 'failed'
        sessionStatus = 'failed'
        startedAtUtc = $null
        completedAtUtc = Get-RooIndustriesUtcStamp
        sessionPath = $SessionPath
        backupManifestPath = $BackupPath
        restorable = $false
        preview = @()
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        backup = $null
        result = $null
        warnings = @()
        errors = @((New-RooIndustriesIssue 'PROCESS_GOVERNOR_RESTORE_FAILED' $_.Exception.Message 'error' 'performance.governor' $BackupPath $true 'Check the session id, session path, or backup path and retry.' $null))
        logs = @((New-RooIndustriesLog 'Process governor restore failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorEnvelope $OutputPath
    exit 1
}
