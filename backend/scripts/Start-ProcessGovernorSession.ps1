param(
    [string]$ProfilePath = '',
    [int]$PollIntervalSeconds = 0,
    [int]$SampleIntervalMilliseconds = 500,
    [int]$MaxDurationSeconds = 0,
    [int]$ForegroundProcessId = 0,
    [string]$OutputPath = '',
    [string]$StateRoot = '',
    [switch]$ConfirmApply,
    [switch]$IncludeCommandLine
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessGovernor.Common.ps1')

function Write-GovernorSessionState {
    param(
        [object]$State,
        [string]$SessionDirectory
    )
    if ([string]::IsNullOrWhiteSpace($SessionDirectory)) { return }
    Write-RooIndustriesProcessGovernorJsonFile $State (Join-Path $SessionDirectory 'session.json')
}

function New-GovernorSkippedItem {
    param(
        [object]$Entry,
        [string]$Reason,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = Get-RooIndustriesPropertyValue $Entry 'processId' $null
        processName = Get-RooIndustriesPropertyValue $Entry 'processName' $null
        cpuPercent = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Entry 'currentState' $null) 'cpuPercent' $null
        ruleId = Get-RooIndustriesPropertyValue $Entry 'ruleId' $null
        reason = $Reason
        reasonCodes = @(Get-RooIndustriesPropertyArray $Entry 'reasonCodes')
        pollIndex = $PollIndex
        skippedAtUtc = Get-RooIndustriesUtcStamp
    }
}

function New-GovernorSkippedProcessItem {
    param(
        [object]$Process,
        [object]$Decision,
        [string]$Reason,
        [int]$PollIndex
    )
    $ruleId = [string](Get-RooIndustriesPropertyValue $Decision 'matchedRuleId' '')
    if ([string]::IsNullOrWhiteSpace($ruleId)) { $ruleId = 'governor-skip' }
    return [pscustomobject]@{
        processId = [int](Get-RooIndustriesPropertyValue $Process 'pid' 0)
        processName = [string](Get-RooIndustriesPropertyValue $Process 'name' '')
        cpuPercent = Get-RooIndustriesPropertyValue $Process 'cpuPercent' $null
        ruleId = $ruleId
        reason = $Reason
        reasonCodes = @(Get-RooIndustriesPropertyArray $Decision 'reasonCodes')
        pollIndex = $PollIndex
        skippedAtUtc = Get-RooIndustriesUtcStamp
    }
}

function New-GovernorChangedItem {
    param(
        [object]$Entry,
        [object]$OriginalState,
        [object]$AppliedState,
        [object[]]$AppliedControls,
        [int]$PollIndex,
        [double]$SustainedSeconds
    )
    return [pscustomobject]@{
        processId = [int](Get-RooIndustriesPropertyValue $Entry 'processId' 0)
        processName = [string](Get-RooIndustriesPropertyValue $Entry 'processName' '')
        executablePath = Get-RooIndustriesPropertyValue $Entry 'executablePath' $null
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
        ruleId = [string](Get-RooIndustriesPropertyValue $Entry 'ruleId' '')
        cpuPercent = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Entry 'currentState' $null) 'cpuPercent' $null
        totalCpuPercent = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Entry 'currentState' $null) 'totalCpuPercent' $null
        sustainedSeconds = $SustainedSeconds
        reason = [string](Get-RooIndustriesPropertyValue $Entry 'reason' '')
        pollIndex = $PollIndex
        changedAtUtc = Get-RooIndustriesUtcStamp
    }
}

function New-GovernorRestoredItem {
    param(
        [object]$Snapshot,
        [object]$RestoredState,
        [object[]]$RestoredControls,
        [string]$Reason,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = [int](Get-RooIndustriesPropertyValue $Snapshot 'processId' 0)
        processName = [string](Get-RooIndustriesPropertyValue $Snapshot 'processName' '')
        executablePath = Get-RooIndustriesPropertyValue $Snapshot 'executablePath' $null
        originalPriorityClass = Get-RooIndustriesPropertyValue $Snapshot 'originalPriorityClass' $null
        restoredPriorityClass = Get-RooIndustriesPropertyValue $RestoredState 'priorityClass' $null
        originalAffinityMask = Get-RooIndustriesPropertyValue $Snapshot 'originalAffinityMask' $null
        restoredAffinityMask = Get-RooIndustriesPropertyValue $RestoredState 'affinityMask' $null
        originalIoPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalIoPriority' $null
        originalMemoryPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalMemoryPriority' $null
        restoredIoPriority = Get-RooIndustriesPropertyValue $RestoredState 'ioPriority' $null
        restoredMemoryPriority = Get-RooIndustriesPropertyValue $RestoredState 'memoryPriority' $null
        originalGpuPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalGpuPriority' $null
        restoredGpuPriority = Get-RooIndustriesPropertyValue $RestoredState 'gpuPriority' $null
        restoredControls = @(Get-RooIndustriesArray $RestoredControls)
        ruleId = [string](Get-RooIndustriesPropertyValue $Snapshot 'ruleId' '')
        reason = $Reason
        pollIndex = $PollIndex
        restoredAtUtc = Get-RooIndustriesUtcStamp
    }
}

