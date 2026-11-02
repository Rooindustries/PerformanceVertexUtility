. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$script:RooIndustriesGameTuneStateFolderName = 'game-tune-sessions'

function Resolve-RooIndustriesGameTuneStateRoot {
    param([string]$StateRoot)
    $defaultStateRoot = Join-Path $PSScriptRoot '..\state'
    $resolvedStateRoot = Resolve-RooIndustriesPath $StateRoot $defaultStateRoot
    return [System.IO.Path]::GetFullPath((Join-Path $resolvedStateRoot $script:RooIndustriesGameTuneStateFolderName))
}

function New-RooIndustriesGameTuneSessionId {
    param([string]$ProfileId)
    $safeProfileId = if ([string]::IsNullOrWhiteSpace($ProfileId)) { 'profile' } else { $ProfileId.ToLowerInvariant() -replace '[^a-z0-9\-]+', '-' }
    return "game-tune-$safeProfileId-$(Get-RooIndustriesFileStamp)"
}

function Get-RooIndustriesGameTuneSessionDirectory {
    param(
        [string]$ResolvedGameTuneStateRoot,
        [string]$SessionId
    )
    return Join-Path $ResolvedGameTuneStateRoot $SessionId
}

function Write-RooIndustriesGameTuneJsonFile {
    param(
        [object]$Value,
        [string]$Path
    )
    Ensure-RooIndustriesDirectory (Split-Path $Path -Parent)
    Write-RooIndustriesOperationJson $Value $Path
}

function Add-RooIndustriesGameTuneLogFileEntry {
    param(
        [string]$SessionDirectory,
        [object]$Entry
    )
    if ([string]::IsNullOrWhiteSpace($SessionDirectory)) { return }
    Ensure-RooIndustriesDirectory $SessionDirectory
    ($Entry | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath (Join-Path $SessionDirectory 'events.jsonl') -Encoding UTF8
}

function Get-RooIndustriesGameTuneSessionFileFromPath {
    param([string]$SessionPath)
    if ([string]::IsNullOrWhiteSpace($SessionPath)) { return $null }
    $resolved = Resolve-RooIndustriesPath $SessionPath $SessionPath
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        return Join-Path $resolved 'session.json'
    }
    return $resolved
}

function Get-RooIndustriesGameTuneLatestSessionFile {
    param([string]$ResolvedGameTuneStateRoot)
    if (-not (Test-Path -LiteralPath $ResolvedGameTuneStateRoot)) { return $null }
    $latest = Get-ChildItem -LiteralPath $ResolvedGameTuneStateRoot -Filter 'session.json' -Recurse -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { return $null }
    return $latest.FullName
}

function Resolve-RooIndustriesGameTuneSessionFile {
    param(
        [string]$SessionId,
        [string]$SessionPath,
        [string]$StateRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($SessionPath)) {
        return Get-RooIndustriesGameTuneSessionFileFromPath $SessionPath
    }
    $resolvedStateRoot = Resolve-RooIndustriesGameTuneStateRoot $StateRoot
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return Join-Path (Get-RooIndustriesGameTuneSessionDirectory $resolvedStateRoot $SessionId) 'session.json'
    }
    return Get-RooIndustriesGameTuneLatestSessionFile $resolvedStateRoot
}

