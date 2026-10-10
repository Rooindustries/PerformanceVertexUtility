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
    $reason = if ($blocked) {
        [string]$Candidate.reason
    } else {
        'Restore original process controls from process governor backup.'
    }
    $controlChanges = New-Object System.Collections.Generic.List[object]
    $currentState = if ($blocked) {
        [pscustomobject]@{ priorityClass = $null; affinityMask = $null; ioPriority = $null; memoryPriority = $null; memoryPriorityAvailable = $false; gpuPriority = $null; gpuPriorityAvailable = $false }
    } else {
        $Candidate.currentControlState
    }
    if (-not $blocked) {
        if (-not [string]::IsNullOrWhiteSpace([string]$originalPriority) -and (Test-RooIndustriesPriorityAllowed ([string]$originalPriority) -Restoring) -and [string](Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null) -ne [string]$originalPriority) {
            $controlChanges.Add((New-RooIndustriesControlChange 'priorityClass' (Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null) $originalPriority 'restorePriority' 'Restore original process priority after governor restraint.')) | Out-Null
        }
        if ($null -ne $originalAffinity -and -not [string]::IsNullOrWhiteSpace([string]$originalAffinity) -and (Test-RooIndustriesAffinityMaskAllowed $originalAffinity) -and [string](Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null) -ne [string]$originalAffinity) {
            $controlChanges.Add((New-RooIndustriesControlChange 'affinityMask' (Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null) ([int64]$originalAffinity) 'restoreAffinity' 'Restore original CPU affinity after governor restraint.')) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$originalIoPriority) -and (Test-RooIndustriesIoPriorityAllowed ([string]$originalIoPriority) -Restoring) -and [string](Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null) -ne [string]$originalIoPriority) {
            $controlChanges.Add((New-RooIndustriesControlChange 'ioPriority' (Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null) $originalIoPriority 'restoreIoPriority' 'Restore original I/O priority after governor restraint.')) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$originalMemoryPriority) -and (Test-RooIndustriesMemoryPriorityAllowed ([string]$originalMemoryPriority)) -and [string](Get-RooIndustriesPropertyValue $currentState 'memoryPriority' $null) -ne [string]$originalMemoryPriority) {
            $controlChanges.Add((New-RooIndustriesControlChange 'memoryPriority' (Get-RooIndustriesPropertyValue $currentState 'memoryPriority' $null) $originalMemoryPriority 'restoreMemoryPriority' 'Restore original memory priority after governor restraint.')) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$originalGpuPriority) -and (Test-RooIndustriesGpuPriorityAllowed ([string]$originalGpuPriority)) -and [string](Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null) -ne [string]$originalGpuPriority) {
            if ([bool](Get-RooIndustriesPropertyValue $currentState 'gpuPriorityAvailable' $false)) {
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' (Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null) $originalGpuPriority 'restoreGpuPriority' 'Restore original GPU scheduling priority after governor restraint.')) | Out-Null
            } else {
                $reason = 'GPU scheduling priority is unavailable for this restore target.'
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' (Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null) $originalGpuPriority 'restoreGpuPriority' 'GPU scheduling priority is unavailable for this restore target.' $true $reason)) | Out-Null
            }
        }
        if ($controlChanges.Count -eq 0) {
            $reason = 'Process already matches the process governor backup.'
        }
    }
    $selectedChanges=@(Select-RooIndustriesGovernorOwnedRestoreChanges $Snapshot @($controlChanges.ToArray()))
    $controlChanges.Clear()
    foreach($change in $selectedChanges){$controlChanges.Add($change)|Out-Null}
    $blocked=(-not $Candidate.exists) -or (-not $Candidate.matches)
    if(@($selectedChanges|Where-Object {$_.blocked}).Count -gt 0){$reason='A recorded control changed externally; its current value was preserved.'}
    $selectedControls=@($selectedChanges|ForEach-Object {$_.control})
    if($selectedControls -notcontains 'priorityClass'){$originalPriority=Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null}
    if($selectedControls -notcontains 'affinityMask'){$originalAffinity=Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null}
    if($selectedControls -notcontains 'ioPriority'){$originalIoPriority=Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null}
    if($selectedControls -notcontains 'memoryPriority'){$originalMemoryPriority=Get-RooIndustriesPropertyValue $currentState 'memoryPriority' $null}
    if($selectedControls -notcontains 'gpuPriority'){$originalGpuPriority=Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null}
    $applicableControlChanges = @(Get-RooIndustriesGovernorApplicableControlChanges @($controlChanges.ToArray()))
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
        controlChanges = @($controlChanges.ToArray())
        ruleId = [string](Get-RooIndustriesPropertyValue $Snapshot 'ruleId' '')
        reason = $reason
        reasonCodes = if ($blocked) { @('PROCESS_GOVERNOR_RESTORE_SKIPPED') } else { @('PROCESS_GOVERNOR_RESTORE') }
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

