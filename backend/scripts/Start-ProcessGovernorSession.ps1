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
    Write-RooProcessGovernorJsonFile $State (Join-Path $SessionDirectory 'session.json')
}

function New-GovernorSkippedItem {
    param(
        [object]$Entry,
        [string]$Reason,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = Get-RooPropertyValue $Entry 'processId' $null
        processName = Get-RooPropertyValue $Entry 'processName' $null
        cpuPercent = Get-RooPropertyValue (Get-RooPropertyValue $Entry 'currentState' $null) 'cpuPercent' $null
        ruleId = Get-RooPropertyValue $Entry 'ruleId' $null
        reason = $Reason
        reasonCodes = @(Get-RooPropertyArray $Entry 'reasonCodes')
        pollIndex = $PollIndex
        skippedAtUtc = Get-RooUtcStamp
    }
}

function New-GovernorSkippedProcessItem {
    param(
        [object]$Process,
        [object]$Decision,
        [string]$Reason,
        [int]$PollIndex
    )
    $ruleId = [string](Get-RooPropertyValue $Decision 'matchedRuleId' '')
    if ([string]::IsNullOrWhiteSpace($ruleId)) { $ruleId = 'governor-skip' }
    return [pscustomobject]@{
        processId = [int](Get-RooPropertyValue $Process 'pid' 0)
        processName = [string](Get-RooPropertyValue $Process 'name' '')
        cpuPercent = Get-RooPropertyValue $Process 'cpuPercent' $null
        ruleId = $ruleId
        reason = $Reason
        reasonCodes = @(Get-RooPropertyArray $Decision 'reasonCodes')
        pollIndex = $PollIndex
        skippedAtUtc = Get-RooUtcStamp
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
        processId = [int](Get-RooPropertyValue $Entry 'processId' 0)
        processName = [string](Get-RooPropertyValue $Entry 'processName' '')
        executablePath = Get-RooPropertyValue $Entry 'executablePath' $null
        originalPriorityClass = Get-RooPropertyValue $OriginalState 'priorityClass' $null
        appliedPriorityClass = Get-RooPropertyValue $AppliedState 'priorityClass' $null
        originalAffinityMask = Get-RooPropertyValue $OriginalState 'affinityMask' $null
        appliedAffinityMask = Get-RooPropertyValue $AppliedState 'affinityMask' $null
        originalIoPriority = Get-RooPropertyValue $OriginalState 'ioPriority' $null
        appliedIoPriority = Get-RooPropertyValue $AppliedState 'ioPriority' $null
        originalGpuPriority = Get-RooPropertyValue $OriginalState 'gpuPriority' $null
        appliedGpuPriority = Get-RooPropertyValue $AppliedState 'gpuPriority' $null
        appliedControls = @(Get-RooArray $AppliedControls)
        ruleId = [string](Get-RooPropertyValue $Entry 'ruleId' '')
        cpuPercent = Get-RooPropertyValue (Get-RooPropertyValue $Entry 'currentState' $null) 'cpuPercent' $null
        totalCpuPercent = Get-RooPropertyValue (Get-RooPropertyValue $Entry 'currentState' $null) 'totalCpuPercent' $null
        sustainedSeconds = $SustainedSeconds
        reason = [string](Get-RooPropertyValue $Entry 'reason' '')
        pollIndex = $PollIndex
        changedAtUtc = Get-RooUtcStamp
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
        processId = [int](Get-RooPropertyValue $Snapshot 'processId' 0)
        processName = [string](Get-RooPropertyValue $Snapshot 'processName' '')
        executablePath = Get-RooPropertyValue $Snapshot 'executablePath' $null
        originalPriorityClass = Get-RooPropertyValue $Snapshot 'originalPriorityClass' $null
        restoredPriorityClass = Get-RooPropertyValue $RestoredState 'priorityClass' $null
        originalAffinityMask = Get-RooPropertyValue $Snapshot 'originalAffinityMask' $null
        restoredAffinityMask = Get-RooPropertyValue $RestoredState 'affinityMask' $null
        originalIoPriority = Get-RooPropertyValue $Snapshot 'originalIoPriority' $null
        restoredIoPriority = Get-RooPropertyValue $RestoredState 'ioPriority' $null
        originalGpuPriority = Get-RooPropertyValue $Snapshot 'originalGpuPriority' $null
        restoredGpuPriority = Get-RooPropertyValue $RestoredState 'gpuPriority' $null
        restoredControls = @(Get-RooArray $RestoredControls)
        ruleId = [string](Get-RooPropertyValue $Snapshot 'ruleId' '')
        reason = $Reason
        pollIndex = $PollIndex
        restoredAtUtc = Get-RooUtcStamp
    }
}

