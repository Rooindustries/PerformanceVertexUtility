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
    $processId = [int](Get-RooPropertyValue $Snapshot 'processId' 0)
    $processName = [string](Get-RooPropertyValue $Snapshot 'processName' '')
    $originalPriority = Get-RooPropertyValue $Snapshot 'originalPriorityClass' $null
    $originalAffinity = Get-RooPropertyValue $Snapshot 'originalAffinityMask' $null
    $originalIoPriority = Get-RooPropertyValue $Snapshot 'originalIoPriority' $null
    $originalGpuPriority = Get-RooPropertyValue $Snapshot 'originalGpuPriority' $null
    $blocked = (-not $Candidate.exists) -or (-not $Candidate.matches)
    $reason = if ($blocked) {
        [string]$Candidate.reason
    } else {
        'Restore original process controls from process governor backup.'
    }
    $controlChanges = New-Object System.Collections.Generic.List[object]
    $currentState = if ($blocked) {
        [pscustomobject]@{ priorityClass = $null; affinityMask = $null; ioPriority = $null; gpuPriority = $null; gpuPriorityAvailable = $false }
    } else {
        Get-RooProcessControlState $processId $null
    }
    if (-not $blocked) {
        if (-not [string]::IsNullOrWhiteSpace([string]$originalPriority) -and (Test-RooPriorityAllowed ([string]$originalPriority)) -and [string](Get-RooPropertyValue $currentState 'priorityClass' $null) -ne [string]$originalPriority) {
            $controlChanges.Add((New-RooControlChange 'priorityClass' (Get-RooPropertyValue $currentState 'priorityClass' $null) $originalPriority 'restorePriority' 'Restore original process priority after governor restraint.')) | Out-Null
        }
        if ($null -ne $originalAffinity -and -not [string]::IsNullOrWhiteSpace([string]$originalAffinity) -and (Test-RooAffinityMaskAllowed $originalAffinity) -and [string](Get-RooPropertyValue $currentState 'affinityMask' $null) -ne [string]$originalAffinity) {
            $controlChanges.Add((New-RooControlChange 'affinityMask' (Get-RooPropertyValue $currentState 'affinityMask' $null) ([int64]$originalAffinity) 'restoreAffinity' 'Restore original CPU affinity after governor restraint.')) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$originalIoPriority) -and (Test-RooIoPriorityAllowed ([string]$originalIoPriority)) -and [string](Get-RooPropertyValue $currentState 'ioPriority' $null) -ne [string]$originalIoPriority) {
            $controlChanges.Add((New-RooControlChange 'ioPriority' (Get-RooPropertyValue $currentState 'ioPriority' $null) $originalIoPriority 'restoreIoPriority' 'Restore original I/O priority after governor restraint.')) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$originalGpuPriority) -and (Test-RooGpuPriorityAllowed ([string]$originalGpuPriority)) -and [string](Get-RooPropertyValue $currentState 'gpuPriority' $null) -ne [string]$originalGpuPriority) {
            if ([bool](Get-RooPropertyValue $currentState 'gpuPriorityAvailable' $false)) {
                $controlChanges.Add((New-RooControlChange 'gpuPriority' (Get-RooPropertyValue $currentState 'gpuPriority' $null) $originalGpuPriority 'restoreGpuPriority' 'Restore original GPU scheduling priority after governor restraint.')) | Out-Null
            } else {
                $blocked = $true
                $reason = 'GPU scheduling priority is unavailable for this restore target.'
                $controlChanges.Add((New-RooControlChange 'gpuPriority' (Get-RooPropertyValue $currentState 'gpuPriority' $null) $originalGpuPriority 'restoreGpuPriority' 'GPU scheduling priority is unavailable for this restore target.' $true $reason)) | Out-Null
            }
        }
        if ($controlChanges.Count -eq 0) {
            $reason = 'Process already matches the process governor backup.'
        }
    }
    $selectedChanges=@(Select-RooGovernorOwnedRestoreChanges $Snapshot @($controlChanges.ToArray()))
    $controlChanges.Clear()
    foreach($change in $selectedChanges){$controlChanges.Add($change)|Out-Null}
    $blocked=(-not $Candidate.exists) -or (-not $Candidate.matches) -or @($selectedChanges|Where-Object {$_.blocked}).Count -gt 0
    if(@($selectedChanges|Where-Object {$_.blocked}).Count -gt 0){$reason='A recorded control changed externally; its current value was preserved.'}
    $selectedControls=@($selectedChanges|ForEach-Object {$_.control})
    if($selectedControls -notcontains 'priorityClass'){$originalPriority=Get-RooPropertyValue $currentState 'priorityClass' $null}
    if($selectedControls -notcontains 'affinityMask'){$originalAffinity=Get-RooPropertyValue $currentState 'affinityMask' $null}
    if($selectedControls -notcontains 'ioPriority'){$originalIoPriority=Get-RooPropertyValue $currentState 'ioPriority' $null}
    if($selectedControls -notcontains 'gpuPriority'){$originalGpuPriority=Get-RooPropertyValue $currentState 'gpuPriority' $null}
    $applicableControlChanges = @(Get-RooGovernorApplicableControlChanges @($controlChanges.ToArray()))
    $proposedAction = if ($blocked -or $applicableControlChanges.Count -eq 0) { 'noChange' } elseif ($applicableControlChanges.Count -eq 1 -and [string](Get-RooPropertyValue $applicableControlChanges[0] 'control' '') -eq 'priorityClass') { 'restorePriority' } else { 'restoreProcessControls' }
    return [pscustomobject]@{
        previewId = ("process-governor-restore-$processName-$processId").ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = 'processGovernorRestore'
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooPropertyValue $Snapshot 'executablePath' $null
        currentPriorityClass = Get-RooPropertyValue $currentState 'priorityClass' $null
        proposedPriorityClass = if ($blocked) { Get-RooPropertyValue $currentState 'priorityClass' $null } else { $originalPriority }
        currentAffinityMask = Get-RooPropertyValue $currentState 'affinityMask' $null
        proposedAffinityMask = if ($blocked) { Get-RooPropertyValue $currentState 'affinityMask' $null } else { $originalAffinity }
        currentIoPriority = Get-RooPropertyValue $currentState 'ioPriority' $null
        proposedIoPriority = if ($blocked) { Get-RooPropertyValue $currentState 'ioPriority' $null } else { $originalIoPriority }
        currentGpuPriority = Get-RooPropertyValue $currentState 'gpuPriority' $null
        proposedGpuPriority = if ($blocked) { Get-RooPropertyValue $currentState 'gpuPriority' $null } else { $originalGpuPriority }
        gpuPriorityAvailable = Get-RooPropertyValue $currentState 'gpuPriorityAvailable' $false
        gpuPriorityStatus = Get-RooPropertyValue $currentState 'gpuPriorityStatus' $null
        proposedAction = $proposedAction
        controlChanges = @($controlChanges.ToArray())
        ruleId = [string](Get-RooPropertyValue $Snapshot 'ruleId' '')
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
            priorityClass = Get-RooPropertyValue $currentState 'priorityClass' $null
            affinityMask = Get-RooPropertyValue $currentState 'affinityMask' $null
            ioPriority = Get-RooPropertyValue $currentState 'ioPriority' $null
            gpuPriority = Get-RooPropertyValue $currentState 'gpuPriority' $null
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked) { Get-RooPropertyValue $currentState 'priorityClass' $null } else { $originalPriority }
            affinityMask = if ($blocked) { Get-RooPropertyValue $currentState 'affinityMask' $null } else { $originalAffinity }
            ioPriority = if ($blocked) { Get-RooPropertyValue $currentState 'ioPriority' $null } else { $originalIoPriority }
            gpuPriority = if ($blocked) { Get-RooPropertyValue $currentState 'gpuPriority' $null } else { $originalGpuPriority }
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
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $resolvedSessionPath = Resolve-RooProcessGovernorSessionFile $SessionId $SessionPath $StateRoot
        if ($resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
            $session = Read-RooJsonFile $resolvedSessionPath
            $BackupPath = [string](Get-RooPropertyValue $session 'backupManifestPath' '')
        }
    }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'No process governor backup path was provided or found for the selected session.'
    }
    $resolvedBackupPath = Resolve-RooPath $BackupPath $BackupPath
    $backup = Read-RooJsonFile $resolvedBackupPath
    $sessionIdValue = [string](Get-RooPropertyValue $backup 'sessionId' (Get-RooPropertyValue $session 'sessionId' ''))
    $profileId = [string](Get-RooPropertyValue $backup 'profileId' (Get-RooPropertyValue $session 'profileId' ''))
    $startedAtUtc = Get-RooUtcStamp

    $preview = New-Object System.Collections.Generic.List[object]
    $snapshotList=@(Get-RooPropertyArray $backup 'snapshots')
    $seenIdentities=@{}
    for($snapshotIndex=$snapshotList.Count-1;$snapshotIndex -ge 0;$snapshotIndex--) {
        $snapshot=$snapshotList[$snapshotIndex]
        $identityKey=([string](Get-RooPropertyValue $snapshot 'processId' 0))+'|'+([string](Get-RooPropertyValue $snapshot 'processStartTimeUtc' ''))+'|'+([string](Get-RooPropertyValue $snapshot 'executablePath' ''))
        if($seenIdentities.ContainsKey($identityKey)){continue}
        $seenIdentities[$identityKey]=$true
        $candidate = Get-RooProcessGovernorLiveIdentity ([pscustomobject]@{
            processId = Get-RooPropertyValue $snapshot 'processId' 0
            processName = Get-RooPropertyValue $snapshot 'processName' ''
            executablePath = Get-RooPropertyValue $snapshot 'executablePath' $null
            processStartTimeUtc = Get-RooPropertyValue $snapshot 'processStartTimeUtc' $null
        })
        $preview.Add((New-GovernorRestorePreview $snapshot $candidate)) | Out-Null
    }

    $changed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $restored = New-Object System.Collections.Generic.List[object]
    if ($ConfirmApply) {
        foreach ($entry in @($preview.ToArray())) {
            if ([bool](Get-RooPropertyValue $entry 'blocked' $false)) {
                $skip = [pscustomobject]@{
                    processId = Get-RooPropertyValue $entry 'processId' 0
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = Get-RooPropertyValue $entry 'blockedReason' 'Restore entry is blocked.'
                    skippedAtUtc = Get-RooUtcStamp
                }
                $skipped.Add($skip) | Out-Null
                continue
            }
            $processId = [int](Get-RooPropertyValue $entry 'processId' 0)
            $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -eq $live) {
                $skipped.Add([pscustomobject]@{
                    processId = $processId
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = 'Process exited before governor restore.'
                    skippedAtUtc = Get-RooUtcStamp
                }) | Out-Null
                continue
            }
            $entryControlChanges = @(Get-RooGovernorApplicableControlChanges @(Get-RooPreviewControlChanges $entry))
            if ($entryControlChanges.Count -eq 0) { continue }
            $appliedControls = New-Object System.Collections.Generic.List[object]
            $failedControls = New-Object System.Collections.Generic.List[string]
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
                $restoreItem = [pscustomobject]@{
                    processId = $processId
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    restoredPriorityClass = $afterControls.priorityClass
                    restoredAffinityMask = $afterControls.affinityMask
                    restoredIoPriority = $afterControls.ioPriority
                    restoredGpuPriority = $afterControls.gpuPriority
                    restoredControls = @($appliedControls.ToArray())
                    ruleId = Get-RooPropertyValue $entry 'ruleId' ''
                    restoredAtUtc = Get-RooUtcStamp
                }
                $restored.Add($restoreItem) | Out-Null
                $changed.Add($restoreItem) | Out-Null
            }
            if ($failedControls.Count -gt 0) {
                $skipped.Add([pscustomobject]@{
                    processId = $processId
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = $failedControls -join '; '
                    skippedAtUtc = Get-RooUtcStamp
                }) | Out-Null
            }
        }
    } else {
        foreach ($entry in @($preview.ToArray())) {
            if ([bool](Get-RooPropertyValue $entry 'blocked' $false)) {
                $skipped.Add([pscustomobject]@{
                    processId = Get-RooPropertyValue $entry 'processId' 0
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = Get-RooPropertyValue $entry 'blockedReason' 'Restore entry is blocked.'
                    skippedAtUtc = Get-RooUtcStamp
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
        $warnings.Add((New-RooIssue 'PROCESS_GOVERNOR_RESTORE_PREVIEW_ONLY' 'Governor restore preview did not change any process because -ConfirmApply was omitted.' 'info' 'performance.governor' $resolvedBackupPath $false 'Rerun with -ConfirmApply only after reviewing the restore preview.' $null)) | Out-Null
    }
    $summary = if ($ConfirmApply) {
        "Process governor restore completed with $($restored.Count) restored item(s) and $($skipped.Count) skipped item(s)."
    } else {
        'Process governor restore preview completed. No process changes were applied.'
    }
    $backupMetadata = New-RooProcessGovernorBackupMetadata $backup $resolvedBackupPath
    $result = [pscustomobject]@{
        resultId = "process-governor-restore-$(Get-RooFileStamp)"
        status = if ($status -eq 'completed' -and $ConfirmApply) { 'rolledBack' } elseif ($status -eq 'preview') { 'preview' } else { $status }
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-RooUtcStamp
        summary = $summary
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        artifacts = @([pscustomobject]@{ type = 'processGovernorSessionBackup'; path = $resolvedBackupPath })
    }
    $envelope = [pscustomobject]@{
        actionId = 'performance.governor.stopSession'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        correlationId = $sessionIdValue
        sessionId = $sessionIdValue
        dryRun = (-not $ConfirmApply)
        profileId = $profileId
        status = $status
        sessionStatus = $sessionStatus
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-RooUtcStamp
        sessionPath = $resolvedSessionPath
        backupManifestPath = $resolvedBackupPath
        restorable = (-not $ConfirmApply)
        preview = @($preview.ToArray())
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        backup = $backupMetadata
        result = $result
        warnings = @($warnings.ToArray())
        errors = @()
        logs = @((New-RooLog $summary))
    }

    if ($ConfirmApply -and $resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
        $session = Read-RooJsonFile $resolvedSessionPath
        $session.sessionStatus = $sessionStatus
        $session.status = $sessionStatus
        $session.restorable = $false
        $session.activeRestraints = @()
        $session.restoredItems = @($restored.ToArray())
        $session.skippedItems = @($skipped.ToArray())
        $session.completedAtUtc = Get-RooUtcStamp
        Write-RooProcessGovernorJsonFile $session $resolvedSessionPath
        Add-RooProcessGovernorLogFileEntry (Split-Path $resolvedSessionPath -Parent) (New-RooLog $summary)
    }

    Write-RooJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.governor.stopSession'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        correlationId = $SessionId
        sessionId = if ([string]::IsNullOrWhiteSpace($SessionId)) { $null } else { $SessionId }
        dryRun = (-not $ConfirmApply)
        profileId = $null
        status = 'failed'
        sessionStatus = 'failed'
        startedAtUtc = $null
        completedAtUtc = Get-RooUtcStamp
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
        errors = @((New-RooIssue 'PROCESS_GOVERNOR_RESTORE_FAILED' $_.Exception.Message 'error' 'performance.governor' $BackupPath $true 'Check the session id, session path, or backup path and retry.' $null))
        logs = @((New-RooLog 'Process governor restore failed.' 'error'))
    }
    Write-RooJsonOutput $errorEnvelope $OutputPath
    exit 1
}
