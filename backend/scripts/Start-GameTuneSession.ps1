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
    Write-RooIndustriesGameTuneJsonFile $State (Join-Path $SessionDirectory 'session.json')
}

try {
    if ($PollIntervalSeconds -lt 1) { $PollIntervalSeconds = 1 }
    if ($MaxDurationSeconds -lt 1) { $MaxDurationSeconds = 1 }

    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\game-session.profile.json'
    $resolvedProfilePath = Resolve-RooIndustriesPath $ProfilePath $defaultProfilePath
    $profile = Read-RooIndustriesJsonFile $resolvedProfilePath
    $profileId = [string](Get-RooIndustriesPropertyValue $profile 'profileId' 'game-session')
    $sessionId = New-RooIndustriesGameTuneSessionId $profileId
    $startedAtUtc = Get-RooIndustriesUtcStamp
    $sessionDirectory = $null
    $sessionStatePath = $null
    $backupPath = $null
    $resolvedGameTuneStateRoot = $null

    if ($ConfirmApply) {
        $resolvedGameTuneStateRoot = Resolve-RooIndustriesGameTuneStateRoot $StateRoot
        $sessionDirectory = Get-RooIndustriesGameTuneSessionDirectory $resolvedGameTuneStateRoot $sessionId
        Ensure-RooIndustriesDirectory $sessionDirectory
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
    $snapshotsByKey = @{}

    $backupManifest = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        backupId = "game-tune-$profileId-$(Get-RooIndustriesFileStamp)"
        sessionId = $sessionId
        createdAtUtc = $startedAtUtc
        actionId = 'performance.gameTune.startSession'
        profileId = $profileId
        profilePath = $resolvedProfilePath
        dryRun = $false
        snapshots = @()
    }

    $logs.Add((New-RooIndustriesLog "Game Tune session $sessionId started.")) | Out-Null
    if (-not $ConfirmApply) {
        $warnings.Add((New-RooIndustriesIssue 'GAME_TUNE_DRY_RUN' 'Game Tune session ran in dry-run mode. No process priority changes were applied.' 'info' 'performance.gameTune' $profileId $false 'Rerun with -ConfirmApply only after reviewing the per-poll preview.' $null)) | Out-Null
    } else {
        Add-RooIndustriesGameTuneLogFileEntry $sessionDirectory (New-RooIndustriesLog 'Confirmed Game Tune session state initialized.')
    }

    $state = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
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
        $pollStartedAtUtc = Get-RooIndustriesUtcStamp
        $previewArgs = @{ ProfilePath = $resolvedProfilePath }
        if (-not [string]::IsNullOrWhiteSpace($TargetGameProcessName)) {
            $previewArgs['TargetGameProcessName'] = $TargetGameProcessName
        }
        $previewEnvelope = & (Join-Path $PSScriptRoot 'Preview-ProcessProfile.ps1') @previewArgs | ConvertFrom-Json
        foreach ($warning in @(Get-RooIndustriesPropertyArray $previewEnvelope 'warnings')) { $warnings.Add($warning) | Out-Null }
        foreach ($errorItem in @(Get-RooIndustriesPropertyArray $previewEnvelope 'errors')) { $errors.Add($errorItem) | Out-Null }

        $pollWouldApply = New-Object System.Collections.Generic.List[object]
        $pollChanged = New-Object System.Collections.Generic.List[object]
        $pollSkipped = New-Object System.Collections.Generic.List[object]

        $gate = $null
        $gateMissed = $false
        if ($ConfirmApply) {
            $gate = Enter-RooIndustriesGovernorGate
            if ($null -eq $gate) {
                $gateMissed = $true
                $warnings.Add((New-RooIndustriesIssue 'GAME_TUNE_GOVERNOR_BUSY' 'A rule change kept the governor busy, so this poll changed nothing.' 'warning' 'performance.gameTune' $sessionId $false 'The next poll tries again.' $null)) | Out-Null
            }
        }
        try {
            foreach ($entry in @(if ($gateMissed) { @() } else { Get-RooIndustriesPropertyArray $previewEnvelope 'preview' })) {
                $entryControlChanges = @(Get-RooIndustriesPreviewControlChanges $entry)
                if ($entryControlChanges.Count -eq 0) { continue }

                $allowed = Test-RooIndustriesGameTuneEntryAllowed $entry
                if (-not $allowed.allowed) {
                    $skip = New-RooIndustriesGameTuneSkippedItem $entry $allowed.reason $pollIndex
                    $skipped.Add($skip) | Out-Null
                    $pollSkipped.Add($skip) | Out-Null
                    continue
                }

                if (-not $ConfirmApply) {
                    $wouldApply = [pscustomobject]@{
                        processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
                        processName = [string](Get-RooIndustriesPropertyValue $entry 'processName' '')
                        currentPriorityClass = Get-RooIndustriesPropertyValue $entry 'currentPriorityClass' $null
                        proposedPriorityClass = Get-RooIndustriesPropertyValue $entry 'proposedPriorityClass' $null
                        currentAffinityMask = Get-RooIndustriesPropertyValue $entry 'currentAffinityMask' $null
                        proposedAffinityMask = Get-RooIndustriesPropertyValue $entry 'proposedAffinityMask' $null
                        currentIoPriority = Get-RooIndustriesPropertyValue $entry 'currentIoPriority' $null
                        proposedIoPriority = Get-RooIndustriesPropertyValue $entry 'proposedIoPriority' $null
                        currentGpuPriority = Get-RooIndustriesPropertyValue $entry 'currentGpuPriority' $null
                        proposedGpuPriority = Get-RooIndustriesPropertyValue $entry 'proposedGpuPriority' $null
                        controlChanges = @($entryControlChanges)
                        ruleId = Get-RooIndustriesPropertyValue $entry 'ruleId' $null
                        reason = Get-RooIndustriesPropertyValue $entry 'reason' $null
                    }
                    $pollWouldApply.Add($wouldApply) | Out-Null
                    $skip = New-RooIndustriesGameTuneSkippedItem $entry 'Dry-run session; -ConfirmApply was not provided.' $pollIndex
                    $skipped.Add($skip) | Out-Null
                    $pollSkipped.Add($skip) | Out-Null
                    continue
                }

                $identity = Get-RooIndustriesGameTuneLiveProcessIdentity $entry
                if (-not $identity.exists -or -not $identity.matches) {
                    $skip = New-RooIndustriesGameTuneSkippedItem $entry $identity.reason $pollIndex
                    $skipped.Add($skip) | Out-Null
                    $pollSkipped.Add($skip) | Out-Null
                    continue
                }

                $livePlan = Get-RooIndustriesApplicableProcessControlChanges $entryControlChanges $identity.currentControlState
                foreach ($skippedControl in @(Get-RooIndustriesPropertyArray $livePlan 'skippedControls')) {
                    $skip = New-RooIndustriesGameTuneSkippedItem $entry ([string](Get-RooIndustriesPropertyValue $skippedControl 'reason' 'Process control was skipped.')) $pollIndex
                    $skipped.Add($skip) | Out-Null
                    $pollSkipped.Add($skip) | Out-Null
                }
                $entryControlChanges = @(Get-RooIndustriesPropertyArray $livePlan 'changes')
                if ($entryControlChanges.Count -eq 0) {
                    continue
                }

                $snapshotKey = "$([int](Get-RooIndustriesPropertyValue $entry 'processId' 0))|$([string](Get-RooIndustriesPropertyValue $entry 'processName' ''))|$([string](Get-RooIndustriesPropertyValue $entry 'executablePath' ''))|$([string]$identity.processStartTimeUtc)"
                $originalState = [pscustomobject]@{
                    priorityClass = Get-RooIndustriesPropertyValue $identity.currentControlState 'priorityClass' $identity.currentPriorityClass
                    affinityMask = Get-RooIndustriesPropertyValue $identity.currentControlState 'affinityMask' $identity.currentAffinityMask
                    ioPriority = Get-RooIndustriesPropertyValue $identity.currentControlState 'ioPriority' $identity.currentIoPriority
                    gpuPriority = Get-RooIndustriesPropertyValue $identity.currentControlState 'gpuPriority' $identity.currentGpuPriority
                }
                if (-not $snapshotKeys.Contains($snapshotKey)) {
                    $snapshot = [pscustomobject]@{
                        processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
                        processName = [string](Get-RooIndustriesPropertyValue $entry 'processName' '')
                        executablePath = Get-RooIndustriesPropertyValue $entry 'executablePath' $identity.currentPath
                        originalPriorityClass = Get-RooIndustriesPropertyValue $identity.currentControlState 'priorityClass' $identity.currentPriorityClass
                        proposedPriorityClass = Get-RooIndustriesPropertyValue $entry 'proposedPriorityClass' $null
                        originalAffinityMask = Get-RooIndustriesPropertyValue $identity.currentControlState 'affinityMask' $identity.currentAffinityMask
                        proposedAffinityMask = Get-RooIndustriesPropertyValue $entry 'proposedAffinityMask' $null
                        originalIoPriority = Get-RooIndustriesPropertyValue $identity.currentControlState 'ioPriority' $identity.currentIoPriority
                        proposedIoPriority = Get-RooIndustriesPropertyValue $entry 'proposedIoPriority' $null
                        originalGpuPriority = Get-RooIndustriesPropertyValue $identity.currentControlState 'gpuPriority' $identity.currentGpuPriority
                        proposedGpuPriority = Get-RooIndustriesPropertyValue $entry 'proposedGpuPriority' $null
                        controlChanges = @($entryControlChanges)
                        processStartTimeUtc = $identity.processStartTimeUtc
                        capturedAtUtc = Get-RooIndustriesUtcStamp
                        profileId = $profileId
                        ruleId = [string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')
                        reason = [string](Get-RooIndustriesPropertyValue $entry 'reason' '')
                        sessionId = $sessionId
                    }
                    $snapshots.Add($snapshot) | Out-Null
                    $snapshotKeys.Add($snapshotKey) | Out-Null
                    $snapshotsByKey[$snapshotKey] = $snapshot
                } else {
                    $known = $snapshotsByKey[$snapshotKey]
                    $recordedControls = @(Get-RooIndustriesPropertyArray $known 'controlChanges' | ForEach-Object { [string](Get-RooIndustriesPropertyValue $_ 'control' '') })
                    $later = @($entryControlChanges | Where-Object { $recordedControls -notcontains [string](Get-RooIndustriesPropertyValue $_ 'control' '') })
                    foreach ($change in $later) {
                        switch ([string](Get-RooIndustriesPropertyValue $change 'control' '')) {
                            'priorityClass' { $known.originalPriorityClass = $originalState.priorityClass }
                            'affinityMask' { $known.originalAffinityMask = $originalState.affinityMask }
                            'ioPriority' { $known.originalIoPriority = $originalState.ioPriority }
                            'gpuPriority' { $known.originalGpuPriority = $originalState.gpuPriority }
                        }
                    }
                    if ($later.Count -gt 0) { $known.controlChanges = @($known.controlChanges) + $later }
                }

                $backupManifest.snapshots = @($snapshots.ToArray())
                $backupPath = Join-Path $sessionDirectory 'backup.json'
                Write-RooIndustriesGameTuneJsonFile $backupManifest $backupPath
                $state.backupManifestPath = $backupPath
                $state.restorable = $true
                Write-SessionState $state $sessionDirectory
                if (($env:ROO_INDUSTRIES_TEST_GAMETUNE_PAUSE_MS -as [int]) -gt 0) { Start-Sleep -Milliseconds ([Math]::Min([int]$env:ROO_INDUSTRIES_TEST_GAMETUNE_PAUSE_MS, 60000)) }

                $appliedControls = New-Object System.Collections.Generic.List[object]
                $failedControls = New-Object System.Collections.Generic.List[string]
                foreach ($change in $entryControlChanges) {
                    try {
                        Invoke-RooIndustriesProcessControlChange $identity.process $change
                        $appliedControls.Add($change) | Out-Null
                    } catch {
                        $failedControls.Add("$([string](Get-RooIndustriesPropertyValue $change 'control' 'unknown')): $($_.Exception.Message)") | Out-Null
                    }
                }

                if ($appliedControls.Count -gt 0) {
                    $afterControls = Get-RooIndustriesProcessControlState ([int](Get-RooIndustriesPropertyValue $entry 'processId' 0)) $null
                    $appliedState = [pscustomobject]@{
                        priorityClass = $afterControls.priorityClass
                        affinityMask = $afterControls.affinityMask
                        ioPriority = $afterControls.ioPriority
                        gpuPriority = $afterControls.gpuPriority
                    }
                    $changedItem = New-RooIndustriesGameTuneChangedItem $entry $originalState $appliedState @($appliedControls.ToArray()) $pollIndex
                    $changed.Add($changedItem) | Out-Null
                    $pollChanged.Add($changedItem) | Out-Null
                }
                if ($failedControls.Count -gt 0) {
                    $skip = New-RooIndustriesGameTuneSkippedItem $entry ($failedControls -join '; ') $pollIndex
                    $skipped.Add($skip) | Out-Null
                    $pollSkipped.Add($skip) | Out-Null
                }
            }

            $poll = [pscustomobject]@{
                pollIndex = $pollIndex
                capturedAtUtc = $pollStartedAtUtc
                previewCount = @(Get-RooIndustriesPropertyArray $previewEnvelope 'preview').Count
                wouldApplyItems = @($pollWouldApply.ToArray())
                changedItems = @($pollChanged.ToArray())
                skippedItems = @($pollSkipped.ToArray())
            }
            $polls.Add($poll) | Out-Null
            $logEntry = New-RooIndustriesLog "Game Tune poll $pollIndex completed with $($pollChanged.Count) changed item(s), $($pollWouldApply.Count) dry-run item(s), and $($pollSkipped.Count) skipped item(s)."
            $logs.Add($logEntry) | Out-Null
            if ($ConfirmApply) {
                Add-RooIndustriesGameTuneLogFileEntry $sessionDirectory $logEntry
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
        } finally {
            Exit-RooIndustriesGovernorGate $gate
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
    $completedAtUtc = Get-RooIndustriesUtcStamp
    $backupMetadata = if ($backupPath -and (Test-Path -LiteralPath $backupPath)) { New-RooIndustriesGameTuneBackupMetadata $backupManifest $backupPath } else { $null }
    $artifacts = New-Object System.Collections.Generic.List[object]
    if ($sessionStatePath) { $artifacts.Add([pscustomobject]@{ type = 'gameTuneSessionState'; path = $sessionStatePath }) | Out-Null }
    if ($backupPath) { $artifacts.Add([pscustomobject]@{ type = 'gameTuneSessionBackup'; path = $backupPath }) | Out-Null }

    $result = New-RooIndustriesGameTuneResult `
        -ResultId ("game-tune-session-" + (Get-RooIndustriesFileStamp)) `
        -Status $resultStatus `
        -Summary "Game Tune session completed after $pollIndex poll(s) with $($changed.Count) changed item(s), $($skipped.Count) skipped item(s), and $($restored.Count) restored item(s)." `
        -ChangedItems @($changed.ToArray()) `
        -SkippedItems @($skipped.ToArray()) `
        -RestoredItems @($restored.ToArray()) `
        -Artifacts @($artifacts.ToArray())

    $envelope = [pscustomobject]@{
        actionId = 'performance.gameTune.startSession'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
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

    Write-RooIndustriesJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.gameTune.startSession'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        correlationId = $null
        sessionId = $null
        dryRun = (-not $ConfirmApply)
        profileId = $null
        profilePath = $ProfilePath
        targetGameProcessName = if ([string]::IsNullOrWhiteSpace($TargetGameProcessName)) { $null } else { $TargetGameProcessName }
        status = 'failed'
        sessionStatus = 'failed'
        startedAtUtc = $null
        completedAtUtc = Get-RooIndustriesUtcStamp
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
        errors = @((New-RooIndustriesIssue 'GAME_TUNE_SESSION_FAILED' $_.Exception.Message 'error' 'performance.gameTune' $ProfilePath $true 'Review profile path, permissions, and process inventory availability.' $null))
        logs = @((New-RooIndustriesLog 'Game Tune session failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorEnvelope $OutputPath
    exit 1
}