function Get-RooIndustriesGameTuneLiveProcessIdentity {
    param([object]$PreviewEntry)
    $processId = [int](Get-RooIndustriesPropertyValue $PreviewEntry 'processId' 0)
    $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $live) {
        return [pscustomobject]@{
            exists = $false
            matches = $false
            instanceEnded = $true
            process = $null
            currentPriorityClass = $null
            currentPath = $null
            reason = 'Process is no longer running.'
        }
    }

    $expectedName = [string](Get-RooIndustriesPropertyValue $PreviewEntry 'processName' '')
    $nameMatches = Test-RooIndustriesProcessNameEquals $live.ProcessName $expectedName
    $currentPath = $null
    try { $currentPath = $live.Path } catch { $currentPath = $null }
    $expectedPath = Get-RooIndustriesPropertyValue $PreviewEntry 'executablePath' $null
    $pathMatches = $true
    $pathReason = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$expectedPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$currentPath)) {
            $pathMatches = $false
            $pathReason = 'Live process path could not be verified.'
        } else {
            $pathMatches = ([string]$expectedPath -eq [string]$currentPath)
            if (-not $pathMatches) { $pathReason = 'Live process path does not match the preview entry.' }
        }
    }

    $controlState = Get-RooIndustriesProcessControlState $processId $null -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $PreviewEntry)
    $savedStart = Get-RooIndustriesPropertyValue $PreviewEntry 'processStartTimeUtc' $null
    $startMatches = Test-RooIndustriesProcessStartTime $savedStart $controlState.startTimeUtc
    $savedTime = [datetime]::MinValue
    $currentTime = [datetime]::MinValue
    $knownStartMismatch = -not $startMatches -and [datetime]::TryParse([string]$savedStart, [ref]$savedTime) -and [datetime]::TryParse([string]$controlState.startTimeUtc, [ref]$currentTime)
    $knownPathMismatch = -not $pathMatches -and -not [string]::IsNullOrWhiteSpace([string]$currentPath)
    $exitedNow = -not $controlState.exists
    if (-not $exitedNow) { try { $exitedNow = $live.HasExited } catch { $exitedNow = $false } }
    $currentPriority = $controlState.priorityClass
    if (-not $exitedNow) { try { $currentPriority = [string]$live.PriorityClass } catch { $currentPriority = $controlState.priorityClass } }
    $matches = ($nameMatches -and $pathMatches -and $startMatches)
    $reason = if (-not $startMatches) { 'This app was restarted, or its start time could not be verified. Nothing was changed or restored.' } elseif ($matches) { $null } elseif (-not $nameMatches) { 'Live process name does not match the preview entry.' } else { $pathReason }
    return [pscustomobject]@{
        exists = $true
        matches = $matches
        instanceEnded = ($exitedNow -or -not $nameMatches -or $knownPathMismatch -or $knownStartMismatch)
        process = $live
        currentPriorityClass = $currentPriority
        currentControlState = $controlState
        currentAffinityMask = $controlState.affinityMask
        currentIoPriority = $controlState.ioPriority
        currentMemoryPriority = $controlState.memoryPriority
        currentGpuPriority = $controlState.gpuPriority
        processStartTimeUtc = $controlState.startTimeUtc
        currentPath = $currentPath
        reason = $reason
    }
}

function Test-RooIndustriesGameTuneEntryAllowed {
    param([object]$PreviewEntry)
    if ([bool](Get-RooIndustriesPropertyValue $PreviewEntry 'protected' $false) -or [bool](Get-RooIndustriesPropertyValue $PreviewEntry 'blocked' $false)) {
        return [pscustomobject]@{ allowed = $false; reason = 'Preview entry is protected or blocked.' }
    }
    $changes = @(Get-RooIndustriesPreviewControlChanges $PreviewEntry)
    if ($changes.Count -eq 0) {
        return [pscustomobject]@{ allowed = $false; reason = 'Preview entry does not request a process control change.' }
    }
    foreach ($change in $changes) {
        if ([bool](Get-RooIndustriesPropertyValue $change 'blocked' $false)) {
            if ([string](Get-RooIndustriesPropertyValue $change 'control' '') -eq 'memoryPriority') { continue }
            return [pscustomobject]@{ allowed = $false; reason = [string](Get-RooIndustriesPropertyValue $change 'blockedReason' 'A requested process control is blocked.') }
        }
        $control = [string](Get-RooIndustriesPropertyValue $change 'control' '')
        $value = Get-RooIndustriesPropertyValue $change 'proposedValue' $null
        $action = [string](Get-RooIndustriesPropertyValue $change 'action' '')
        switch ($control) {
            'priorityClass' {
                if (-not (Test-RooIndustriesPriorityAllowed ([string]$value) -Restoring:($action -eq 'restorePriority'))) { return [pscustomobject]@{ allowed = $false; reason = "Priority class '$value' is outside the allow-list." } }
            }
            'affinityMask' {
                if (-not (Test-RooIndustriesAffinityMaskAllowed $value)) { return [pscustomobject]@{ allowed = $false; reason = "Affinity mask '$value' is invalid." } }
            }
            'ioPriority' {
                if (-not (Test-RooIndustriesIoPriorityAllowed ([string]$value) -Restoring:($action -eq 'restoreIoPriority'))) { return [pscustomobject]@{ allowed = $false; reason = "I/O priority '$value' is outside the allow-list." } }
            }
            'memoryPriority' {
                if (-not (Test-RooIndustriesMemoryPriorityAllowed $value)) { return [pscustomobject]@{ allowed = $false; reason = "Memory priority '$value' is outside the allow-list." } }
            }
            'gpuPriority' {
                if (-not (Test-RooIndustriesGpuPriorityAllowed ([string]$value))) { return [pscustomobject]@{ allowed = $false; reason = "GPU priority '$value' is outside the allow-list." } }
            }
            default {
                return [pscustomobject]@{ allowed = $false; reason = "Unsupported process control '$control'." }
            }
        }
    }
    return [pscustomobject]@{ allowed = $true; reason = $null }
}

