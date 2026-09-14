param(
    [ValidateSet('preview','approve','apply','status','restore','remove')]
    [string]$Action = 'preview',
    [string]$RulePath = '',
    [string]$RuleId = '',
    [string]$ProfilePath = '',
    [string]$StateRoot = '',
    [string]$OutputPath = '',
    [string]$CreatedBy = 'local-user',
    [string]$ApprovedBy = '',
    [string]$Reason = '',
    [switch]$ConfirmApply,
    [switch]$IncludeCommandLine
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessPolicyRules.Common.ps1')

function Get-LifecycleProfileContext {
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\persistent-policy.profile.json'
    $resolvedProfilePath = Resolve-RooPath $ProfilePath $defaultProfilePath
    $profile = Read-RooJsonFile $resolvedProfilePath
    $protectedCatalogPath = Resolve-RooProcessPolicyProtectedCatalog $profile $resolvedProfilePath
    $protectedCatalog = Read-RooJsonFile $protectedCatalogPath
    return [pscustomobject]@{
        profilePath = $resolvedProfilePath
        profile = $profile
        protectedCatalogPath = $protectedCatalogPath
        protectedCatalog = $protectedCatalog
    }
}

function Set-LifecycleRuleTimestamp {
    param(
        [object]$Rule,
        [string]$Name
    )
    $timestamps = Get-RooPropertyValue $Rule 'timestamps' $null
    if ($null -eq $timestamps) {
        $timestamps = [pscustomobject]@{}
        Set-RooProcessPolicyObjectProperty $Rule 'timestamps' $timestamps
    }
    $now = Get-RooUtcStamp
    Set-RooProcessPolicyObjectProperty $timestamps $Name $now
    Set-RooProcessPolicyObjectProperty $timestamps 'updatedAtUtc' $now
}

function Get-LifecycleRule {
    param([switch]$RequireStored)
    if (-not [string]::IsNullOrWhiteSpace($RulePath)) {
        $resolvedRulePath = Resolve-RooPath $RulePath $RulePath
        $raw = Read-RooJsonFile $resolvedRulePath
        $ruleNode = Get-RooPropertyValue $raw 'rule' $raw
        $inputRuleId = [string](Get-RooPropertyValue $ruleNode 'id' (Get-RooPropertyValue $ruleNode 'ruleId' $RuleId))
        $existing = if (-not [string]::IsNullOrWhiteSpace($inputRuleId)) { Get-RooProcessPolicyStoredRule $StateRoot $inputRuleId } else { $null }
        $stored = ConvertTo-RooProcessPolicyStoredRule -Rule $ruleNode -CreatedBy $CreatedBy -ExistingRule $existing
        return [pscustomobject]@{ rule = $stored; fromStore = ($null -ne $existing); rulePath = $resolvedRulePath }
    }
    if ([string]::IsNullOrWhiteSpace($RuleId)) {
        throw 'RulePath or RuleId is required.'
    }
    $rule = Get-RooProcessPolicyStoredRule $StateRoot $RuleId
    if ($null -eq $rule -and $RequireStored) {
        throw "Process policy rule '$RuleId' was not found in the runtime rule store."
    }
    return [pscustomobject]@{ rule = $rule; fromStore = $true; rulePath = $null }
}

function Get-LifecyclePreview {
    param(
        [object]$Rule,
        [object]$Context
    )
    $profileForRule = New-RooProcessPolicyProfileForRule -Profile $Context.profile -StoredRule $Rule
    $previewState = Get-RooProcessPolicyPreview `
        -Profile $profileForRule `
        -ProfilePath $Context.profilePath `
        -ProtectedCatalog $Context.protectedCatalog `
        -IncludeCommandLine:$IncludeCommandLine
    $ruleId = [string](Get-RooPropertyValue $Rule 'id' '')
    $ruleEntries = @(@(Get-RooPropertyArray $previewState 'preview') | Where-Object { [string](Get-RooPropertyValue $_ 'ruleId' '') -eq $ruleId })
    Set-RooProcessPolicyObjectProperty $previewState 'preview' $ruleEntries
    return $previewState
}

function Get-LifecycleControlValue {
    param(
        [object]$State,
        [string]$Control
    )
    switch ($Control) {
        'priorityClass' { return Get-RooPropertyValue $State 'priorityClass' $null }
        'affinityMask' { return Get-RooPropertyValue $State 'affinityMask' $null }
        'ioPriority' { return Get-RooPropertyValue $State 'ioPriority' $null }
        'gpuPriority' { return Get-RooPropertyValue $State 'gpuPriority' $null }
        default { return $null }
    }
}

function New-LifecycleSnapshot {
    param(
        [object]$Rule,
        [object]$Entry,
        [object]$OriginalState,
        [object[]]$Changes
    )
    return [pscustomobject]@{
        snapshotId = "process-policy-snapshot-$([guid]::NewGuid().ToString('N'))"
        ruleId = [string](Get-RooPropertyValue $Rule 'id' '')
        targetProcess = (New-RooProcessPolicyTargetIdentity $Entry)
        processId = [int](Get-RooPropertyValue $Entry 'processId' 0)
        processName = [string](Get-RooPropertyValue $Entry 'processName' '')
        executablePath = Get-RooPropertyValue $Entry 'executablePath' $null
        publisher = Get-RooPropertyValue $Entry 'publisher' $null
        startTimeUtc = Get-RooPropertyValue (Get-RooPropertyValue $Entry 'currentState' $null) 'startTimeUtc' $null
        protectionCategory = [string](Get-RooPropertyValue (Get-RooPropertyValue $Entry 'currentState' $null) 'category' (Get-RooPropertyValue $Rule 'protectionCategory' 'unknown'))
        originalPriorityClass = Get-RooPropertyValue $OriginalState 'priorityClass' $null
        proposedPriorityClass = Get-RooPropertyValue $Entry 'proposedPriorityClass' $null
        originalAffinityMask = Get-RooPropertyValue $OriginalState 'affinityMask' $null
        proposedAffinityMask = Get-RooPropertyValue $Entry 'proposedAffinityMask' $null
        originalIoPriority = Get-RooPropertyValue $OriginalState 'ioPriority' $null
        proposedIoPriority = Get-RooPropertyValue $Entry 'proposedIoPriority' $null
        originalGpuPriority = Get-RooPropertyValue $OriginalState 'gpuPriority' $null
        proposedGpuPriority = Get-RooPropertyValue $Entry 'proposedGpuPriority' $null
        controlChanges = @(Get-RooArray $Changes)
        capturedAtUtc = Get-RooUtcStamp
        reason = [string](Get-RooPropertyValue $Entry 'reason' (Get-RooPropertyValue $Rule 'reason' 'Persistent process policy rule.'))
    }
}

function Add-LifecycleActiveEffect {
    param(
        [object]$Rule,
        [object]$Effect
    )
    $effectKey = "$([int](Get-RooPropertyValue $Effect 'processId' 0))|$([string](Get-RooPropertyValue $Effect 'processName' ''))|$([string](Get-RooPropertyValue $Effect 'executablePath' ''))|$([string](Get-RooPropertyValue $Effect 'startTimeUtc' ''))"
    $effects = New-Object System.Collections.Generic.List[object]
    foreach ($existing in @(Get-RooPropertyArray $Rule 'activeEffects')) {
        $existingKey = "$([int](Get-RooPropertyValue $existing 'processId' 0))|$([string](Get-RooPropertyValue $existing 'processName' ''))|$([string](Get-RooPropertyValue $existing 'executablePath' ''))|$([string](Get-RooPropertyValue $existing 'startTimeUtc' ''))"
        if ($existingKey -ne $effectKey) { $effects.Add($existing) | Out-Null }
    }
    $effects.Add($Effect) | Out-Null
    Set-RooProcessPolicyObjectProperty $Rule 'activeEffects' @($effects.ToArray())
}

function Add-LifecycleBackupPath {
    param(
        [object]$Rule,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($existing in @(Get-RooPropertyArray $Rule 'backupManifestPaths')) {
        if (-not $paths.Contains([string]$existing)) { $paths.Add([string]$existing) | Out-Null }
    }
    if (-not $paths.Contains($Path)) { $paths.Add($Path) | Out-Null }
    Set-RooProcessPolicyObjectProperty $Rule 'backupManifestPaths' @($paths.ToArray())
}

function New-LifecyclePreviewAuditRows {
    param(
        [object]$Rule,
        [object[]]$PreviewEntries,
        [string]$Outcome,
        [string]$ActionName = 'preview'
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $ruleId = [string](Get-RooPropertyValue $Rule 'id' '')
    $restraint = Get-RooPropertyValue (Get-RooPropertyValue $Rule 'requestedControls' $null) 'restraint' $null
    foreach ($entry in @(Get-RooArray $PreviewEntries)) {
        $category = [string](Get-RooPropertyValue (Get-RooPropertyValue $entry 'currentState' $null) 'category' (Get-RooPropertyValue $Rule 'protectionCategory' 'unknown'))
        if ([bool](Get-RooPropertyValue $entry 'blocked' $false)) {
            $rows.Add((New-RooProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string](Get-RooPropertyValue $entry 'blockedReason' 'Process policy rule was blocked.')) -ProtectionCategory $category -Outcome 'skipped' -DryRun $true)) | Out-Null
            continue
        }
        $changes = @(Get-RooPreviewControlChanges $entry)
        if ($changes.Count -eq 0) {
            $rows.Add((New-RooProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string](Get-RooPropertyValue $entry 'reason' 'No process control change was needed.')) -ProtectionCategory $category -Outcome 'noChange' -DryRun $true)) | Out-Null
        } else {
            foreach ($change in $changes) {
                $rows.Add((New-RooProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $entry -Control ([string](Get-RooPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooPropertyValue $change 'currentValue' $null) -AfterValue (Get-RooPropertyValue $change 'proposedValue' $null) -Reason ([string](Get-RooPropertyValue $change 'reason' (Get-RooPropertyValue $entry 'reason' 'Policy preview.'))) -ProtectionCategory $category -Outcome $Outcome -DryRun $true)) | Out-Null
            }
        }
        if ($null -ne $restraint) {
            $rows.Add((New-RooProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $entry -Control 'restraint' -BeforeValue $null -AfterValue $restraint -Reason 'Policy restraint metadata was recorded for the target.' -ProtectionCategory $category -Outcome $Outcome -DryRun $true)) | Out-Null
        }
    }
    if ($rows.Count -eq 0) {
        $rows.Add((New-RooProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $null -Control 'ruleLifecycle' -BeforeValue $null -AfterValue (Get-RooPropertyValue $Rule 'status' $null) -Reason 'No running process matched the policy rule.' -ProtectionCategory (Get-RooPropertyValue $Rule 'protectionCategory' 'unknown') -Outcome 'noMatch' -DryRun $true)) | Out-Null
    }
    return @($rows.ToArray())
}