function Get-GovernorRestoreChanges {
    param(
        [object]$Snapshot,
        [object]$CurrentState
    )
    $changes = New-Object System.Collections.Generic.List[object]
    $originalPriority = Get-RooPropertyValue $Snapshot 'originalPriorityClass' $null
    $originalAffinity = Get-RooPropertyValue $Snapshot 'originalAffinityMask' $null
    $originalIoPriority = Get-RooPropertyValue $Snapshot 'originalIoPriority' $null
    $originalGpuPriority = Get-RooPropertyValue $Snapshot 'originalGpuPriority' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$originalPriority) -and [string](Get-RooPropertyValue $CurrentState 'priorityClass' $null) -ne [string]$originalPriority) {
        $changes.Add((New-RooControlChange 'priorityClass' (Get-RooPropertyValue $CurrentState 'priorityClass' $null) $originalPriority 'restorePriority' 'Restore original process priority after governor restraint.')) | Out-Null
    }
    if ($null -ne $originalAffinity -and -not [string]::IsNullOrWhiteSpace([string]$originalAffinity) -and (Test-RooAffinityMaskAllowed $originalAffinity) -and [string](Get-RooPropertyValue $CurrentState 'affinityMask' $null) -ne [string]$originalAffinity) {
        $changes.Add((New-RooControlChange 'affinityMask' (Get-RooPropertyValue $CurrentState 'affinityMask' $null) ([int64]$originalAffinity) 'restoreAffinity' 'Restore original CPU affinity after governor restraint.')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$originalIoPriority) -and [string](Get-RooPropertyValue $CurrentState 'ioPriority' $null) -ne [string]$originalIoPriority) {
        $changes.Add((New-RooControlChange 'ioPriority' (Get-RooPropertyValue $CurrentState 'ioPriority' $null) $originalIoPriority 'restoreIoPriority' 'Restore original I/O priority after governor restraint.')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$originalGpuPriority) -and (Test-RooGpuPriorityAllowed ([string]$originalGpuPriority)) -and [string](Get-RooPropertyValue $CurrentState 'gpuPriority' $null) -ne [string]$originalGpuPriority -and [bool](Get-RooPropertyValue $CurrentState 'gpuPriorityAvailable' $false)) {
        $changes.Add((New-RooControlChange 'gpuPriority' (Get-RooPropertyValue $CurrentState 'gpuPriority' $null) $originalGpuPriority 'restoreGpuPriority' 'Restore original GPU scheduling priority after governor restraint.')) | Out-Null
    }
    return @(Select-RooGovernorOwnedRestoreChanges $Snapshot @($changes.ToArray()))
}

