. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$script:RooGameTuneStateFolderName = 'game-tune-sessions'

function Resolve-RooGameTuneStateRoot {
    param([string]$StateRoot)
    $defaultStateRoot = Join-Path $PSScriptRoot '..\state'
    $resolvedStateRoot = Resolve-RooPath $StateRoot $defaultStateRoot
    return [System.IO.Path]::GetFullPath((Join-Path $resolvedStateRoot $script:RooGameTuneStateFolderName))
}

function New-RooGameTuneSessionId {
    param([string]$ProfileId)
    $safeProfileId = if ([string]::IsNullOrWhiteSpace($ProfileId)) { 'profile' } else { $ProfileId.ToLowerInvariant() -replace '[^a-z0-9\-]+', '-' }
    return "game-tune-$safeProfileId-$(Get-RooFileStamp)"
}

function Get-RooGameTuneSessionDirectory {
    param(
        [string]$ResolvedGameTuneStateRoot,
        [string]$SessionId
    )
    return Join-Path $ResolvedGameTuneStateRoot $SessionId
}

function Write-RooGameTuneJsonFile {
    param(
        [object]$Value,
        [string]$Path
    )
    Ensure-RooDirectory (Split-Path $Path -Parent)
    ($Value | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Add-RooGameTuneLogFileEntry {
    param(
        [string]$SessionDirectory,
        [object]$Entry
    )
    if ([string]::IsNullOrWhiteSpace($SessionDirectory)) { return }
    Ensure-RooDirectory $SessionDirectory
    ($Entry | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath (Join-Path $SessionDirectory 'events.jsonl') -Encoding UTF8
}

function Get-RooGameTuneSessionFileFromPath {
    param([string]$SessionPath)
    if ([string]::IsNullOrWhiteSpace($SessionPath)) { return $null }
    $resolved = Resolve-RooPath $SessionPath $SessionPath
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        return Join-Path $resolved 'session.json'
    }
    return $resolved
}

function Get-RooGameTuneLatestSessionFile {
    param([string]$ResolvedGameTuneStateRoot)
    if (-not (Test-Path -LiteralPath $ResolvedGameTuneStateRoot)) { return $null }
    $latest = Get-ChildItem -LiteralPath $ResolvedGameTuneStateRoot -Filter 'session.json' -Recurse -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { return $null }
    return $latest.FullName
}

function Resolve-RooGameTuneSessionFile {
    param(
        [string]$SessionId,
        [string]$SessionPath,
        [string]$StateRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($SessionPath)) {
        return Get-RooGameTuneSessionFileFromPath $SessionPath
    }
    $resolvedStateRoot = Resolve-RooGameTuneStateRoot $StateRoot
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return Join-Path (Get-RooGameTuneSessionDirectory $resolvedStateRoot $SessionId) 'session.json'
    }
    return Get-RooGameTuneLatestSessionFile $resolvedStateRoot
}

function Get-RooGameTuneLiveProcessIdentity {
    param([object]$PreviewEntry)
    $processId = [int](Get-RooPropertyValue $PreviewEntry 'processId' 0)
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

    $expectedName = [string](Get-RooPropertyValue $PreviewEntry 'processName' '')
    $nameMatches = Test-RooProcessNameEquals $live.ProcessName $expectedName
    $currentPath = $null
    try { $currentPath = $live.Path } catch { $currentPath = $null }
    $expectedPath = Get-RooPropertyValue $PreviewEntry 'executablePath' $null
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

    $matches = ($nameMatches -and $pathMatches)
    $reason = if ($matches) { $null } elseif (-not $nameMatches) { 'Live process name does not match the preview entry.' } else { $pathReason }
    $controlState = Get-RooProcessControlState $processId $null
    return [pscustomobject]@{
        exists = $true
        matches = $matches
        process = $live
        currentPriorityClass = [string]$live.PriorityClass
        currentControlState = $controlState
        currentAffinityMask = $controlState.affinityMask
        currentIoPriority = $controlState.ioPriority
        currentGpuPriority = $controlState.gpuPriority
        processStartTimeUtc = $controlState.startTimeUtc
        currentPath = $currentPath
        reason = $reason
    }
}

function Test-RooGameTuneEntryAllowed {
    param([object]$PreviewEntry)
    if ([bool](Get-RooPropertyValue $PreviewEntry 'protected' $false) -or [bool](Get-RooPropertyValue $PreviewEntry 'blocked' $false)) {
        return [pscustomobject]@{ allowed = $false; reason = 'Preview entry is protected or blocked.' }
    }
    $changes = @(Get-RooPreviewControlChanges $PreviewEntry)
    if ($changes.Count -eq 0) {
        return [pscustomobject]@{ allowed = $false; reason = 'Preview entry does not request a process control change.' }
    }
    foreach ($change in $changes) {
        if ([bool](Get-RooPropertyValue $change 'blocked' $false)) {
            return [pscustomobject]@{ allowed = $false; reason = [string](Get-RooPropertyValue $change 'blockedReason' 'A requested process control is blocked.') }
        }
        $control = [string](Get-RooPropertyValue $change 'control' '')
        $value = Get-RooPropertyValue $change 'proposedValue' $null
        switch ($control) {
            'priorityClass' {
                if (-not (Test-RooPriorityAllowed ([string]$value))) { return [pscustomobject]@{ allowed = $false; reason = "Priority class '$value' is outside the allow-list." } }
            }
            'affinityMask' {
                if (-not (Test-RooAffinityMaskAllowed $value)) { return [pscustomobject]@{ allowed = $false; reason = "Affinity mask '$value' is invalid." } }
            }
            'ioPriority' {
                if (-not (Test-RooIoPriorityAllowed ([string]$value))) { return [pscustomobject]@{ allowed = $false; reason = "I/O priority '$value' is outside the allow-list." } }
            }
            'gpuPriority' {
                if (-not (Test-RooGpuPriorityAllowed ([string]$value))) { return [pscustomobject]@{ allowed = $false; reason = "GPU priority '$value' is outside the allow-list." } }
            }
            default {
                return [pscustomobject]@{ allowed = $false; reason = "Unsupported process control '$control'." }
            }
        }
    }
    return [pscustomobject]@{ allowed = $true; reason = $null }
}

function New-RooGameTuneChangedItem {
    param(
        [object]$PreviewEntry,
        [object]$OriginalState,
        [object]$AppliedState,
        [object[]]$AppliedControls,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = [int](Get-RooPropertyValue $PreviewEntry 'processId' 0)
        processName = [string](Get-RooPropertyValue $PreviewEntry 'processName' '')
        executablePath = Get-RooPropertyValue $PreviewEntry 'executablePath' $null
        originalPriorityClass = Get-RooPropertyValue $OriginalState 'priorityClass' $null
        appliedPriorityClass = Get-RooPropertyValue $AppliedState 'priorityClass' $null
        originalAffinityMask = Get-RooPropertyValue $OriginalState 'affinityMask' $null
        appliedAffinityMask = Get-RooPropertyValue $AppliedState 'affinityMask' $null
        originalIoPriority = Get-RooPropertyValue $OriginalState 'ioPriority' $null
        appliedIoPriority = Get-RooPropertyValue $AppliedState 'ioPriority' $null
        originalGpuPriority = Get-RooPropertyValue $OriginalState 'gpuPriority' $null
        appliedGpuPriority = Get-RooPropertyValue $AppliedState 'gpuPriority' $null
        appliedControls = @(Get-RooArray $AppliedControls)
        ruleId = [string](Get-RooPropertyValue $PreviewEntry 'ruleId' '')
        reason = [string](Get-RooPropertyValue $PreviewEntry 'reason' '')
        pollIndex = $PollIndex
        changedAtUtc = Get-RooUtcStamp
    }
}

function New-RooGameTuneSkippedItem {
    param(
        [object]$PreviewEntry,
        [string]$Reason,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = Get-RooPropertyValue $PreviewEntry 'processId' $null
        processName = Get-RooPropertyValue $PreviewEntry 'processName' $null
        proposedPriorityClass = Get-RooPropertyValue $PreviewEntry 'proposedPriorityClass' $null
        proposedAffinityMask = Get-RooPropertyValue $PreviewEntry 'proposedAffinityMask' $null
        proposedIoPriority = Get-RooPropertyValue $PreviewEntry 'proposedIoPriority' $null
        proposedGpuPriority = Get-RooPropertyValue $PreviewEntry 'proposedGpuPriority' $null
        controlChanges = @(Get-RooPreviewControlChanges $PreviewEntry)
        ruleId = Get-RooPropertyValue $PreviewEntry 'ruleId' $null
        reason = $Reason
        pollIndex = $PollIndex
        skippedAtUtc = Get-RooUtcStamp
    }
}

function New-RooGameTuneBackupMetadata {
    param(
        [object]$BackupManifest,
        [string]$BackupPath
    )
    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($snap in @(Get-RooPropertyArray $BackupManifest 'snapshots')) {
        $snapshots.Add([pscustomobject]@{
            type = 'processControls'
            target = "$([string](Get-RooPropertyValue $snap 'processName' ''))`:$([int](Get-RooPropertyValue $snap 'processId' 0))"
            originalState = [pscustomobject]@{
                priorityClass = Get-RooPropertyValue $snap 'originalPriorityClass' $null
                affinityMask = Get-RooPropertyValue $snap 'originalAffinityMask' $null
                ioPriority = Get-RooPropertyValue $snap 'originalIoPriority' $null
                gpuPriority = Get-RooPropertyValue $snap 'originalGpuPriority' $null
                executablePath = Get-RooPropertyValue $snap 'executablePath' $null
            }
        }) | Out-Null
    }

    return [pscustomobject]@{
        backupId = [string](Get-RooPropertyValue $BackupManifest 'backupId' '')
        scope = 'game-tune-session-process-controls'
        createdAtUtc = [string](Get-RooPropertyValue $BackupManifest 'createdAtUtc' '')
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

function New-RooGameTuneResult {
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
        completedAtUtc = Get-RooUtcStamp
        summary = $Summary
        changedItems = @(Get-RooArray $ChangedItems)
        skippedItems = @(Get-RooArray $SkippedItems)
        restoredItems = @(Get-RooArray $RestoredItems)
        artifacts = @(Get-RooArray $Artifacts)
    }
}