function New-RooIndustriesGameTuneChangedItem {
    param(
        [object]$PreviewEntry,
        [object]$OriginalState,
        [object]$AppliedState,
        [object[]]$AppliedControls,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = [int](Get-RooIndustriesPropertyValue $PreviewEntry 'processId' 0)
        processName = [string](Get-RooIndustriesPropertyValue $PreviewEntry 'processName' '')
        executablePath = Get-RooIndustriesPropertyValue $PreviewEntry 'executablePath' $null
        originalPriorityClass = Get-RooIndustriesPropertyValue $OriginalState 'priorityClass' $null
        appliedPriorityClass = Get-RooIndustriesPropertyValue $AppliedState 'priorityClass' $null
        originalAffinityMask = Get-RooIndustriesPropertyValue $OriginalState 'affinityMask' $null
        appliedAffinityMask = Get-RooIndustriesPropertyValue $AppliedState 'affinityMask' $null
        originalIoPriority = Get-RooIndustriesPropertyValue $OriginalState 'ioPriority' $null
        originalMemoryPriority = Get-RooIndustriesPropertyValue $OriginalState 'memoryPriority' $null
        appliedIoPriority = Get-RooIndustriesPropertyValue $AppliedState 'ioPriority' $null
        appliedMemoryPriority = Get-RooIndustriesPropertyValue $AppliedState 'memoryPriority' $null
        originalGpuPriority = Get-RooIndustriesPropertyValue $OriginalState 'gpuPriority' $null
        appliedGpuPriority = Get-RooIndustriesPropertyValue $AppliedState 'gpuPriority' $null
        appliedControls = @(Get-RooIndustriesArray $AppliedControls)
        ruleId = [string](Get-RooIndustriesPropertyValue $PreviewEntry 'ruleId' '')
        reason = [string](Get-RooIndustriesPropertyValue $PreviewEntry 'reason' '')
        pollIndex = $PollIndex
        changedAtUtc = Get-RooIndustriesUtcStamp
    }
}

function New-RooIndustriesGameTuneSkippedItem {
    param(
        [object]$PreviewEntry,
        [string]$Reason,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = Get-RooIndustriesPropertyValue $PreviewEntry 'processId' $null
        processName = Get-RooIndustriesPropertyValue $PreviewEntry 'processName' $null
        proposedPriorityClass = Get-RooIndustriesPropertyValue $PreviewEntry 'proposedPriorityClass' $null
        proposedAffinityMask = Get-RooIndustriesPropertyValue $PreviewEntry 'proposedAffinityMask' $null
        proposedIoPriority = Get-RooIndustriesPropertyValue $PreviewEntry 'proposedIoPriority' $null
        proposedMemoryPriority = Get-RooIndustriesPropertyValue $PreviewEntry 'proposedMemoryPriority' $null
        proposedGpuPriority = Get-RooIndustriesPropertyValue $PreviewEntry 'proposedGpuPriority' $null
        controlChanges = @(Get-RooIndustriesPreviewControlChanges $PreviewEntry)
        ruleId = Get-RooIndustriesPropertyValue $PreviewEntry 'ruleId' $null
        reason = $Reason
        pollIndex = $PollIndex
        skippedAtUtc = Get-RooIndustriesUtcStamp
    }
}

