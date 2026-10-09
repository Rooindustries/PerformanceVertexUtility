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
    ($Value | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $Path -Encoding UTF8
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

    $controlState = Get-RooIndustriesProcessControlState $processId $null
    $startMatches = Test-RooIndustriesProcessStartTime (Get-RooIndustriesPropertyValue $PreviewEntry 'processStartTimeUtc' $null) $controlState.startTimeUtc
    $matches = ($nameMatches -and $pathMatches -and $startMatches)
    $reason = if (-not $startMatches) { 'This app was restarted, or its start time could not be verified. Nothing was changed or restored.' } elseif ($matches) { $null } elseif (-not $nameMatches) { 'Live process name does not match the preview entry.' } else { $pathReason }
    return [pscustomobject]@{
        exists = $true
        matches = $matches
        process = $live
        currentPriorityClass = [string]$live.PriorityClass
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