function Get-GovernorRestoreChanges {
    param(
        [object]$Snapshot,
        [object]$CurrentState
    )
    $changes = New-Object System.Collections.Generic.List[object]
    $originalPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalPriorityClass' $null
    $originalAffinity = Get-RooIndustriesPropertyValue $Snapshot 'originalAffinityMask' $null
    $originalIoPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalIoPriority' $null
    $originalMemoryPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalMemoryPriority' $null
    $originalGpuPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalGpuPriority' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$originalPriority) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'priorityClass' $null) -ne [string]$originalPriority) {
        $changes.Add((New-RooIndustriesControlChange 'priorityClass' (Get-RooIndustriesPropertyValue $CurrentState 'priorityClass' $null) $originalPriority 'restorePriority' 'Restore original process priority after governor restraint.')) | Out-Null
    }
    if ($null -ne $originalAffinity -and -not [string]::IsNullOrWhiteSpace([string]$originalAffinity) -and (Test-RooIndustriesAffinityMaskAllowed $originalAffinity) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'affinityMask' $null) -ne [string]$originalAffinity) {
        $changes.Add((New-RooIndustriesControlChange 'affinityMask' (Get-RooIndustriesPropertyValue $CurrentState 'affinityMask' $null) ([int64]$originalAffinity) 'restoreAffinity' 'Restore original CPU affinity after governor restraint.')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$originalIoPriority) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'ioPriority' $null) -ne [string]$originalIoPriority) {
        $changes.Add((New-RooIndustriesControlChange 'ioPriority' (Get-RooIndustriesPropertyValue $CurrentState 'ioPriority' $null) $originalIoPriority 'restoreIoPriority' 'Restore original I/O priority after governor restraint.')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$originalMemoryPriority) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'memoryPriority' $null) -ne [string]$originalMemoryPriority) {
        $changes.Add((New-RooIndustriesControlChange 'memoryPriority' (Get-RooIndustriesPropertyValue $CurrentState 'memoryPriority' $null) $originalMemoryPriority 'restoreMemoryPriority' 'Restore original memory priority after governor restraint.')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$originalGpuPriority) -and (Test-RooIndustriesGpuPriorityAllowed ([string]$originalGpuPriority)) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'gpuPriority' $null) -ne [string]$originalGpuPriority -and [bool](Get-RooIndustriesPropertyValue $CurrentState 'gpuPriorityAvailable' $false)) {
        $changes.Add((New-RooIndustriesControlChange 'gpuPriority' (Get-RooIndustriesPropertyValue $CurrentState 'gpuPriority' $null) $originalGpuPriority 'restoreGpuPriority' 'Restore original GPU scheduling priority after governor restraint.')) | Out-Null
    }
    return @(Select-RooIndustriesGovernorOwnedRestoreChanges $Snapshot @($changes.ToArray()))
}

function Get-GovernorProcessKey {
    param([object]$Process)
    $processId = [int](Get-RooIndustriesPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooIndustriesPropertyValue $Process 'name' '')
    $processPath = [string](Get-RooIndustriesPropertyValue $Process 'executablePath' '')
    return "$processId|$processName|$processPath"
}

function Invoke-GovernorActiveRestore {
    param(
        [string]$Key,
        [object]$Active,
        [object]$Process,
        [object]$Config,
        [hashtable]$ActiveRestraints,
        [hashtable]$LastRestoreAt,
        [System.Collections.Generic.List[object]]$RestoredItems,
        [System.Collections.Generic.List[object]]$PollRestoredItems,
        [System.Collections.Generic.List[object]]$Errors,
        [int]$PollIndex,
        [string]$Reason,
        [datetime]$Now
    )
    $restrainedAt = [datetime](Get-RooIndustriesPropertyValue $Active 'restrainedAtLocal' $Now)
    $minimumElapsed = (($Now - $restrainedAt).TotalSeconds -ge [double]$Config.minimumRestraintSeconds)
    $cpuPercent = [double](Get-RooIndustriesPropertyValue $Process 'cpuPercent' 0)
    if (-not $minimumElapsed) {
        return $false
    }
    if ($cpuPercent -gt [double]$Config.restoreCpuThresholdPercent) {
        if ($Active.PSObject.Properties['lowCpuSampleCount']) {
            $Active.lowCpuSampleCount = 0
        } else {
            $Active | Add-Member -NotePropertyName lowCpuSampleCount -NotePropertyValue 0
        }
        return $false
    }

    $lowSampleCount = [int](Get-RooIndustriesPropertyValue $Active 'lowCpuSampleCount' 0) + 1
    if ($Active.PSObject.Properties['lowCpuSampleCount']) {
        $Active.lowCpuSampleCount = $lowSampleCount
    } else {
        $Active | Add-Member -NotePropertyName lowCpuSampleCount -NotePropertyValue $lowSampleCount
    }
    if ($lowSampleCount -lt 2) {
        return $false
    }

    $snapshot = Get-RooIndustriesPropertyValue $Active 'snapshot' $null
    $candidate = Get-RooIndustriesProcessGovernorLiveIdentity ([pscustomobject]@{
        processId = Get-RooIndustriesPropertyValue $snapshot 'processId' 0
        processName = Get-RooIndustriesPropertyValue $snapshot 'processName' ''
        executablePath = Get-RooIndustriesPropertyValue $snapshot 'executablePath' $null
        processStartTimeUtc = Get-RooIndustriesPropertyValue $snapshot 'processStartTimeUtc' $null
    })
    if (-not ($candidate.exists -and $candidate.matches)) {
        return $false
    }

    $currentState = Get-RooIndustriesProcessControlState ([int](Get-RooIndustriesPropertyValue $snapshot 'processId' 0)) $null -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $snapshot)
    $restoreChanges = @(Get-GovernorRestoreChanges $snapshot $currentState)
    $appliedRestoreControls = New-Object System.Collections.Generic.List[object]
    $restoreFailed = $false
    foreach ($change in $restoreChanges) {
        if([bool](Get-RooIndustriesPropertyValue $change 'blocked' $false)) {
            $Errors.Add((New-RooIndustriesIssue 'PROCESS_GOVERNOR_RESTORE_CONFLICT' ([string]$change.blockedReason) 'warning' 'performance.governor' ([string](Get-RooIndustriesPropertyValue $snapshot 'processName' '')) $false 'Inspect the external process-control change before restoring it.' $null))|Out-Null
            continue
        }
        try {
            Invoke-RooIndustriesProcessControlChange $candidate.process $change
            $appliedRestoreControls.Add($change) | Out-Null
        } catch {
            $restoreFailed = $true
            $Errors.Add((New-RooIndustriesIssue 'PROCESS_GOVERNOR_RESTORE_CONTROL_FAILED' $_.Exception.Message 'error' 'performance.governor' ([string](Get-RooIndustriesPropertyValue $snapshot 'processName' '')) $true 'Stop the session and retry restore if the process is still running.' $null)) | Out-Null
        }
    }
    $restoredState = Get-RooIndustriesProcessControlState ([int](Get-RooIndustriesPropertyValue $snapshot 'processId' 0)) $null -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $snapshot)
    $restoreItem = New-GovernorRestoredItem $snapshot $restoredState @($appliedRestoreControls.ToArray()) $Reason $PollIndex
    if($appliedRestoreControls.Count -gt 0) {
        if(@($restoreChanges|Where-Object {$_.blocked}).Count -gt 0){$restoreItem.reason='Restored owned controls; conflicting external controls were preserved.'}
        $RestoredItems.Add($restoreItem) | Out-Null
        $PollRestoredItems.Add($restoreItem) | Out-Null
    }
    if ($restoreFailed) { return $false }
    $ActiveRestraints.Remove($Key)
    $LastRestoreAt[$Key] = $Now
    return $true
}