function Get-LifecycleBackupPaths {
    param([object]$Rule)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($effect in @(Get-RooPropertyArray $Rule 'activeEffects')) {
        $path = [string](Get-RooPropertyValue $effect 'backupManifestPath' '')
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not $paths.Contains($path)) { $paths.Add($path) | Out-Null }
    }
    foreach ($pathValue in @(Get-RooPropertyArray $Rule 'backupManifestPaths')) {
        $path = [string]$pathValue
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not $paths.Contains($path)) { $paths.Add($path) | Out-Null }
    }
    return @($paths.ToArray())
}

function Invoke-LifecycleRestore {
    param(
        [object]$Rule,
        [switch]$ApplyRestore
    )
    $ruleId = [string](Get-RooPropertyValue $Rule 'id' '')
    $preview = New-Object System.Collections.Generic.List[object]
    $restored = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $auditRows = New-Object System.Collections.Generic.List[object]
    $failedControlCount = 0

    foreach ($backupPath in @(Get-LifecycleBackupPaths $Rule)) {
        if (-not (Test-Path -LiteralPath $backupPath)) {
            $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $null -Control 'backupManifest' -BeforeValue $backupPath -AfterValue $null -Reason 'Backup manifest was not available for restore.' -ProtectionCategory (Get-RooPropertyValue $Rule 'protectionCategory' 'unknown') -RestorePath $backupPath -RestoreAvailable $false -Outcome 'skipped' -DryRun (-not $ApplyRestore))) | Out-Null
            continue
        }
        $backup = Read-RooJsonFile $backupPath
        foreach ($snapshot in @(Get-RooPropertyArray $backup 'snapshots')) {
            if ([string](Get-RooPropertyValue $snapshot 'ruleId' '') -ne $ruleId) { continue }
            $candidate = Get-RooProcessPolicyLiveIdentity ([pscustomobject]@{
                processId = Get-RooPropertyValue $snapshot 'processId' 0
                processName = Get-RooPropertyValue $snapshot 'processName' ''
                executablePath = Get-RooPropertyValue $snapshot 'executablePath' $null
            })
            $target = [pscustomobject]@{
                processId = Get-RooPropertyValue $snapshot 'processId' $null
                processName = Get-RooPropertyValue $snapshot 'processName' $null
                executablePath = Get-RooPropertyValue $snapshot 'executablePath' $null
                publisher = Get-RooPropertyValue $snapshot 'publisher' $null
            }
            $category = [string](Get-RooPropertyValue $snapshot 'protectionCategory' (Get-RooPropertyValue $Rule 'protectionCategory' 'unknown'))
            if (-not $candidate.exists -or -not $candidate.matches) {
                $reasonText = [string](Get-RooPropertyValue $candidate 'reason' 'Process was not available for restore.')
                $skipped.Add([pscustomobject]@{
                    processId = Get-RooPropertyValue $snapshot 'processId' $null
                    processName = Get-RooPropertyValue $snapshot 'processName' $null
                    reason = $reasonText
                    backupManifestPath = $backupPath
                    skippedAtUtc = Get-RooUtcStamp
                }) | Out-Null
                $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason $reasonText -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'skipped' -DryRun (-not $ApplyRestore))) | Out-Null
                continue
            }
            $currentState = Get-RooProcessControlState ([int](Get-RooPropertyValue $snapshot 'processId' 0)) $null
            $changes = @(Get-RooProcessPolicyRestoreChanges $snapshot $currentState)
            $preview.Add([pscustomobject]@{
                ruleId = $ruleId
                processId = Get-RooPropertyValue $snapshot 'processId' $null
                processName = Get-RooPropertyValue $snapshot 'processName' $null
                executablePath = Get-RooPropertyValue $snapshot 'executablePath' $null
                backupManifestPath = $backupPath
                controlChanges = @($changes)
                requiresConfirmation = ($changes.Count -gt 0)
                blocked = $false
            }) | Out-Null
            if ($changes.Count -eq 0) {
                $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason 'Process already matched the stored backup controls.' -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'noChange' -DryRun (-not $ApplyRestore))) | Out-Null
                continue
            }
            if (-not $ApplyRestore) {
                foreach ($change in $changes) {
                    $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control ([string](Get-RooPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooPropertyValue $change 'currentValue' $null) -AfterValue (Get-RooPropertyValue $change 'proposedValue' $null) -Reason ([string](Get-RooPropertyValue $change 'reason' 'Restore process controls.')) -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'confirmationRequired' -DryRun $true)) | Out-Null
                }
                continue
            }
            $appliedControls = New-Object System.Collections.Generic.List[object]
            foreach ($change in $changes) {
                try {
                    Invoke-RooProcessControlChange $candidate.process $change
                    $appliedControls.Add($change) | Out-Null
                    $afterState = Get-RooProcessControlState ([int](Get-RooPropertyValue $snapshot 'processId' 0)) $null
                    $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control ([string](Get-RooPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooPropertyValue $change 'currentValue' $null) -AfterValue (Get-LifecycleControlValue $afterState ([string](Get-RooPropertyValue $change 'control' ''))) -Reason ([string](Get-RooPropertyValue $change 'reason' 'Restore process controls.')) -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'restored' -DryRun $false)) | Out-Null
                } catch {
                    $failedControlCount++
                    $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control ([string](Get-RooPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooPropertyValue $change 'currentValue' $null) -AfterValue (Get-RooPropertyValue $change 'currentValue' $null) -Reason $_.Exception.Message -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'failed' -DryRun $false)) | Out-Null
                }
            }
            if ($appliedControls.Count -gt 0) {
                $afterControls = Get-RooProcessControlState ([int](Get-RooPropertyValue $snapshot 'processId' 0)) $null
                $restored.Add([pscustomobject]@{
                    processId = Get-RooPropertyValue $snapshot 'processId' $null
                    processName = Get-RooPropertyValue $snapshot 'processName' $null
                    executablePath = Get-RooPropertyValue $snapshot 'executablePath' $null
                    restoredPriorityClass = Get-RooPropertyValue $afterControls 'priorityClass' $null
                    restoredAffinityMask = Get-RooPropertyValue $afterControls 'affinityMask' $null
                    restoredIoPriority = Get-RooPropertyValue $afterControls 'ioPriority' $null
                    restoredGpuPriority = Get-RooPropertyValue $afterControls 'gpuPriority' $null
                    restoredControls = @($appliedControls.ToArray())
                    backupManifestPath = $backupPath
                    restoredAtUtc = Get-RooUtcStamp
                }) | Out-Null
            }
        }
    }

    return [pscustomobject]@{
        preview = @($preview.ToArray())
        restoredItems = @($restored.ToArray())
        skippedItems = @($skipped.ToArray())
        auditRows = @($auditRows.ToArray())
        failedControlCount = $failedControlCount
    }
}