function Get-GovernorProcessKey {
    param([object]$Process)
    $processId = [int](Get-RooPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooPropertyValue $Process 'name' '')
    $processPath = [string](Get-RooPropertyValue $Process 'executablePath' '')
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
    $restrainedAt = [datetime](Get-RooPropertyValue $Active 'restrainedAtLocal' $Now)
    $minimumElapsed = (($Now - $restrainedAt).TotalSeconds -ge [double]$Config.minimumRestraintSeconds)
    $cpuPercent = [double](Get-RooPropertyValue $Process 'cpuPercent' 0)
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

    $lowSampleCount = [int](Get-RooPropertyValue $Active 'lowCpuSampleCount' 0) + 1
    if ($Active.PSObject.Properties['lowCpuSampleCount']) {
        $Active.lowCpuSampleCount = $lowSampleCount
    } else {
        $Active | Add-Member -NotePropertyName lowCpuSampleCount -NotePropertyValue $lowSampleCount
    }
    if ($lowSampleCount -lt 2) {
        return $false
    }

    $snapshot = Get-RooPropertyValue $Active 'snapshot' $null
    $candidate = Get-RooProcessGovernorLiveIdentity ([pscustomobject]@{
        processId = Get-RooPropertyValue $snapshot 'processId' 0
        processName = Get-RooPropertyValue $snapshot 'processName' ''
        executablePath = Get-RooPropertyValue $snapshot 'executablePath' $null
        processStartTimeUtc = Get-RooPropertyValue $snapshot 'processStartTimeUtc' $null
    })
    if (-not ($candidate.exists -and $candidate.matches)) {
        return $false
    }

    $currentState = Get-RooProcessControlState ([int](Get-RooPropertyValue $snapshot 'processId' 0)) $null
    $restoreChanges = @(Get-GovernorRestoreChanges $snapshot $currentState)
    $appliedRestoreControls = New-Object System.Collections.Generic.List[object]
    foreach ($change in $restoreChanges) {
        if([bool](Get-RooPropertyValue $change 'blocked' $false)) {
            $Errors.Add((New-RooIssue 'PROCESS_GOVERNOR_RESTORE_CONFLICT' ([string]$change.blockedReason) 'warning' 'performance.governor' ([string](Get-RooPropertyValue $snapshot 'processName' '')) $false 'Inspect the external process-control change before restoring it.' $null))|Out-Null
            continue
        }
        try {
            Invoke-RooProcessControlChange $candidate.process $change
            $appliedRestoreControls.Add($change) | Out-Null
        } catch {
            $Errors.Add((New-RooIssue 'PROCESS_GOVERNOR_RESTORE_CONTROL_FAILED' $_.Exception.Message 'error' 'performance.governor' ([string](Get-RooPropertyValue $snapshot 'processName' '')) $true 'Stop the session and retry restore if the process is still running.' $null)) | Out-Null
        }
    }
    $restoredState = Get-RooProcessControlState ([int](Get-RooPropertyValue $snapshot 'processId' 0)) $null
    $restoreItem = New-GovernorRestoredItem $snapshot $restoredState @($appliedRestoreControls.ToArray()) $Reason $PollIndex
    if($appliedRestoreControls.Count -gt 0) {
        if(@($restoreChanges|Where-Object {$_.blocked}).Count -gt 0){$restoreItem.reason='Restored owned controls; conflicting external controls were preserved.'}
        $RestoredItems.Add($restoreItem) | Out-Null
        $PollRestoredItems.Add($restoreItem) | Out-Null
    }
    $ActiveRestraints.Remove($Key)
    $LastRestoreAt[$Key] = $Now
    return $true
}

