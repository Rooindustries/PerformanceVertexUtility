param(
    [string]$ProfilePath = '',
    [string]$TargetGameProcessName = '',
    [string]$OutputPath = '',
    [string]$StateRoot = '',
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Get-LiveProcessIdentity {
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
    $actualName = $live.ProcessName
    $nameMatches = Test-RooProcessNameEquals $actualName $expectedName
    $currentPath = $null
    try { $currentPath = $live.Path } catch { $currentPath = $null }
    $expectedPath = Get-RooPropertyValue $PreviewEntry 'executablePath' $null
    $pathMatches = $true
    if (-not [string]::IsNullOrWhiteSpace([string]$expectedPath) -and -not [string]::IsNullOrWhiteSpace([string]$currentPath)) {
        $pathMatches = ([string]$expectedPath -eq [string]$currentPath)
    }

    return [pscustomobject]@{
        exists = $true
        matches = ($nameMatches -and $pathMatches)
        process = $live
        currentPriorityClass = [string]$live.PriorityClass
        currentControlState = Get-RooProcessControlState $processId $null
        currentPath = $currentPath
        reason = if ($nameMatches -and $pathMatches) { $null } else { 'Live process identity does not match the preview entry.' }
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
        processId = Get-RooPropertyValue $Entry 'processId' 0
        processName = Get-RooPropertyValue $Entry 'processName' ''
        proposedPriorityClass = Get-RooPropertyValue $Entry 'proposedPriorityClass' $null
        proposedAffinityMask = Get-RooPropertyValue $Entry 'proposedAffinityMask' $null
        proposedIoPriority = Get-RooPropertyValue $Entry 'proposedIoPriority' $null
        proposedGpuPriority = Get-RooPropertyValue $Entry 'proposedGpuPriority' $null
        controlChanges = @(Get-RooArray $ControlChanges)
        skippedControls = @(Get-RooArray $SkippedControls)
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
        scope = 'process-profile-process-controls'
        createdAtUtc = [string](Get-RooPropertyValue $BackupManifest 'createdAtUtc' '')
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
    $resolvedProfilePath = Resolve-RooPath $ProfilePath $defaultProfilePath
    $profile = Read-RooJsonFile $resolvedProfilePath

    $previewArgs = @{ ProfilePath = $resolvedProfilePath }
    if (-not [string]::IsNullOrWhiteSpace($TargetGameProcessName)) {
        $previewArgs['TargetGameProcessName'] = $TargetGameProcessName
    }
    $previewEnvelope = & (Join-Path $PSScriptRoot 'Preview-ProcessProfile.ps1') @previewArgs | ConvertFrom-Json

    if (-not $ConfirmApply) {
        $skipped = New-Object System.Collections.Generic.List[object]
        foreach ($entry in @(Get-RooPropertyArray $previewEnvelope 'preview')) {
            $entryChanges = @(Get-RooPreviewControlChanges $entry)
            if ($entryChanges.Count -eq 0) { continue }
            $reason = if ([bool](Get-RooPropertyValue $entry 'blocked' $false) -or [bool](Get-RooPropertyValue $entry 'protected' $false)) {
                [string](Get-RooPropertyValue $entry 'blockedReason' (Get-RooPropertyValue $entry 'reason' 'Preview entry is protected or blocked.'))
            } else {
                'Dry-run apply; -ConfirmApply was not provided.'
            }
            $category = if ([bool](Get-RooPropertyValue $entry 'blocked' $false) -or [bool](Get-RooPropertyValue $entry 'protected' $false)) { 'blocked' } else { 'dry-run' }
            $skipped.Add((New-ApplySkippedItem $entry $reason $entryChanges @() $category)) | Out-Null
        }

        $result = New-RooActionResult `
            -ResultId ("dry-run-apply-" + (Get-RooFileStamp)) `
            -Status 'preview' `
            -Summary 'Dry-run only. No process control changes were applied.' `
            -ChangedItems @() `
            -SkippedItems @($skipped.ToArray()) `
            -Artifacts @()

        $warnings = New-Object System.Collections.Generic.List[object]
        foreach ($warning in @(Get-RooPropertyArray $previewEnvelope 'warnings')) { $warnings.Add($warning) | Out-Null }
        $warnings.Add((New-RooIssue 'CONFIRM_APPLY_REQUIRED' 'Apply-ProcessProfile.ps1 did not change any process because -ConfirmApply was omitted.' 'info' 'performance.profile' ([string](Get-RooPropertyValue $profile 'profileId' '')) $false 'Review the preview, then rerun with -ConfirmApply if changes are desired.' $null)) | Out-Null

        $dryRunEnvelope = New-RooActionEnvelope `
            -ActionId 'performance.applyProfile' `
            -DryRun $true `
            -Risk ([string](Get-RooPropertyValue $profile 'risk' 'medium')) `
            -RequiresElevation $false `
            -Status 'preview' `
            -Preview @(Get-RooPropertyArray $previewEnvelope 'preview') `
            -Backup $null `
            -Result $result `
            -Warnings @($warnings.ToArray()) `
            -Errors @(Get-RooPropertyArray $previewEnvelope 'errors') `
            -Logs @((New-RooLog 'Dry-run apply completed without changing process controls.'))

        Write-RooJsonOutput $dryRunEnvelope $OutputPath
        exit 0
    }

    $skipped = New-Object System.Collections.Generic.List[object]
    $candidateEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-RooPropertyArray $previewEnvelope 'preview')) {
        $entryChanges = @(Get-RooPreviewControlChanges $entry)
        $applicablePreviewChanges = @($entryChanges | Where-Object { -not [bool](Get-RooPropertyValue $_ 'blocked' $false) })
        $isChange = ($applicablePreviewChanges.Count -gt 0)
        $isBlocked = [bool](Get-RooPropertyValue $entry 'blocked' $false)
        $isProtected = [bool](Get-RooPropertyValue $entry 'protected' $false)
        if ($isChange -and -not $isBlocked -and -not $isProtected) {
            $candidateEntries.Add($entry) | Out-Null
        } elseif ($entryChanges.Count -gt 0 -and ($isBlocked -or $isProtected)) {
            $skippedReason = [string](Get-RooPropertyValue $entry 'blockedReason' (Get-RooPropertyValue $entry 'reason' 'Preview entry is protected or blocked.'))
            $skipped.Add((New-ApplySkippedItem $entry $skippedReason $entryChanges @() 'blocked')) | Out-Null
        }
    }

    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($candidateEntries.ToArray())) {
        $entryChanges = @(Get-RooPreviewControlChanges $entry | Where-Object { -not [bool](Get-RooPropertyValue $_ 'blocked' $false) })

        $identity = Get-LiveProcessIdentity $entry
        if (-not $identity.exists -or -not $identity.matches) {
            $skipped.Add((New-ApplySkippedItem $entry $identity.reason $entryChanges @() 'identity-mismatch')) | Out-Null
            continue
        }

        $livePlan = Get-RooApplicableProcessControlChanges $entryChanges $identity.currentControlState
        foreach ($skippedControl in @(Get-RooPropertyArray $livePlan 'skippedControls')) {
            $skipped.Add((New-ApplySkippedItem $entry ([string](Get-RooPropertyValue $skippedControl 'reason' 'Process control was skipped.')) @() @($skippedControl) ([string](Get-RooPropertyValue $skippedControl 'category' 'skipped')))) | Out-Null
        }
        $liveChanges = @(Get-RooPropertyArray $livePlan 'changes')
        if ($liveChanges.Count -eq 0) {
            continue
        }

        $snapshots.Add([pscustomobject]@{
            processId = [int](Get-RooPropertyValue $entry 'processId' 0)
            processName = [string](Get-RooPropertyValue $entry 'processName' '')
            executablePath = Get-RooPropertyValue $entry 'executablePath' $identity.currentPath
            originalPriorityClass = Get-RooPropertyValue $identity.currentControlState 'priorityClass' $null
            proposedPriorityClass = Get-RooPropertyValue $entry 'proposedPriorityClass' $null
            originalAffinityMask = Get-RooPropertyValue $identity.currentControlState 'affinityMask' $null
            proposedAffinityMask = Get-RooPropertyValue $entry 'proposedAffinityMask' $null
            originalIoPriority = Get-RooPropertyValue $identity.currentControlState 'ioPriority' $null
            proposedIoPriority = Get-RooPropertyValue $entry 'proposedIoPriority' $null
            originalGpuPriority = Get-RooPropertyValue $identity.currentControlState 'gpuPriority' $null
            proposedGpuPriority = Get-RooPropertyValue $entry 'proposedGpuPriority' $null
            controlChanges = @($liveChanges)
            processStartTimeUtc = Get-RooPropertyValue $identity.currentControlState 'startTimeUtc' $null
            capturedAtUtc = Get-RooUtcStamp
            profileId = [string](Get-RooPropertyValue $profile 'profileId' '')
            ruleId = [string](Get-RooPropertyValue $entry 'ruleId' '')
            reason = [string](Get-RooPropertyValue $entry 'reason' '')
        }) | Out-Null
    }

    $backupMetadata = $null
    $backupPath = $null
    if ($snapshots.Count -gt 0) {
        $defaultStateRoot = Join-Path $PSScriptRoot '..\state'
        $resolvedStateRoot = Resolve-RooPath $StateRoot $defaultStateRoot
        $backupId = "process-profile-$([string](Get-RooPropertyValue $profile 'profileId' 'profile'))-$(Get-RooFileStamp)"
        $backupDir = Join-Path $resolvedStateRoot (Join-Path 'process-profile-backups' $backupId)
        Ensure-RooDirectory $backupDir
        $backupPath = Join-Path $backupDir 'backup.json'

        $backupManifest = [pscustomobject]@{
            schemaVersion = 1
            productName = $script:RooProcessProductName
            backupId = $backupId
            createdAtUtc = Get-RooUtcStamp
            actionId = 'performance.applyProfile'
            profileId = [string](Get-RooPropertyValue $profile 'profileId' '')
            profilePath = $resolvedProfilePath
            dryRun = $false
            snapshots = @($snapshots.ToArray())
        }
        ($backupManifest | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $backupPath -Encoding UTF8
        $backupMetadata = New-BackupMetadata $backupManifest $backupPath
    }

    $changed = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @($snapshots.ToArray())) {
        $live = Get-Process -Id ([int](Get-RooPropertyValue $snapshot 'processId' 0)) -ErrorAction SilentlyContinue
        if ($null -eq $live) {
            $skipped.Add((New-ApplySkippedItem $snapshot 'Process exited before apply.' @(Get-RooPropertyArray $snapshot 'controlChanges') @() 'exited')) | Out-Null
            continue
        }
        if (-not (Test-RooProcessNameEquals $live.ProcessName ([string](Get-RooPropertyValue $snapshot 'processName' '')))) {
            $skipped.Add((New-ApplySkippedItem $snapshot 'Process identity changed before apply.' @(Get-RooPropertyArray $snapshot 'controlChanges') @() 'identity-mismatch')) | Out-Null
            continue
        }

        $controlChanges = @(Get-RooPropertyArray $snapshot 'controlChanges')
        $appliedControls = New-Object System.Collections.Generic.List[object]
        $failedControls = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($change in $controlChanges) {
                try {
                    Invoke-RooProcessControlChange $live $change
                    $appliedControls.Add($change) | Out-Null
                } catch {
                    $failedControls.Add("$([string](Get-RooPropertyValue $change 'control' 'unknown')): $($_.Exception.Message)") | Out-Null
                }
            }
            $afterControls = Get-RooProcessControlState ([int](Get-RooPropertyValue $snapshot 'processId' 0)) $null
            if ($appliedControls.Count -gt 0) {
                $changed.Add([pscustomobject]@{
                    processId = Get-RooPropertyValue $snapshot 'processId' 0
                    processName = Get-RooPropertyValue $snapshot 'processName' ''
                    originalPriorityClass = Get-RooPropertyValue $snapshot 'originalPriorityClass' $null
                    appliedPriorityClass = $afterControls.priorityClass
                    originalAffinityMask = Get-RooPropertyValue $snapshot 'originalAffinityMask' $null
                    appliedAffinityMask = $afterControls.affinityMask
                    originalIoPriority = Get-RooPropertyValue $snapshot 'originalIoPriority' $null
                    appliedIoPriority = $afterControls.ioPriority
                    originalGpuPriority = Get-RooPropertyValue $snapshot 'originalGpuPriority' $null
                    appliedGpuPriority = $afterControls.gpuPriority
                    appliedControls = @($appliedControls.ToArray())
                    ruleId = Get-RooPropertyValue $snapshot 'ruleId' ''
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
    $nonNoopSkipped = @($skipped.ToArray() | Where-Object { [string](Get-RooPropertyValue $_ 'category' '') -ne 'no-change' })
    if ($changed.Count -eq 0 -and ($candidateEntries.Count -gt 0 -or $nonNoopSkipped.Count -gt 0)) { $status = if ($nonNoopSkipped.Count -eq 0) { 'success' } else { 'failed' } }
    if ($changed.Count -gt 0 -and $nonNoopSkipped.Count -gt 0) { $status = 'partial' }

    $result = New-RooActionResult `
        -ResultId ("apply-" + (Get-RooFileStamp)) `
        -Status $status `
        -Summary "Confirmed apply completed with $($changed.Count) process control change item(s) and $($skipped.Count) skipped item(s)." `
        -ChangedItems @($changed.ToArray()) `
        -SkippedItems @($skipped.ToArray()) `
        -Artifacts $(if ($backupPath) { @([pscustomobject]@{ type = 'processProfileBackup'; path = $backupPath }) } else { @() })

    $applyEnvelope = New-RooActionEnvelope `
        -ActionId 'performance.applyProfile' `
        -DryRun $false `
        -Risk ([string](Get-RooPropertyValue $profile 'risk' 'medium')) `
        -RequiresElevation $false `
        -Status $status `
        -Preview @(Get-RooPropertyArray $previewEnvelope 'preview') `
        -Backup $backupMetadata `
        -Result $result `
        -Warnings @(Get-RooPropertyArray $previewEnvelope 'warnings') `
        -Errors @(Get-RooPropertyArray $previewEnvelope 'errors') `
        -Logs @((New-RooLog "Confirmed apply finished with status $status."))

    Write-RooJsonOutput $applyEnvelope $OutputPath
} catch {
    $envelope = New-RooActionEnvelope `
        -ActionId 'performance.applyProfile' `
        -DryRun (-not $ConfirmApply) `
        -Risk 'medium' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIssue 'PROCESS_PROFILE_APPLY_FAILED' $_.Exception.Message 'error' 'performance.profile' $ProfilePath $true 'Review the profile path and permissions, then retry.' $null)) `
        -Logs @((New-RooLog 'Apply failed.' 'error'))
    Write-RooJsonOutput $envelope $OutputPath
    exit 1
}
