param(
    [string]$SessionId = '',
    [string]$SessionPath = '',
    [string]$BackupPath = '',
    [string]$StateRoot = '',
    [string]$OutputPath = '',
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessPolicy.Common.ps1')

function New-PolicyRestorePreview {
    param(
        [object]$Snapshot,
        [object]$Candidate
    )
    $processId = [int](Get-RooPropertyValue $Snapshot 'processId' 0)
    $processName = [string](Get-RooPropertyValue $Snapshot 'processName' '')
    $blocked = (-not $Candidate.exists) -or (-not $Candidate.matches)
    $reason = if ($blocked) {
        [string]$Candidate.reason
    } else {
        'Restore original process controls from persistent policy backup.'
    }
    $currentState = if ($blocked) {
        [pscustomobject]@{
            priorityClass = $null
            affinityMask = $null
            ioPriority = $null
            gpuPriority = $null
        }
    } else {
        Get-RooProcessControlState $processId $null
    }
    $restoreChanges = if ($blocked) { @() } else { @(Get-RooProcessPolicyRestoreChanges $Snapshot $currentState) }
    $restoreChanges = @($restoreChanges)
    $restoreChangeCount = @($restoreChanges).Count
    if (-not $blocked -and $restoreChangeCount -eq 0) {
        $reason = 'Process already matches the persistent policy backup.'
    }
    $proposedAction = if ($blocked -or $restoreChangeCount -eq 0) {
        'noChange'
    } elseif ($restoreChangeCount -eq 1 -and [string](Get-RooPropertyValue $restoreChanges[0] 'control' '') -eq 'priorityClass') {
        'restorePriority'
    } else {
        'restoreProcessControls'
    }
    return [pscustomobject]@{
        previewId = ("process-policy-restore-$processName-$processId").ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = 'persistentProcessPolicyRestore'
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooPropertyValue $Snapshot 'executablePath' $null
        currentPriorityClass = Get-RooPropertyValue $currentState 'priorityClass' $null
        proposedPriorityClass = if ($blocked) { Get-RooPropertyValue $currentState 'priorityClass' $null } else { Get-RooPropertyValue $Snapshot 'originalPriorityClass' $null }
        currentAffinityMask = Get-RooPropertyValue $currentState 'affinityMask' $null
        proposedAffinityMask = if ($blocked) { Get-RooPropertyValue $currentState 'affinityMask' $null } else { Get-RooPropertyValue $Snapshot 'originalAffinityMask' $null }
        currentIoPriority = Get-RooPropertyValue $currentState 'ioPriority' $null
        proposedIoPriority = if ($blocked) { Get-RooPropertyValue $currentState 'ioPriority' $null } else { Get-RooPropertyValue $Snapshot 'originalIoPriority' $null }
        currentGpuPriority = Get-RooPropertyValue $currentState 'gpuPriority' $null
        proposedGpuPriority = if ($blocked) { Get-RooPropertyValue $currentState 'gpuPriority' $null } else { Get-RooPropertyValue $Snapshot 'originalGpuPriority' $null }
        proposedAction = $proposedAction
        controlChanges = @($restoreChanges)
        ruleId = [string](Get-RooPropertyValue $Snapshot 'ruleId' '')
        reason = $reason
        reasonCodes = if ($blocked) { @('PROCESS_POLICY_RESTORE_SKIPPED') } else { @('PROCESS_POLICY_RESTORE') }
        classification = 'rollbackCandidate'
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = 'low'
        confidence = 'medium'
        protected = $false
        requiresConfirmation = ($restoreChangeCount -gt 0)
        rollbackSupported = ($restoreChangeCount -gt 0)
        currentState = [pscustomobject]@{
            priorityClass = Get-RooPropertyValue $currentState 'priorityClass' $null
            affinityMask = Get-RooPropertyValue $currentState 'affinityMask' $null
            ioPriority = Get-RooPropertyValue $currentState 'ioPriority' $null
            gpuPriority = Get-RooPropertyValue $currentState 'gpuPriority' $null
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked) { Get-RooPropertyValue $currentState 'priorityClass' $null } else { Get-RooPropertyValue $Snapshot 'originalPriorityClass' $null }
            affinityMask = if ($blocked) { Get-RooPropertyValue $currentState 'affinityMask' $null } else { Get-RooPropertyValue $Snapshot 'originalAffinityMask' $null }
            ioPriority = if ($blocked) { Get-RooPropertyValue $currentState 'ioPriority' $null } else { Get-RooPropertyValue $Snapshot 'originalIoPriority' $null }
            gpuPriority = if ($blocked) { Get-RooPropertyValue $currentState 'gpuPriority' $null } else { Get-RooPropertyValue $Snapshot 'originalGpuPriority' $null }
            reason = $reason
        }
        impact = [pscustomobject]@{
            expectedMemoryEffectBytes = 0
            expectedCpuWakeupEffect = 'neutral'
            targetMetrics = @('persistent-policy-restore-safety')
        }
        rollback = $null
    }
}