try {
    if ($SampleIntervalMilliseconds -lt 100) { $SampleIntervalMilliseconds = 100 }
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\probalance-governor.profile.json'
    $resolvedProfilePath = Resolve-RooPath $ProfilePath $defaultProfilePath
    $profile = Read-RooJsonFile $resolvedProfilePath
    $profileId = [string](Get-RooPropertyValue $profile 'profileId' 'process-governor')
    $protectedCatalogPath = Resolve-RooProcessGovernorProtectedCatalog $profile $resolvedProfilePath
    $protectedCatalog = Read-RooJsonFile $protectedCatalogPath
    $config = Get-RooProcessGovernorConfig $profile $MaxDurationSeconds
    if ($PollIntervalSeconds -gt 0) { $config.pollIntervalSeconds = $PollIntervalSeconds }
    $foregroundPid = Get-RooForegroundProcessId $ForegroundProcessId
    $startedAtUtc = Get-RooUtcStamp

    if (-not $ConfirmApply) {
        $previewState = Get-RooProcessGovernorPreview `
            -Profile $profile `
            -ProfilePath $resolvedProfilePath `
            -ProtectedCatalog $protectedCatalog `
            -SampleIntervalMilliseconds $SampleIntervalMilliseconds `
            -ForegroundProcessId $ForegroundProcessId `
            -MaxDurationSecondsOverride $MaxDurationSeconds `
            -IncludeCommandLine:$IncludeCommandLine
        $warning = New-RooIssue 'PROCESS_GOVERNOR_DRY_RUN' 'Process governor session ran in dry-run mode. No process changes were applied.' 'info' 'performance.governor' $profileId $false 'Rerun with -ConfirmApply only after reviewing the governor preview.' $null
        $poll = [pscustomobject]@{
            pollIndex = 1
            capturedAtUtc = Get-RooUtcStamp
            totalCpuPercent = Get-RooPropertyValue (Get-RooPropertyValue $previewState 'sample' $null) 'totalCpuPercent' 0
            previewCount = @(Get-RooPropertyArray $previewState 'preview').Count
            wouldRestrainItems = @(Get-RooPropertyArray $previewState 'preview' | Where-Object { $_.requiresConfirmation -eq $true })
            changedItems = @()
            skippedItems = @(Get-RooPropertyArray $previewState 'preview' | Where-Object { $_.blocked -eq $true })
            restoredItems = @()
        }
        $result = [pscustomobject]@{
            resultId = "process-governor-session-$(Get-RooFileStamp)"
            status = 'preview'
            startedAtUtc = $startedAtUtc
            completedAtUtc = Get-RooUtcStamp
            summary = "Process governor dry-run completed with $(@($poll.wouldRestrainItems).Count) restraint candidate(s)."
            changedItems = @()
            skippedItems = @()
            restoredItems = @()
            artifacts = @()
        }
        $envelope = [pscustomobject]@{
            actionId = 'performance.governor.startSession'
            schemaVersion = 1
            productName = $script:RooProcessProductName
            correlationId = $null
            sessionId = $null
            dryRun = $true
            profileId = $profileId
            profilePath = $resolvedProfilePath
            protectedCatalogPath = $protectedCatalogPath
            foregroundProcessId = Get-RooPropertyValue $previewState 'foregroundProcessId' $null
            status = 'completed'
            sessionStatus = 'completed'
            startedAtUtc = $startedAtUtc
            completedAtUtc = Get-RooUtcStamp
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
            runtimeEvidence = New-RooProcessGovernorRuntimeEvidence -Session $null -StateRoot $null -SessionPath $null -BackupManifestPath $null
            warnings = @($warning)
            errors = @()
            logs = @((New-RooLog 'Process governor dry-run completed without live changes.'))
        }
        Write-RooJsonOutput $envelope $OutputPath
        exit 0
    }

    $sessionId = New-RooProcessGovernorSessionId $profileId
    $resolvedGovernorStateRoot = Resolve-RooProcessGovernorStateRoot $StateRoot
    $sessionDirectory = Get-RooProcessGovernorSessionDirectory $resolvedGovernorStateRoot $sessionId
    Ensure-RooDirectory $sessionDirectory
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
    $activeRestraints = @{}
    $lastRestoreAt = @{}

    $backupManifest = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooProcessProductName
        backupId = "process-governor-$profileId-$(Get-RooFileStamp)"
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
        productName = $script:RooProcessProductName
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
        runtimeEvidence = New-RooProcessGovernorRuntimeEvidence -Session $null -StateRoot $resolvedGovernorStateRoot -SessionPath $sessionStatePath -BackupManifestPath $backupPath
        warnings = @()
        errors = @()
        logs = @()
    }
    Write-GovernorSessionState $state $sessionDirectory
    Add-RooProcessGovernorLogFileEntry $sessionDirectory (New-RooLog 'Confirmed process governor session state initialized.')

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollIndex = 0
    while ($true) {
        $pollIndex++
        $pollStartedAtUtc = Get-RooUtcStamp
        $sample = Get-RooGovernorCpuSample -SampleIntervalMilliseconds $SampleIntervalMilliseconds -IncludeCommandLine:$IncludeCommandLine
        $pollWouldRestrain = New-Object System.Collections.Generic.List[object]
        $pollChanged = New-Object System.Collections.Generic.List[object]
        $pollSkipped = New-Object System.Collections.Generic.List[object]
        $pollRestored = New-Object System.Collections.Generic.List[object]
        $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'
        $pollPressureCandidateSeen = $false

        foreach ($proc in @(Get-RooPropertyArray $sample 'processes')) {
            $processId = [int](Get-RooPropertyValue $proc 'pid' 0)
            $processName = [string](Get-RooPropertyValue $proc 'name' '')
            $key = Get-GovernorProcessKey $proc
            $seenKeys.Add($key) | Out-Null
            $decision = Get-RooProcessGovernorDecision $proc $profile $protectedCatalog $foregroundPid $config
            $cpuPercent = [double](Get-RooPropertyValue $proc 'cpuPercent' 0)
            $pressureMet = ([double](Get-RooPropertyValue $sample 'totalCpuPercent' 0) -ge [double]$config.totalCpuPressureThresholdPercent -and $cpuPercent -ge [double]$config.perProcessCpuThresholdPercent)

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
                    $sampleSeconds = [double](Get-RooPropertyValue $sample 'sampleIntervalSeconds' 0)
                    if ($sampleSeconds -lt 0) { $sampleSeconds = 0 }
                    $overThresholdSince[$key] = $now.AddSeconds(-1 * $sampleSeconds)
                }
            } else {
                if ($overThresholdSince.ContainsKey($key)) { $overThresholdSince.Remove($key) }
            }
            $sustainedSeconds = if ($overThresholdSince.ContainsKey($key)) { [math]::Max(0, ($now - [datetime]$overThresholdSince[$key]).TotalSeconds) } else { 0 }

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
                $entry = New-RooProcessGovernorPreviewEntry $proc $profile $protectedCatalog $foregroundPid $config ([double](Get-RooPropertyValue $sample 'totalCpuPercent' 0)) 'cooldown' $sustainedSeconds
                $skip = New-GovernorSkippedItem $entry 'Process is inside cooldown after a prior governor restore.' $pollIndex
                $skipped.Add($skip) | Out-Null
                $pollSkipped.Add($skip) | Out-Null
                continue
            }

            $entryToApply = New-RooProcessGovernorPreviewEntry $proc $profile $protectedCatalog $foregroundPid $config ([double](Get-RooPropertyValue $sample 'totalCpuPercent' 0)) 'restrain' $sustainedSeconds
            $entryChanges = @(Get-RooGovernorApplicableControlChanges @(Get-RooPreviewControlChanges $entryToApply))
            if ($entryChanges.Count -eq 0 -or [bool](Get-RooPropertyValue $entryToApply 'blocked' $false)) {
                $skip = New-GovernorSkippedItem $entryToApply (Get-RooPropertyValue $entryToApply 'blockedReason' 'No process control change was needed for governor restraint.') $pollIndex
                $skipped.Add($skip) | Out-Null
                $pollSkipped.Add($skip) | Out-Null
                continue
            }
            $pollWouldRestrain.Add($entryToApply) | Out-Null
            $identity = Get-RooProcessGovernorLiveIdentity $entryToApply
            if (-not $identity.exists -or -not $identity.matches) {
                $skip = New-GovernorSkippedItem $entryToApply $identity.reason $pollIndex
                $skipped.Add($skip) | Out-Null
                $pollSkipped.Add($skip) | Out-Null
                continue
            }
            $originalState = $identity.currentControlState
            $livePlan = Get-RooApplicableProcessControlChanges $entryChanges $originalState
            foreach ($skippedControl in @(Get-RooPropertyArray $livePlan 'skippedControls')) {
                $skip = New-GovernorSkippedItem $entryToApply ([string](Get-RooPropertyValue $skippedControl 'reason' 'Process control was skipped.')) $pollIndex
                $skipped.Add($skip) | Out-Null
                $pollSkipped.Add($skip) | Out-Null
            }
            $entryChanges = @(Get-RooPropertyArray $livePlan 'changes')
            if ($entryChanges.Count -eq 0) {
                continue
            }
            $snapshot = [pscustomobject]@{
                processId = $processId
                processName = $processName
                executablePath = Get-RooPropertyValue $entryToApply 'executablePath' $identity.currentPath
                originalPriorityClass = $originalState.priorityClass
                proposedPriorityClass = Get-RooPropertyValue $entryToApply 'proposedPriorityClass' $null
                originalAffinityMask = $originalState.affinityMask
                proposedAffinityMask = Get-RooPropertyValue $entryToApply 'proposedAffinityMask' $null
                originalIoPriority = $originalState.ioPriority
                proposedIoPriority = Get-RooPropertyValue $entryToApply 'proposedIoPriority' $null
                originalGpuPriority = $originalState.gpuPriority
                proposedGpuPriority = Get-RooPropertyValue $entryToApply 'proposedGpuPriority' $null
                controlChanges = @($entryChanges)
                processStartTimeUtc = $identity.processStartTimeUtc
                capturedAtUtc = Get-RooUtcStamp
                profileId = $profileId
                ruleId = [string](Get-RooPropertyValue $entryToApply 'ruleId' '')
                reason = [string](Get-RooPropertyValue $entryToApply 'reason' '')
                sessionId = $sessionId
            }
            # A new restraint cycle captures the user's current originals. An
            # older cycle must not overwrite values changed between cycles.
            for($index=$snapshots.Count-1;$index -ge 0;$index--) {
                if([int](Get-RooPropertyValue $snapshots[$index] 'processId' 0) -eq $processId){$snapshots.RemoveAt($index)}
            }
            $snapshots.Add($snapshot) | Out-Null
            $backupManifest.snapshots = @($snapshots.ToArray())
            Write-RooProcessGovernorJsonFile $backupManifest $backupPath
            $state.backupManifestPath = $backupPath
            $state.restorable = $true
            $state.activeRestraints = @($activeRestraints.Values)
            Write-GovernorSessionState $state $sessionDirectory

            $appliedControls = New-Object System.Collections.Generic.List[object]
            $failedControls = New-Object System.Collections.Generic.List[string]
            foreach ($change in $entryChanges) {
                try {
                    Invoke-RooProcessControlChange $identity.process $change
                    $appliedControls.Add($change) | Out-Null
                } catch {
                    $failedControls.Add("$([string](Get-RooPropertyValue $change 'control' 'unknown')): $($_.Exception.Message)") | Out-Null
                }
            }
            if ($appliedControls.Count -gt 0) {
                $appliedState = Get-RooProcessControlState $processId $null
                $changedItem = New-GovernorChangedItem $entryToApply $originalState $appliedState @($appliedControls.ToArray()) $pollIndex $sustainedSeconds
                $changed.Add($changedItem) | Out-Null
                $pollChanged.Add($changedItem) | Out-Null
                $activeRestraints[$key] = [pscustomobject]@{
                    processId = $processId
                    processName = $processName
                    executablePath = Get-RooPropertyValue $snapshot 'executablePath' $null
                    ruleId = Get-RooPropertyValue $snapshot 'ruleId' ''
                    restrainedAtUtc = Get-RooUtcStamp
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

        foreach ($key in @($activeRestraints.Keys)) {
            if (-not $seenKeys.Contains([string]$key)) {
                $active = $activeRestraints[$key]
                $skip = [pscustomobject]@{
                    processId = Get-RooPropertyValue $active 'processId' 0
                    processName = Get-RooPropertyValue $active 'processName' ''
                    ruleId = Get-RooPropertyValue $active 'ruleId' ''
                    reason = 'Restrained process exited before restore was needed.'
                    pollIndex = $pollIndex
                    skippedAtUtc = Get-RooUtcStamp
                }
                $skipped.Add($skip) | Out-Null
                $pollSkipped.Add($skip) | Out-Null
                $activeRestraints.Remove($key)
            }
        }

        $poll = [pscustomobject]@{
            pollIndex = $pollIndex
            capturedAtUtc = $pollStartedAtUtc
            totalCpuPercent = Get-RooPropertyValue $sample 'totalCpuPercent' 0
            previewCount = $pollWouldRestrain.Count + $pollSkipped.Count
            wouldRestrainItems = @($pollWouldRestrain.ToArray())
            changedItems = @($pollChanged.ToArray())
            skippedItems = @($pollSkipped.ToArray())
            restoredItems = @($pollRestored.ToArray())
            activeRestraintCount = $activeRestraints.Count
        }
        $polls.Add($poll) | Out-Null
        $logEntry = New-RooLog "Process governor poll $pollIndex completed with $($pollChanged.Count) restraint(s), $($pollRestored.Count) restore(s), and $($pollSkipped.Count) skip(s)."
        $logs.Add($logEntry) | Out-Null
        Add-RooProcessGovernorLogFileEntry $sessionDirectory $logEntry

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

        $elapsedAfterPoll = $stopwatch.Elapsed.TotalSeconds
        $allowFollowUpApplyPoll = ($pollPressureCandidateSeen -and $changed.Count -eq 0 -and $activeRestraints.Count -eq 0 -and $pollIndex -lt 2)
        if ($elapsedAfterPoll -ge [double]$config.maxSessionDurationSeconds -and -not $allowFollowUpApplyPoll) { break }
        if (($elapsedAfterPoll + [int]$config.pollIntervalSeconds) -gt [double]$config.maxSessionDurationSeconds -and -not $allowFollowUpApplyPoll) { break }
        Start-Sleep -Seconds ([int]$config.pollIntervalSeconds)
    }

    if ($activeRestraints.Count -gt 0) {
        $finalSample = Get-RooGovernorCpuSample -SampleIntervalMilliseconds $SampleIntervalMilliseconds -IncludeCommandLine:$IncludeCommandLine
        $finalPollIndex = $pollIndex + 1
        $finalPollStartedAtUtc = Get-RooUtcStamp
        $finalProcessByKey = @{}
        foreach ($proc in @(Get-RooPropertyArray $finalSample 'processes')) {
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
                    processId = Get-RooPropertyValue $active 'processId' 0
                    processName = Get-RooPropertyValue $active 'processName' ''
                    ruleId = Get-RooPropertyValue $active 'ruleId' ''
                    reason = 'Restrained process exited before final calm restore.'
                    pollIndex = $finalPollIndex
                    skippedAtUtc = Get-RooUtcStamp
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
                totalCpuPercent = Get-RooPropertyValue $finalSample 'totalCpuPercent' 0
                previewCount = $finalPollSkipped.Count
                wouldRestrainItems = @()
                changedItems = @()
                skippedItems = @($finalPollSkipped.ToArray())
                restoredItems = @($finalPollRestored.ToArray())
                activeRestraintCount = $activeRestraints.Count
            }
            $polls.Add($finalPoll) | Out-Null
            $logEntry = New-RooLog "Process governor final calm sample completed with $($finalPollRestored.Count) restore(s) and $($finalPollSkipped.Count) skip(s)."
            $logs.Add($logEntry) | Out-Null
            Add-RooProcessGovernorLogFileEntry $sessionDirectory $logEntry
        }
    }

    $completedAtUtc = Get-RooUtcStamp
    $sessionStatus = if ($errors.Count -gt 0) { 'failed' } else { 'completed' }
    $resultStatus = if ($errors.Count -gt 0) { 'partial' } elseif ($changed.Count -gt 0 -or $restored.Count -gt 0) { 'success' } else { 'success' }
    $backupMetadata = if (Test-Path -LiteralPath $backupPath) { New-RooProcessGovernorBackupMetadata $backupManifest $backupPath } else { $null }
    $artifacts = New-Object System.Collections.Generic.List[object]
    $artifacts.Add([pscustomobject]@{ type = 'processGovernorSessionState'; path = $sessionStatePath }) | Out-Null
    if ($backupMetadata) { $artifacts.Add([pscustomobject]@{ type = 'processGovernorSessionBackup'; path = $backupPath }) | Out-Null }
    $result = [pscustomobject]@{
        resultId = "process-governor-session-$(Get-RooFileStamp)"
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
        productName = $script:RooProcessProductName
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
        runtimeEvidence = New-RooProcessGovernorRuntimeEvidence -Session $state -StateRoot $resolvedGovernorStateRoot -SessionPath $sessionStatePath -BackupManifestPath $(if ($backupMetadata) { $backupPath } else { $null })
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
    $state.runtimeEvidence = New-RooProcessGovernorRuntimeEvidence -Session $state -StateRoot $resolvedGovernorStateRoot -SessionPath $sessionStatePath -BackupManifestPath $(if ($backupMetadata) { $backupPath } else { $null })
    $state.warnings = @($warnings.ToArray())
    $state.errors = @($errors.ToArray())
    $state.logs = @($logs.ToArray())
    Write-GovernorSessionState $state $sessionDirectory

    Write-RooJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.governor.startSession'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        correlationId = $null
        sessionId = $null
        dryRun = (-not $ConfirmApply)
        profileId = $null
        profilePath = $ProfilePath
        status = 'failed'
        sessionStatus = 'failed'
        startedAtUtc = $null
        completedAtUtc = Get-RooUtcStamp
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
        errors = @((New-RooIssue 'PROCESS_GOVERNOR_SESSION_FAILED' $_.Exception.Message 'error' 'performance.governor' $ProfilePath $true 'Review profile path, process permissions, and governor thresholds.' $null))
        logs = @((New-RooLog 'Process governor session failed.' 'error'))
    }
    Write-RooJsonOutput $errorEnvelope $OutputPath
    exit 1
}
