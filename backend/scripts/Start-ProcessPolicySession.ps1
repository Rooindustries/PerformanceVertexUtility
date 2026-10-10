param(
    [string]$ProfilePath = '',
    [int]$PollIntervalSeconds = 0,
    [int]$MaxDurationSeconds = 0,
    [string]$OutputPath = '',
    [string]$StateRoot = '',
    [switch]$ConfirmApply,
    [switch]$IncludeCommandLine
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessPolicy.Common.ps1')
. (Join-Path $PSScriptRoot 'ProcessPolicyRules.Common.ps1')

function Write-PolicySessionState {
    param(
        [object]$State,
        [string]$SessionDirectory
    )
    if ([string]::IsNullOrWhiteSpace($SessionDirectory)) { return }
    Write-RooIndustriesProcessPolicyJsonFile $State (Join-Path $SessionDirectory 'session.json')
}

try {
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\persistent-policy.profile.json'
    $resolvedProfilePath = Resolve-RooIndustriesPath $ProfilePath $defaultProfilePath
    $profile = Read-RooIndustriesJsonFile $resolvedProfilePath
    $profileId = [string](Get-RooIndustriesPropertyValue $profile 'profileId' 'persistent-policy')
    $protectedCatalogPath = Resolve-RooIndustriesProcessPolicyProtectedCatalog $profile $resolvedProfilePath
    $protectedCatalog = Read-RooIndustriesJsonFile $protectedCatalogPath
    $config = Get-RooIndustriesProcessPolicyConfig $profile $MaxDurationSeconds $PollIntervalSeconds
    $startedAtUtc = Get-RooIndustriesUtcStamp

    if (-not $ConfirmApply) {
        $previewState = Get-RooIndustriesProcessPolicyPreview `
            -Profile $profile `
            -ProfilePath $resolvedProfilePath `
            -ProtectedCatalog $protectedCatalog `
            -IncludeCommandLine:$IncludeCommandLine
        $wouldApply = @(@(Get-RooIndustriesPropertyArray $previewState 'preview') | Where-Object { $_.requiresConfirmation -eq $true })
        $blocked = @(@(Get-RooIndustriesPropertyArray $previewState 'preview') | Where-Object { $_.blocked -eq $true })
        $poll = [pscustomobject]@{
            pollIndex = 1
            capturedAtUtc = Get-RooIndustriesUtcStamp
            previewCount = @(Get-RooIndustriesPropertyArray $previewState 'preview').Count
            wouldApplyItems = @($wouldApply)
            changedItems = @()
            skippedItems = @($blocked)
            noOpItems = @(@(Get-RooIndustriesPropertyArray $previewState 'preview') | Where-Object { $_.proposedAction -eq 'noChange' -and $_.blocked -ne $true })
            activeApplicationCount = 0
        }
        $warning = New-RooIndustriesIssue 'PROCESS_POLICY_DRY_RUN' 'Persistent policy session ran in dry-run mode. No process changes were applied.' 'info' 'performance.policy' $profileId $false 'Rerun with -ConfirmApply only after reviewing policy preview and safety gates.' $null
        $result = [pscustomobject]@{
            resultId = "process-policy-session-$(Get-RooIndustriesFileStamp)"
            status = 'preview'
            startedAtUtc = $startedAtUtc
            completedAtUtc = Get-RooIndustriesUtcStamp
            summary = "Persistent policy dry-run completed with $($wouldApply.Count) apply candidate(s)."
            changedItems = @()
            skippedItems = @()
            restoredItems = @()
            artifacts = @()
        }
        $envelope = [pscustomobject]@{
            actionId = 'performance.policy.startSession'
            schemaVersion = 1
            productName = $script:RooIndustriesProcessProductName
            correlationId = $null
            sessionId = $null
            dryRun = $true
            profileId = $profileId
            profilePath = $resolvedProfilePath
            protectedCatalogPath = $protectedCatalogPath
            status = 'completed'
            sessionStatus = 'completed'
            startedAtUtc = $startedAtUtc
            completedAtUtc = Get-RooIndustriesUtcStamp
            pollIntervalSeconds = [int]$config.pollIntervalSeconds
            maxDurationSeconds = [int]$config.maxSessionDurationSeconds
            pollCount = 1
            stateRoot = $null
            sessionPath = $null
            backupManifestPath = $null
            restorable = $false
            activeApplications = @()
            changedItems = @()
            skippedItems = @()
            restoredItems = @()
            polls = @($poll)
            backup = $null
            result = $result
            policy = $config
            warnings = @($warning)
            errors = @()
            logs = @((New-RooIndustriesLog 'Persistent policy dry-run completed without live changes.'))
        }
        Write-RooIndustriesJsonOutput $envelope $OutputPath
        exit 0
    }

    $sessionId = New-RooIndustriesProcessPolicySessionId $profileId
    $resolvedPolicyStateRoot = Resolve-RooIndustriesProcessPolicyStateRoot $StateRoot
    $sessionDirectory = Get-RooIndustriesProcessPolicySessionDirectory $resolvedPolicyStateRoot $sessionId
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
    $auditRows = New-Object System.Collections.Generic.List[object]
    $snapshots = New-Object System.Collections.Generic.List[object]
    $snapshotKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $skipKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $exitSkipKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $activeApplications = @{}

    $backupManifest = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        backupId = "process-policy-$profileId-$(Get-RooIndustriesFileStamp)"
        sessionId = $sessionId
        createdAtUtc = $startedAtUtc
        actionId = 'performance.policy.startSession'
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
        maxDurationSeconds = [int]$config.maxSessionDurationSeconds
        pollCount = 0
        stateRoot = $resolvedPolicyStateRoot
        sessionPath = $sessionStatePath
        backupManifestPath = $null
        restorable = $false
        activeApplications = @()
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        policy = $config
        warnings = @()
        errors = @()
        logs = @()
    }
    Write-PolicySessionState $state $sessionDirectory
    Add-RooIndustriesProcessPolicyLogFileEntry $sessionDirectory (New-RooIndustriesLog 'Confirmed persistent policy session state initialized.')

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollIndex = 0
    while ($true) {
        $pollIndex++
        $pollStartedAtUtc = Get-RooIndustriesUtcStamp
        $previewState = Get-RooIndustriesProcessPolicyPreview `
            -Profile $profile `
            -ProfilePath $resolvedProfilePath `
            -ProtectedCatalog $protectedCatalog `
            -IncludeCommandLine:$IncludeCommandLine
        $pollWouldApply = New-Object System.Collections.Generic.List[object]
        $pollChanged = New-Object System.Collections.Generic.List[object]
        $pollSkipped = New-Object System.Collections.Generic.List[object]
        $pollNoOp = New-Object System.Collections.Generic.List[object]
        $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'

        $gate = Enter-RooIndustriesGovernorGate
        if ($null -eq $gate) {
            $warnings.Add((New-RooIndustriesIssue 'PROCESS_POLICY_GOVERNOR_BUSY' 'A rule change kept the governor busy, so this poll changed nothing.' 'warning' 'performance.policy' $sessionId $false 'The next poll tries again.')) | Out-Null
            if ($stopwatch.Elapsed.TotalSeconds -ge [double]$config.maxSessionDurationSeconds) { break }
            Start-Sleep -Seconds ([int]$config.pollIntervalSeconds)
            continue
        }
        try {
            foreach ($entry in @(Get-RooIndustriesPropertyArray $previewState 'preview')) {
                $entryKey = Get-RooIndustriesProcessPolicyEntryKey $entry
                $seenKeys.Add($entryKey) | Out-Null
                if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
                    $skipKey = "$entryKey|blocked"
                    if (-not $skipKeys.Contains($skipKey)) {
                        $skip = New-RooIndustriesProcessPolicySkippedItem $entry (Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Process is protected from persistent policy control.') $pollIndex
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                        $skipKeys.Add($skipKey) | Out-Null
                        $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'sessionApply' -RuleId ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')) -SessionId $sessionId -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string](Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Process is protected from persistent policy control.')) -ProtectionCategory ([string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'category' 'unknown')) -Outcome 'skipped' -DryRun $false -Source 'processPolicySession')) | Out-Null
                    }
                    continue
                }

                $entryChanges = @(Get-RooIndustriesPreviewControlChanges $entry)
                if ($entryChanges.Count -eq 0) {
                    $pollNoOp.Add($entry) | Out-Null
                    continue
                }
                $pollWouldApply.Add($entry) | Out-Null

                $rule = Get-RooIndustriesProcessPolicyRuleById $profile ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' ''))
                $safety = Test-RooIndustriesProcessPolicyConfirmedAllowed $entry $rule $profile
                if (-not $safety.allowed) {
                    $skipKey = "$entryKey|safety|$($safety.reason)"
                    if (-not $skipKeys.Contains($skipKey)) {
                        $skip = New-RooIndustriesProcessPolicySkippedItem $entry ([string]$safety.reason) $pollIndex
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                        $skipKeys.Add($skipKey) | Out-Null
                        $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'sessionApply' -RuleId ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')) -SessionId $sessionId -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string]$safety.reason) -ProtectionCategory ([string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'category' 'unknown')) -Outcome 'skipped' -DryRun $false -Source 'processPolicySession')) | Out-Null
                    }
                    continue
                }

                $identity = Get-RooIndustriesProcessPolicyLiveIdentity $entry
                if (-not $identity.exists -or -not $identity.matches) {
                    $skipKey = "$entryKey|identity|$($identity.reason)"
                    if (-not $skipKeys.Contains($skipKey)) {
                        $skip = New-RooIndustriesProcessPolicySkippedItem $entry $identity.reason $pollIndex
                        $skipped.Add($skip) | Out-Null
                        $pollSkipped.Add($skip) | Out-Null
                        $skipKeys.Add($skipKey) | Out-Null
                        $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'sessionApply' -RuleId ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')) -SessionId $sessionId -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string]$identity.reason) -ProtectionCategory ([string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'category' 'unknown')) -Outcome 'skipped' -DryRun $false -Source 'processPolicySession')) | Out-Null
                    }
                    continue
                }

                $processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
                $processName = [string](Get-RooIndustriesPropertyValue $entry 'processName' '')
                $originalState = Get-RooIndustriesProcessControlState $processId $null
                $snapshot = [pscustomobject]@{
                    processId = $processId
                    processName = $processName
                    executablePath = Get-RooIndustriesPropertyValue $entry 'executablePath' $identity.currentPath
                    startTimeUtc = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'startTimeUtc' $null
                    originalPriorityClass = $originalState.priorityClass
                    proposedPriorityClass = Get-RooIndustriesPropertyValue $entry 'proposedPriorityClass' $null
                    originalAffinityMask = $originalState.affinityMask
                    proposedAffinityMask = Get-RooIndustriesPropertyValue $entry 'proposedAffinityMask' $null
                    originalIoPriority = $originalState.ioPriority
                    proposedIoPriority = Get-RooIndustriesPropertyValue $entry 'proposedIoPriority' $null
                    originalGpuPriority = $originalState.gpuPriority
                    proposedGpuPriority = Get-RooIndustriesPropertyValue $entry 'proposedGpuPriority' $null
                    controlChanges = @($entryChanges)
                    capturedAtUtc = Get-RooIndustriesUtcStamp
                    profileId = $profileId
                    ruleId = [string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')
                    reason = [string](Get-RooIndustriesPropertyValue $entry 'reason' '')
                    sessionId = $sessionId
                }
                if (-not $snapshotKeys.Contains($entryKey)) {
                    $snapshots.Add($snapshot) | Out-Null
                    $snapshotKeys.Add($entryKey) | Out-Null
                }
                $backupManifest.snapshots = @($snapshots.ToArray())
                Write-RooIndustriesProcessPolicyJsonFile $backupManifest $backupPath
                $state.backupManifestPath = $backupPath
                $state.restorable = ($activeApplications.Count -gt 0 -or $snapshots.Count -gt 0)
                Write-PolicySessionState $state $sessionDirectory

                $appliedControls = New-Object System.Collections.Generic.List[object]
                $failedControls = New-Object System.Collections.Generic.List[string]
                foreach ($change in $entryChanges) {
                    try {
                        Invoke-RooIndustriesProcessControlChange $identity.process $change
                        $appliedControls.Add($change) | Out-Null
                    } catch {
                        $failedControls.Add("$([string](Get-RooIndustriesPropertyValue $change 'control' 'unknown')): $($_.Exception.Message)") | Out-Null
                    }
                }

                if ($appliedControls.Count -gt 0) {
                    $appliedState = Get-RooIndustriesProcessControlState $processId $null
                    $changedItem = New-RooIndustriesProcessPolicyChangedItem $entry $originalState $appliedState @($appliedControls.ToArray()) $pollIndex
                    $changed.Add($changedItem) | Out-Null
                    $pollChanged.Add($changedItem) | Out-Null
                    foreach ($appliedControl in @($appliedControls.ToArray())) {
                        $controlName = [string](Get-RooIndustriesPropertyValue $appliedControl 'control' 'processControls')
                        $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'sessionApply' -RuleId ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')) -SessionId $sessionId -Target $entry -Control $controlName -BeforeValue (Get-RooIndustriesPropertyValue $appliedControl 'currentValue' $null) -AfterValue (Get-RooIndustriesPropertyValue $appliedControl 'proposedValue' $null) -Reason ([string](Get-RooIndustriesPropertyValue $appliedControl 'reason' (Get-RooIndustriesPropertyValue $entry 'reason' 'Apply process controls.'))) -ProtectionCategory ([string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'category' 'unknown')) -RestorePath $backupPath -RestoreAvailable $true -Outcome 'applied' -DryRun $false -Source 'processPolicySession')) | Out-Null
                    }
                    $activeApplications[$entryKey] = [pscustomobject]@{
                        processId = $processId
                        processName = $processName
                        executablePath = Get-RooIndustriesPropertyValue $entry 'executablePath' $null
                        startTimeUtc = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'startTimeUtc' $null
                        ruleId = Get-RooIndustriesPropertyValue $entry 'ruleId' ''
                        appliedAtUtc = Get-RooIndustriesUtcStamp
                        snapshot = $snapshot
                    }
                }
                if ($failedControls.Count -gt 0) {
                    $skip = New-RooIndustriesProcessPolicySkippedItem $entry ($failedControls -join '; ') $pollIndex
                    $skipped.Add($skip) | Out-Null
                    $pollSkipped.Add($skip) | Out-Null
                    $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'sessionApply' -RuleId ([string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')) -SessionId $sessionId -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ($failedControls -join '; ') -ProtectionCategory ([string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'category' 'unknown')) -RestorePath $backupPath -RestoreAvailable $true -Outcome 'failed' -DryRun $false -Source 'processPolicySession')) | Out-Null
                }
            }
        } finally {
            Exit-RooIndustriesGovernorGate $gate
        }

        foreach ($activeKey in @($activeApplications.Keys)) {
            if (-not $seenKeys.Contains([string]$activeKey)) {
                $active = $activeApplications[$activeKey]
                if (-not $exitSkipKeys.Contains([string]$activeKey)) {
                    $skip = [pscustomobject]@{
                        processId = Get-RooIndustriesPropertyValue $active 'processId' 0
                        processName = Get-RooIndustriesPropertyValue $active 'processName' ''
                        executablePath = Get-RooIndustriesPropertyValue $active 'executablePath' $null
                        ruleId = Get-RooIndustriesPropertyValue $active 'ruleId' ''
                        reason = 'Policy-controlled process exited before restore.'
                        pollIndex = $pollIndex
                        skippedAtUtc = Get-RooIndustriesUtcStamp
                    }
                    $skipped.Add($skip) | Out-Null
                    $pollSkipped.Add($skip) | Out-Null
                    $exitSkipKeys.Add([string]$activeKey) | Out-Null
                }
                $activeApplications.Remove($activeKey)
            }
        }

        $poll = [pscustomobject]@{
            pollIndex = $pollIndex
            capturedAtUtc = $pollStartedAtUtc
            previewCount = @(Get-RooIndustriesPropertyArray $previewState 'preview').Count
            wouldApplyItems = @($pollWouldApply.ToArray())
            changedItems = @($pollChanged.ToArray())
            skippedItems = @($pollSkipped.ToArray())
            noOpItems = @($pollNoOp.ToArray())
            activeApplicationCount = $activeApplications.Count
        }
        $polls.Add($poll) | Out-Null
        $logEntry = New-RooIndustriesLog "Persistent policy poll $pollIndex completed with $($pollChanged.Count) application(s), $($pollSkipped.Count) skip(s), and $($pollNoOp.Count) no-op match(es)."
        $logs.Add($logEntry) | Out-Null
        Add-RooIndustriesProcessPolicyLogFileEntry $sessionDirectory $logEntry

        $state.pollCount = $pollIndex
        $state.changedItems = @($changed.ToArray())
        $state.skippedItems = @($skipped.ToArray())
        $state.restoredItems = @($restored.ToArray())
        $state.activeApplications = @($activeApplications.Values | ForEach-Object { $_ })
        $state.restorable = ($activeApplications.Count -gt 0)
        $state.warnings = @($warnings.ToArray())
        $state.errors = @($errors.ToArray())
        $state.logs = @($logs.ToArray())
        Write-PolicySessionState $state $sessionDirectory

        if ($stopwatch.Elapsed.TotalSeconds -ge [double]$config.maxSessionDurationSeconds) { break }
        if (($stopwatch.Elapsed.TotalSeconds + [int]$config.pollIntervalSeconds) -gt [double]$config.maxSessionDurationSeconds) { break }
        Start-Sleep -Seconds ([int]$config.pollIntervalSeconds)
    }

    $completedAtUtc = Get-RooIndustriesUtcStamp
    $auditPath = Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows @($auditRows.ToArray())
    $sessionStatus = if ($errors.Count -gt 0) { 'failed' } else { 'completed' }
    $resultStatus = if ($errors.Count -gt 0) { 'partial' } else { 'success' }
    $backupMetadata = if (Test-Path -LiteralPath $backupPath) { New-RooIndustriesProcessPolicyBackupMetadata $backupManifest $backupPath } else { $null }
    $artifacts = New-Object System.Collections.Generic.List[object]
    $artifacts.Add([pscustomobject]@{ type = 'processPolicySessionState'; path = $sessionStatePath }) | Out-Null
    if ($backupMetadata) { $artifacts.Add([pscustomobject]@{ type = 'processPolicySessionBackup'; path = $backupPath }) | Out-Null }
    $result = [pscustomobject]@{
        resultId = "process-policy-session-$(Get-RooIndustriesFileStamp)"
        status = $resultStatus
        startedAtUtc = $startedAtUtc
        completedAtUtc = $completedAtUtc
        summary = "Persistent policy session completed after $pollIndex poll(s) with $($changed.Count) application(s), $($skipped.Count) skip(s), and $($activeApplications.Count) active application(s)."
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        artifacts = @($artifacts.ToArray())
    }
    $envelope = [pscustomobject]@{
        actionId = 'performance.policy.startSession'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        correlationId = $sessionId
        sessionId = $sessionId
        dryRun = $false
        profileId = $profileId
        profilePath = $resolvedProfilePath
        protectedCatalogPath = $protectedCatalogPath
        status = $sessionStatus
        sessionStatus = $sessionStatus
        startedAtUtc = $startedAtUtc
        completedAtUtc = $completedAtUtc
        pollIntervalSeconds = [int]$config.pollIntervalSeconds
        maxDurationSeconds = [int]$config.maxSessionDurationSeconds
        pollCount = $pollIndex
        stateRoot = $resolvedPolicyStateRoot
        sessionPath = $sessionStatePath
        backupManifestPath = if ($backupMetadata) { $backupPath } else { $null }
        auditPath = $auditPath
        restorable = ($activeApplications.Count -gt 0)
        activeApplications = @($activeApplications.Values | ForEach-Object { $_ })
        changedItems = @($changed.ToArray())
        skippedItems = @($skipped.ToArray())
        restoredItems = @($restored.ToArray())
        polls = @($polls.ToArray())
        backup = $backupMetadata
        result = $result
        policy = $config
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
    $state.activeApplications = @($activeApplications.Values | ForEach-Object { $_ })
    $state.restorable = ($activeApplications.Count -gt 0)
    $state.backupManifestPath = if ($backupMetadata) { $backupPath } else { $null }
    $state.warnings = @($warnings.ToArray())
    $state.errors = @($errors.ToArray())
    $state.logs = @($logs.ToArray())
    Write-PolicySessionState $state $sessionDirectory

    Write-RooIndustriesJsonOutput $envelope $OutputPath
} catch {
    $errorEnvelope = [pscustomobject]@{
        actionId = 'performance.policy.startSession'
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
        maxDurationSeconds = $MaxDurationSeconds
        pollCount = 0
        stateRoot = $null
        sessionPath = $null
        backupManifestPath = $null
        restorable = $false
        activeApplications = @()
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        polls = @()
        backup = $null
        result = $null
        policy = $null
        warnings = @()
        errors = @((New-RooIndustriesIssue 'PROCESS_POLICY_SESSION_FAILED' $_.Exception.Message 'error' 'performance.policy' $ProfilePath $true 'Review policy profile path, process permissions, and safety gates.' $null))
        logs = @((New-RooIndustriesLog 'Persistent policy session failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorEnvelope $OutputPath
    exit 1
}
