param(
    [string]$ProfilePath = '',
    [int]$PollIntervalSeconds = 5,
    [int]$MaxDurationSeconds = 60,
    [string]$OutputPath = '',
    [string]$StateRoot = '',
    [string]$TargetGameProcessName = '',
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameTuneSession.Common.ps1')

function Write-SessionState {
    param(
        [object]$State,
        [string]$SessionDirectory
    )
    if ([string]::IsNullOrWhiteSpace($SessionDirectory)) { return }
    Write-RooGameTuneJsonFile $State (Join-Path $SessionDirectory 'session.json')
}

try {
    if ($PollIntervalSeconds -lt 1) { $PollIntervalSeconds = 1 }
    if ($MaxDurationSeconds -lt 1) { $MaxDurationSeconds = 1 }

    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\game-session.profile.json'
    $resolvedProfilePath = Resolve-RooPath $ProfilePath $defaultProfilePath
    $profile = Read-RooJsonFile $resolvedProfilePath
    $profileId = [string](Get-RooPropertyValue $profile 'profileId' 'game-session')
    $sessionId = New-RooGameTuneSessionId $profileId
    $startedAtUtc = Get-RooUtcStamp
    $sessionDirectory = $null
    $sessionStatePath = $null
    $backupPath = $null
    $resolvedGameTuneStateRoot = $null

    if ($ConfirmApply) {
        $resolvedGameTuneStateRoot = Resolve-RooGameTuneStateRoot $StateRoot
        $sessionDirectory = Get-RooGameTuneSessionDirectory $resolvedGameTuneStateRoot $sessionId
        Ensure-RooDirectory $sessionDirectory
        $sessionStatePath = Join-Path $sessionDirectory 'session.json'
    }

    $changed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $restored = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $logs = New-Object System.Collections.Generic.List[object]
    $polls = New-Object System.Collections.Generic.List[object]
    $snapshots = New-Object System.Collections.Generic.List[object]
    $snapshotKeys = New-Object 'System.Collections.Generic.HashSet[string]'

    $backupManifest = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooProcessProductName
        backupId = "game-tune-$profileId-$(Get-RooFileStamp)"
        sessionId = $sessionId
        createdAtUtc = $startedAtUtc
        actionId = 'performance.gameTune.startSession'
        profileId = $profileId
        profilePath = $resolvedProfilePath
        dryRun = $false
        snapshots = @()
    }

    $logs.Add((New-RooLog "Game Tune session $sessionId started.")) | Out-Null
    if (-not $ConfirmApply) {
        $warnings.Add((New-RooIssue 'GAME_TUNE_DRY_RUN' 'Game Tune session ran in dry-run mode. No process priority changes were applied.' 'info' 'performance.gameTune' $profileId $false 'Rerun with -ConfirmApply only after reviewing the per-poll preview.' $null)) | Out-Null
    } else {
        Add-RooGameTuneLogFileEntry $sessionDirectory (New-RooLog 'Confirmed Game Tune session state initialized.')
    }

    $state = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooProcessProductName
        sessionId = $sessionId
        profileId = $profileId
        profilePath = $resolvedProfilePath
        targetGameProcessName = if ([string]::IsNullOrWhiteSpace($TargetGameProcessName)) { $null } else { $TargetGameProcessName }
        dryRun = (-not $ConfirmApply)
        sessionStatus = 'running'
        status = 'running'
        startedAtUtc = $startedAtUtc
        completedAtUtc = $null
        pollIntervalSeconds = $PollIntervalSeconds
        maxDurationSeconds = $MaxDurationSeconds
        pollCount = 0
        stateRoot = $resolvedGameTuneStateRoot
        sessionPath = $sessionStatePath
        backupManifestPath = $null
        restorable = $false
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        warnings = @($warnings.ToArray())
        errors = @()
        logs = @($logs.ToArray())
    }
    if ($ConfirmApply) { Write-SessionState $state $sessionDirectory }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollIndex = 0
    while ($true) {
        $pollIndex++
        $pollStartedAtUtc = Get-RooUtcStamp
        $previewArgs = @{ ProfilePath = $resolvedProfilePath }
        if (-not [string]::IsNullOrWhiteSpace($TargetGameProcessName)) {
            $previewArgs['TargetGameProcessName'] = $TargetGameProcessName
        }
        $previewEnvelope = & (Join-Path $PSScriptRoot 'Preview-ProcessProfile.ps1') @previewArgs | ConvertFrom-Json
        foreach ($warning in @(Get-RooPropertyArray $previewEnvelope 'warnings')) { $warnings.Add($warning) | Out-Null }
        foreach ($errorItem in @(Get-RooPropertyArray $previewEnvelope 'errors')) { $errors.Add($errorItem) | Out-Null }

        $pollWouldApply = New-Object System.Collections.Generic.List[object]
        $pollChanged = New-Object System.Collections.Generic.List[object]
        $pollSkipped = New-Object System.Collections.Generic.List[object]

        foreach ($entry in @(Get-RooPropertyArray $previewEnvelope 'preview')) {
            $entryControlChanges = @(Get-RooPreviewControlChanges $entry)
            if ($entryControlChanges.Count -eq 0) { continue }

            $allowed = Test-RooGameTuneEntryAllowed $entry
            if (-not $allowed.allowed) {
                $skip = New-RooGameTuneSkippedItem $entry $allowed.reason $pollIndex
                $skipped.Add($skip) | Out-Null
                $pollSkipped.Add($skip) | Out-Null
                continue
            }

            if (-not $ConfirmApply) {
                $wouldApply = [pscustomobject]@{
                    processId = [int](Get-RooPropertyValue $entry 'processId' 0)
                    processName = [string](Get-RooPropertyValue $entry 'processName' '')
                    currentPriorityClass = Get-RooPropertyValue $entry 'currentPriorityClass' $null
                    proposedPriorityClass = Get-RooPropertyValue $entry 'proposedPriorityClass' $null
                    currentAffinityMask = Get-RooPropertyValue $entry 'currentAffinityMask' $null
                    proposedAffinityMask = Get-RooPropertyValue $entry 'proposedAffinityMask' $null
                    currentIoPriority = Get-RooPropertyValue $entry 'currentIoPriority' $null
                    proposedIoPriority = Get-RooPropertyValue $entry 'proposedIoPriority' $null
                    currentGpuPriority = Get-RooPropertyValue $entry 'currentGpuPriority' $null
                    proposedGpuPriority = Get-RooPropertyValue $entry 'proposedGpuPriority' $null
                    controlChanges = @($entryControlChanges)
                    ruleId = Get-RooPropertyValue $entry 'ruleId' $null
                    reason = Get-RooPropertyValue $entry 'reason' $null
                }
                $pollWouldApply.Add($wouldApply) | Out-Null
                $skip = New-RooGameTuneSkippedItem $entry 'Dry-run session; -ConfirmApply was not provided.' $pollIndex
                $skipped.Add($skip) | Out-Null
                $pollSkipped.Add($skip) | Out-Null
                continue
            }

            $identity = Get-RooGameTuneLiveProcessIdentity $entry
            if (-not $identity.exists -or -not $identity.matches) {
                $skip = New-RooGameTuneSkippedItem $entry $identity.reason $pollIndex
                $skipped.Add($skip) | Out-Null
                $pollSkipped.Add($skip) | Out-Null
                continue
            }

            $snapshotKey = "$([int](Get-RooPropertyValue $entry 'processId' 0))|$([string](Get-RooPropertyValue $entry 'processName' ''))|$([string](Get-RooPropertyValue $entry 'executablePath' ''))"
            $originalState = [pscustomobject]@{
                priorityClass = [string]$identity.currentPriorityClass
                affinityMask = $identity.currentAffinityMask
                ioPriority = $identity.currentIoPriority
                gpuPriority = $identity.currentGpuPriority
            }
            if (-not $snapshotKeys.Contains($snapshotKey)) {
                $snapshot = [pscustomobject]@{
                    processId = [int](Get-RooPropertyValue $entry 'processId' 0)
                    processName = [string](Get-RooPropertyValue $entry 'processName' '')
                    executablePath = Get-RooPropertyValue $entry 'executablePath' $identity.currentPath
                    originalPriorityClass = [string]$identity.currentPriorityClass
                    proposedPriorityClass = Get-RooPropertyValue $entry 'proposedPriorityClass' $null
                    originalAffinityMask = $identity.currentAffinityMask
                    proposedAffinityMask = Get-RooPropertyValue $entry 'proposedAffinityMask' $null
                    originalIoPriority = $identity.currentIoPriority
                    proposedIoPriority = Get-RooPropertyValue $entry 'proposedIoPriority' $null
                    originalGpuPriority = $identity.currentGpuPriority
                    proposedGpuPriority = Get-RooPropertyValue $entry 'proposedGpuPriority' $null
                    controlChanges = @($entryControlChanges)
                    capturedAtUtc = Get-RooUtcStamp
                    profileId = $profileId
                    ruleId = [string](Get-RooPropertyValue $entry 'ruleId' '')
                    reason = [string](Get-RooPropertyValue $entry 'reason' '')
                    sessionId = $sessionId
                }
                $snapshots.Add($snapshot) | Out-Null
                $snapshotKeys.Add($snapshotKey) | Out-Null
            }

            $appliedControls = New-Object System.Collections.Generic.List[object]
            $failedControls = New-Object System.Collections.Generic.List[string]
            foreach ($change in $entryControlChanges) {
                try {
                    Invoke-RooProcessControlChange $identity.process $change
                    $appliedControls.Add($change) | Out-Null
                } catch {
                    $failedControls.Add("$([string](Get-RooPropertyValue $change 'control' 'unknown')): $($_.Exception.Message)") | Out-Null
                }
            }

            if ($appliedControls.Count -gt 0) {
                $afterControls = Get-RooProcessControlState ([int](Get-RooPropertyValue $entry 'processId' 0)) $null
                $appliedState = [pscustomobject]@{
                    priorityClass = $afterControls.priorityClass
                    affinityMask = $afterControls.affinityMask
                    ioPriority = $afterControls.ioPriority
                    gpuPriority = $afterControls.gpuPriority
                }
                $changedItem = New-RooGameTuneChangedItem $entry $originalState $appliedState @($appliedControls.ToArray()) $pollIndex
                $changed.Add($changedItem) | Out-Null
                $pollChanged.Add($changedItem) | Out-Null
            }
            if ($failedControls.Count -gt 0) {
                $skip = New-RooGameTuneSkippedItem $entry ($failedControls -join '; ') $pollIndex
                $skipped.Add($skip) | Out-Null
                $pollSkipped.Add($skip) | Out-Null
            }
        }

        $poll = [pscustomobject]@{
            pollIndex = $pollIndex
            capturedAtUtc = $pollStartedAtUtc
            previewCount = @(Get-RooPropertyArray $previewEnvelope 'preview').Count
            wouldApplyItems = @($pollWouldApply.ToArray())
            changedItems = @($pollChanged.ToArray())
            skippedItems = @($pollSkipped.ToArray())
        }
        $polls.Add($poll) | Out-Null
        $logEntry = New-RooLog "Game Tune poll $pollIndex completed with $($pollChanged.Count) changed item(s), $($pollWouldApply.Count) dry-run item(s), and $($pollSkipped.Count) skipped item(s)."
        $logs.Add($logEntry) | Out-Null
        if ($ConfirmApply) {
            Add-RooGameTuneLogFileEntry $sessionDirectory $logEntry
            if ($snapshots.Count -gt 0) {
                $backupManifest.snapshots = @($snapshots.ToArray())
                $backupPath = Join-Path $sessionDirectory 'backup.json'
                Write-RooGameTuneJsonFile $backupManifest $backupPath
            }
            $state.pollCount = $pollIndex
            $state.changedItems = @($changed.ToArray())
            $state.skippedItems = @($skipped.ToArray())
            $state.warnings = @($warnings.ToArray())
            $state.errors = @($errors.ToArray())
            $state.logs = @($logs.ToArray())
            $state.backupManifestPath = $backupPath
            $state.restorable = ($snapshots.Count -gt 0)
            Write-SessionState $state $sessionDirectory
        }

        if ($stopwatch.Elapsed.TotalSeconds -ge $MaxDurationSeconds) { break }
        if (($stopwatch.Elapsed.TotalSeconds + $PollIntervalSeconds) -gt $MaxDurationSeconds) { break }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    $sessionStatus = if ($errors.Count -gt 0) { 'failed' } else { 'completed' }
    $resultStatus = if ($ConfirmApply) {
        if ($changed.Count -gt 0 -and $skipped.Count -gt 0) { 'partial' }
        elseif ($changed.Count -gt 0) { 'success' }
        elseif ($skipped.Count -gt 0) { 'failed' }
        else { 'success' }
    } else {
        'preview'
    }
    $completedAtUtc = Get-RooUtcStamp
    $backupMetadata = if ($backupPath -and (Test-Path -LiteralPath $backupPath)) { New-RooGameTuneBackupMetadata $backupManifest $backupPath } else { $null }
    $artifacts = New-Object System.Collections.Generic.List[object]
    if ($sessionStatePath) { $artifacts.Add([pscustomobject]@{ type = 'gameTuneSessionState'; path = $sessionStatePath }) | Out-Null }
    if ($backupPath) { $artifacts.Add([pscustomobject]@{ type = 'gameTuneSessionBackup'; path = $backupPath }) | Out-Null }

    $result = New-RooGameTuneResult `
        -ResultId ("game-tune-session-" + (Get-RooFileStamp)) `
        -Status $resultStatus `
        -Summary "Game Tune session completed after $pollIndex poll(s) with $($changed.Count) changed item(s), $($skipped.Count) skipped item(s), and $($restored.Count) restored item(s)." `
        -ChangedItems @($changed.ToArray()) `
        -SkippedItems @($skipped.ToArray()) `
        -RestoredItems @($restored.ToArray()) `
        -Artifacts @($artifacts.ToArray())

    $envelope = [pscustomobject]@{
        actionId = 'performance.gameTune.startSession'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        correlationId = $sessionId
        sessionId = $sessionId
        dryRun = (-not $ConfirmApply)
        profileId = $profileId
        profilePath = $resolvedProfilePath
        targetGameProcessName = if ([string]::IsNullOrWhiteSpace($TargetGameProcessName)) { $null } else { $TargetGameProcessName }
        status = $sessionStatus
        sessionStatus = $sessionStatus
        startedAtUtc = $startedAtUtc
        completedAtUtc = $completedAtUtc
        pollIntervalSeconds = $PollIntervalSeconds
        maxDurationSeconds = $MaxDurationSeconds
        pollCount = $pollIndex
        stateRoot = $resolvedGameTuneStateRoot
        sessionPath = $sessionStatePath
        backupManifestPath = $backupPath
        restorable = ($null -ne $backupMetadata)
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        polls = @($polls.ToArray())
        backup = $backupMetadata
        result = $result
        warnings = @($warnings.ToArray())
        errors = @($errors.ToArray())
        logs = @($logs.ToArray())
    }

    if ($ConfirmApply) {
        $state.sessionStatus = $sessionStatus
        $state.status = $sessionStatus
        $state.completedAtUtc = $completedAtUtc
        $state.pollCount = $pollIndex
        $state.changedItems = @($changed.ToArray())
        $state.skippedItems = @($skipped.ToArray())
        $state.restoredItems = @($restored.ToArray())
        $state.backupManifestPath = $backupPath
        $state.restorable = ($null -ne $backupMetadata)
        $state.warnings = @($warnings.ToArray())
        $state.errors = @($errors.ToArray())
        $state.logs = @($logs.ToArray())
        Write-SessionState $state $sessionDirectory
    }

    Write-RooJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.gameTune.startSession'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        correlationId = $null
        sessionId = $null
        dryRun = (-not $ConfirmApply)
        profileId = $null
        profilePath = $ProfilePath
        targetGameProcessName = if ([string]::IsNullOrWhiteSpace($TargetGameProcessName)) { $null } else { $TargetGameProcessName }
        status = 'failed'
        sessionStatus = 'failed'
        startedAtUtc = $null
        completedAtUtc = Get-RooUtcStamp
        pollIntervalSeconds = $PollIntervalSeconds
        maxDurationSeconds = $MaxDurationSeconds
        pollCount = 0
        stateRoot = $null
        sessionPath = $null
        backupManifestPath = $null
        restorable = $false
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        polls = @()
        backup = $null
        result = $null
        warnings = @()
        errors = @((New-RooIssue 'GAME_TUNE_SESSION_FAILED' $_.Exception.Message 'error' 'performance.gameTune' $ProfilePath $true 'Review profile path, permissions, and process inventory availability.' $null))
        logs = @((New-RooLog 'Game Tune session failed.' 'error'))
    }
    Write-RooJsonOutput $errorEnvelope $OutputPath
    exit 1
}
