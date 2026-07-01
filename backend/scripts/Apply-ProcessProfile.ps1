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
        currentPath = $currentPath
        reason = if ($nameMatches -and $pathMatches) { $null } else { 'Live process identity does not match the preview entry.' }
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
            type = 'processPriority'
            target = "$([string](Get-RooPropertyValue $snap 'processName' ''))`:$([int](Get-RooPropertyValue $snap 'processId' 0))"
            originalState = [pscustomobject]@{
                priorityClass = Get-RooPropertyValue $snap 'originalPriorityClass' $null
                executablePath = Get-RooPropertyValue $snap 'executablePath' $null
            }
        }) | Out-Null
    }

    return [pscustomobject]@{
        backupId = [string](Get-RooPropertyValue $BackupManifest 'backupId' '')
        scope = 'process-priority-profile'
        createdAtUtc = [string](Get-RooPropertyValue $BackupManifest 'createdAtUtc' '')
        location = $BackupPath
        restorePoint = [pscustomobject]@{
            requested = $false
            status = 'not-required-for-process-priority'
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
            if ([string](Get-RooPropertyValue $entry 'proposedAction' '') -eq 'setPriority') {
                $skipped.Add([pscustomobject]@{
                    processId = Get-RooPropertyValue $entry 'processId' 0
                    processName = Get-RooPropertyValue $entry 'processName' ''
                    proposedPriorityClass = Get-RooPropertyValue $entry 'proposedPriorityClass' $null
                    reason = 'Dry-run apply; -ConfirmApply was not provided.'
                }) | Out-Null
            }
        }

        $result = New-RooActionResult `
            -ResultId ("dry-run-apply-" + (Get-RooFileStamp)) `
            -Status 'preview' `
            -Summary 'Dry-run only. No process priority changes were applied.' `
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
            -Logs @((New-RooLog 'Dry-run apply completed without changing process priorities.'))

        Write-RooJsonOutput $dryRunEnvelope $OutputPath
        exit 0
    }

    $candidateEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-RooPropertyArray $previewEnvelope 'preview')) {
        $isChange = ([string](Get-RooPropertyValue $entry 'proposedAction' '') -eq 'setPriority')
        $isBlocked = [bool](Get-RooPropertyValue $entry 'blocked' $false)
        $isProtected = [bool](Get-RooPropertyValue $entry 'protected' $false)
        if ($isChange -and -not $isBlocked -and -not $isProtected) {
            $candidateEntries.Add($entry) | Out-Null
        }
    }

    $skipped = New-Object System.Collections.Generic.List[object]
    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($candidateEntries.ToArray())) {
        $targetPriority = [string](Get-RooPropertyValue $entry 'proposedPriorityClass' '')
        if (-not (Test-RooPriorityAllowed $targetPriority)) {
            $skipped.Add([pscustomobject]@{
                processId = Get-RooPropertyValue $entry 'processId' 0
                processName = Get-RooPropertyValue $entry 'processName' ''
                reason = "Priority class '$targetPriority' is outside the allow-list."
            }) | Out-Null
            continue
        }

        $identity = Get-LiveProcessIdentity $entry
        if (-not $identity.exists -or -not $identity.matches) {
            $skipped.Add([pscustomobject]@{
                processId = Get-RooPropertyValue $entry 'processId' 0
                processName = Get-RooPropertyValue $entry 'processName' ''
                reason = $identity.reason
            }) | Out-Null
            continue
        }

        if ([string]$identity.currentPriorityClass -eq $targetPriority) {
            $skipped.Add([pscustomobject]@{
                processId = Get-RooPropertyValue $entry 'processId' 0
                processName = Get-RooPropertyValue $entry 'processName' ''
                reason = "Process is already at $targetPriority priority."
            }) | Out-Null
            continue
        }

        $snapshots.Add([pscustomobject]@{
            processId = [int](Get-RooPropertyValue $entry 'processId' 0)
            processName = [string](Get-RooPropertyValue $entry 'processName' '')
            executablePath = Get-RooPropertyValue $entry 'executablePath' $identity.currentPath
            originalPriorityClass = [string]$identity.currentPriorityClass
            proposedPriorityClass = $targetPriority
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
            $skipped.Add([pscustomobject]@{
                processId = Get-RooPropertyValue $snapshot 'processId' 0
                processName = Get-RooPropertyValue $snapshot 'processName' ''
                reason = 'Process exited before apply.'
            }) | Out-Null
            continue
        }
        if (-not (Test-RooProcessNameEquals $live.ProcessName ([string](Get-RooPropertyValue $snapshot 'processName' '')))) {
            $skipped.Add([pscustomobject]@{
                processId = Get-RooPropertyValue $snapshot 'processId' 0
                processName = Get-RooPropertyValue $snapshot 'processName' ''
                reason = 'Process identity changed before apply.'
            }) | Out-Null
            continue
        }

        $desiredPriority = [string](Get-RooPropertyValue $snapshot 'proposedPriorityClass' '')
        try {
            $live.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$desiredPriority
            $changed.Add([pscustomobject]@{
                processId = Get-RooPropertyValue $snapshot 'processId' 0
                processName = Get-RooPropertyValue $snapshot 'processName' ''
                originalPriorityClass = Get-RooPropertyValue $snapshot 'originalPriorityClass' $null
                appliedPriorityClass = $desiredPriority
                ruleId = Get-RooPropertyValue $snapshot 'ruleId' ''
            }) | Out-Null
        } catch {
            $skipped.Add([pscustomobject]@{
                processId = Get-RooPropertyValue $snapshot 'processId' 0
                processName = Get-RooPropertyValue $snapshot 'processName' ''
                reason = $_.Exception.Message
            }) | Out-Null
        }
    }

    $status = 'success'
    if ($changed.Count -eq 0 -and ($candidateEntries.Count -gt 0 -or $skipped.Count -gt 0)) { $status = 'failed' }
    if ($changed.Count -gt 0 -and $skipped.Count -gt 0) { $status = 'partial' }

    $result = New-RooActionResult `
        -ResultId ("apply-" + (Get-RooFileStamp)) `
        -Status $status `
        -Summary "Confirmed apply completed with $($changed.Count) priority change(s) and $($skipped.Count) skipped item(s)." `
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