try {
    $session = $null
    $resolvedSessionPath = $null
    if (-not [string]::IsNullOrWhiteSpace($SessionId) -or -not [string]::IsNullOrWhiteSpace($SessionPath)) {
        $resolvedSessionPath = Resolve-RooIndustriesProcessGovernorSessionFile $SessionId $SessionPath $StateRoot
        if ([string]::IsNullOrWhiteSpace($resolvedSessionPath) -or -not (Test-Path -LiteralPath $resolvedSessionPath)) {
            throw 'The selected process governor session file was not found.'
        }
        $session = Read-RooIndustriesJsonFile $resolvedSessionPath
    }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        if ($null -eq $session) {
            $resolvedSessionPath = Resolve-RooIndustriesProcessGovernorSessionFile $SessionId $SessionPath $StateRoot
        }
        if ($resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
            if ($null -eq $session) { $session = Read-RooIndustriesJsonFile $resolvedSessionPath }
            $BackupPath = [string](Get-RooIndustriesPropertyValue $session 'backupManifestPath' '')
        }
    }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'No process governor backup path was provided or found for the selected session.'
    }
    $resolvedBackupPath = Resolve-RooIndustriesPath $BackupPath $BackupPath
    $backup = Read-RooIndustriesJsonFile $resolvedBackupPath
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
            $session = Read-RooIndustriesJsonFile $resolvedSessionPath
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

    $preview = New-Object System.Collections.Generic.List[object]
    $snapshotList=@(Get-RooIndustriesPropertyArray $backup 'snapshots')
    $seenIdentities=@{}
    for($snapshotIndex=$snapshotList.Count-1;$snapshotIndex -ge 0;$snapshotIndex--) {
        $snapshot=$snapshotList[$snapshotIndex]
        $identityKey=([string](Get-RooIndustriesPropertyValue $snapshot 'processId' 0))+'|'+([string](Get-RooIndustriesPropertyValue $snapshot 'processStartTimeUtc' ''))+'|'+([string](Get-RooIndustriesPropertyValue $snapshot 'executablePath' ''))
        if($seenIdentities.ContainsKey($identityKey)){continue}
        $seenIdentities[$identityKey]=$true
        $candidate = Get-RooIndustriesProcessGovernorLiveIdentity ([pscustomobject]@{
            processId = Get-RooIndustriesPropertyValue $snapshot 'processId' 0
            processName = Get-RooIndustriesPropertyValue $snapshot 'processName' ''
            executablePath = Get-RooIndustriesPropertyValue $snapshot 'executablePath' $null
            processStartTimeUtc = Get-RooIndustriesPropertyValue $snapshot 'processStartTimeUtc' $null
            controlChanges = @(Get-RooIndustriesPreviewControlChanges $snapshot)
        })
        $preview.Add((New-GovernorRestorePreview $snapshot $candidate)) | Out-Null
    }

    $changed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $restored = New-Object System.Collections.Generic.List[object]
    if ($ConfirmApply) {
        foreach ($entry in @($preview.ToArray())) {
            if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
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
                $skipped.Add([pscustomobject]@{
                    processId = $processId
                    processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                    reason = $identity.reason
                    skippedAtUtc = Get-RooIndustriesUtcStamp
                }) | Out-Null
                continue
            }
            $live = $identity.process
            foreach ($control in @(Get-RooIndustriesPreviewControlChanges $entry | Where-Object { $_.blocked })) {
                $skipped.Add([pscustomobject]@{ processId = $processId; processName = $entry.processName; control = $control.control; reason = $control.blockedReason; skippedAtUtc = Get-RooIndustriesUtcStamp }) | Out-Null
            }
            $entryControlChanges = @(Get-RooIndustriesGovernorApplicableControlChanges @(Get-RooIndustriesPreviewControlChanges $entry))
            if ($entryControlChanges.Count -eq 0) { continue }
            $appliedControls = New-Object System.Collections.Generic.List[object]
            $failedControls = New-Object System.Collections.Generic.List[string]
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
    $summary = if ($ConfirmApply) {
        "Process governor restore completed with $($restored.Count) restored item(s) and $($skipped.Count) skipped item(s)."
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
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
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
        restorable = (-not $ConfirmApply -or $status -in @('partial', 'failed'))
        preview = @($preview.ToArray())
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        backup = $backupMetadata
        result = $result
        warnings = @($warnings.ToArray())
        errors = @()
        logs = @((New-RooIndustriesLog $summary))
    }

    if ($ConfirmApply -and $resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
        $session = Read-RooIndustriesJsonFile $resolvedSessionPath
        $session.sessionStatus = $sessionStatus
        $session.status = $sessionStatus
        $session.restorable = ($status -in @('partial', 'failed'))
        $session.activeRestraints = @()
        $session.restoredItems = @($restored.ToArray())
        $session.skippedItems = @($skipped.ToArray())
        $session.completedAtUtc = Get-RooIndustriesUtcStamp
        Write-RooIndustriesProcessGovernorJsonFile $session $resolvedSessionPath
        Add-RooIndustriesProcessGovernorLogFileEntry (Split-Path $resolvedSessionPath -Parent) (New-RooIndustriesLog $summary)
    }

    Write-RooIndustriesJsonOutput $envelope $OutputPath
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