function New-RooIndustriesGameTuneBackupMetadata {
    param(
        [object]$BackupManifest,
        [string]$BackupPath
    )
    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($snap in @(Get-RooIndustriesPropertyArray $BackupManifest 'snapshots')) {
        $snapshots.Add([pscustomobject]@{
            type = 'processControls'
            target = "$([string](Get-RooIndustriesPropertyValue $snap 'processName' ''))`:$([int](Get-RooIndustriesPropertyValue $snap 'processId' 0))"
            originalState = [pscustomobject]@{
                priorityClass = Get-RooIndustriesPropertyValue $snap 'originalPriorityClass' $null
                affinityMask = Get-RooIndustriesPropertyValue $snap 'originalAffinityMask' $null
                ioPriority = Get-RooIndustriesPropertyValue $snap 'originalIoPriority' $null
                memoryPriority = Get-RooIndustriesPropertyValue $snap 'originalMemoryPriority' $null
                gpuPriority = Get-RooIndustriesPropertyValue $snap 'originalGpuPriority' $null
                executablePath = Get-RooIndustriesPropertyValue $snap 'executablePath' $null
            }
        }) | Out-Null
    }

    return [pscustomobject]@{
        backupId = [string](Get-RooIndustriesPropertyValue $BackupManifest 'backupId' '')
        scope = 'game-tune-session-process-controls'
        createdAtUtc = [string](Get-RooIndustriesPropertyValue $BackupManifest 'createdAtUtc' '')
        location = $BackupPath
        restorePoint = [pscustomobject]@{
            requested = $false
            status = 'not-required-for-process-priority'
            id = $null
        }
        snapshots = @($snapshots.ToArray())
        rollbackActionId = 'performance.gameTune.stopSession'
        rollbackSupported = $true
        retentionPolicy = [pscustomobject]@{
            keepLatestCount = 10
            minimumDays = 14
        }
    }
}

function New-RooIndustriesGameTuneResult {
    param(
        [string]$ResultId,
        [string]$Status,
        [string]$Summary,
        [object[]]$ChangedItems = @(),
        [object[]]$SkippedItems = @(),
        [object[]]$RestoredItems = @(),
        [object[]]$Artifacts = @()
    )
    return [pscustomobject]@{
        resultId = $ResultId
        status = $Status
        startedAtUtc = $null
        completedAtUtc = Get-RooIndustriesUtcStamp
        summary = $Summary
        changedItems = @(Get-RooIndustriesArray $ChangedItems)
        skippedItems = @(Get-RooIndustriesArray $SkippedItems)
        restoredItems = @(Get-RooIndustriesArray $RestoredItems)
        artifacts = @(Get-RooIndustriesArray $Artifacts)
    }
}

function Format-RooIndustriesGameTuneSkipText {
    param([object[]]$Items)
    $parts = foreach ($item in @(Get-RooIndustriesArray $Items)) {
        $name = [string](Get-RooIndustriesPropertyValue $item 'processName' '')
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'the game' }
        foreach ($part in [regex]::Split([string](Get-RooIndustriesPropertyValue $item 'reason' ''), '; (?=\w+: )')) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $match = [regex]::Match($part, '^(priorityClass|affinityMask|ioPriority|memoryPriority|gpuPriority): (.+)$')
            $text = if ($match.Success) { (Get-RooIndustriesControlLabel $match.Groups[1].Value) + ' for ' + $name + ': ' + $match.Groups[2].Value } else { $name + ': ' + $part }
            $text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1)
        }
    }
    return (@($parts) -join ' ')
}

function Test-RooIndustriesGameTuneOwnerRunning {
    param([int]$OwnerId, [string]$OwnerStart)
    $savedTime = [datetime]::MinValue
    if ($OwnerId -le 0 -or -not [datetime]::TryParse($OwnerStart, [ref]$savedTime)) { return $false }
    $owner = Get-Process -Id $OwnerId -ErrorAction SilentlyContinue
    if ($null -eq $owner) { return $false }
    try { return Test-RooIndustriesProcessStartTime $OwnerStart ($owner.StartTime.ToUniversalTime().ToString('o')) }
    catch { return $false }
}

function Test-RooIndustriesGameTuneOwnerEnded {
    param([int]$OwnerId, [string]$OwnerStart)
    $savedTime = [datetime]::MinValue
    if ($OwnerId -le 0 -or -not [datetime]::TryParse($OwnerStart, [ref]$savedTime)) { return $false }
    $owner = Get-Process -Id $OwnerId -ErrorAction SilentlyContinue
    if ($null -ne $owner) {
        try {
            return -not (Test-RooIndustriesProcessStartTime $OwnerStart ($owner.StartTime.ToUniversalTime().ToString('o')))
        } catch { return $false }
    }
    return $true
}

