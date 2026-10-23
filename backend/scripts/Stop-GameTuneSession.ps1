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
$script:GameTuneAlreadyClosed = 'This app was already closed or restarted. Its settings ended with it, so nothing remains to restore.'

function New-GameTuneAlreadyClosedItem {
    param([object]$Entry)
    return [pscustomobject]@{
        processId = Get-RooIndustriesPropertyValue $Entry 'processId' 0
        processName = Get-RooIndustriesPropertyValue $Entry 'processName' ''
        reason = $script:GameTuneAlreadyClosed
        outcome = 'alreadyClosed'
        skippedAtUtc = Get-RooIndustriesUtcStamp
    }
}

function New-GameTuneRestorePreview {
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
    $savedControls = @(Get-RooIndustriesPropertyArray $Snapshot 'controlChanges')
    $recorded = @(Get-RooIndustriesRestorableProcessControls $Snapshot (Get-RooIndustriesPropertyValue $Candidate 'currentControlState' $null) | ForEach-Object { [string](Get-RooIndustriesPropertyValue $_ 'control' '') })
    $restoresAll = $null -eq $Snapshot.PSObject.Properties['controlChanges']
    $blocked = (-not $Candidate.exists) -or (-not $Candidate.matches)
    $ended = $blocked -and [bool](Get-RooIndustriesPropertyValue $Candidate 'instanceEnded' $false)
    $reason = if ($ended) {
        $script:GameTuneAlreadyClosed
    } elseif ($blocked) {
        [string]$Candidate.reason
    } else {
        'Restore original process controls from Game Tune session backup.'
    }
    $leftAsSet = @()
    $alreadyOriginal = @()
    $controlChanges = New-Object System.Collections.Generic.List[object]
    if (-not $blocked) {
        if (($restoresAll -or $recorded -contains 'priorityClass') -and -not [string]::IsNullOrWhiteSpace($originalPriority) -and (Test-RooIndustriesPriorityAllowed $originalPriority -Restoring)) {
            $controlChanges.Add((New-RooIndustriesControlChange 'priorityClass' $Candidate.currentPriorityClass $originalPriority 'restorePriority' 'Restore original process priority.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'affinityMask') -and $null -ne $originalAffinityMask -and (Test-RooIndustriesAffinityMaskAllowed $originalAffinityMask)) {
            $controlChanges.Add((New-RooIndustriesControlChange 'affinityMask' $Candidate.currentAffinityMask ([int64]$originalAffinityMask) 'restoreAffinity' 'Restore original CPU affinity.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'ioPriority') -and -not [string]::IsNullOrWhiteSpace([string]$originalIoPriority) -and (Test-RooIndustriesIoPriorityAllowed $originalIoPriority -Restoring)) {
            $controlChanges.Add((New-RooIndustriesControlChange 'ioPriority' $Candidate.currentIoPriority $originalIoPriority 'restoreIoPriority' 'Restore original I/O priority.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'memoryPriority') -and -not [string]::IsNullOrWhiteSpace([string]$originalMemoryPriority) -and (Test-RooIndustriesMemoryPriorityAllowed $originalMemoryPriority)) {
            $controlChanges.Add((New-RooIndustriesControlChange 'memoryPriority' $Candidate.currentMemoryPriority $originalMemoryPriority 'restoreMemoryPriority' 'Restore original memory priority.')) | Out-Null
        }
        if (($restoresAll -or $recorded -contains 'gpuPriority') -and -not [string]::IsNullOrWhiteSpace([string]$originalGpuPriority) -and (Test-RooIndustriesGpuPriorityAllowed $originalGpuPriority)) {
            if ([bool](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Candidate 'currentControlState' $null) 'gpuPriorityAvailable' $false)) {
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $Candidate.currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'Restore original GPU priority.')) | Out-Null
            } else {
                $gpuReason = 'GPU scheduling priority is unavailable for this restore target.'
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $Candidate.currentGpuPriority $originalGpuPriority 'restoreGpuPriority' 'GPU scheduling priority is unavailable for this restore target.' $true $gpuReason)) | Out-Null
            }
        }
        $missingOriginal = @($savedControls | Where-Object { $_.control -notin @($controlChanges | ForEach-Object { $_.control }) }).Count -gt 0
        $split = Split-RooIndustriesLeftAsSetRestoreChanges $Snapshot @($controlChanges.ToArray()) (Get-RooIndustriesPropertyValue $Candidate 'currentControlState' $null)
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
            $reason = if ($leftAsSet.Count -gt 0) { $script:RooIndustriesLeftAsSet } else { 'Process already matches the Game Tune backup.' }
        }
        if ($missingOriginal) {
            $blocked = $true
            $reason = 'A saved control has no valid original value. Its current value and backup were kept.'
        }
    }
    $applicableControlChanges = @($controlChanges.ToArray() | Where-Object { -not $_.blocked })
    $proposedAction = if ($blocked -or $applicableControlChanges.Count -eq 0) { 'noChange' } elseif ($applicableControlChanges.Count -eq 1 -and [string](Get-RooIndustriesPropertyValue $applicableControlChanges[0] 'control' '') -eq 'priorityClass') { 'restorePriority' } else { 'restoreProcessControls' }

    return [pscustomobject]@{
        previewId = ("game-tune-restore-$processName-$processId").ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = if ($controlChanges.Count -gt 1) { 'gameTuneProcessControlsRestore' } else { 'gameTuneProcessPriorityRestore' }
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooIndustriesPropertyValue $Snapshot 'executablePath' $null
        processStartTimeUtc = Get-RooIndustriesPropertyValue $Snapshot 'processStartTimeUtc' $null
        currentPriorityClass = $Candidate.currentPriorityClass
        proposedPriorityClass = if ($blocked) { $Candidate.currentPriorityClass } else { $originalPriority }
        currentAffinityMask = $Candidate.currentAffinityMask
        proposedAffinityMask = if ($blocked) { $Candidate.currentAffinityMask } else { $originalAffinityMask }
        currentIoPriority = $Candidate.currentIoPriority
        currentMemoryPriority = $Candidate.currentMemoryPriority
        proposedIoPriority = if ($blocked) { $Candidate.currentIoPriority } else { $originalIoPriority }
        proposedMemoryPriority = if ($blocked) { $Candidate.currentMemoryPriority } else { $originalMemoryPriority }
        currentGpuPriority = $Candidate.currentGpuPriority
        proposedGpuPriority = if ($blocked) { $Candidate.currentGpuPriority } else { $originalGpuPriority }
        gpuPriorityAvailable = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Candidate 'currentControlState' $null) 'gpuPriorityAvailable' $false
        gpuPriorityStatus = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Candidate 'currentControlState' $null) 'gpuPriorityStatus' $null
        proposedAction = $proposedAction
        controlChanges = @($controlChanges.ToArray())
        leftAsSet = @($leftAsSet)
        alreadyOriginal = @($alreadyOriginal)
        ruleId = [string](Get-RooIndustriesPropertyValue $Snapshot 'ruleId' '')
        reason = $reason
        reasonCodes = @(if ($ended) { 'GAME_TUNE_ALREADY_CLOSED' } elseif ($blocked) { 'GAME_TUNE_RESTORE_SKIPPED' } else { 'GAME_TUNE_PROCESS_CONTROLS_RESTORE' })
        classification = 'rollbackCandidate'
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = 'low'
        confidence = 'medium'
        protected = $false
        requiresConfirmation = ($applicableControlChanges.Count -gt 0 -and -not $blocked)
        rollbackSupported = ($applicableControlChanges.Count -gt 0 -and -not $blocked)
        currentState = [pscustomobject]@{
            priorityClass = $Candidate.currentPriorityClass
            affinityMask = $Candidate.currentAffinityMask
            ioPriority = $Candidate.currentIoPriority
            memoryPriority = $Candidate.currentMemoryPriority
            gpuPriority = $Candidate.currentGpuPriority
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked) { $Candidate.currentPriorityClass } else { $originalPriority }
            affinityMask = if ($blocked) { $Candidate.currentAffinityMask } else { $originalAffinityMask }
            ioPriority = if ($blocked) { $Candidate.currentIoPriority } else { $originalIoPriority }
            memoryPriority = if ($blocked) { $Candidate.currentMemoryPriority } else { $originalMemoryPriority }
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
    $script:RooIndustriesProcessOperationPreview = $null
    $session = $null
    $resolvedSessionPath = $null
    if (-not [string]::IsNullOrWhiteSpace($SessionId) -or -not [string]::IsNullOrWhiteSpace($SessionPath)) {
        $resolvedSessionPath = Resolve-RooIndustriesGameTuneSessionFile $SessionId $SessionPath $StateRoot
        if ([string]::IsNullOrWhiteSpace($resolvedSessionPath) -or -not (Test-Path -LiteralPath $resolvedSessionPath)) {
            throw 'The selected Game Tune session file was not found.'
        }
        $session = Read-RooIndustriesJsonFile $resolvedSessionPath
    }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        if ($null -eq $session) {
            $resolvedSessionPath = Resolve-RooIndustriesGameTuneSessionFile $SessionId $SessionPath $StateRoot
        }
        if ($resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
            if ($null -eq $session) { $session = Read-RooIndustriesJsonFile $resolvedSessionPath }
            $BackupPath = [string](Get-RooIndustriesPropertyValue $session 'backupManifestPath' '')
        }
    }

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'No Game Tune backup path was provided or found for the selected session.'
    }

    $resolvedBackupPath = Resolve-RooIndustriesPath $BackupPath $BackupPath
    $backup = Read-RooIndustriesJsonFile $resolvedBackupPath
    $backupDryRun = Get-RooIndustriesPropertyValue $backup 'dryRun' $null
    if ([string](Get-RooIndustriesPropertyValue $backup 'actionId' '') -cne 'performance.gameTune.startSession' -or $backupDryRun -isnot [bool] -or $backupDryRun) {
        throw 'The Game Tune backup is not a confirmed backup for this session type.'
    }
    $sessionIdValue = [string](Get-RooIndustriesPropertyValue $backup 'sessionId' '')
    $profileId = [string](Get-RooIndustriesPropertyValue $backup 'profileId' '')
    if ([string]::IsNullOrWhiteSpace($sessionIdValue) -or [string]::IsNullOrWhiteSpace($profileId)) {
        throw 'The Game Tune backup identity is incomplete.'
    }
    if (-not [string]::IsNullOrWhiteSpace($SessionId) -and $SessionId -cne $sessionIdValue) {
        throw 'The Game Tune session ID does not match the selected backup.'
    }
    if ($null -eq $session) {
        $candidateSessionPath = Resolve-RooIndustriesGameTuneSessionFile $sessionIdValue '' $StateRoot
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
            (-not [string]::IsNullOrWhiteSpace($recordedSessionPath) -and -not [string]::Equals((Get-RooIndustriesGameTuneSessionFileFromPath $recordedSessionPath), $resolvedSessionPath, [StringComparison]::OrdinalIgnoreCase))) {
            throw 'The Game Tune session and backup identity do not match.'
        }
    }
    $startedAtUtc = Get-RooIndustriesUtcStamp

    $executionPairs = New-Object System.Collections.Generic.List[object]
    $preview = New-Object System.Collections.Generic.List[object]
    $changed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $alreadyClosed = New-Object System.Collections.Generic.List[object]
    $restored = New-Object System.Collections.Generic.List[object]
    $leftAsSetItems = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @(Get-RooIndustriesPropertyArray $backup 'snapshots')) {
        $candidateEntry = [pscustomobject]@{
            processId = Get-RooIndustriesPropertyValue $snapshot 'processId' 0
            processName = Get-RooIndustriesPropertyValue $snapshot 'processName' ''
            executablePath = Get-RooIndustriesPropertyValue $snapshot 'executablePath' $null
            processStartTimeUtc = Get-RooIndustriesPropertyValue $snapshot 'processStartTimeUtc' $null
            controlChanges = @(Get-RooIndustriesPreviewControlChanges $snapshot)
        }
        $candidate = Get-RooIndustriesGameTuneLiveProcessIdentity $candidateEntry
        $entry = New-GameTuneRestorePreview $snapshot $candidate
        $preview.Add($entry) | Out-Null
        $executionPairs.Add([pscustomobject]@{
            entry = $entry
            snapshot = $snapshot
            failed = $false
            executionMatched = $false
            closed = $false
            stopControls = $false
            failureReasons = (New-Object System.Collections.Generic.List[string])
            stagedChanged = $null
            stagedKept = (New-Object System.Collections.Generic.List[object])
        }) | Out-Null
    }

    if ($ConfirmApply) {
        foreach ($pair in @($executionPairs.ToArray())) {
            $entry = $pair.entry
            if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
                if (@(Get-RooIndustriesPropertyArray $entry 'reasonCodes') -contains 'GAME_TUNE_ALREADY_CLOSED') {
                    $pair.closed = $true
                } else {
                    $pair.failed = $true
                    $pair.failureReasons.Add([string](Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Restore entry is blocked.')) | Out-Null
                }
                continue
            }

            try {
                $processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
                $identity = Get-RooIndustriesGameTuneLiveProcessIdentity $entry
                $live = $identity.process
                if (-not $identity.exists -or -not $identity.matches) {
                    if ($identity.instanceEnded) {
                        $pair.closed = $true
                    } else {
                        $pair.failed = $true
                        $pair.failureReasons.Add([string]$identity.reason) | Out-Null
                    }
                    continue
                }
                $pair.executionMatched = $true
                $appliedControls = New-Object System.Collections.Generic.List[object]
                $workItems = New-Object System.Collections.Generic.List[object]
                foreach ($check in (@(Get-RooIndustriesPropertyArray $entry 'alreadyOriginal') + @(Get-RooIndustriesPropertyArray $entry 'leftAsSet'))) {
                    $workItems.Add([pscustomobject]@{ check = $check; change = $null }) | Out-Null
                }
                foreach ($change in @(Get-RooIndustriesPreviewControlChanges $entry)) {
                    $workItems.Add([pscustomobject]@{ check = $change; change = $change }) | Out-Null
                }
                foreach ($work in @($workItems.ToArray())) {
                    try {
                        $verification = Confirm-RooIndustriesRestoreControl $live $work.check $pair.snapshot $entry $work.change -Feature 'Game priority'
                        if ($null -eq $verification) { throw 'Restore confirmation returned no result.' }
                        foreach ($flag in @('confirmed', 'restored', 'instanceEnded', 'cleanupFailed')) {
                            $property = $verification.PSObject.Properties[$flag]
                            if ($null -eq $property -or $property.Value -isnot [bool]) { throw 'Restore confirmation returned an incomplete result.' }
                        }
                        if ($verification.cleanupFailed) { throw [string]$verification.reason }
                        if ($verification.instanceEnded) {
                            if ($verification.confirmed -or $verification.restored -or $null -ne $verification.leftAsSet) { throw 'Restore confirmation returned conflicting results.' }
                            $pair.stopControls = $true
                            if (-not $pair.failed) { $pair.closed = $true }
                            break
                        }
                        if (-not $verification.confirmed) { throw [string]$verification.reason }
                        if ($verification.restored) {
                            if ($null -eq $work.change -or $null -ne $verification.leftAsSet) { throw 'Restore confirmation returned conflicting results.' }
                            $appliedControls.Add($work.change) | Out-Null
                        } elseif ($null -ne $verification.leftAsSet) {
                            $pair.stagedKept.Add((New-RooIndustriesLeftAsSetItem $entry $verification.leftAsSet)) | Out-Null
                        }
                    } catch {
                        $pair.failed = $true
                        $pair.failureReasons.Add([string](Get-RooIndustriesPropertyValue $work.check 'control' '') + ': ' + $_.Exception.Message) | Out-Null
                    }
                }

                if (-not $pair.failed -and -not $pair.closed) {
                    if (Test-RooIndustriesRestoreInstanceEnded $pair.snapshot $entry) {
                        $pair.closed = $true
                        $pair.stopControls = $true
                    }
                }
                if (-not $pair.closed -and -not $pair.stopControls -and $appliedControls.Count -gt 0) {
                    $afterControls = Get-RooIndustriesProcessControlState $processId $null -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $entry)
                    $existsProperty = if ($null -ne $afterControls) { $afterControls.PSObject.Properties['exists'] } else { $null }
                    if ($null -eq $existsProperty -or $existsProperty.Value -isnot [bool] -or -not $existsProperty.Value) {
                        throw 'Windows could not verify the restored process controls.'
                    }
                    foreach ($appliedControl in @($appliedControls.ToArray())) {
                        $control = [string]$appliedControl.control
                        $actual = Get-RooIndustriesPropertyValue $afterControls $control $null
                        $available = Get-RooIndustriesPropertyValue $afterControls ($control + 'Available') $null
                        $valid = switch ($control) {
                            'priorityClass' { $actual -is [string] -and (Test-RooIndustriesPriorityAllowed $actual -Restoring) }
                            'affinityMask' { ($actual -is [int] -or $actual -is [long]) -and (Test-RooIndustriesAffinityMaskAllowed $actual) }
                            'ioPriority' { $actual -is [string] -and (Test-RooIndustriesIoPriorityAllowed $actual -Restoring) -and $available -is [bool] -and $available }
                            'memoryPriority' { ($actual -is [int] -or $actual -is [long]) -and (Test-RooIndustriesMemoryPriorityAllowed $actual) -and $available -is [bool] -and $available }
                            'gpuPriority' { $actual -is [string] -and (Test-RooIndustriesGpuPriorityAllowed $actual) -and $available -is [bool] -and $available }
                            default { $false }
                        }
                        if (-not $valid -or -not (Test-RooIndustriesControlValueEqual $control $actual $appliedControl.proposedValue)) {
                            throw ('Windows could not verify the restored value for ' + $control + '.')
                        }
                    }
                    if (-not $pair.failed) {
                        if (Test-RooIndustriesRestoreInstanceEnded $pair.snapshot $entry) {
                            $pair.closed = $true
                            $pair.stopControls = $true
                        }
                    }
                    if (-not $pair.closed -and -not $pair.stopControls) {
                        $pair.stagedChanged = [pscustomobject]@{
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
                    }
                }
            } catch {
                $pair.failed = $true
                $pair.failureReasons.Add($_.Exception.Message) | Out-Null
            }
        }

        foreach ($pair in @($executionPairs.ToArray())) {
            $entry = $pair.entry
            if ($pair.executionMatched -and -not $pair.failed -and -not $pair.closed) {
                try {
                    if (Test-RooIndustriesRestoreInstanceEnded $pair.snapshot $entry) {
                        $pair.closed = $true
                        $pair.stopControls = $true
                    }
                } catch {
                    $pair.failed = $true
                    $pair.failureReasons.Add($_.Exception.Message) | Out-Null
                }
            }
            if ($pair.closed -and -not $pair.failed) {
                $alreadyClosed.Add((New-GameTuneAlreadyClosedItem $entry)) | Out-Null
                continue
            }
            if (-not $pair.stopControls) {
                if ($null -ne $pair.stagedChanged) {
                    $restored.Add($pair.stagedChanged) | Out-Null
                    $changed.Add($pair.stagedChanged) | Out-Null
                }
                foreach ($item in @($pair.stagedKept.ToArray())) { $leftAsSetItems.Add($item) | Out-Null }
            }
            if ($pair.failed) {
                $skipped.Add([pscustomobject]@{
                    processId = Get-RooIndustriesPropertyValue $entry 'processId' 0
                    processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                    reason = ($pair.failureReasons -join '; ')
                    skippedAtUtc = Get-RooIndustriesUtcStamp
                }) | Out-Null
            }
        }
    } else {
        foreach ($entry in @($preview.ToArray())) {
            if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
                if (@(Get-RooIndustriesPropertyArray $entry 'reasonCodes') -contains 'GAME_TUNE_ALREADY_CLOSED') {
                    $alreadyClosed.Add((New-GameTuneAlreadyClosedItem $entry)) | Out-Null
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
        elseif ($restored.Count -gt 0) { 'restored' }
        elseif ($skipped.Count -gt 0) { 'failed' }
        else { 'restored' }
    } else {
        'preview'
    }
    $sessionStatus = if ($ConfirmApply -and $status -in @('restored', 'partial')) { 'completed' } elseif ($status -eq 'failed') { 'failed' } else { 'preview' }

    $warnings = New-Object System.Collections.Generic.List[object]
    if (-not $ConfirmApply) {
        $warnings.Add((New-RooIndustriesIssue 'GAME_TUNE_RESTORE_PREVIEW_ONLY' 'Restore preview did not change any process because -ConfirmApply was omitted.' 'info' 'performance.gameTune' $resolvedBackupPath $false 'Rerun with -ConfirmApply only after reviewing the restore preview.' $null)) | Out-Null
    }

    $closedText = if ($alreadyClosed.Count -gt 0) { ' Already closed or restarted, so nothing remained to restore: ' + (($alreadyClosed | ForEach-Object { $_.processName + ' (PID ' + $_.processId + ')' }) -join ', ') + '.' } else { '' }
    $skippedOut = @($skipped.ToArray()) + @($alreadyClosed.ToArray())
    $summary = if ($ConfirmApply) {
        "Game Tune restore completed with $($restored.Count) restored item(s) and $($skipped.Count) skipped item(s)." + (Format-RooIndustriesLeftAsSetText @($leftAsSetItems.ToArray())) + $closedText
    } else {
        "Game Tune restore preview completed. No process priority changes were applied."
    }
    $backupMetadata = New-RooIndustriesGameTuneBackupMetadata $backup $resolvedBackupPath
    $result = New-RooIndustriesGameTuneResult `
        -ResultId ("game-tune-restore-" + (Get-RooIndustriesFileStamp)) `
        -Status $(if ($status -eq 'restored') { 'rolledBack' } elseif ($status -eq 'preview') { 'preview' } else { $status }) `
        -Summary $summary `
        -ChangedItems @($changed.ToArray()) `
        -SkippedItems $skippedOut `
        -RestoredItems @($restored.ToArray()) `
        -Artifacts @([pscustomobject]@{ type = 'gameTuneSessionBackup'; path = $resolvedBackupPath })
    $result | Add-Member -NotePropertyName leftAsSetItems -NotePropertyValue @($leftAsSetItems.ToArray()) -Force

    $logs = @((New-RooIndustriesLog $summary))
    $envelope = [pscustomobject]@{
        actionId = 'performance.gameTune.stopSession'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        correlationId = $sessionIdValue
        sessionId = $sessionIdValue
        dryRun = (-not $ConfirmApply)
        profileId = $profileId
        status = $sessionStatus
        sessionStatus = $sessionStatus
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-RooIndustriesUtcStamp
        sessionPath = $resolvedSessionPath
        backupManifestPath = $resolvedBackupPath
        restorable = (-not $ConfirmApply -or $status -in @('partial', 'failed'))
        preview = @($preview.ToArray())
        changedItems = @($changed.ToArray())
        skippedItems = $skippedOut
        restoredItems = @($restored.ToArray())
        leftAsSetItems = @($leftAsSetItems.ToArray())
        backup = $backupMetadata
        result = $result
        warnings = @($warnings.ToArray())
        errors = @()
        logs = $logs
    }

    if ($ConfirmApply -and $resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
        $session = Read-RooIndustriesJsonFile $resolvedSessionPath
        $session.sessionStatus = $sessionStatus
        $session.status = $sessionStatus
        $session.restorable = ($status -in @('partial', 'failed'))
        $session.restoredItems = @($restored.ToArray())
        $session.skippedItems = $skippedOut
        $session | Add-Member -NotePropertyName leftAsSetItems -NotePropertyValue @($leftAsSetItems.ToArray()) -Force
        $session.completedAtUtc = Get-RooIndustriesUtcStamp
        Write-RooIndustriesGameTuneJsonFile $session $resolvedSessionPath
        Add-RooIndustriesGameTuneLogFileEntry (Split-Path $resolvedSessionPath -Parent) (New-RooIndustriesLog $summary)
    }

    Write-RooIndustriesJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.gameTune.stopSession'
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
        errors = @((New-RooIndustriesIssue 'GAME_TUNE_RESTORE_FAILED' $_.Exception.Message 'error' 'performance.gameTune' $BackupPath $true 'Check the session id, session path, or backup path and retry.' $null))
        logs = @((New-RooIndustriesLog 'Game Tune restore failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorEnvelope $OutputPath
    exit 1
}
