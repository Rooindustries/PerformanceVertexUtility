param(
    [string]$SessionId = '',
    [string]$SessionPath = '',
    [string]$BackupPath = '',
    [string]$StateRoot = '',
    [string]$OutputPath = '',
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameTuneSession.Common.ps1')

function New-GameTuneRestorePreview {
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
    $blocked = (-not $Candidate.exists) -or (-not $Candidate.matches)
    $reason = if ($blocked) {
        [string]$Candidate.reason
    } else {
        'Restore original process controls from Game Tune session backup.'
    }
    $controlChanges = New-Object System.Collections.Generic.List[object]
    if (-not $blocked) {
        if (-not [string]::IsNullOrWhiteSpace($originalPriority) -and (Test-RooPriorityAllowed $originalPriority) -and [string]$Candidate.currentPriorityClass -ne $originalPriority) {
            $controlChanges.Add((New-RooControlChange 'priorityClass' $Candidate.currentPriorityClass $originalPriority 'restorePriority' 'Restore original process priority.')) | Out-Null
        }
        if ($null -ne $originalAffinityMask -and (Test-RooAffinityMaskAllowed $originalAffinityMask) -and [int64]$Candidate.currentAffinityMask -ne [int64]$originalAffinityMask) {
            $controlChanges.Add((New-RooControlChange 'affinityMask' $Candidate.currentAffinityMask ([int64]$originalAffinityMask) 'restoreAffinity' 'Restore original CPU affinity.')) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$originalIoPriority) -and (Test-RooIoPriorityAllowed $originalIoPriority) -and [string]$Candidate.currentIoPriority -ne [string]$originalIoPriority) {
            $controlChanges.Add((New-RooControlChange 'ioPriority' $Candidate.currentIoPriority $originalIoPriority 'restoreIoPriority' 'Restore original I/O priority.')) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$originalGpuPriority) -and (Test-RooGpuPriorityAllowed $originalGpuPriority) -and [string]$Candidate.currentGpuPriority -ne [string]$originalGpuPriority) {
            if ([bool](Get-RooPropertyValue (Get-RooPropertyValue $Candidate 'currentControlState' $null) 'gpuPriorityAvailable' $false)) {
                $controlChanges.Add((New-RooControlChange 'gpuPriority' $Candidate.currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'Restore original GPU priority.')) | Out-Null
            } else {
                $blocked = $true
                $reason = 'GPU scheduling priority is unavailable for this restore target.'
                $controlChanges.Add((New-RooControlChange 'gpuPriority' $Candidate.currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'GPU scheduling priority is unavailable for this restore target.' $true $reason)) | Out-Null
            }
        }
        if ($controlChanges.Count -eq 0) {
            $reason = 'Process already matches the Game Tune backup.'
        }
    }
    $proposedAction = if ($blocked -or $controlChanges.Count -eq 0) { 'noChange' } elseif ($controlChanges.Count -eq 1 -and [string](Get-RooPropertyValue $controlChanges[0] 'control' '') -eq 'priorityClass') { 'restorePriority' } else { 'restoreProcessControls' }

    return [pscustomobject]@{
        previewId = ("game-tune-restore-$processName-$processId").ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = if ($controlChanges.Count -gt 1) { 'gameTuneProcessControlsRestore' } else { 'gameTuneProcessPriorityRestore' }
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooPropertyValue $Snapshot 'executablePath' $null
        currentPriorityClass = $Candidate.currentPriorityClass
        proposedPriorityClass = if ($blocked) { $Candidate.currentPriorityClass } else { $originalPriority }
        currentAffinityMask = $Candidate.currentAffinityMask
        proposedAffinityMask = if ($blocked) { $Candidate.currentAffinityMask } else { $originalAffinityMask }
        currentIoPriority = $Candidate.currentIoPriority
        proposedIoPriority = if ($blocked) { $Candidate.currentIoPriority } else { $originalIoPriority }
        currentGpuPriority = $Candidate.currentGpuPriority
        proposedGpuPriority = if ($blocked) { $Candidate.currentGpuPriority } else { $originalGpuPriority }
        gpuPriorityAvailable = Get-RooPropertyValue (Get-RooPropertyValue $Candidate 'currentControlState' $null) 'gpuPriorityAvailable' $false
        gpuPriorityStatus = Get-RooPropertyValue (Get-RooPropertyValue $Candidate 'currentControlState' $null) 'gpuPriorityStatus' $null
        proposedAction = $proposedAction
        controlChanges = @($controlChanges.ToArray())
        ruleId = [string](Get-RooPropertyValue $Snapshot 'ruleId' '')
        reason = $reason
        reasonCodes = if ($blocked) { @('GAME_TUNE_RESTORE_SKIPPED') } else { @('GAME_TUNE_PROCESS_CONTROLS_RESTORE') }
        classification = 'rollbackCandidate'
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = 'low'
        confidence = 'medium'
        protected = $false
        requiresConfirmation = ($controlChanges.Count -gt 0 -and -not $blocked)
        rollbackSupported = ($controlChanges.Count -gt 0 -and -not $blocked)
        currentState = [pscustomobject]@{
            priorityClass = $Candidate.currentPriorityClass
            affinityMask = $Candidate.currentAffinityMask
            ioPriority = $Candidate.currentIoPriority
            gpuPriority = $Candidate.currentGpuPriority
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked) { $Candidate.currentPriorityClass } else { $originalPriority }
            affinityMask = if ($blocked) { $Candidate.currentAffinityMask } else { $originalAffinityMask }
            ioPriority = if ($blocked) { $Candidate.currentIoPriority } else { $originalIoPriority }
            gpuPriority = if ($blocked) { $Candidate.currentGpuPriority } else { $originalGpuPriority }
            reason = $reason
        }
        impact = [pscustomobject]@{
            expectedMemoryEffectBytes = 0
            expectedCpuWakeupEffect = 'neutral'
            targetMetrics = @('game-tune-restore-safety')
        }
        rollback = $null
    }
}