function Repair-RooIndustriesInterruptedGameTuneSession {
    param([object]$Session, [string]$SessionPath)
    $rawStatus = [string](Get-RooIndustriesPropertyValue $Session 'sessionStatus' '')
    $ownerId = [int](Get-RooIndustriesPropertyValue $Session 'ownerProcessId' 0)
    $ownerStart = [string](Get-RooIndustriesPropertyValue $Session 'ownerStartTimeUtc' '')
    $recoverWhenOwnerEnds = [bool](Get-RooIndustriesPropertyValue $Session 'recoverWhenOwnerEnds' $false)
    $parsedOwnerStart = [datetime]::MinValue
    $ownerIdentityUnreadable = $recoverWhenOwnerEnds -and ($ownerId -le 0 -or -not [datetime]::TryParse($ownerStart, [ref]$parsedOwnerStart))
    $ownerEnded = Test-RooIndustriesGameTuneOwnerEnded $ownerId $ownerStart
    $workerEnded = Test-RooIndustriesGameTuneOwnerEnded ([int](Get-RooIndustriesPropertyValue $Session 'workerProcessId' 0)) ([string](Get-RooIndustriesPropertyValue $Session 'workerStartTimeUtc' ''))
    if ($rawStatus -eq 'running') { if (-not $ownerIdentityUnreadable -and -not $ownerEnded -and -not $workerEnded) { return $Session } }
    elseif ($rawStatus -ne 'completed' -or (-not $ownerEnded -and -not $ownerIdentityUnreadable) -or -not $recoverWhenOwnerEnds -or -not [bool](Get-RooIndustriesPropertyValue $Session 'restorable' $false)) { return $Session }
    $gate = Enter-RooIndustriesGovernorGate
    if ($null -eq $gate) { return $Session }
    try {
        $Session = Read-RooIndustriesJsonFile $SessionPath
        if ([string](Get-RooIndustriesPropertyValue $Session 'sessionStatus' '') -ne $rawStatus) { return $Session }
        if ([int](Get-RooIndustriesPropertyValue $Session 'ownerProcessId' 0) -ne $ownerId -or [string](Get-RooIndustriesPropertyValue $Session 'ownerStartTimeUtc' '') -ne $ownerStart) { return $Session }
        $Session.sessionStatus = 'failed'
        $Session.status = 'failed'
        $Session.completedAtUtc = Get-RooIndustriesUtcStamp
        Write-RooIndustriesGameTuneJsonFile $Session $SessionPath
        try {
            if ($ownerIdentityUnreadable) { throw 'The saved controller identity could not be checked. Its backup was kept.' }
            $backupPath = [string](Get-RooIndustriesPropertyValue $Session 'backupManifestPath' '')
            if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
                if (-not [string]::Equals([IO.Path]::GetFullPath($backupPath), (Join-Path (Split-Path $SessionPath -Parent) 'backup.json'), [StringComparison]::OrdinalIgnoreCase)) { throw 'The interrupted session backup is outside its session folder.' }
                $backup = Read-RooIndustriesJsonFile $backupPath
                if ([string](Get-RooIndustriesPropertyValue $backup 'sessionId' '') -cne [string](Get-RooIndustriesPropertyValue $Session 'sessionId' '') -or
                    [string](Get-RooIndustriesPropertyValue $backup 'profileId' '') -cne [string](Get-RooIndustriesPropertyValue $Session 'profileId' '')) { throw 'The interrupted session and backup do not match.' }
                $held = New-Object System.Collections.Generic.List[object]
                foreach ($snapshot in @(Get-RooIndustriesPropertyArray $backup 'snapshots')) {
                    $identity = Get-RooIndustriesGameTuneLiveProcessIdentity $snapshot
                    if ($identity.instanceEnded) { continue }
                    if (-not $identity.exists -or -not $identity.matches) { throw 'A saved app identity could not be checked. Its values were kept.' }
                    if ($null -eq $snapshot.PSObject.Properties['controlChanges']) { throw 'The interrupted session has no record of the controls it changed.' }
                    $reasons = New-Object System.Collections.Generic.List[string]
                    foreach ($change in @(Get-RooIndustriesPropertyArray $snapshot 'controlChanges')) {
                        if ([string](Get-RooIndustriesPropertyValue $change 'outcome' '') -eq 'failed') { continue }
                        $control = [string](Get-RooIndustriesPropertyValue $change 'control' '')
                        $current = Get-RooIndustriesControlStateValue $identity.currentControlState $control
                        $originalField = switch ($control) { 'priorityClass' { 'originalPriorityClass' }; 'affinityMask' { 'originalAffinityMask' }; 'ioPriority' { 'originalIoPriority' }; 'memoryPriority' { 'originalMemoryPriority' }; 'gpuPriority' { 'originalGpuPriority' }; default { throw 'The saved session contains an unknown control.' } }
                        if ($null -eq (Get-RooIndustriesPropertyValue $snapshot $originalField $null) -or $null -eq (Get-RooIndustriesPropertyValue $change 'proposedValue' $null)) { throw 'The saved session has an incomplete control backup.' }
                        $reason = if (Test-RooIndustriesGovernorOwnsControl $identity.process $control) {
                            $script:RooIndustriesGovernorManaged
                        } elseif (-not (Test-RooIndustriesControlValueEqual $control $current (Get-RooIndustriesPropertyValue $snapshot $originalField $null)) -and
                            -not (Test-RooIndustriesControlValueEqual $control $current (Get-RooIndustriesPropertyValue $change 'proposedValue' $null))) {
                            if ((Get-RooIndustriesAppliedControlValue $snapshot $control).verified) { $script:RooIndustriesRecoveryLeftForeign } else { $script:RooIndustriesUnprovenWrite }
                        } else { $null }
                        if ($null -ne $reason -and -not $reasons.Contains($control + ': ' + $reason)) { $reasons.Add($control + ': ' + $reason) | Out-Null }
                    }
                    if ($reasons.Count -gt 0) {
                        $held.Add([pscustomobject]@{
                            processId = Get-RooIndustriesPropertyValue $snapshot 'processId' 0
                            processName = Get-RooIndustriesPropertyValue $snapshot 'processName' ''
                            reason = ($reasons -join '; ')
                            skippedAtUtc = Get-RooIndustriesUtcStamp
                        }) | Out-Null
                    }
                }
                if ($held.Count -gt 0) {
                    $Session | Add-Member -NotePropertyName skippedItems -NotePropertyValue @($held.ToArray()) -Force
                    throw (Format-RooIndustriesGameTuneSkipText @($held.ToArray()))
                }
                $restore = & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') -SessionPath $SessionPath -ConfirmApply | ConvertFrom-Json
                $Session = Read-RooIndustriesJsonFile $SessionPath
                if ([bool](Get-RooIndustriesPropertyValue $restore 'restorable' $true)) {
                    $named = Format-RooIndustriesGameTuneSkipText @(Get-RooIndustriesPropertyArray $Session 'skippedItems' | Where-Object { [string](Get-RooIndustriesPropertyValue $_ 'outcome' '') -ne 'alreadyClosed' })
                    throw ('The interrupted session could not be fully restored. Its backup was kept.' + $(if ($named) { ' ' + $named } else { '' }))
                }
            } else {
                if (Test-Path -LiteralPath (Join-Path (Split-Path $SessionPath -Parent) 'backup.json')) { throw 'The interrupted session lost its backup reference. Its backup was kept.' }
                $Session.sessionStatus = 'completed'
                $Session.status = 'completed'
            }
            $Session.logs = @(Get-RooIndustriesPropertyArray $Session 'logs') + @((New-RooIndustriesLog 'Restored the interrupted game session from its saved backup.'))
        } catch {
            $Session.sessionStatus = 'failed'
            $Session.status = 'failed'
            $Session.errors = @(Get-RooIndustriesPropertyArray $Session 'errors') + @((New-RooIndustriesIssue 'GAME_TUNE_RECOVERY_NEEDS_ATTENTION' $_.Exception.Message 'error' 'performance.gameTune' $SessionPath $false 'Review the saved session before restoring.' $null))
        }
        Write-RooIndustriesGameTuneJsonFile $Session $SessionPath
        return $Session
    } finally { Exit-RooIndustriesGovernorGate $gate }
}

