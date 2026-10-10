param(
    [string]$ProfilePath = '',
    [string]$TargetGameProcessName = '',
    [ValidateSet('lower', 'placement')][string]$Preset = 'lower',
    [string]$OutputPath = '',
    [string]$StateRoot = '',
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Get-LiveProcessIdentity {
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
    $actualName = $live.ProcessName
    $nameMatches = Test-RooIndustriesProcessNameEquals $actualName $expectedName
    $currentPath = $null
    try { $currentPath = $live.Path } catch { $currentPath = $null }
    $expectedPath = Get-RooIndustriesPropertyValue $PreviewEntry 'executablePath' $null
    $pathMatches = $true
    if (-not [string]::IsNullOrWhiteSpace([string]$expectedPath)) {
        $pathMatches = ([string]$expectedPath -eq [string]$currentPath)
    }
    $controlState = Get-RooIndustriesProcessControlState $processId $null
    $startMatches = Test-RooIndustriesProcessStartTime (Get-RooIndustriesPropertyValue $PreviewEntry 'processStartTimeUtc' $null) $controlState.startTimeUtc

    return [pscustomobject]@{
        exists = $true
        matches = ($nameMatches -and $pathMatches -and $startMatches)
        process = $live
        currentPriorityClass = [string]$live.PriorityClass
        currentControlState = $controlState
        currentPath = $currentPath
        reason = if (-not $startMatches) { 'This app was restarted, or its start time could not be verified. Nothing was changed.' } elseif ($nameMatches -and $pathMatches) { $null } else { 'Live process identity does not match the preview entry.' }
    }
}

function New-ApplySkippedItem {
    param(
        [object]$Entry,
        [string]$Reason,
        [object[]]$ControlChanges = @(),
        [object[]]$SkippedControls = @(),
        [string]$Category = 'skipped'
    )
    return [pscustomobject]@{
        processId = Get-RooIndustriesPropertyValue $Entry 'processId' 0
        processName = Get-RooIndustriesPropertyValue $Entry 'processName' ''
        proposedPriorityClass = Get-RooIndustriesPropertyValue $Entry 'proposedPriorityClass' $null
        proposedAffinityMask = Get-RooIndustriesPropertyValue $Entry 'proposedAffinityMask' $null
        proposedIoPriority = Get-RooIndustriesPropertyValue $Entry 'proposedIoPriority' $null
        proposedMemoryPriority = Get-RooIndustriesPropertyValue $Entry 'proposedMemoryPriority' $null
        proposedGpuPriority = Get-RooIndustriesPropertyValue $Entry 'proposedGpuPriority' $null
        controlChanges = @(Get-RooIndustriesArray $ControlChanges)
        skippedControls = @(Get-RooIndustriesArray $SkippedControls)
        category = $Category
        reason = $Reason
    }
}

function New-BackupMetadata {
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
        scope = 'process-profile-process-controls'
        createdAtUtc = [string](Get-RooIndustriesPropertyValue $BackupManifest 'createdAtUtc' '')
        location = $BackupPath
        restorePoint = [pscustomobject]@{
            requested = $false
            status = 'not-required-for-process-controls'
            id = $null
        }
        snapshots = @($snapshots.ToArray())
        rollbackActionId = 'performance.rollbackProfile'
        rollbackSupported = $true
        retentionPolicy = [pscustomobject]@{
            keepLatestCount = 10
            minimumDays = 14
        }
    }
}