try {
    $session = $null
    $resolvedSessionPath = $null
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $resolvedSessionPath = Resolve-RooProcessPolicySessionFile $SessionId $SessionPath $StateRoot
        if ($resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
            $session = Read-RooJsonFile $resolvedSessionPath
            $BackupPath = [string](Get-RooPropertyValue $session 'backupManifestPath' '')
        }
    }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'No persistent policy backup path was provided or found for the selected session.'
    }
    $resolvedBackupPath = Resolve-RooPath $BackupPath $BackupPath
    $backup = Read-RooJsonFile $resolvedBackupPath
    $sessionIdValue = [string](Get-RooPropertyValue $backup 'sessionId' (Get-RooPropertyValue $session 'sessionId' ''))
    $profileId = [string](Get-RooPropertyValue $backup 'profileId' (Get-RooPropertyValue $session 'profileId' ''))
    $startedAtUtc = Get-RooUtcStamp

    $preview = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @(Get-RooPropertyArray $backup 'snapshots')) {
        $candidate = Get-RooProcessPolicyLiveIdentity ([pscustomobject]@{
            processId = Get-RooPropertyValue $snapshot 'processId' 0
            processName = Get-RooPropertyValue $snapshot 'processName' ''
            executablePath = Get-RooPropertyValue $snapshot 'executablePath' $null
        })
        $preview.Add((New-PolicyRestorePreview $snapshot $candidate)) | Out-Null
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
                    reason = 'Process exited before persistent policy restore.'
                    skippedAtUtc = Get-RooUtcStamp
                }) | Out-Null
                continue
            }
            $entryControlChanges = @(Get-RooPreviewControlChanges $entry)
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
        $warnings.Add((New-RooIssue 'PROCESS_POLICY_RESTORE_PREVIEW_ONLY' 'Persistent policy restore preview did not change any process because -ConfirmApply was omitted.' 'info' 'performance.policy' $resolvedBackupPath $false 'Rerun with -ConfirmApply only after reviewing the restore preview.' $null)) | Out-Null
    }
    $summary = if ($ConfirmApply) {
        "Persistent policy restore completed with $($restored.Count) restored item(s) and $($skipped.Count) skipped item(s)."
    } else {
        'Persistent policy restore preview completed. No process changes were applied.'
    }
    $backupMetadata = New-RooProcessPolicyBackupMetadata $backup $resolvedBackupPath
    $result = [pscustomobject]@{
        resultId = "process-policy-restore-$(Get-RooFileStamp)"
        status = if ($status -eq 'completed' -and $ConfirmApply) { 'rolledBack' } elseif ($status -eq 'preview') { 'preview' } else { $status }
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-RooUtcStamp
        summary = $summary
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        artifacts = @([pscustomobject]@{ type = 'processPolicySessionBackup'; path = $resolvedBackupPath })
    }
    $envelope = [pscustomobject]@{
        actionId = 'performance.policy.stopSession'
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
        $session.activeApplications = @()
        $session.restoredItems = @($restored.ToArray())
        $session.skippedItems = @($skipped.ToArray())
        $session.completedAtUtc = Get-RooUtcStamp
        Write-RooProcessPolicyJsonFile $session $resolvedSessionPath
        Add-RooProcessPolicyLogFileEntry (Split-Path $resolvedSessionPath -Parent) (New-RooLog $summary)
    }

    Write-RooJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.policy.stopSession'
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
        errors = @((New-RooIssue 'PROCESS_POLICY_RESTORE_FAILED' $_.Exception.Message 'error' 'performance.policy' $BackupPath $true 'Check the session id, session path, or backup path and retry.' $null))
        logs = @((New-RooLog 'Persistent policy restore failed.' 'error'))
    }
    Write-RooJsonOutput $errorEnvelope $OutputPath
    exit 1
}