function Test-RooIndustriesGameTuneSameInstance {
    param(
        [object]$Reviewed,
        [object]$Current
    )
    return [int](Get-RooIndustriesPropertyValue $Reviewed 'processId' 0) -eq [int](Get-RooIndustriesPropertyValue $Current 'processId' -1) -and
        (Test-RooIndustriesProcessNameEquals ([string](Get-RooIndustriesPropertyValue $Reviewed 'processName' '')) ([string](Get-RooIndustriesPropertyValue $Current 'processName' ''))) -and
        [string](Get-RooIndustriesPropertyValue $Reviewed 'executablePath' '') -eq [string](Get-RooIndustriesPropertyValue $Current 'executablePath' '') -and
        (Test-RooIndustriesProcessStartTime (Get-RooIndustriesPropertyValue $Reviewed 'processStartTimeUtc' $null) (Get-RooIndustriesPropertyValue $Current 'processStartTimeUtc' $null))
}

function Get-RooIndustriesGameTunePlanKey {
    param([object]$Entry)
    $controls = @(Get-RooIndustriesPreviewControlChanges $Entry | ForEach-Object {
        "$([string](Get-RooIndustriesPropertyValue $_ 'control' ''))=$([string](Get-RooIndustriesPropertyValue $_ 'currentValue' $null))>$([string](Get-RooIndustriesPropertyValue $_ 'proposedValue' $null))|$([bool](Get-RooIndustriesPropertyValue $_ 'blocked' $false))"
    } | Sort-Object)
    return "$([string](Get-RooIndustriesPropertyValue $Entry 'classification' ''))|$([bool](Get-RooIndustriesPropertyValue $Entry 'blocked' $false))|$([bool](Get-RooIndustriesPropertyValue $Entry 'protected' $false))|$($controls -join ';')"
}