function Write-LifecycleOutput {
    param(
        [string]$Status,
        [object]$Rule = $null,
        [object[]]$Rules = @(),
        [object[]]$Preview = @(),
        [object[]]$ChangedItems = @(),
        [object[]]$RestoredItems = @(),
        [object[]]$SkippedItems = @(),
        [object]$Backup = $null,
        [object[]]$AuditRows = @(),
        [object[]]$Warnings = @(),
        [object[]]$Errors = @()
    )
    $resolvedRoot = Resolve-RooProcessPolicyRuntimeStateRoot $StateRoot
    $envelope = [pscustomobject]@{
        actionId = "performance.policy.rule.$Action"
        schemaVersion = 1
        productName = $script:RooProcessProductName
        action = $Action
        status = $Status
        dryRun = (-not $ConfirmApply)
        stateRoot = $resolvedRoot
        ruleStorePath = Get-RooProcessPolicyRuleStorePath $StateRoot
        auditPath = Get-RooProcessPolicyAuditPath $StateRoot
        capturedAtUtc = Get-RooUtcStamp
        ruleId = if ($Rule) { [string](Get-RooPropertyValue $Rule 'id' '') } elseif (-not [string]::IsNullOrWhiteSpace($RuleId)) { $RuleId } else { $null }
        rule = $Rule
        rules = @(Get-RooArray $Rules)
        preview = @(Get-RooArray $Preview)
        changedItems = @(Get-RooArray $ChangedItems)
        restoredItems = @(Get-RooArray $RestoredItems)
        skippedItems = @(Get-RooArray $SkippedItems)
        backup = $Backup
        auditRows = @(Get-RooArray $AuditRows)
        warnings = @(Get-RooArray $Warnings)
        errors = @(Get-RooArray $Errors)
    }
    Write-RooJsonOutput $envelope $OutputPath
}