try {
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\game-session.profile.json'
    $resolvedProfilePath = Resolve-RooIndustriesPath $ProfilePath $defaultProfilePath
    $profile = Read-RooIndustriesJsonFile $resolvedProfilePath

    $previewArgs = @{ ProfilePath = $resolvedProfilePath; Preset = $Preset }
    if (-not [string]::IsNullOrWhiteSpace($TargetGameProcessName)) {
        $previewArgs['TargetGameProcessName'] = $TargetGameProcessName
    }
    $previewEnvelope = & (Join-Path $PSScriptRoot 'Preview-ProcessProfile.ps1') @previewArgs | ConvertFrom-Json

    if (-not $ConfirmApply) {
        $skipped = New-Object System.Collections.Generic.List[object]
        foreach ($entry in @(Get-RooIndustriesPropertyArray $previewEnvelope 'preview')) {
            $entryChanges = @(Get-RooIndustriesPreviewControlChanges $entry)
            if ($entryChanges.Count -eq 0) { continue }
            $reason = if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false) -or [bool](Get-RooIndustriesPropertyValue $entry 'protected' $false)) {
                [string](Get-RooIndustriesPropertyValue $entry 'blockedReason' (Get-RooIndustriesPropertyValue $entry 'reason' 'Preview entry is protected or blocked.'))
            } else {
                'Dry-run apply; -ConfirmApply was not provided.'
            }
            $category = if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false) -or [bool](Get-RooIndustriesPropertyValue $entry 'protected' $false)) { 'blocked' } else { 'dry-run' }
            $skipped.Add((New-ApplySkippedItem $entry $reason $entryChanges @() $category)) | Out-Null
        }

        $result = New-RooIndustriesActionResult `
            -ResultId ("dry-run-apply-" + (Get-RooIndustriesFileStamp)) `
            -Status 'preview' `
            -Summary 'Dry-run only. No process control changes were applied.' `
            -ChangedItems @() `
            -SkippedItems @($skipped.ToArray()) `
            -Artifacts @()

        $warnings = New-Object System.Collections.Generic.List[object]
        foreach ($warning in @(Get-RooIndustriesPropertyArray $previewEnvelope 'warnings')) { $warnings.Add($warning) | Out-Null }
        $warnings.Add((New-RooIndustriesIssue 'CONFIRM_APPLY_REQUIRED' 'Apply-ProcessProfile.ps1 did not change any process because -ConfirmApply was omitted.' 'info' 'performance.profile' ([string](Get-RooIndustriesPropertyValue $profile 'profileId' '')) $false 'Review the preview, then rerun with -ConfirmApply if changes are desired.' $null)) | Out-Null

        $dryRunEnvelope = New-RooIndustriesActionEnvelope `
            -ActionId 'performance.applyProfile' `
            -DryRun $true `
            -Risk ([string](Get-RooIndustriesPropertyValue $profile 'risk' 'medium')) `
            -RequiresElevation $false `
            -Status 'preview' `
            -Preview @(Get-RooIndustriesPropertyArray $previewEnvelope 'preview') `
            -Backup $null `
            -Result $result `
            -Warnings @($warnings.ToArray()) `
            -Errors @(Get-RooIndustriesPropertyArray $previewEnvelope 'errors') `
            -Logs @((New-RooIndustriesLog 'Dry-run apply completed without changing process controls.'))

        Write-RooIndustriesJsonOutput $dryRunEnvelope $OutputPath
        exit 0
    }

    $skipped = New-Object System.Collections.Generic.List[object]
    $candidateEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-RooIndustriesPropertyArray $previewEnvelope 'preview')) {
        $entryChanges = @(Get-RooIndustriesPreviewControlChanges $entry)
        foreach ($change in @($entryChanges | Where-Object { $_.control -eq 'memoryPriority' -and $_.blocked })) {
            $skipped.Add((New-ApplySkippedItem $entry $change.blockedReason @() @($change) 'blocked')) | Out-Null
        }
        $applicablePreviewChanges = @($entryChanges | Where-Object { -not [bool](Get-RooIndustriesPropertyValue $_ 'blocked' $false) })
        $isChange = ($applicablePreviewChanges.Count -gt 0)
        $isBlocked = [bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)
        $isProtected = [bool](Get-RooIndustriesPropertyValue $entry 'protected' $false)
        if ($isChange -and -not $isBlocked -and -not $isProtected) {
            $candidateEntries.Add($entry) | Out-Null
        } elseif ($entryChanges.Count -gt 0 -and ($isBlocked -or $isProtected)) {
            $skippedReason = [string](Get-RooIndustriesPropertyValue $entry 'blockedReason' (Get-RooIndustriesPropertyValue $entry 'reason' 'Preview entry is protected or blocked.'))
            $skipped.Add((New-ApplySkippedItem $entry $skippedReason $entryChanges @() 'blocked')) | Out-Null
        }
    }

    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($candidateEntries.ToArray())) {
        $entryChanges = @(Get-RooIndustriesPreviewControlChanges $entry | Where-Object { -not [bool](Get-RooIndustriesPropertyValue $_ 'blocked' $false) })

        $identity = Get-LiveProcessIdentity $entry
        if (-not $identity.exists -or -not $identity.matches) {
            $skipped.Add((New-ApplySkippedItem $entry $identity.reason $entryChanges @() 'identity-mismatch')) | Out-Null
            continue
        }

        if ($Preset -eq 'placement' -and @(Get-RooIndustriesGovernorProcessControls $identity.process).Count -gt 0) {
            $skipped.Add((New-ApplySkippedItem $entry $script:RooIndustriesGovernorManaged $entryChanges @() 'managed')) | Out-Null
            continue
        }

        $livePlan = Get-RooIndustriesApplicableProcessControlChanges $entryChanges $identity.currentControlState
        foreach ($skippedControl in @(Get-RooIndustriesPropertyArray $livePlan 'skippedControls')) {
            $skipped.Add((New-ApplySkippedItem $entry ([string](Get-RooIndustriesPropertyValue $skippedControl 'reason' 'Process control was skipped.')) @() @($skippedControl) ([string](Get-RooIndustriesPropertyValue $skippedControl 'category' 'skipped')))) | Out-Null
        }
        $liveChanges = @(Get-RooIndustriesPropertyArray $livePlan 'changes')
        if ($liveChanges.Count -eq 0) {
            continue
        }

        $snapshots.Add([pscustomobject]@{
            processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
            processName = [string](Get-RooIndustriesPropertyValue $entry 'processName' '')
            executablePath = Get-RooIndustriesPropertyValue $entry 'executablePath' $identity.currentPath
            originalPriorityClass = Get-RooIndustriesPropertyValue $identity.currentControlState 'priorityClass' $null
            proposedPriorityClass = Get-RooIndustriesPropertyValue $entry 'proposedPriorityClass' $null
            originalAffinityMask = Get-RooIndustriesPropertyValue $identity.currentControlState 'affinityMask' $null
            proposedAffinityMask = Get-RooIndustriesPropertyValue $entry 'proposedAffinityMask' $null
            originalIoPriority = Get-RooIndustriesPropertyValue $identity.currentControlState 'ioPriority' $null
            originalMemoryPriority = Get-RooIndustriesPropertyValue $identity.currentControlState 'memoryPriority' $null
            proposedIoPriority = Get-RooIndustriesPropertyValue $entry 'proposedIoPriority' $null
            proposedMemoryPriority = Get-RooIndustriesPropertyValue $entry 'proposedMemoryPriority' $null
            originalGpuPriority = Get-RooIndustriesPropertyValue $identity.currentControlState 'gpuPriority' $null
            proposedGpuPriority = Get-RooIndustriesPropertyValue $entry 'proposedGpuPriority' $null
            controlChanges = @($liveChanges)
            processStartTimeUtc = Get-RooIndustriesPropertyValue $identity.currentControlState 'startTimeUtc' $null
            capturedAtUtc = Get-RooIndustriesUtcStamp
            profileId = [string](Get-RooIndustriesPropertyValue $profile 'profileId' '')
            ruleId = [string](Get-RooIndustriesPropertyValue $entry 'ruleId' '')
            reason = [string](Get-RooIndustriesPropertyValue $entry 'reason' '')
        }) | Out-Null
    }

    $backupMetadata = $null
    $backupPath = $null
    if ($snapshots.Count -gt 0) {
        $defaultStateRoot = Join-Path $PSScriptRoot '..\state'
        $resolvedStateRoot = Resolve-RooIndustriesPath $StateRoot $defaultStateRoot
        $backupId = "process-profile-$([string](Get-RooIndustriesPropertyValue $profile 'profileId' 'profile'))-$(Get-RooIndustriesFileStamp)"
        $backupDir = Join-Path $resolvedStateRoot (Join-Path 'process-profile-backups' $backupId)
        Ensure-RooIndustriesDirectory $backupDir
        $backupPath = Join-Path $backupDir 'backup.json'

        $backupManifest = [pscustomobject]@{
            schemaVersion = 1
            productName = $script:RooIndustriesProcessProductName
            backupId = $backupId
            createdAtUtc = Get-RooIndustriesUtcStamp
            actionId = 'performance.applyProfile'
            profileId = [string](Get-RooIndustriesPropertyValue $profile 'profileId' '')
            profilePath = $resolvedProfilePath
            dryRun = $false
            snapshots = @($snapshots.ToArray())
        }
        Write-RooIndustriesOperationJson $backupManifest $backupPath
        $backupMetadata = New-BackupMetadata $backupManifest $backupPath
    }

    $changed = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @($snapshots.ToArray())) {
        $identity = Get-LiveProcessIdentity $snapshot
        if (-not $identity.exists -or -not $identity.matches) {
            $skipped.Add((New-ApplySkippedItem $snapshot $identity.reason @(Get-RooIndustriesPropertyArray $snapshot 'controlChanges') @() 'identity-mismatch')) | Out-Null
            continue
        }
        $live = $identity.process
        if ($Preset -eq 'placement' -and @(Get-RooIndustriesGovernorProcessControls $live).Count -gt 0) {
            $skipped.Add((New-ApplySkippedItem $snapshot $script:RooIndustriesGovernorManaged @(Get-RooIndustriesPropertyArray $snapshot 'controlChanges') @() 'managed')) | Out-Null
            continue
        }

        $controlChanges = @(Get-RooIndustriesPropertyArray $snapshot 'controlChanges')
        $appliedControls = New-Object System.Collections.Generic.List[object]
        $failedControls = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($change in $controlChanges) {
                try {
                    Invoke-RooIndustriesProcessControlChange $live $change
                    $appliedControls.Add($change) | Out-Null
                } catch {
                    $failedControls.Add("$([string](Get-RooIndustriesPropertyValue $change 'control' 'unknown')): $($_.Exception.Message)") | Out-Null
                } finally {
                    Write-RooIndustriesOperationJson $backupManifest $backupPath
                }
            }
            $afterControls = Get-RooIndustriesProcessControlState ([int](Get-RooIndustriesPropertyValue $snapshot 'processId' 0)) $null
            if ($appliedControls.Count -gt 0) {
                $changed.Add([pscustomobject]@{
                    processId = Get-RooIndustriesPropertyValue $snapshot 'processId' 0
                    processName = Get-RooIndustriesPropertyValue $snapshot 'processName' ''
                    originalPriorityClass = Get-RooIndustriesPropertyValue $snapshot 'originalPriorityClass' $null
                    appliedPriorityClass = $afterControls.priorityClass
                    originalAffinityMask = Get-RooIndustriesPropertyValue $snapshot 'originalAffinityMask' $null
                    appliedAffinityMask = $afterControls.affinityMask
                    originalIoPriority = Get-RooIndustriesPropertyValue $snapshot 'originalIoPriority' $null
                    originalMemoryPriority = Get-RooIndustriesPropertyValue $snapshot 'originalMemoryPriority' $null
                    appliedIoPriority = $afterControls.ioPriority
                    appliedMemoryPriority = $afterControls.memoryPriority
                    originalGpuPriority = Get-RooIndustriesPropertyValue $snapshot 'originalGpuPriority' $null
                    appliedGpuPriority = $afterControls.gpuPriority
                    appliedControls = @($appliedControls.ToArray())
                    ruleId = Get-RooIndustriesPropertyValue $snapshot 'ruleId' ''
                }) | Out-Null
            }
            if ($failedControls.Count -gt 0) {
                $skipped.Add((New-ApplySkippedItem $snapshot ($failedControls -join '; ') $controlChanges @() 'apply-failed')) | Out-Null
            }
        } catch {
            $skipped.Add((New-ApplySkippedItem $snapshot $_.Exception.Message $controlChanges @() 'apply-failed')) | Out-Null
        }
    }

    $status = 'success'
    $nonNoopSkipped = @($skipped.ToArray() | Where-Object { [string](Get-RooIndustriesPropertyValue $_ 'category' '') -ne 'no-change' })
    if ($changed.Count -eq 0 -and ($candidateEntries.Count -gt 0 -or $nonNoopSkipped.Count -gt 0)) { $status = if ($nonNoopSkipped.Count -eq 0) { 'success' } else { 'failed' } }
    if ($changed.Count -gt 0 -and $nonNoopSkipped.Count -gt 0) { $status = 'partial' }

    $result = New-RooIndustriesActionResult `
        -ResultId ("apply-" + (Get-RooIndustriesFileStamp)) `
        -Status $status `
        -Summary "Confirmed apply completed with $($changed.Count) process control change item(s) and $($skipped.Count) skipped item(s)." `
        -ChangedItems @($changed.ToArray()) `
        -SkippedItems @($skipped.ToArray()) `
        -Artifacts $(if ($backupPath) { @([pscustomobject]@{ type = 'processProfileBackup'; path = $backupPath }) } else { @() })

    $applyEnvelope = New-RooIndustriesActionEnvelope `
        -ActionId 'performance.applyProfile' `
        -DryRun $false `
        -Risk ([string](Get-RooIndustriesPropertyValue $profile 'risk' 'medium')) `
        -RequiresElevation $false `
        -Status $status `
        -Preview @(Get-RooIndustriesPropertyArray $previewEnvelope 'preview') `
        -Backup $backupMetadata `
        -Result $result `
        -Warnings @(Get-RooIndustriesPropertyArray $previewEnvelope 'warnings') `
        -Errors @(Get-RooIndustriesPropertyArray $previewEnvelope 'errors') `
        -Logs @((New-RooIndustriesLog "Confirmed apply finished with status $status."))

    Write-RooIndustriesJsonOutput $applyEnvelope $OutputPath
} catch {
    $envelope = New-RooIndustriesActionEnvelope `
        -ActionId 'performance.applyProfile' `
        -DryRun (-not $ConfirmApply) `
        -Risk 'medium' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIndustriesIssue 'PROCESS_PROFILE_APPLY_FAILED' $_.Exception.Message 'error' 'performance.profile' $ProfilePath $true 'Review the profile path and permissions, then retry.' $null)) `
        -Logs @((New-RooIndustriesLog 'Apply failed.' 'error'))
    Write-RooIndustriesJsonOutput $envelope $OutputPath
    exit 1
}