function New-RooIndustriesGameTuneReview {
    param(
        [object[]]$Preview,
        [string]$ProfileId,
        [string]$ProfilePath,
        [string]$TargetGameProcessName
    )
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-RooIndustriesArray $Preview)) {
        $isGame = [string](Get-RooIndustriesPropertyValue $entry 'classification' '') -eq 'gameTarget'
        if (-not $isGame -and -not (Test-RooIndustriesGameTuneEntryAllowed $entry).allowed) { continue }
        $entries.Add([pscustomobject]@{
            processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
            processName = [string](Get-RooIndustriesPropertyValue $entry 'processName' '')
            executablePath = Get-RooIndustriesPropertyValue $entry 'executablePath' $null
            processStartTimeUtc = Get-RooIndustriesPropertyValue $entry 'processStartTimeUtc' $null
            classification = [string](Get-RooIndustriesPropertyValue $entry 'classification' '')
            ruleId = Get-RooIndustriesPropertyValue $entry 'ruleId' $null
            blocked = [bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)
            protected = [bool](Get-RooIndustriesPropertyValue $entry 'protected' $false)
            controlChanges = @(Get-RooIndustriesPreviewControlChanges $entry)
        }) | Out-Null
    }
    return [pscustomobject]@{
        schemaVersion = 1
        kind = 'game-tune-review'
        reviewId = [guid]::NewGuid().ToString('N')
        createdAtUtc = Get-RooIndustriesUtcStamp
        profileId = $ProfileId
        profilePath = $ProfilePath
        profileSha256 = (Get-FileHash -LiteralPath $ProfilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        targetGameProcessName = if ([string]::IsNullOrWhiteSpace($TargetGameProcessName)) { $null } else { $TargetGameProcessName }
        entries = @($entries.ToArray())
    }
}