try {
    $context = Get-LifecycleProfileContext
    switch ($Action) {
        'preview' {
            $resolved = Get-LifecycleRule
            $rule = $resolved.rule
            Set-RooProcessPolicyObjectProperty $rule 'status' 'previewed'
            Set-RooProcessPolicyObjectProperty $rule 'removed' $false
            Set-LifecycleRuleTimestamp $rule 'previewedAtUtc'
            $previewState = Get-LifecyclePreview -Rule $rule -Context $context
            $previewEntries = @(Get-RooPropertyArray $previewState 'preview')
            $changeCount = 0
            foreach ($entry in $previewEntries) { $changeCount += @(Get-RooPreviewControlChanges $entry).Count }
            Set-RooProcessPolicyObjectProperty $rule 'lastPreview' ([pscustomobject]@{
                capturedAtUtc = Get-RooPropertyValue $previewState 'capturedAtUtc' $null
                processCount = [int](Get-RooPropertyValue $previewState 'processCount' 0)
                matchedProcessCount = $previewEntries.Count
                changeCount = $changeCount
            })
            Set-RooProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            $auditRows = @(New-LifecyclePreviewAuditRows -Rule $rule -PreviewEntries $previewEntries -Outcome 'previewed' -ActionName 'preview')
            Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
            Write-LifecycleOutput -Status 'previewed' -Rule $rule -Preview $previewEntries -AuditRows $auditRows
        }
        'approve' {
            $resolved = Get-LifecycleRule -RequireStored
            $rule = $resolved.rule
            $beforeStatus = [string](Get-RooPropertyValue $rule 'status' $null)
            if ([bool](Get-RooPropertyValue $rule 'removed' $false)) {
                throw "Process policy rule '$([string](Get-RooPropertyValue $rule 'id' ''))' has been removed."
            }
            $approver = if ([string]::IsNullOrWhiteSpace($ApprovedBy)) { $CreatedBy } else { $ApprovedBy }
            Set-RooProcessPolicyObjectProperty $rule 'status' 'approved'
            Set-RooProcessPolicyObjectProperty $rule 'approval' ([pscustomobject]@{
                decision = 'approved'
                approvedBy = $approver
                approvedAtUtc = Get-RooUtcStamp
                reason = if ([string]::IsNullOrWhiteSpace($Reason)) { 'Approved for confirmed process policy application.' } else { $Reason }
            })
            Set-LifecycleRuleTimestamp $rule 'approvedAtUtc'
            Set-RooProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            $auditRows = @((New-RooProcessPolicyAuditRow -Action 'approve' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue $beforeStatus -AfterValue 'approved' -Reason (Get-RooPropertyValue (Get-RooPropertyValue $rule 'approval' $null) 'reason' '') -ProtectionCategory (Get-RooPropertyValue $rule 'protectionCategory' 'unknown') -Outcome 'approved' -DryRun $false))
            Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
            Write-LifecycleOutput -Status 'approved' -Rule $rule -AuditRows $auditRows
        }
        'apply' {
            $resolved = Get-LifecycleRule -RequireStored
            $rule = $resolved.rule
            $approval = Get-RooPropertyValue $rule 'approval' $null
            if ([bool](Get-RooPropertyValue $rule 'removed' $false)) {
                throw "Process policy rule '$([string](Get-RooPropertyValue $rule 'id' ''))' has been removed."
            }
            if ([string](Get-RooPropertyValue $approval 'decision' '') -ne 'approved') {
                $auditRows = @((New-RooProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue (Get-RooPropertyValue $rule 'status' $null) -AfterValue (Get-RooPropertyValue $rule 'status' $null) -Reason 'Rule approval is required before apply.' -ProtectionCategory (Get-RooPropertyValue $rule 'protectionCategory' 'unknown') -Outcome 'approvalRequired' -DryRun $true))
                Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
                Write-LifecycleOutput -Status 'approvalRequired' -Rule $rule -AuditRows $auditRows
                exit 1
            }
            $previewState = Get-LifecyclePreview -Rule $rule -Context $context
            $previewEntries = @(Get-RooPropertyArray $previewState 'preview')
            if (-not $ConfirmApply) {
                $auditRows = @(New-LifecyclePreviewAuditRows -Rule $rule -PreviewEntries $previewEntries -Outcome 'confirmationRequired' -ActionName 'apply')
                Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
                Write-LifecycleOutput -Status 'confirmationRequired' -Rule $rule -Preview $previewEntries -AuditRows $auditRows -Warnings @((New-RooIssue 'PROCESS_POLICY_RULE_CONFIRM_REQUIRED' 'Apply requires -ConfirmApply after approval.' 'info' 'performance.policy' ([string](Get-RooPropertyValue $rule 'id' '')) $false 'Rerun with -ConfirmApply against a safe runtime state root and allow-listed process path.' $null))
                exit 0
            }

            $profileForRule = New-RooProcessPolicyProfileForRule -Profile $context.profile -StoredRule $rule
            $ruleForProfile = ConvertTo-RooProcessPolicyRuleForProfile $rule
            $eligible = New-Object System.Collections.Generic.List[object]
            $changedItems = New-Object System.Collections.Generic.List[object]
            $skippedItems = New-Object System.Collections.Generic.List[object]
            $auditRows = New-Object System.Collections.Generic.List[object]
            foreach ($entry in $previewEntries) {
                $category = [string](Get-RooPropertyValue (Get-RooPropertyValue $entry 'currentState' $null) 'category' (Get-RooPropertyValue $rule 'protectionCategory' 'unknown'))
                if ([bool](Get-RooPropertyValue $entry 'blocked' $false)) {
                    $reasonText = [string](Get-RooPropertyValue $entry 'blockedReason' 'Policy target is protected.')
                    $skippedItems.Add((New-RooProcessPolicySkippedItem $entry $reasonText 0)) | Out-Null
                    $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason $reasonText -ProtectionCategory $category -Outcome 'skipped' -DryRun $false)) | Out-Null
                    continue
                }
                $changes = @(Get-RooPreviewControlChanges $entry)
                if ($changes.Count -eq 0) {
                    $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string](Get-RooPropertyValue $entry 'reason' 'No process control change was needed.')) -ProtectionCategory $category -Outcome 'noChange' -DryRun $false)) | Out-Null
                    continue
                }
                $safety = Test-RooProcessPolicyConfirmedAllowed $entry $ruleForProfile $profileForRule
                if (-not $safety.allowed) {
                    $skippedItems.Add((New-RooProcessPolicySkippedItem $entry ([string]$safety.reason) 0)) | Out-Null
                    $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string]$safety.reason) -ProtectionCategory $category -Outcome 'skipped' -DryRun $false)) | Out-Null
                    continue
                }
                $identity = Get-RooProcessPolicyLiveIdentity $entry
                if (-not $identity.exists -or -not $identity.matches) {
                    $skippedItems.Add((New-RooProcessPolicySkippedItem $entry ([string]$identity.reason) 0)) | Out-Null
                    $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string]$identity.reason) -ProtectionCategory $category -Outcome 'skipped' -DryRun $false)) | Out-Null
                    continue
                }
                $processId = [int](Get-RooPropertyValue $entry 'processId' 0)
                $originalState = Get-RooProcessControlState $processId $null
                $snapshot = New-LifecycleSnapshot -Rule $rule -Entry $entry -OriginalState $originalState -Changes $changes
                $eligible.Add([pscustomobject]@{
                    entry = $entry
                    identity = $identity
                    originalState = $originalState
                    changes = @($changes)
                    snapshot = $snapshot
                    protectionCategory = $category
                }) | Out-Null
            }

            $backupInfo = $null
            if ($eligible.Count -gt 0) {
                $backupInfo = New-RooProcessPolicyRuleBackupManifest -StateRoot $StateRoot -Rule $rule -ActionId 'performance.policy.rule.apply' -Snapshots @($eligible | ForEach-Object { $_.snapshot })
                Add-LifecycleBackupPath -Rule $rule -Path $backupInfo.path
            }

            foreach ($item in @($eligible.ToArray())) {
                $entry = $item.entry
                $processId = [int](Get-RooPropertyValue $entry 'processId' 0)
                $appliedControls = New-Object System.Collections.Generic.List[object]
                foreach ($change in @(Get-RooArray $item.changes)) {
                    try {
                        Invoke-RooProcessControlChange $item.identity.process $change
                        $appliedControls.Add($change) | Out-Null
                        $afterState = Get-RooProcessControlState $processId $null
                        $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $entry -Control ([string](Get-RooPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooPropertyValue $change 'currentValue' $null) -AfterValue (Get-LifecycleControlValue $afterState ([string](Get-RooPropertyValue $change 'control' ''))) -Reason ([string](Get-RooPropertyValue $change 'reason' (Get-RooPropertyValue $entry 'reason' 'Apply process controls.'))) -ProtectionCategory ([string]$item.protectionCategory) -RestorePath $backupInfo.path -RestoreAvailable $true -Outcome 'applied' -DryRun $false)) | Out-Null
                    } catch {
                        $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $entry -Control ([string](Get-RooPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooPropertyValue $change 'currentValue' $null) -AfterValue (Get-RooPropertyValue $change 'currentValue' $null) -Reason $_.Exception.Message -ProtectionCategory ([string]$item.protectionCategory) -RestorePath $backupInfo.path -RestoreAvailable $true -Outcome 'failed' -DryRun $false)) | Out-Null
                    }
                }
                if ($appliedControls.Count -gt 0) {
                    $appliedState = Get-RooProcessControlState $processId $null
                    $changed = New-RooProcessPolicyChangedItem $entry $item.originalState $appliedState @($appliedControls.ToArray()) 0
                    $changedItems.Add($changed) | Out-Null
                    Add-LifecycleActiveEffect -Rule $rule -Effect ([pscustomobject]@{
                        processId = $processId
                        processName = Get-RooPropertyValue $entry 'processName' ''
                        executablePath = Get-RooPropertyValue $entry 'executablePath' $null
                        startTimeUtc = Get-RooPropertyValue (Get-RooPropertyValue $entry 'currentState' $null) 'startTimeUtc' $null
                        ruleId = Get-RooPropertyValue $rule 'id' ''
                        backupManifestPath = $backupInfo.path
                        backupSnapshotId = Get-RooPropertyValue $item.snapshot 'snapshotId' ''
                        appliedControls = @($appliedControls.ToArray())
                        appliedAtUtc = Get-RooUtcStamp
                    })
                }
            }

            if ($changedItems.Count -gt 0) {
                Set-RooProcessPolicyObjectProperty $rule 'status' 'applied'
                Set-LifecycleRuleTimestamp $rule 'appliedAtUtc'
            }
            Set-RooProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows @($auditRows.ToArray()) | Out-Null
            $status = if ($changedItems.Count -gt 0 -and $skippedItems.Count -gt 0) { 'partial' } elseif ($changedItems.Count -gt 0) { 'applied' } elseif ($skippedItems.Count -gt 0) { 'skipped' } else { 'noChange' }
            Write-LifecycleOutput -Status $status -Rule $rule -Preview $previewEntries -ChangedItems @($changedItems.ToArray()) -SkippedItems @($skippedItems.ToArray()) -Backup (if ($backupInfo) { $backupInfo.manifest } else { $null }) -AuditRows @($auditRows.ToArray())
        }
        'status' {
            $store = Read-RooProcessPolicyRuleStore $StateRoot
            $rules = if ([string]::IsNullOrWhiteSpace($RuleId)) {
                @(Get-RooPropertyArray $store 'rules')
            } else {
                @((Get-RooProcessPolicyStoredRule $StateRoot $RuleId))
            }
            $rules = @($rules | Where-Object { $null -ne $_ })
            $auditRows = New-Object System.Collections.Generic.List[object]
            foreach ($rule in $rules) {
                $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'status' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue $null -AfterValue (Get-RooPropertyValue $rule 'status' $null) -Reason 'Rule lifecycle status was queried.' -ProtectionCategory (Get-RooPropertyValue $rule 'protectionCategory' 'unknown') -RestoreAvailable (@(Get-RooPropertyArray $rule 'backupManifestPaths').Count -gt 0) -Outcome 'reported' -DryRun $true)) | Out-Null
            }
            if ($auditRows.Count -eq 0) {
                $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'status' -RuleId $RuleId -Target $null -Control 'ruleLifecycle' -BeforeValue $null -AfterValue $null -Reason 'No process policy rule matched the status query.' -ProtectionCategory 'unknown' -Outcome 'notFound' -DryRun $true)) | Out-Null
            }
            Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows @($auditRows.ToArray()) | Out-Null
            Write-LifecycleOutput -Status 'reported' -Rules $rules -AuditRows @($auditRows.ToArray())
        }
        'restore' {
            $resolved = Get-LifecycleRule -RequireStored
            $rule = $resolved.rule
            $restore = Invoke-LifecycleRestore -Rule $rule -ApplyRestore:$ConfirmApply
            if ($ConfirmApply -and [int](Get-RooPropertyValue $restore 'failedControlCount' 0) -eq 0) {
                Set-RooProcessPolicyObjectProperty $rule 'activeEffects' @()
                Set-RooProcessPolicyObjectProperty $rule 'status' 'restored'
                Set-LifecycleRuleTimestamp $rule 'restoredAtUtc'
                Set-RooProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            }
            Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows @(Get-RooPropertyArray $restore 'auditRows') | Out-Null
            $status = if (-not $ConfirmApply) { 'confirmationRequired' } elseif ([int](Get-RooPropertyValue $restore 'failedControlCount' 0) -gt 0) { 'partial' } else { 'restored' }
            Write-LifecycleOutput -Status $status -Rule $rule -Preview @(Get-RooPropertyArray $restore 'preview') -RestoredItems @(Get-RooPropertyArray $restore 'restoredItems') -SkippedItems @(Get-RooPropertyArray $restore 'skippedItems') -AuditRows @(Get-RooPropertyArray $restore 'auditRows')
        }
        'remove' {
            $resolved = Get-LifecycleRule -RequireStored
            $rule = $resolved.rule
            $activeCount = @(Get-RooPropertyArray $rule 'activeEffects').Count
            if ($activeCount -gt 0 -and -not $ConfirmApply) {
                $restorePreview = Invoke-LifecycleRestore -Rule $rule
                $auditRows = @(Get-RooPropertyArray $restorePreview 'auditRows')
                $auditRows += (New-RooProcessPolicyAuditRow -Action 'remove' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue (Get-RooPropertyValue $rule 'status' $null) -AfterValue (Get-RooPropertyValue $rule 'status' $null) -Reason 'Remove requires restore confirmation while active effects exist.' -ProtectionCategory (Get-RooPropertyValue $rule 'protectionCategory' 'unknown') -RestoreAvailable $true -Outcome 'confirmationRequired' -DryRun $true)
                Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
                Write-LifecycleOutput -Status 'confirmationRequired' -Rule $rule -Preview @(Get-RooPropertyArray $restorePreview 'preview') -SkippedItems @(Get-RooPropertyArray $restorePreview 'skippedItems') -AuditRows $auditRows
                exit 0
            }
            $restoreResult = $null
            $auditRows = New-Object System.Collections.Generic.List[object]
            if ($activeCount -gt 0) {
                $restoreResult = Invoke-LifecycleRestore -Rule $rule -ApplyRestore:$ConfirmApply
                foreach ($row in @(Get-RooPropertyArray $restoreResult 'auditRows')) { $auditRows.Add($row) | Out-Null }
                if ([int](Get-RooPropertyValue $restoreResult 'failedControlCount' 0) -gt 0) {
                    Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows @($auditRows.ToArray()) | Out-Null
                    Write-LifecycleOutput -Status 'partial' -Rule $rule -RestoredItems @(Get-RooPropertyArray $restoreResult 'restoredItems') -SkippedItems @(Get-RooPropertyArray $restoreResult 'skippedItems') -AuditRows @($auditRows.ToArray())
                    exit 1
                }
            }
            $beforeStatus = [string](Get-RooPropertyValue $rule 'status' $null)
            Set-RooProcessPolicyObjectProperty $rule 'activeEffects' @()
            Set-RooProcessPolicyObjectProperty $rule 'status' 'removed'
            Set-RooProcessPolicyObjectProperty $rule 'removed' $true
            Set-LifecycleRuleTimestamp $rule 'removedAtUtc'
            Set-RooProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            $auditRows.Add((New-RooProcessPolicyAuditRow -Action 'remove' -RuleId ([string](Get-RooPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue $beforeStatus -AfterValue 'removed' -Reason (if ([string]::IsNullOrWhiteSpace($Reason)) { 'Rule was tombstoned after active effects were restored or found inactive.' } else { $Reason }) -ProtectionCategory (Get-RooPropertyValue $rule 'protectionCategory' 'unknown') -RestoreAvailable $false -Outcome 'removed' -DryRun $false)) | Out-Null
            Add-RooProcessPolicyAuditRows -StateRoot $StateRoot -Rows @($auditRows.ToArray()) | Out-Null
            Write-LifecycleOutput -Status 'removed' -Rule $rule -RestoredItems @(if ($restoreResult) { Get-RooPropertyArray $restoreResult 'restoredItems' } else { @() }) -SkippedItems @(if ($restoreResult) { Get-RooPropertyArray $restoreResult 'skippedItems' } else { @() }) -AuditRows @($auditRows.ToArray())
        }
    }
} catch {
    $error = New-RooIssue 'PROCESS_POLICY_RULE_LIFECYCLE_FAILED' $_.Exception.Message 'error' 'performance.policy' $RuleId $true 'Review the rule id, profile path, runtime state root, and confirmation flags.' $null
    Write-LifecycleOutput -Status 'failed' -Errors @($error)
    exit 1
}