try {
    if ($SampleIntervalMilliseconds -lt 100) { $SampleIntervalMilliseconds = 100 }
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\probalance-governor.profile.json'
    $resolvedProfilePath = Resolve-RooIndustriesPath $ProfilePath $defaultProfilePath
    $profile = Read-RooIndustriesJsonFile $resolvedProfilePath
    $profileId = [string](Get-RooIndustriesPropertyValue $profile 'profileId' 'process-governor')
    $protectedCatalogPath = Resolve-RooIndustriesProcessGovernorProtectedCatalog $profile $resolvedProfilePath
    $protectedCatalog = Read-RooIndustriesJsonFile $protectedCatalogPath
    $config = Get-RooIndustriesProcessGovernorConfig $profile $MaxDurationSeconds
    if ($PollIntervalSeconds -gt 0) { $config.pollIntervalSeconds = $PollIntervalSeconds }
    $foregroundPid = Get-RooIndustriesForegroundProcessId $ForegroundProcessId
    $startedAtUtc = Get-RooIndustriesUtcStamp

    if (-not $ConfirmApply) {
        $previewState = Get-RooIndustriesProcessGovernorPreview `
            -Profile $profile `
            -ProfilePath $resolvedProfilePath `
            -ProtectedCatalog $protectedCatalog `
            -SampleIntervalMilliseconds $SampleIntervalMilliseconds `
            -ForegroundProcessId $ForegroundProcessId `
            -MaxDurationSecondsOverride $MaxDurationSeconds `
            -IncludeCommandLine:$IncludeCommandLine
        $warning = New-RooIndustriesIssue 'PROCESS_GOVERNOR_DRY_RUN' 'Process governor session ran in dry-run mode. No process changes were applied.' 'info' 'performance.governor' $profileId $false 'Rerun with -ConfirmApply only after reviewing the governor preview.' $null
        $poll = [pscustomobject]@{
            pollIndex = 1
            capturedAtUtc = Get-RooIndustriesUtcStamp
            totalCpuPercent = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $previewState 'sample' $null) 'totalCpuPercent' 0
            previewCount = @(Get-RooIndustriesPropertyArray $previewState 'preview').Count
            wouldRestrainItems = @(Get-RooIndustriesPropertyArray $previewState 'preview' | Where-Object { $_.requiresConfirmation -eq $true })
            changedItems = @()
            skippedItems = @(Get-RooIndustriesPropertyArray $previewState 'preview' | Where-Object { $_.blocked -eq $true })
            restoredItems = @()
        }
        $result = [pscustomobject]@{
            resultId = "process-governor-session-$(Get-RooIndustriesFileStamp)"
            status = 'preview'
            startedAtUtc = $startedAtUtc
            completedAtUtc = Get-RooIndustriesUtcStamp
            summary = "Process governor dry-run completed with $(@($poll.wouldRestrainItems).Count) restraint candidate(s)."
            changedItems = @()
            skippedItems = @()
            restoredItems = @()
            artifacts = @()
        }
        $envelope = [pscustomobject]@{
            actionId = 'performance.governor.startSession'
            schemaVersion = 1
            productName = $script:RooIndustriesProcessProductName
            correlationId = $null
            sessionId = $null
            dryRun = $true
            profileId = $profileId
            profilePath = $resolvedProfilePath
            protectedCatalogPath = $protectedCatalogPath
            foregroundProcessId = Get-RooIndustriesPropertyValue $previewState 'foregroundProcessId' $null
            status = 'completed'
            sessionStatus = 'completed'
            startedAtUtc = $startedAtUtc
            completedAtUtc = Get-RooIndustriesUtcStamp
            pollIntervalSeconds = [int]$config.pollIntervalSeconds
            sampleIntervalMilliseconds = $SampleIntervalMilliseconds
            maxDurationSeconds = [int]$config.maxSessionDurationSeconds
            pollCount = 1
            stateRoot = $null
            sessionPath = $null
            backupManifestPath = $null
            restorable = $false
            activeRestraints = @()
            changedItems = @()
            skippedItems = @()
            restoredItems = @()
            polls = @($poll)
            backup = $null
            result = $result
            governor = $config
            runtimeEvidence = New-RooIndustriesProcessGovernorRuntimeEvidence -Session $null -StateRoot $null -SessionPath $null -BackupManifestPath $null
            warnings = @($warning)
            errors = @()
            logs = @((New-RooIndustriesLog 'Process governor dry-run completed without live changes.'))
        }
        Write-RooIndustriesJsonOutput $envelope $OutputPath
        exit 0
    }

    $sessionId = New-RooIndustriesProcessGovernorSessionId $profileId
    $resolvedGovernorStateRoot = Resolve-RooIndustriesProcessGovernorStateRoot $StateRoot
    $sessionDirectory = Get-RooIndustriesProcessGovernorSessionDirectory $resolvedGovernorStateRoot $sessionId
    Ensure-RooIndustriesDirectory $sessionDirectory
    $sessionStatePath = Join-Path $sessionDirectory 'session.json'
    $backupPath = Join-Path $sessionDirectory 'backup.json'

    $changed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $restored = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $logs = New-Object System.Collections.Generic.List[object]
    $polls = New-Object System.Collections.Generic.List[object]
    $snapshots = New-Object System.Collections.Generic.List[object]
    $overThresholdSince = @{}
    $decisions = @{}
    $activeRestraints = @{}
    $lastRestoreAt = @{}

    $backupManifest = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        backupId = "process-governor-$profileId-$(Get-RooIndustriesFileStamp)"
        sessionId = $sessionId
        createdAtUtc = $startedAtUtc
        actionId = 'performance.governor.startSession'
        profileId = $profileId
        profilePath = $resolvedProfilePath
        dryRun = $false
        snapshots = @()
    }

    $state = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        sessionId = $sessionId
        profileId = $profileId
        profilePath = $resolvedProfilePath
        protectedCatalogPath = $protectedCatalogPath
        dryRun = $false
        sessionStatus = 'running'
        status = 'running'
        startedAtUtc = $startedAtUtc
        completedAtUtc = $null
        pollIntervalSeconds = [int]$config.pollIntervalSeconds
        sampleIntervalMilliseconds = $SampleIntervalMilliseconds
        maxDurationSeconds = [int]$config.maxSessionDurationSeconds
        pollCount = 0
        stateRoot = $resolvedGovernorStateRoot
        sessionPath = $sessionStatePath
        backupManifestPath = $backupPath
        restorable = $false
        activeRestraints = @()
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        governor = $config
        runtimeEvidence = New-RooIndustriesProcessGovernorRuntimeEvidence -Session $null -StateRoot $resolvedGovernorStateRoot -SessionPath $sessionStatePath -BackupManifestPath $backupPath
        warnings = @()
        errors = @()
        logs = @()
    }
    Write-GovernorSessionState $state $sessionDirectory
    Add-RooIndustriesProcessGovernorLogFileEntry $sessionDirectory (New-RooIndustriesLog 'Confirmed process governor session state initialized.')

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollIndex = 0
    while ($true) {
        $pollIndex++
        if ($env:ROO_FORCE_FOREGROUND_FILE -and (Test-Path -LiteralPath $env:ROO_FORCE_FOREGROUND_FILE)) { $foregroundPid = [int](Get-Content -LiteralPath $env:ROO_FORCE_FOREGROUND_FILE -Raw) }
        $pollStartedAtUtc = Get-RooIndustriesUtcStamp
        $sample = Get-RooIndustriesGovernorCpuSample -SampleIntervalMilliseconds $SampleIntervalMilliseconds -IncludeCommandLine:$IncludeCommandLine
        $sampledAt = Get-Date
        if ($pollIndex -eq 1 -and $env:ROO_FORCE_FIRST_POLL_LAG_MS) { Start-Sleep -Milliseconds ([int]$env:ROO_FORCE_FIRST_POLL_LAG_MS) }
        $pollWouldRestrain = New-Object System.Collections.Generic.List[object]
        $pollChanged = New-Object System.Collections.Generic.List[object]
        $pollSkipped = New-Object System.Collections.Generic.List[object]
        $pollRestored = New-Object System.Collections.Generic.List[object]
        $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'
        $pollPressureCandidateSeen = $false

        $gate = Enter-RooIndustriesGovernorGate
        if ($null -eq $gate) {
            $warnings.Add((New-RooIndustriesIssue 'PROCESS_GOVERNOR_BUSY' 'A rule change kept the governor busy, so this poll changed nothing.' 'warning' 'performance.governor' $sessionId $false 'The next poll tries again.' $null)) | Out-Null
        }
        try {
            if ($null -ne $gate) {
                $pollDecisions = @{}
                foreach ($proc in @(Get-RooIndustriesPropertyArray $sample 'processes')) {
                    $processId = [int](Get-RooIndustriesPropertyValue $proc 'pid' 0)
                    $processName = [string](Get-RooIndustriesPropertyValue $proc 'name' '')
                    $key = Get-GovernorProcessKey $proc
                    $seenKeys.Add($key) | Out-Null
                    $decisionKey = "$key|$foregroundPid|$([string](Get-RooIndustriesPropertyValue $proc 'commandLine' ''))"
                    $decision = $decisions[$decisionKey]
                    if ($null -eq $decision) {
                        $decision = Get-RooIndustriesProcessGovernorDecision $proc $profile $protectedCatalog $foregroundPid $config
                    }
                    $pollDecisions[$decisionKey] = $decision
                    $cpuPercent = [double](Get-RooIndustriesPropertyValue $proc 'cpuPercent' 0)
                    $pressureMet = ([double](Get-RooIndustriesPropertyValue $sample 'totalCpuPercent' 0) -ge [double]$config.totalCpuPressureThresholdPercent -and $cpuPercent -ge [double]$config.perProcessCpuThresholdPercent)

                    if ($decision.blocked -and ($decision.candidateMatched -or $decision.profileProtected -or $decision.foregroundMatched)) {
                        $skipReason = ($decision.skipReasons -join ' ')
                        if ([string]::IsNullOrWhiteSpace($skipReason)) { $skipReason = 'Process is protected from governor restraint.' }
                        $skip = New-GovernorSkippedProcessItem $proc $decision $skipReason $pollIndex
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                        continue
                    }

                    if (-not $decision.candidateMatched) { continue }

                    $now = Get-Date
                    if ($pressureMet) {
                        $pollPressureCandidateSeen = $true
                        if (-not $overThresholdSince.ContainsKey($key)) {
                            $sampleSeconds = [double](Get-RooIndustriesPropertyValue $sample 'sampleIntervalSeconds' 0)
                            if ($sampleSeconds -lt 0) { $sampleSeconds = 0 }
                            $overThresholdSince[$key] = $sampledAt.AddSeconds(-1 * $sampleSeconds)
                        }
                    } else {
                        if ($overThresholdSince.ContainsKey($key)) { $overThresholdSince.Remove($key) }
                    }
                    $sustainedSeconds = if ($overThresholdSince.ContainsKey($key)) { [math]::Max(0.0, ($sampledAt - [datetime]$overThresholdSince[$key]).TotalSeconds) } else { 0 }

                    if ($activeRestraints.ContainsKey($key)) {
                        Invoke-GovernorActiveRestore `
                            -Key $key `
                            -Active $activeRestraints[$key] `
                            -Process $proc `
                            -Config $config `
                            -ActiveRestraints $activeRestraints `
                            -LastRestoreAt $lastRestoreAt `
                            -RestoredItems $restored `
                            -PollRestoredItems $pollRestored `
                            -Errors $errors `
                            -PollIndex $pollIndex `
                            -Reason 'Process CPU usage stayed below restore threshold after minimum restraint duration.' `
                            -Now $now | Out-Null
                        continue
                    }

                    if (-not $pressureMet) { continue }
                    if ($sustainedSeconds -lt [double]$config.timeOverThresholdSeconds) { continue }
                    if ($lastRestoreAt.ContainsKey($key) -and (($now - [datetime]$lastRestoreAt[$key]).TotalSeconds -lt [double]$config.cooldownAfterRestoreSeconds)) {
                        $entry = New-RooIndustriesProcessGovernorPreviewEntry $proc $profile $protectedCatalog $foregroundPid $config ([double](Get-RooIndustriesPropertyValue $sample 'totalCpuPercent' 0)) 'cooldown' $sustainedSeconds
                        $skip = New-GovernorSkippedItem $entry 'Process is inside cooldown after a prior governor restore.' $pollIndex
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                        continue
                    }

                    $entryToApply = New-RooIndustriesProcessGovernorPreviewEntry $proc $profile $protectedCatalog $foregroundPid $config ([double](Get-RooIndustriesPropertyValue $sample 'totalCpuPercent' 0)) 'restrain' $sustainedSeconds
                    $entryChanges = @(Get-RooIndustriesGovernorApplicableControlChanges @(Get-RooIndustriesPreviewControlChanges $entryToApply))
                    if ($entryChanges.Count -eq 0 -or [bool](Get-RooIndustriesPropertyValue $entryToApply 'blocked' $false)) {
                        $skip = New-GovernorSkippedItem $entryToApply (Get-RooIndustriesPropertyValue $entryToApply 'blockedReason' (Get-RooIndustriesPropertyValue $entryToApply 'reason' 'No process control change was needed for governor restraint.')) $pollIndex
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                        continue
                    }
                    $pollWouldRestrain.Add($entryToApply) | Out-Null
                    $identity = Get-RooIndustriesProcessGovernorLiveIdentity $entryToApply
                    if (-not $identity.exists -or -not $identity.matches) {
                        $skip = New-GovernorSkippedItem $entryToApply $identity.reason $pollIndex
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                        continue
                    }
                    $originalState = $identity.currentControlState
                    $livePlan = Get-RooIndustriesApplicableProcessControlChanges $entryChanges $originalState
                    foreach ($skippedControl in @(Get-RooIndustriesPropertyArray $livePlan 'skippedControls')) {
                        $skip = New-GovernorSkippedItem $entryToApply ([string](Get-RooIndustriesPropertyValue $skippedControl 'reason' 'Process control was skipped.')) $pollIndex
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                    }
                    $entryChanges = @(Get-RooIndustriesPropertyArray $livePlan 'changes')
                    if ($entryChanges.Count -eq 0) {
                        continue
                    }
                    $snapshot = [pscustomobject]@{
                        processId = $processId
                        processName = $processName
                        executablePath = Get-RooIndustriesPropertyValue $entryToApply 'executablePath' $identity.currentPath
                        originalPriorityClass = $originalState.priorityClass
                        proposedPriorityClass = Get-RooIndustriesPropertyValue $entryToApply 'proposedPriorityClass' $null
                        originalAffinityMask = $originalState.affinityMask
                        proposedAffinityMask = Get-RooIndustriesPropertyValue $entryToApply 'proposedAffinityMask' $null
                        originalIoPriority = $originalState.ioPriority
                        originalMemoryPriority = $originalState.memoryPriority
                        proposedIoPriority = Get-RooIndustriesPropertyValue $entryToApply 'proposedIoPriority' $null
                        proposedMemoryPriority = Get-RooIndustriesPropertyValue $entryToApply 'proposedMemoryPriority' $null
                        originalGpuPriority = $originalState.gpuPriority
                        proposedGpuPriority = Get-RooIndustriesPropertyValue $entryToApply 'proposedGpuPriority' $null
                        controlChanges = @($entryChanges)
                        processStartTimeUtc = $identity.processStartTimeUtc
                        capturedAtUtc = Get-RooIndustriesUtcStamp
                        profileId = $profileId
                        ruleId = [string](Get-RooIndustriesPropertyValue $entryToApply 'ruleId' '')
                        reason = [string](Get-RooIndustriesPropertyValue $entryToApply 'reason' '')
                        sessionId = $sessionId
                    }
                    # A new restraint cycle captures the user's current originals. An
                    # older cycle must not overwrite values changed between cycles.
                    for($index=$snapshots.Count-1;$index -ge 0;$index--) {
                        if([int](Get-RooIndustriesPropertyValue $snapshots[$index] 'processId' 0) -eq $processId){$snapshots.RemoveAt($index)}
                    }
                    $snapshots.Add($snapshot) | Out-Null
                    $backupManifest.snapshots = @($snapshots.ToArray())
                    Write-RooIndustriesProcessGovernorJsonFile $backupManifest $backupPath
                    $state.backupManifestPath = $backupPath
                    $state.restorable = $true
                    $state.activeRestraints = @($activeRestraints.Values)
                    Write-GovernorSessionState $state $sessionDirectory

                    $appliedControls = New-Object System.Collections.Generic.List[object]
                    $failedControls = New-Object System.Collections.Generic.List[string]
                    foreach ($change in $entryChanges) {
                        try {
                            Invoke-RooIndustriesProcessControlChange $identity.process $change
                            $appliedControls.Add($change) | Out-Null
                        } catch {
                            $failedControls.Add("$([string](Get-RooIndustriesPropertyValue $change 'control' 'unknown')): $($_.Exception.Message)") | Out-Null
                        } finally {
                            Write-RooIndustriesProcessGovernorJsonFile $backupManifest $backupPath
                        }
                    }
                    if ($appliedControls.Count -gt 0) {
                        $appliedState = Get-RooIndustriesProcessControlState $processId $null -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $entryToApply)
                        $changedItem = New-GovernorChangedItem $entryToApply $originalState $appliedState @($appliedControls.ToArray()) $pollIndex $sustainedSeconds
                        $changed.Add($changedItem) | Out-Null
                        $pollChanged.Add($changedItem) | Out-Null
                        $activeRestraints[$key] = [pscustomobject]@{
                            processId = $processId
                            processName = $processName
                            executablePath = Get-RooIndustriesPropertyValue $snapshot 'executablePath' $null
                            ruleId = Get-RooIndustriesPropertyValue $snapshot 'ruleId' ''
                            restrainedAtUtc = Get-RooIndustriesUtcStamp
                            restrainedAtLocal = $now
                            minimumUntilUtc = $now.AddSeconds([double]$config.minimumRestraintSeconds).ToUniversalTime().ToString('o')
                            snapshot = $snapshot
                        }
                    }
                    if ($failedControls.Count -gt 0) {
                        $skip = New-GovernorSkippedItem $entryToApply ($failedControls -join '; ') $pollIndex
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                    }
                }
                $decisions = $pollDecisions

                foreach ($key in @($activeRestraints.Keys)) {
                    if (-not $seenKeys.Contains([string]$key)) {
                        $active = $activeRestraints[$key]
                        $skip = [pscustomobject]@{
                            processId = Get-RooIndustriesPropertyValue $active 'processId' 0
                            processName = Get-RooIndustriesPropertyValue $active 'processName' ''
                            ruleId = Get-RooIndustriesPropertyValue $active 'ruleId' ''
                            reason = 'Restrained process exited before restore was needed.'
                            pollIndex = $pollIndex
                            skippedAtUtc = Get-RooIndustriesUtcStamp
                        }
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                        $activeRestraints.Remove($key)
                    }
                }

                $poll = [pscustomobject]@{
                    pollIndex = $pollIndex
                    capturedAtUtc = $pollStartedAtUtc
                    totalCpuPercent = Get-RooIndustriesPropertyValue $sample 'totalCpuPercent' 0
                    previewCount = $pollWouldRestrain.Count + $pollSkipped.Count
                    wouldRestrainItems = @($pollWouldRestrain.ToArray())
                    changedItems = @($pollChanged.ToArray())
                    skippedItems = @($pollSkipped.ToArray())
                    restoredItems = @($pollRestored.ToArray())
                    activeRestraintCount = $activeRestraints.Count
                }
                $polls.Add($poll) | Out-Null
                $logEntry = New-RooIndustriesLog "Process governor poll $pollIndex completed with $($pollChanged.Count) restraint(s), $($pollRestored.Count) restore(s), and $($pollSkipped.Count) skip(s)."
                $logs.Add($logEntry) | Out-Null
                Add-RooIndustriesProcessGovernorLogFileEntry $sessionDirectory $logEntry

                $state.pollCount = $pollIndex
                $state.changedItems = @($changed.ToArray())
                $state.skippedItems = @($skipped.ToArray())
                $state.restoredItems = @($restored.ToArray())
                $state.activeRestraints = @($activeRestraints.Values)
                $state.restorable = ($activeRestraints.Count -gt 0)
                $state.warnings = @($warnings.ToArray())
                $state.errors = @($errors.ToArray())
                $state.logs = @($logs.ToArray())
                Write-GovernorSessionState $state $sessionDirectory
            }
        } finally {
            Exit-RooIndustriesGovernorGate $gate
        }

        $elapsedAfterPoll = $stopwatch.Elapsed.TotalSeconds
        $allowFollowUpApplyPoll = ($pollPressureCandidateSeen -and $changed.Count -eq 0 -and $activeRestraints.Count -eq 0 -and $pollIndex -lt 2)
        if ($elapsedAfterPoll -ge [double]$config.maxSessionDurationSeconds -and -not $allowFollowUpApplyPoll) { break }
        if (($elapsedAfterPoll + [int]$config.pollIntervalSeconds) -gt [double]$config.maxSessionDurationSeconds -and -not $allowFollowUpApplyPoll) { break }
        Start-Sleep -Seconds ([int]$config.pollIntervalSeconds)
    }

    if ($activeRestraints.Count -gt 0) {
        $finalSample = Get-RooIndustriesGovernorCpuSample -SampleIntervalMilliseconds $SampleIntervalMilliseconds -IncludeCommandLine:$IncludeCommandLine
        $finalPollIndex = $pollIndex + 1
        $finalPollStartedAtUtc = Get-RooIndustriesUtcStamp
        $finalProcessByKey = @{}
        foreach ($proc in @(Get-RooIndustriesPropertyArray $finalSample 'processes')) {
            $finalProcessByKey[(Get-GovernorProcessKey $proc)] = $proc
        }
        $finalPollRestored = New-Object System.Collections.Generic.List[object]
        $finalPollSkipped = New-Object System.Collections.Generic.List[object]
        foreach ($key in @($activeRestraints.Keys)) {
            if ($finalProcessByKey.ContainsKey([string]$key)) {
                $finalNow = Get-Date
                Invoke-GovernorActiveRestore `
                    -Key ([string]$key) `
                    -Active $activeRestraints[$key] `
                    -Process $finalProcessByKey[[string]$key] `
                    -Config $config `
                    -ActiveRestraints $activeRestraints `
                    -LastRestoreAt $lastRestoreAt `
                    -RestoredItems $restored `
                    -PollRestoredItems $finalPollRestored `
                    -Errors $errors `
                    -PollIndex $finalPollIndex `
                    -Reason 'Process CPU usage stayed below restore threshold in the final calm sample.' `
                    -Now $finalNow | Out-Null
            } else {
                $active = $activeRestraints[$key]
                $skip = [pscustomobject]@{
                    processId = Get-RooIndustriesPropertyValue $active 'processId' 0
                    processName = Get-RooIndustriesPropertyValue $active 'processName' ''
                    ruleId = Get-RooIndustriesPropertyValue $active 'ruleId' ''
                    reason = 'Restrained process exited before final calm restore.'
                    pollIndex = $finalPollIndex
                    skippedAtUtc = Get-RooIndustriesUtcStamp
                }
                $skipped.Add($skip) | Out-Null
                $finalPollSkipped.Add($skip) | Out-Null
                $activeRestraints.Remove($key)
            }
        }
        if ($finalPollRestored.Count -gt 0 -or $finalPollSkipped.Count -gt 0) {
            $pollIndex = $finalPollIndex
            $finalPoll = [pscustomobject]@{
                pollIndex = $finalPollIndex
                capturedAtUtc = $finalPollStartedAtUtc
                totalCpuPercent = Get-RooIndustriesPropertyValue $finalSample 'totalCpuPercent' 0
                previewCount = $finalPollSkipped.Count
                wouldRestrainItems = @()
                changedItems = @()
                skippedItems = @($finalPollSkipped.ToArray())
                restoredItems = @($finalPollRestored.ToArray())
                activeRestraintCount = $activeRestraints.Count
            }
            $polls.Add($finalPoll) | Out-Null
            $logEntry = New-RooIndustriesLog "Process governor final calm sample completed with $($finalPollRestored.Count) restore(s) and $($finalPollSkipped.Count) skip(s)."
            $logs.Add($logEntry) | Out-Null
            Add-RooIndustriesProcessGovernorLogFileEntry $sessionDirectory $logEntry
        }
    }

    $completedAtUtc = Get-RooIndustriesUtcStamp
    $sessionStatus = if ($errors.Count -gt 0) { 'failed' } else { 'completed' }
    $resultStatus = if ($errors.Count -gt 0) { 'partial' } elseif ($changed.Count -gt 0 -or $restored.Count -gt 0) { 'success' } else { 'success' }
    $backupMetadata = if (Test-Path -LiteralPath $backupPath) { New-RooIndustriesProcessGovernorBackupMetadata $backupManifest $backupPath } else { $null }
    $artifacts = New-Object System.Collections.Generic.List[object]
    $artifacts.Add([pscustomobject]@{ type = 'processGovernorSessionState'; path = $sessionStatePath }) | Out-Null
    if ($backupMetadata) { $artifacts.Add([pscustomobject]@{ type = 'processGovernorSessionBackup'; path = $backupPath }) | Out-Null }
    $result = [pscustomobject]@{
        resultId = "process-governor-session-$(Get-RooIndustriesFileStamp)"
        status = $resultStatus
        startedAtUtc = $startedAtUtc
        completedAtUtc = $completedAtUtc
        summary = "Process governor completed after $pollIndex poll(s) with $($changed.Count) restraint(s), $($restored.Count) restore(s), $($skipped.Count) skip(s), and $($activeRestraints.Count) active restraint(s)."
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        artifacts = @($artifacts.ToArray())
    }
    $envelope = [pscustomobject]@{
        actionId = 'performance.governor.startSession'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        correlationId = $sessionId
        sessionId = $sessionId
        dryRun = $false
        profileId = $profileId
        profilePath = $resolvedProfilePath
        protectedCatalogPath = $protectedCatalogPath
        foregroundProcessId = $foregroundPid
        status = $sessionStatus
        sessionStatus = $sessionStatus
        startedAtUtc = $startedAtUtc
        completedAtUtc = $completedAtUtc
        pollIntervalSeconds = [int]$config.pollIntervalSeconds
        sampleIntervalMilliseconds = $SampleIntervalMilliseconds
        maxDurationSeconds = [int]$config.maxSessionDurationSeconds
        pollCount = $pollIndex
        stateRoot = $resolvedGovernorStateRoot
        sessionPath = $sessionStatePath
        backupManifestPath = if ($backupMetadata) { $backupPath } else { $null }
        restorable = ($activeRestraints.Count -gt 0)
        activeRestraints = @($activeRestraints.Values)
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        polls = @($polls.ToArray())
        backup = $backupMetadata
        result = $result
        governor = $config
        runtimeEvidence = New-RooIndustriesProcessGovernorRuntimeEvidence -Session $state -StateRoot $resolvedGovernorStateRoot -SessionPath $sessionStatePath -BackupManifestPath $(if ($backupMetadata) { $backupPath } else { $null })
        warnings = @($warnings.ToArray())
        errors = @($errors.ToArray())
        logs = @($logs.ToArray())
    }
    $state.sessionStatus = $sessionStatus
    $state.status = $sessionStatus
    $state.completedAtUtc = $completedAtUtc
    $state.pollCount = $pollIndex
    $state.changedItems = @($changed.ToArray())
    $state.skippedItems = @($skipped.ToArray())
    $state.restoredItems = @($restored.ToArray())
    $state.activeRestraints = @($activeRestraints.Values)
    $state.restorable = ($activeRestraints.Count -gt 0)
    $state.backupManifestPath = if ($backupMetadata) { $backupPath } else { $null }
    $state.runtimeEvidence = New-RooIndustriesProcessGovernorRuntimeEvidence -Session $state -StateRoot $resolvedGovernorStateRoot -SessionPath $sessionStatePath -BackupManifestPath $(if ($backupMetadata) { $backupPath } else { $null })
    $state.warnings = @($warnings.ToArray())
    $state.errors = @($errors.ToArray())
    $state.logs = @($logs.ToArray())
    Write-GovernorSessionState $state $sessionDirectory

    Write-RooIndustriesJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.governor.startSession'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        correlationId = $null
        sessionId = $null
        dryRun = (-not $ConfirmApply)
        profileId = $null
        profilePath = $ProfilePath
        status = 'failed'
        sessionStatus = 'failed'
        startedAtUtc = $null
        completedAtUtc = Get-RooIndustriesUtcStamp
        pollIntervalSeconds = $PollIntervalSeconds
        sampleIntervalMilliseconds = $SampleIntervalMilliseconds
        maxDurationSeconds = $MaxDurationSeconds
        pollCount = 0
        stateRoot = $null
        sessionPath = $null
        backupManifestPath = $null
        restorable = $false
        activeRestraints = @()
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        polls = @()
        backup = $null
        result = $null
        governor = $null
        warnings = @()
        errors = @((New-RooIndustriesIssue 'PROCESS_GOVERNOR_SESSION_FAILED' $_.Exception.Message 'error' 'performance.governor' $ProfilePath $true 'Review profile path, process permissions, and governor thresholds.' $null))
        logs = @((New-RooIndustriesLog 'Process governor session failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorEnvelope $OutputPath
    exit 1
}