function Read-RooIndustriesGameTuneReview {
    param(
        [string]$ReviewPath,
        [string]$ReviewSha256,
        [string]$ProfilePath,
        [string]$TargetGameProcessName
    )
    $outOfDate = New-RooIndustriesIssue 'GAME_TUNE_REVIEW_OUT_OF_DATE' 'Your review is missing or out of date, so nothing changed. Review again, then start.' 'error' 'performance.gameTune' $ReviewPath $true 'Review again, then start.' $null
    if ([string]::IsNullOrWhiteSpace($ReviewPath) -or $ReviewSha256 -notmatch '^[a-fA-F0-9]{64}$') { return [pscustomobject]@{ review = $null; problem = $outOfDate } }
    try { $review = (Read-RooIndustriesOperationJson $ReviewPath $ReviewSha256).data }
    catch { return [pscustomobject]@{ review = $null; problem = $outOfDate } }
    if ([int](Get-RooIndustriesPropertyValue $review 'schemaVersion' 0) -ne 1 -or [string](Get-RooIndustriesPropertyValue $review 'kind' '') -ne 'game-tune-review') {
        return [pscustomobject]@{ review = $null; problem = $outOfDate }
    }
    $reviewedProfile = [string](Get-RooIndustriesPropertyValue $review 'profilePath' '')
    $profileMatches = -not [string]::IsNullOrWhiteSpace($reviewedProfile) -and
        [string]::Equals([IO.Path]::GetFullPath($reviewedProfile), [IO.Path]::GetFullPath($ProfilePath), [StringComparison]::OrdinalIgnoreCase) -and
        [string](Get-RooIndustriesPropertyValue $review 'profileSha256' '') -eq (Get-FileHash -LiteralPath $ProfilePath -Algorithm SHA256).Hash -and
        [string](Get-RooIndustriesPropertyValue $review 'targetGameProcessName' '') -eq [string]$TargetGameProcessName
    if (-not $profileMatches) {
        return [pscustomobject]@{ review = $null; problem = (New-RooIndustriesIssue 'GAME_TUNE_REVIEW_PLAN_CHANGED' 'The game profile changed after you reviewed it, so nothing changed. Review again, then start.' 'error' 'performance.gameTune' $ProfilePath $true 'Review again, then start.' $null) }
    }
    return [pscustomobject]@{ review = $review; problem = $null }
}

function Get-RooIndustriesGameTuneReviewProblem {
    param(
        [object]$Review,
        [object[]]$Preview
    )
    $reviewedEntries = @(Get-RooIndustriesPropertyArray $Review 'entries')
    if (@($reviewedEntries | Where-Object { [string](Get-RooIndustriesPropertyValue $_ 'classification' '') -eq 'gameTarget' }).Count -eq 0) {
        return New-RooIndustriesIssue 'GAME_TUNE_REVIEW_NO_GAME' 'No game was running when you reviewed, so nothing changed. Start your game, then review and start again.' 'error' 'performance.gameTune' $null $true 'Start your game, then review again.' $null
    }
    foreach ($reviewed in $reviewedEntries) {
        $name = [string](Get-RooIndustriesPropertyValue $reviewed 'processName' 'An app')
        $isGame = [string](Get-RooIndustriesPropertyValue $reviewed 'classification' '') -eq 'gameTarget'
        $current = @(Get-RooIndustriesArray $Preview | Where-Object { Test-RooIndustriesGameTuneSameInstance $reviewed $_ })
        if ($current.Count -gt 0) {
            $changed = (Get-RooIndustriesGameTunePlanKey $current[0]) -ne (Get-RooIndustriesGameTunePlanKey $reviewed)
        } else {
            $live = Get-RooIndustriesGameTuneLiveProcessIdentity $reviewed
            $changed = $live.exists -and $live.matches
            if (-not $changed -and $isGame) {
                return New-RooIndustriesIssue 'GAME_TUNE_REVIEWED_GAME_GONE' "$name closed or restarted after you reviewed it, so nothing changed. Review again, then start." 'error' 'performance.gameTune' $name $true 'Review again, then start.' $null
            }
        }
        if ($changed) {
            return New-RooIndustriesIssue 'GAME_TUNE_REVIEW_PLAN_CHANGED' "$name's settings are different from when you reviewed them, so nothing changed. Review again, then start." 'error' 'performance.gameTune' $name $true 'Review again, then start.' $null
        }
    }
    return $null
}

function Select-RooIndustriesGameTuneReviewedChanges {
    param(
        [object]$Review,
        [object]$PreviewEntry,
        [object[]]$Changes
    )
    $reviewed = @(Get-RooIndustriesPropertyArray $Review 'entries' | Where-Object { Test-RooIndustriesGameTuneSameInstance $_ $PreviewEntry })
    if ($reviewed.Count -eq 0) { return @() }
    foreach ($change in @(Get-RooIndustriesArray $Changes)) {
        $approved = @(Get-RooIndustriesPreviewControlChanges $reviewed[0] | Where-Object { $_.control -eq $change.control -and (Test-RooIndustriesControlValueEqual $change.control $_.proposedValue $change.proposedValue) })
        if ($approved.Count -eq 0) { continue }
        $boundChange = $change.PSObject.Copy()
        $boundChange.currentValue = $approved[0].currentValue
        $boundChange
    }
}