try {
    $session = $null
    $resolvedSessionPath = $null
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $resolvedSessionPath = Resolve-RooGameTuneSessionFile $SessionId $SessionPath $StateRoot
        if ($resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
            $session = Read-RooJsonFile $resolvedSessionPath
            $BackupPath = [string](Get-RooPropertyValue $session 'backupManifestPath' '')
        }
    }

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'No Game Tune backup path was provided or found for the selected session.'
    }

    $resolvedBackupPath = Resolve-RooPath $BackupPath $BackupPath
    $backup = Read-RooJsonFile $resolvedBackupPath
    $sessionIdValue = [string](Get-RooPropertyValue $backup 'sessionId' (Get-RooPropertyValue $session 'sessionId' ''))
    $profileId = [string](Get-RooPropertyValue $backup 'profileId' (Get-RooPropertyValue $session 'profileId' ''))
    $startedAtUtc = Get-RooUtcStamp

    $preview = New-Object System.Collections.Generic.List[object]
    $changed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $restored = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @(Get-RooPropertyArray $backup 'snapshots')) {
        $candidateEntry = [pscustomobject]@{
            processId = Get-RooPropertyValue $snapshot 'processId' 0
            processName = Get-RooPropertyValue $snapshot 'processName' ''
            executablePath = Get-RooPropertyValue $snapshot 'executablePath' $null
        }
        $candidate = Get-RooGameTuneLiveProcessIdentity $candidateEntry
        $entry = New-GameTuneRestorePreview $snapshot $candidate
        $preview.Add($entry) | Out-Null
    }

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
                $skip = [pscustomobject]@{
                    processId = $processId
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = 'Process exited before Game Tune restore.'
                    skippedAtUtc = Get-RooUtcStamp
                }
                $skipped.Add($skip) | Out-Null
                continue
            }
            $entryControlChanges = @(Get-RooPreviewControlChanges $entry)
            if ($entryControlChanges.Count -eq 0) {
                continue
            }
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
                $skip = [pscustomobject]@{
                    processId = $processId
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    reason = $failedControls -join '; '
                    skippedAtUtc = Get-RooUtcStamp
                }
                $skipped.Add($skip) | Out-Null
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
        elseif ($restored.Count -gt 0) { 'restored' }
        elseif ($skipped.Count -gt 0) { 'failed' }
        else { 'restored' }
    } else {
        'preview'
    }
    $sessionStatus = if ($ConfirmApply -and $status -in @('restored', 'partial')) { 'completed' } elseif ($status -eq 'failed') { 'failed' } else { 'preview' }

    $warnings = New-Object System.Collections.Generic.List[object]
    if (-not $ConfirmApply) {
        $warnings.Add((New-RooIssue 'GAME_TUNE_RESTORE_PREVIEW_ONLY' 'Restore preview did not change any process because -ConfirmApply was omitted.' 'info' 'performance.gameTune' $resolvedBackupPath $false 'Rerun with -ConfirmApply only after reviewing the restore preview.' $null)) | Out-Null
    }

    $summary = if ($ConfirmApply) {
        "Game Tune restore completed with $($restored.Count) restored item(s) and $($skipped.Count) skipped item(s)."
    } else {
        "Game Tune restore preview completed. No process priority changes were applied."
    }
    $backupMetadata = New-RooGameTuneBackupMetadata $backup $resolvedBackupPath
    $result = New-RooGameTuneResult `
        -ResultId ("game-tune-restore-" + (Get-RooFileStamp)) `
        -Status $(if ($status -eq 'restored') { 'rolledBack' } elseif ($status -eq 'preview') { 'preview' } else { $status }) `
        -Summary $summary `
        -ChangedItems @($changed.ToArray()) `
        -SkippedItems @($skipped.ToArray()) `
        -RestoredItems @($restored.ToArray()) `
        -Artifacts @([pscustomobject]@{ type = 'gameTuneSessionBackup'; path = $resolvedBackupPath })

    $logs = @((New-RooLog $summary))
    $envelope = [pscustomobject]@{
        actionId = 'performance.gameTune.stopSession'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        correlationId = $sessionIdValue
        sessionId = $sessionIdValue
        dryRun = (-not $ConfirmApply)
        profileId = $profileId
        status = $sessionStatus
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
        logs = $logs
    }

    if ($ConfirmApply -and $resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
        $session = Read-RooJsonFile $resolvedSessionPath
        $session.sessionStatus = $sessionStatus
        $session.status = $sessionStatus
        $session.restorable = ($status -eq 'partial')
        $session.restoredItems = @($restored.ToArray())
        $session.skippedItems = @($skipped.ToArray())
        $session.completedAtUtc = Get-RooUtcStamp
        Write-RooGameTuneJsonFile $session $resolvedSessionPath
        Add-RooGameTuneLogFileEntry (Split-Path $resolvedSessionPath -Parent) (New-RooLog $summary)
    }

    Write-RooJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.gameTune.stopSession'
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
        errors = @((New-RooIssue 'GAME_TUNE_RESTORE_FAILED' $_.Exception.Message 'error' 'performance.gameTune' $BackupPath $true 'Check the session id, session path, or backup path and retry.' $null))
        logs = @((New-RooLog 'Game Tune restore failed.' 'error'))
    }
    Write-RooJsonOutput $errorEnvelope $OutputPath
    exit 1
}
