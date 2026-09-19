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
. (Join-Path $PSScriptRoot 'ProcessPolicyRules.Common.ps1')

function Resolve-PolicyRestoreAuditStateRoot {
    param(
        [string]$ProvidedStateRoot,
        [object]$Session
    )
    if (-not [string]::IsNullOrWhiteSpace($ProvidedStateRoot)) { return $ProvidedStateRoot }
    $sessionStateRoot = [string](Get-RooIndustriesPropertyValue $Session 'stateRoot' '')
    if ([string]::IsNullOrWhiteSpace($sessionStateRoot)) { return $ProvidedStateRoot }
    $leaf = Split-Path $sessionStateRoot -Leaf
    if ($leaf -eq $script:RooIndustriesProcessPolicyStateFolderName) {
        return Split-Path $sessionStateRoot -Parent
    }
    return $sessionStateRoot
}

function New-PolicyRestorePreview {
    param(
        [object]$Snapshot,
        [object]$Candidate
    )
    $processId = [int](Get-RooIndustriesPropertyValue $Snapshot 'processId' 0)
    $processName = [string](Get-RooIndustriesPropertyValue $Snapshot 'processName' '')
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
        Get-RooIndustriesProcessControlState $processId $null
    }
    $restoreChanges = if ($blocked) { @() } else { @(Get-RooIndustriesProcessPolicyRestoreChanges $Snapshot $currentState) }
    $restoreChanges = @($restoreChanges)
    $restoreChangeCount = @($restoreChanges).Count
    if (-not $blocked -and $restoreChangeCount -eq 0) {
        $reason = 'Process already matches the persistent policy backup.'
    }
    $proposedAction = if ($blocked -or $restoreChangeCount -eq 0) {
        'noChange'
    } elseif ($restoreChangeCount -eq 1 -and [string](Get-RooIndustriesPropertyValue $restoreChanges[0] 'control' '') -eq 'priorityClass') {
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
        executablePath = Get-RooIndustriesPropertyValue $Snapshot 'executablePath' $null
        currentPriorityClass = Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null
        proposedPriorityClass = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null } else { Get-RooIndustriesPropertyValue $Snapshot 'originalPriorityClass' $null }
        currentAffinityMask = Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null
        proposedAffinityMask = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null } else { Get-RooIndustriesPropertyValue $Snapshot 'originalAffinityMask' $null }
        currentIoPriority = Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null
        proposedIoPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null } else { Get-RooIndustriesPropertyValue $Snapshot 'originalIoPriority' $null }
        currentGpuPriority = Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null
        proposedGpuPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null } else { Get-RooIndustriesPropertyValue $Snapshot 'originalGpuPriority' $null }
        proposedAction = $proposedAction
        controlChanges = @($restoreChanges)
        ruleId = [string](Get-RooIndustriesPropertyValue $Snapshot 'ruleId' '')
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
            priorityClass = Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null
            affinityMask = Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null
            ioPriority = Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null
            gpuPriority = Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'priorityClass' $null } else { Get-RooIndustriesPropertyValue $Snapshot 'originalPriorityClass' $null }
            affinityMask = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'affinityMask' $null } else { Get-RooIndustriesPropertyValue $Snapshot 'originalAffinityMask' $null }
            ioPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'ioPriority' $null } else { Get-RooIndustriesPropertyValue $Snapshot 'originalIoPriority' $null }
            gpuPriority = if ($blocked) { Get-RooIndustriesPropertyValue $currentState 'gpuPriority' $null } else { Get-RooIndustriesPropertyValue $Snapshot 'originalGpuPriority' $null }
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
        $resolvedSessionPath = Resolve-RooIndustriesProcessPolicySessionFile $SessionId $SessionPath $StateRoot
        if ($resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
            $session = Read-RooIndustriesJsonFile $resolvedSessionPath
            $BackupPath = [string](Get-RooIndustriesPropertyValue $session 'backupManifestPath' '')
        }
    }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'No persistent policy backup path was provided or found for the selected session.'
    }
    $resolvedBackupPath = Resolve-RooIndustriesPath $BackupPath $BackupPath
    $backup = Read-RooIndustriesJsonFile $resolvedBackupPath
    $sessionIdValue = [string](Get-RooIndustriesPropertyValue $backup 'sessionId' (Get-RooIndustriesPropertyValue $session 'sessionId' ''))
    $profileId = [string](Get-RooIndustriesPropertyValue $backup 'profileId' (Get-RooIndustriesPropertyValue $session 'profileId' ''))
    $startedAtUtc = Get-RooIndustriesUtcStamp

    $preview = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @(Get-RooIndustriesPropertyArray $backup 'snapshots')) {
        $candidate = Get-RooIndustriesProcessPolicyLiveIdentity ([pscustomobject]@{
            processId = Get-RooIndustriesPropertyValue $snapshot 'processId' 0
            processName = Get-RooIndustriesPropertyValue $snapshot 'processName' ''
            executablePath = Get-RooIndustriesPropertyValue $snapshot 'executablePath' $null
        })
        $preview.Add((New-PolicyRestorePreview $snapshot $candidate)) | Out-Null
    }

    $changed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $restored = New-Object System.Collections.Generic.List[object]
    $auditRows = New-Object System.Collections.Generic.List[object]
    $auditStateRoot = Resolve-PolicyRestoreAuditStateRoot $StateRoot $session
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
                $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'sessionRestore' -RuleId ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')) -SessionId $sessionIdValue -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string](Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Restore entry is blocked.')) -ProtectionCategory 'rollbackCandidate' -RestorePath $resolvedBackupPath -RestoreAvailable $true -Outcome 'skipped' -DryRun $false -Source 'processPolicySession')) | Out-Null
                continue
            }
            $processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
            $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -eq $live) {
                $skipped.Add([pscustomobject]@{
                    processId = $processId
                    processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                    reason = 'Process exited before persistent policy restore.'
                    skippedAtUtc = Get-RooIndustriesUtcStamp
                }) | Out-Null
                $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'sessionRestore' -RuleId ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')) -SessionId $sessionIdValue -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason 'Process exited before persistent policy restore.' -ProtectionCategory 'rollbackCandidate' -RestorePath $resolvedBackupPath -RestoreAvailable $true -Outcome 'skipped' -DryRun $false -Source 'processPolicySession')) | Out-Null
                continue
            }
            $entryControlChanges = @(Get-RooIndustriesPreviewControlChanges $entry)
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
                $afterControls = Get-RooIndustriesProcessControlState $processId $null
                $restoreItem = [pscustomobject]@{
                    processId = $processId
                    processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                    restoredPriorityClass = $afterControls.priorityClass
                    restoredAffinityMask = $afterControls.affinityMask
                    restoredIoPriority = $afterControls.ioPriority
                    restoredGpuPriority = $afterControls.gpuPriority
                    restoredControls = @($appliedControls.ToArray())
                    ruleId = Get-RooIndustriesPropertyValue $entry 'ruleId' ''
                    restoredAtUtc = Get-RooIndustriesUtcStamp
                }
                $restored.Add($restoreItem) | Out-Null
                $changed.Add($restoreItem) | Out-Null
                foreach ($appliedControl in @($appliedControls.ToArray())) {
                    $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'sessionRestore' -RuleId ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')) -SessionId $sessionIdValue -Target $entry -Control ([string](Get-RooIndustriesPropertyValue $appliedControl 'control' 'processControls')) -BeforeValue (Get-RooIndustriesPropertyValue $appliedControl 'currentValue' $null) -AfterValue (Get-RooIndustriesPropertyValue $appliedControl 'proposedValue' $null) -Reason ([string](Get-RooIndustriesPropertyValue $appliedControl 'reason' 'Restore original process controls.')) -ProtectionCategory 'rollbackCandidate' -RestorePath $resolvedBackupPath -RestoreAvailable $true -Outcome 'restored' -DryRun $false -Source 'processPolicySession')) | Out-Null
                }
            }
            if ($failedControls.Count -gt 0) {
                $skipped.Add([pscustomobject]@{
                    processId = $processId
                    processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                    reason = $failedControls -join '; '
                    skippedAtUtc = Get-RooIndustriesUtcStamp
                }) | Out-Null
                $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'sessionRestore' -RuleId ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')) -SessionId $sessionIdValue -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ($failedControls -join '; ') -ProtectionCategory 'rollbackCandidate' -RestorePath $resolvedBackupPath -RestoreAvailable $true -Outcome 'failed' -DryRun $false -Source 'processPolicySession')) | Out-Null
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
        $warnings.Add((New-RooIndustriesIssue 'PROCESS_POLICY_RESTORE_PREVIEW_ONLY' 'Persistent policy restore preview did not change any process because -ConfirmApply was omitted.' 'info' 'performance.policy' $resolvedBackupPath $false 'Rerun with -ConfirmApply only after reviewing the restore preview.' $null)) | Out-Null
    }
    $summary = if ($ConfirmApply) {
        "Persistent policy restore completed with $($restored.Count) restored item(s) and $($skipped.Count) skipped item(s)."
    } else {
        'Persistent policy restore preview completed. No process changes were applied.'
    }
    $backupMetadata = New-RooIndustriesProcessPolicyBackupMetadata $backup $resolvedBackupPath
    $auditPath = Add-RooIndustriesProcessPolicyAuditRows -StateRoot $auditStateRoot -Rows @($auditRows.ToArray())
    $result = [pscustomobject]@{
        resultId = "process-policy-restore-$(Get-RooIndustriesFileStamp)"
        status = if ($status -eq 'completed' -and $ConfirmApply) { 'rolledBack' } elseif ($status -eq 'preview') { 'preview' } else { $status }
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-RooIndustriesUtcStamp
        summary = $summary
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        artifacts = @([pscustomobject]@{ type = 'processPolicySessionBackup'; path = $resolvedBackupPath })
    }
    $envelope = [pscustomobject]@{
        actionId = 'performance.policy.stopSession'
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
        auditPath = $auditPath
        restorable = (-not $ConfirmApply)
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
        $session.restorable = $false
        $session.activeApplications = @()
        $session.restoredItems = @($restored.ToArray())
        $session.skippedItems = @($skipped.ToArray())
        $session.completedAtUtc = Get-RooIndustriesUtcStamp
        Write-RooIndustriesProcessPolicyJsonFile $session $resolvedSessionPath
        Add-RooIndustriesProcessPolicyLogFileEntry (Split-Path $resolvedSessionPath -Parent) (New-RooIndustriesLog $summary)
    }

    Write-RooIndustriesJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.policy.stopSession'
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
        errors = @((New-RooIndustriesIssue 'PROCESS_POLICY_RESTORE_FAILED' $_.Exception.Message 'error' 'performance.policy' $BackupPath $true 'Check the session id, session path, or backup path and retry.' $null))
        logs = @((New-RooIndustriesLog 'Persistent policy restore failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorEnvelope $OutputPath
    exit 1
}
