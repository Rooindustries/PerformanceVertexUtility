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
    $resolvedProfilePath = Resolve-RooIndustriesPath $ProfilePath $defaultProfilePath
    $profile = Read-RooIndustriesJsonFile $resolvedProfilePath
    $protectedCatalogPath = Resolve-RooIndustriesProcessPolicyProtectedCatalog $profile $resolvedProfilePath
    $protectedCatalog = Read-RooIndustriesJsonFile $protectedCatalogPath
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
    $timestamps = Get-RooIndustriesPropertyValue $Rule 'timestamps' $null
    if ($null -eq $timestamps) {
        $timestamps = [pscustomobject]@{}
        Set-RooIndustriesProcessPolicyObjectProperty $Rule 'timestamps' $timestamps
    }
    $now = Get-RooIndustriesUtcStamp
    Set-RooIndustriesProcessPolicyObjectProperty $timestamps $Name $now
    Set-RooIndustriesProcessPolicyObjectProperty $timestamps 'updatedAtUtc' $now
}

function Get-LifecycleRule {
    param([switch]$RequireStored)
    if (-not [string]::IsNullOrWhiteSpace($RulePath)) {
        $resolvedRulePath = Resolve-RooIndustriesPath $RulePath $RulePath
        $raw = Read-RooIndustriesJsonFile $resolvedRulePath
        $ruleNode = Get-RooIndustriesPropertyValue $raw 'rule' $raw
        $inputRuleId = [string](Get-RooIndustriesPropertyValue $ruleNode 'id' (Get-RooIndustriesPropertyValue $ruleNode 'ruleId' $RuleId))
        $existing = if (-not [string]::IsNullOrWhiteSpace($inputRuleId)) { Get-RooIndustriesProcessPolicyStoredRule $StateRoot $inputRuleId } else { $null }
        $stored = ConvertTo-RooIndustriesProcessPolicyStoredRule -Rule $ruleNode -CreatedBy $CreatedBy -ExistingRule $existing
        return [pscustomobject]@{ rule = $stored; fromStore = ($null -ne $existing); rulePath = $resolvedRulePath }
    }
    if ([string]::IsNullOrWhiteSpace($RuleId)) {
        throw 'RulePath or RuleId is required.'
    }
    $rule = Get-RooIndustriesProcessPolicyStoredRule $StateRoot $RuleId
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
    $profileForRule = New-RooIndustriesProcessPolicyProfileForRule -Profile $Context.profile -StoredRule $Rule
    $previewState = Get-RooIndustriesProcessPolicyPreview `
        -Profile $profileForRule `
        -ProfilePath $Context.profilePath `
        -ProtectedCatalog $Context.protectedCatalog `
        -IncludeCommandLine:$IncludeCommandLine
    $ruleId = [string](Get-RooIndustriesPropertyValue $Rule 'id' '')
    $ruleEntries = @(@(Get-RooIndustriesPropertyArray $previewState 'preview') | Where-Object { [string](Get-RooIndustriesPropertyValue $_ 'ruleId' '') -eq $ruleId })
    Set-RooIndustriesProcessPolicyObjectProperty $previewState 'preview' $ruleEntries
    return $previewState
}

function Get-LifecycleControlValue {
    param(
        [object]$State,
        [string]$Control
    )
    switch ($Control) {
        'priorityClass' { return Get-RooIndustriesPropertyValue $State 'priorityClass' $null }
        'affinityMask' { return Get-RooIndustriesPropertyValue $State 'affinityMask' $null }
        'ioPriority' { return Get-RooIndustriesPropertyValue $State 'ioPriority' $null }
        'gpuPriority' { return Get-RooIndustriesPropertyValue $State 'gpuPriority' $null }
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
        ruleId = [string](Get-RooIndustriesPropertyValue $Rule 'id' '')
        targetProcess = (New-RooIndustriesProcessPolicyTargetIdentity $Entry)
        processId = [int](Get-RooIndustriesPropertyValue $Entry 'processId' 0)
        processName = [string](Get-RooIndustriesPropertyValue $Entry 'processName' '')
        executablePath = Get-RooIndustriesPropertyValue $Entry 'executablePath' $null
        publisher = Get-RooIndustriesPropertyValue $Entry 'publisher' $null
        startTimeUtc = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Entry 'currentState' $null) 'startTimeUtc' $null
        protectionCategory = [string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Entry 'currentState' $null) 'category' (Get-RooIndustriesPropertyValue $Rule 'protectionCategory' 'unknown'))
        originalPriorityClass = Get-RooIndustriesPropertyValue $OriginalState 'priorityClass' $null
        proposedPriorityClass = Get-RooIndustriesPropertyValue $Entry 'proposedPriorityClass' $null
        originalAffinityMask = Get-RooIndustriesPropertyValue $OriginalState 'affinityMask' $null
        proposedAffinityMask = Get-RooIndustriesPropertyValue $Entry 'proposedAffinityMask' $null
        originalIoPriority = Get-RooIndustriesPropertyValue $OriginalState 'ioPriority' $null
        proposedIoPriority = Get-RooIndustriesPropertyValue $Entry 'proposedIoPriority' $null
        originalGpuPriority = Get-RooIndustriesPropertyValue $OriginalState 'gpuPriority' $null
        proposedGpuPriority = Get-RooIndustriesPropertyValue $Entry 'proposedGpuPriority' $null
        controlChanges = @(Get-RooIndustriesArray $Changes)
        capturedAtUtc = Get-RooIndustriesUtcStamp
        reason = [string](Get-RooIndustriesPropertyValue $Entry 'reason' (Get-RooIndustriesPropertyValue $Rule 'reason' 'Persistent process policy rule.'))
    }
}

function Add-LifecycleActiveEffect {
    param(
        [object]$Rule,
        [object]$Effect
    )
    $effectKey = "$([int](Get-RooIndustriesPropertyValue $Effect 'processId' 0))|$([string](Get-RooIndustriesPropertyValue $Effect 'processName' ''))|$([string](Get-RooIndustriesPropertyValue $Effect 'executablePath' ''))|$([string](Get-RooIndustriesPropertyValue $Effect 'startTimeUtc' ''))"
    $effects = New-Object System.Collections.Generic.List[object]
    foreach ($existing in @(Get-RooIndustriesPropertyArray $Rule 'activeEffects')) {
        $existingKey = "$([int](Get-RooIndustriesPropertyValue $existing 'processId' 0))|$([string](Get-RooIndustriesPropertyValue $existing 'processName' ''))|$([string](Get-RooIndustriesPropertyValue $existing 'executablePath' ''))|$([string](Get-RooIndustriesPropertyValue $existing 'startTimeUtc' ''))"
        if ($existingKey -ne $effectKey) { $effects.Add($existing) | Out-Null }
    }
    $effects.Add($Effect) | Out-Null
    Set-RooIndustriesProcessPolicyObjectProperty $Rule 'activeEffects' @($effects.ToArray())
}

function Add-LifecycleBackupPath {
    param(
        [object]$Rule,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($existing in @(Get-RooIndustriesPropertyArray $Rule 'backupManifestPaths')) {
        if (-not $paths.Contains([string]$existing)) { $paths.Add([string]$existing) | Out-Null }
    }
    if (-not $paths.Contains($Path)) { $paths.Add($Path) | Out-Null }
    Set-RooIndustriesProcessPolicyObjectProperty $Rule 'backupManifestPaths' @($paths.ToArray())
}

function New-LifecyclePreviewAuditRows {
    param(
        [object]$Rule,
        [object[]]$PreviewEntries,
        [string]$Outcome,
        [string]$ActionName = 'preview'
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $ruleId = [string](Get-RooIndustriesPropertyValue $Rule 'id' '')
    $restraint = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Rule 'requestedControls' $null) 'restraint' $null
    foreach ($entry in @(Get-RooIndustriesArray $PreviewEntries)) {
        $category = [string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'category' (Get-RooIndustriesPropertyValue $Rule 'protectionCategory' 'unknown'))
        if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
            $rows.Add((New-RooIndustriesProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string](Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Process policy rule was blocked.')) -ProtectionCategory $category -Outcome 'skipped' -DryRun $true)) | Out-Null
            continue
        }
        $changes = @(Get-RooIndustriesPreviewControlChanges $entry)
        if ($changes.Count -eq 0) {
            $rows.Add((New-RooIndustriesProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string](Get-RooIndustriesPropertyValue $entry 'reason' 'No process control change was needed.')) -ProtectionCategory $category -Outcome 'noChange' -DryRun $true)) | Out-Null
        } else {
            foreach ($change in $changes) {
                $rows.Add((New-RooIndustriesProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $entry -Control ([string](Get-RooIndustriesPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooIndustriesPropertyValue $change 'currentValue' $null) -AfterValue (Get-RooIndustriesPropertyValue $change 'proposedValue' $null) -Reason ([string](Get-RooIndustriesPropertyValue $change 'reason' (Get-RooIndustriesPropertyValue $entry 'reason' 'Policy preview.'))) -ProtectionCategory $category -Outcome $Outcome -DryRun $true)) | Out-Null
            }
        }
        if ($null -ne $restraint) {
            $rows.Add((New-RooIndustriesProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $entry -Control 'restraint' -BeforeValue $null -AfterValue $restraint -Reason 'Policy restraint metadata was recorded for the target.' -ProtectionCategory $category -Outcome $Outcome -DryRun $true)) | Out-Null
        }
    }
    if ($rows.Count -eq 0) {
        $rows.Add((New-RooIndustriesProcessPolicyAuditRow -Action $ActionName -RuleId $ruleId -Target $null -Control 'ruleLifecycle' -BeforeValue $null -AfterValue (Get-RooIndustriesPropertyValue $Rule 'status' $null) -Reason 'No running process matched the policy rule.' -ProtectionCategory (Get-RooIndustriesPropertyValue $Rule 'protectionCategory' 'unknown') -Outcome 'noMatch' -DryRun $true)) | Out-Null
    }
    return @($rows.ToArray())
}

function Get-LifecycleBackupPaths {
    param([object]$Rule)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($effect in @(Get-RooIndustriesPropertyArray $Rule 'activeEffects')) {
        $path = [string](Get-RooIndustriesPropertyValue $effect 'backupManifestPath' '')
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not $paths.Contains($path)) { $paths.Add($path) | Out-Null }
    }
    foreach ($pathValue in @(Get-RooIndustriesPropertyArray $Rule 'backupManifestPaths')) {
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
    $ruleId = [string](Get-RooIndustriesPropertyValue $Rule 'id' '')
    $preview = New-Object System.Collections.Generic.List[object]
    $restored = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $auditRows = New-Object System.Collections.Generic.List[object]
    $failedControlCount = 0

    foreach ($backupPath in @(Get-LifecycleBackupPaths $Rule)) {
        if (-not (Test-Path -LiteralPath $backupPath)) {
            $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $null -Control 'backupManifest' -BeforeValue $backupPath -AfterValue $null -Reason 'Backup manifest was not available for restore.' -ProtectionCategory (Get-RooIndustriesPropertyValue $Rule 'protectionCategory' 'unknown') -RestorePath $backupPath -RestoreAvailable $false -Outcome 'skipped' -DryRun (-not $ApplyRestore))) | Out-Null
            continue
        }
        $backup = Read-RooIndustriesJsonFile $backupPath
        foreach ($snapshot in @(Get-RooIndustriesPropertyArray $backup 'snapshots')) {
            if ([string](Get-RooIndustriesPropertyValue $snapshot 'ruleId' '') -ne $ruleId) { continue }
            $candidate = Get-RooIndustriesProcessPolicyLiveIdentity ([pscustomobject]@{
                processId = Get-RooIndustriesPropertyValue $snapshot 'processId' 0
                processName = Get-RooIndustriesPropertyValue $snapshot 'processName' ''
                executablePath = Get-RooIndustriesPropertyValue $snapshot 'executablePath' $null
            })
            $target = [pscustomobject]@{
                processId = Get-RooIndustriesPropertyValue $snapshot 'processId' $null
                processName = Get-RooIndustriesPropertyValue $snapshot 'processName' $null
                executablePath = Get-RooIndustriesPropertyValue $snapshot 'executablePath' $null
                publisher = Get-RooIndustriesPropertyValue $snapshot 'publisher' $null
            }
            $category = [string](Get-RooIndustriesPropertyValue $snapshot 'protectionCategory' (Get-RooIndustriesPropertyValue $Rule 'protectionCategory' 'unknown'))
            if (-not $candidate.exists -or -not $candidate.matches) {
                $reasonText = [string](Get-RooIndustriesPropertyValue $candidate 'reason' 'Process was not available for restore.')
                $skipped.Add([pscustomobject]@{
                    processId = Get-RooIndustriesPropertyValue $snapshot 'processId' $null
                    processName = Get-RooIndustriesPropertyValue $snapshot 'processName' $null
                    reason = $reasonText
                    backupManifestPath = $backupPath
                    skippedAtUtc = Get-RooIndustriesUtcStamp
                }) | Out-Null
                $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason $reasonText -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'skipped' -DryRun (-not $ApplyRestore))) | Out-Null
                continue
            }
            $currentState = Get-RooIndustriesProcessControlState ([int](Get-RooIndustriesPropertyValue $snapshot 'processId' 0)) $null
            $changes = @(Get-RooIndustriesProcessPolicyRestoreChanges $snapshot $currentState)
            $preview.Add([pscustomobject]@{
                ruleId = $ruleId
                processId = Get-RooIndustriesPropertyValue $snapshot 'processId' $null
                processName = Get-RooIndustriesPropertyValue $snapshot 'processName' $null
                executablePath = Get-RooIndustriesPropertyValue $snapshot 'executablePath' $null
                backupManifestPath = $backupPath
                controlChanges = @($changes)
                requiresConfirmation = ($changes.Count -gt 0)
                blocked = $false
            }) | Out-Null
            if ($changes.Count -eq 0) {
                $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason 'Process already matched the stored backup controls.' -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'noChange' -DryRun (-not $ApplyRestore))) | Out-Null
                continue
            }
            if (-not $ApplyRestore) {
                foreach ($change in $changes) {
                    $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control ([string](Get-RooIndustriesPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooIndustriesPropertyValue $change 'currentValue' $null) -AfterValue (Get-RooIndustriesPropertyValue $change 'proposedValue' $null) -Reason ([string](Get-RooIndustriesPropertyValue $change 'reason' 'Restore process controls.')) -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'confirmationRequired' -DryRun $true)) | Out-Null
                }
                continue
            }
            $appliedControls = New-Object System.Collections.Generic.List[object]
            foreach ($change in $changes) {
                try {
                    Invoke-RooIndustriesProcessControlChange $candidate.process $change
                    $appliedControls.Add($change) | Out-Null
                    $afterState = Get-RooIndustriesProcessControlState ([int](Get-RooIndustriesPropertyValue $snapshot 'processId' 0)) $null
                    $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control ([string](Get-RooIndustriesPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooIndustriesPropertyValue $change 'currentValue' $null) -AfterValue (Get-LifecycleControlValue $afterState ([string](Get-RooIndustriesPropertyValue $change 'control' ''))) -Reason ([string](Get-RooIndustriesPropertyValue $change 'reason' 'Restore process controls.')) -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'restored' -DryRun $false)) | Out-Null
                } catch {
                    $failedControlCount++
                    $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'restore' -RuleId $ruleId -Target $target -Control ([string](Get-RooIndustriesPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooIndustriesPropertyValue $change 'currentValue' $null) -AfterValue (Get-RooIndustriesPropertyValue $change 'currentValue' $null) -Reason $_.Exception.Message -ProtectionCategory $category -RestorePath $backupPath -RestoreAvailable $true -Outcome 'failed' -DryRun $false)) | Out-Null
                }
            }
            if ($appliedControls.Count -gt 0) {
                $afterControls = Get-RooIndustriesProcessControlState ([int](Get-RooIndustriesPropertyValue $snapshot 'processId' 0)) $null
                $restored.Add([pscustomobject]@{
                    processId = Get-RooIndustriesPropertyValue $snapshot 'processId' $null
                    processName = Get-RooIndustriesPropertyValue $snapshot 'processName' $null
                    executablePath = Get-RooIndustriesPropertyValue $snapshot 'executablePath' $null
                    restoredPriorityClass = Get-RooIndustriesPropertyValue $afterControls 'priorityClass' $null
                    restoredAffinityMask = Get-RooIndustriesPropertyValue $afterControls 'affinityMask' $null
                    restoredIoPriority = Get-RooIndustriesPropertyValue $afterControls 'ioPriority' $null
                    restoredGpuPriority = Get-RooIndustriesPropertyValue $afterControls 'gpuPriority' $null
                    restoredControls = @($appliedControls.ToArray())
                    backupManifestPath = $backupPath
                    restoredAtUtc = Get-RooIndustriesUtcStamp
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
    $resolvedRoot = Resolve-RooIndustriesProcessPolicyRuntimeStateRoot $StateRoot
    $envelope = [pscustomobject]@{
        actionId = "performance.policy.rule.$Action"
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        action = $Action
        status = $Status
        dryRun = (-not $ConfirmApply)
        stateRoot = $resolvedRoot
        ruleStorePath = Get-RooIndustriesProcessPolicyRuleStorePath $StateRoot
        auditPath = Get-RooIndustriesProcessPolicyAuditPath $StateRoot
        capturedAtUtc = Get-RooIndustriesUtcStamp
        ruleId = if ($Rule) { [string](Get-RooIndustriesPropertyValue $Rule 'id' '') } elseif (-not [string]::IsNullOrWhiteSpace($RuleId)) { $RuleId } else { $null }
        rule = $Rule
        rules = @(Get-RooIndustriesArray $Rules)
        preview = @(Get-RooIndustriesArray $Preview)
        changedItems = @(Get-RooIndustriesArray $ChangedItems)
        restoredItems = @(Get-RooIndustriesArray $RestoredItems)
        skippedItems = @(Get-RooIndustriesArray $SkippedItems)
        backup = $Backup
        auditRows = @(Get-RooIndustriesArray $AuditRows)
        warnings = @(Get-RooIndustriesArray $Warnings)
        errors = @(Get-RooIndustriesArray $Errors)
    }
    Write-RooIndustriesJsonOutput $envelope $OutputPath
}

try {
    $context = Get-LifecycleProfileContext
    switch ($Action) {
        'preview' {
            $resolved = Get-LifecycleRule
            $rule = $resolved.rule
            Set-RooIndustriesProcessPolicyObjectProperty $rule 'status' 'previewed'
            Set-RooIndustriesProcessPolicyObjectProperty $rule 'removed' $false
            Set-LifecycleRuleTimestamp $rule 'previewedAtUtc'
            $previewState = Get-LifecyclePreview -Rule $rule -Context $context
            $previewEntries = @(Get-RooIndustriesPropertyArray $previewState 'preview')
            $changeCount = 0
            foreach ($entry in $previewEntries) { $changeCount += @(Get-RooIndustriesPreviewControlChanges $entry).Count }
            Set-RooIndustriesProcessPolicyObjectProperty $rule 'lastPreview' ([pscustomobject]@{
                capturedAtUtc = Get-RooIndustriesPropertyValue $previewState 'capturedAtUtc' $null
                processCount = [int](Get-RooIndustriesPropertyValue $previewState 'processCount' 0)
                matchedProcessCount = $previewEntries.Count
                changeCount = $changeCount
            })
            Set-RooIndustriesProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            $auditRows = @(New-LifecyclePreviewAuditRows -Rule $rule -PreviewEntries $previewEntries -Outcome 'previewed' -ActionName 'preview')
            Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
            Write-LifecycleOutput -Status 'previewed' -Rule $rule -Preview $previewEntries -AuditRows $auditRows
        }
        'approve' {
            $resolved = Get-LifecycleRule -RequireStored
            $rule = $resolved.rule
            $beforeStatus = [string](Get-RooIndustriesPropertyValue $rule 'status' $null)
            if ([bool](Get-RooIndustriesPropertyValue $rule 'removed' $false)) {
                throw "Process policy rule '$([string](Get-RooIndustriesPropertyValue $rule 'id' ''))' has been removed."
            }
            $approver = if ([string]::IsNullOrWhiteSpace($ApprovedBy)) { $CreatedBy } else { $ApprovedBy }
            Set-RooIndustriesProcessPolicyObjectProperty $rule 'status' 'approved'
            Set-RooIndustriesProcessPolicyObjectProperty $rule 'approval' ([pscustomobject]@{
                decision = 'approved'
                approvedBy = $approver
                approvedAtUtc = Get-RooIndustriesUtcStamp
                reason = if ([string]::IsNullOrWhiteSpace($Reason)) { 'Approved for confirmed process policy application.' } else { $Reason }
            })
            Set-LifecycleRuleTimestamp $rule 'approvedAtUtc'
            Set-RooIndustriesProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            $auditRows = @((New-RooIndustriesProcessPolicyAuditRow -Action 'approve' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue $beforeStatus -AfterValue 'approved' -Reason (Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $rule 'approval' $null) 'reason' '') -ProtectionCategory (Get-RooIndustriesPropertyValue $rule 'protectionCategory' 'unknown') -Outcome 'approved' -DryRun $false))
            Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
            Write-LifecycleOutput -Status 'approved' -Rule $rule -AuditRows $auditRows
        }
        'apply' {
            $resolved = Get-LifecycleRule -RequireStored
            $rule = $resolved.rule
            $approval = Get-RooIndustriesPropertyValue $rule 'approval' $null
            if ([bool](Get-RooIndustriesPropertyValue $rule 'removed' $false)) {
                throw "Process policy rule '$([string](Get-RooIndustriesPropertyValue $rule 'id' ''))' has been removed."
            }
            if ([string](Get-RooIndustriesPropertyValue $approval 'decision' '') -ne 'approved') {
                $auditRows = @((New-RooIndustriesProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue (Get-RooIndustriesPropertyValue $rule 'status' $null) -AfterValue (Get-RooIndustriesPropertyValue $rule 'status' $null) -Reason 'Rule approval is required before apply.' -ProtectionCategory (Get-RooIndustriesPropertyValue $rule 'protectionCategory' 'unknown') -Outcome 'approvalRequired' -DryRun $true))
                Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
                Write-LifecycleOutput -Status 'approvalRequired' -Rule $rule -AuditRows $auditRows
                exit 1
            }
            $previewState = Get-LifecyclePreview -Rule $rule -Context $context
            $previewEntries = @(Get-RooIndustriesPropertyArray $previewState 'preview')
            if (-not $ConfirmApply) {
                $auditRows = @(New-LifecyclePreviewAuditRows -Rule $rule -PreviewEntries $previewEntries -Outcome 'confirmationRequired' -ActionName 'apply')
                Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
                Write-LifecycleOutput -Status 'confirmationRequired' -Rule $rule -Preview $previewEntries -AuditRows $auditRows -Warnings @((New-RooIndustriesIssue 'PROCESS_POLICY_RULE_CONFIRM_REQUIRED' 'Apply requires -ConfirmApply after approval.' 'info' 'performance.policy' ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) $false 'Rerun with -ConfirmApply against a safe runtime state root and allow-listed process path.' $null))
                exit 0
            }

            $profileForRule = New-RooIndustriesProcessPolicyProfileForRule -Profile $context.profile -StoredRule $rule
            $ruleForProfile = ConvertTo-RooIndustriesProcessPolicyRuleForProfile $rule
            $eligible = New-Object System.Collections.Generic.List[object]
            $changedItems = New-Object System.Collections.Generic.List[object]
            $skippedItems = New-Object System.Collections.Generic.List[object]
            $auditRows = New-Object System.Collections.Generic.List[object]
            foreach ($entry in $previewEntries) {
                $category = [string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'category' (Get-RooIndustriesPropertyValue $rule 'protectionCategory' 'unknown'))
                if ([bool](Get-RooIndustriesPropertyValue $entry 'blocked' $false)) {
                    $reasonText = [string](Get-RooIndustriesPropertyValue $entry 'blockedReason' 'Policy target is protected.')
                    $skippedItems.Add((New-RooIndustriesProcessPolicySkippedItem $entry $reasonText 0)) | Out-Null
                    $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason $reasonText -ProtectionCategory $category -Outcome 'skipped' -DryRun $false)) | Out-Null
                    continue
                }
                $changes = @(Get-RooIndustriesPreviewControlChanges $entry)
                if ($changes.Count -eq 0) {
                    $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string](Get-RooIndustriesPropertyValue $entry 'reason' 'No process control change was needed.')) -ProtectionCategory $category -Outcome 'noChange' -DryRun $false)) | Out-Null
                    continue
                }
                $safety = Test-RooIndustriesProcessPolicyConfirmedAllowed $entry $ruleForProfile $profileForRule
                if (-not $safety.allowed) {
                    $skippedItems.Add((New-RooIndustriesProcessPolicySkippedItem $entry ([string]$safety.reason) 0)) | Out-Null
                    $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string]$safety.reason) -ProtectionCategory $category -Outcome 'skipped' -DryRun $false)) | Out-Null
                    continue
                }
                $identity = Get-RooIndustriesProcessPolicyLiveIdentity $entry
                if (-not $identity.exists -or -not $identity.matches) {
                    $skippedItems.Add((New-RooIndustriesProcessPolicySkippedItem $entry ([string]$identity.reason) 0)) | Out-Null
                    $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $entry -Control 'processControls' -BeforeValue $null -AfterValue $null -Reason ([string]$identity.reason) -ProtectionCategory $category -Outcome 'skipped' -DryRun $false)) | Out-Null
                    continue
                }
                $processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
                $originalState = Get-RooIndustriesProcessControlState $processId $null
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
                $backupInfo = New-RooIndustriesProcessPolicyRuleBackupManifest -StateRoot $StateRoot -Rule $rule -ActionId 'performance.policy.rule.apply' -Snapshots @($eligible | ForEach-Object { $_.snapshot })
                Add-LifecycleBackupPath -Rule $rule -Path $backupInfo.path
            }

            foreach ($item in @($eligible.ToArray())) {
                $entry = $item.entry
                $processId = [int](Get-RooIndustriesPropertyValue $entry 'processId' 0)
                $appliedControls = New-Object System.Collections.Generic.List[object]
                foreach ($change in @(Get-RooIndustriesArray $item.changes)) {
                    try {
                        Invoke-RooIndustriesProcessControlChange $item.identity.process $change
                        $appliedControls.Add($change) | Out-Null
                        $afterState = Get-RooIndustriesProcessControlState $processId $null
                        $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $entry -Control ([string](Get-RooIndustriesPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooIndustriesPropertyValue $change 'currentValue' $null) -AfterValue (Get-LifecycleControlValue $afterState ([string](Get-RooIndustriesPropertyValue $change 'control' ''))) -Reason ([string](Get-RooIndustriesPropertyValue $change 'reason' (Get-RooIndustriesPropertyValue $entry 'reason' 'Apply process controls.'))) -ProtectionCategory ([string]$item.protectionCategory) -RestorePath $backupInfo.path -RestoreAvailable $true -Outcome 'applied' -DryRun $false)) | Out-Null
                    } catch {
                        $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'apply' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $entry -Control ([string](Get-RooIndustriesPropertyValue $change 'control' 'processControls')) -BeforeValue (Get-RooIndustriesPropertyValue $change 'currentValue' $null) -AfterValue (Get-RooIndustriesPropertyValue $change 'currentValue' $null) -Reason $_.Exception.Message -ProtectionCategory ([string]$item.protectionCategory) -RestorePath $backupInfo.path -RestoreAvailable $true -Outcome 'failed' -DryRun $false)) | Out-Null
                    }
                }
                if ($appliedControls.Count -gt 0) {
                    $appliedState = Get-RooIndustriesProcessControlState $processId $null
                    $changed = New-RooIndustriesProcessPolicyChangedItem $entry $item.originalState $appliedState @($appliedControls.ToArray()) 0
                    $changedItems.Add($changed) | Out-Null
                    Add-LifecycleActiveEffect -Rule $rule -Effect ([pscustomobject]@{
                        processId = $processId
                        processName = Get-RooIndustriesPropertyValue $entry 'processName' ''
                        executablePath = Get-RooIndustriesPropertyValue $entry 'executablePath' $null
                        startTimeUtc = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $entry 'currentState' $null) 'startTimeUtc' $null
                        ruleId = Get-RooIndustriesPropertyValue $rule 'id' ''
                        backupManifestPath = $backupInfo.path
                        backupSnapshotId = Get-RooIndustriesPropertyValue $item.snapshot 'snapshotId' ''
                        appliedControls = @($appliedControls.ToArray())
                        appliedAtUtc = Get-RooIndustriesUtcStamp
                    })
                }
            }

            if ($changedItems.Count -gt 0) {
                Set-RooIndustriesProcessPolicyObjectProperty $rule 'status' 'applied'
                Set-LifecycleRuleTimestamp $rule 'appliedAtUtc'
            }
            Set-RooIndustriesProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows @($auditRows.ToArray()) | Out-Null
            $status = if ($changedItems.Count -gt 0 -and $skippedItems.Count -gt 0) { 'partial' } elseif ($changedItems.Count -gt 0) { 'applied' } elseif ($skippedItems.Count -gt 0) { 'skipped' } else { 'noChange' }
            Write-LifecycleOutput -Status $status -Rule $rule -Preview $previewEntries -ChangedItems @($changedItems.ToArray()) -SkippedItems @($skippedItems.ToArray()) -Backup $(if ($backupInfo) { $backupInfo.manifest } else { $null }) -AuditRows @($auditRows.ToArray())
        }
        'status' {
            $store = Read-RooIndustriesProcessPolicyRuleStore $StateRoot
            $rules = if ([string]::IsNullOrWhiteSpace($RuleId)) {
                @(Get-RooIndustriesPropertyArray $store 'rules')
            } else {
                @((Get-RooIndustriesProcessPolicyStoredRule $StateRoot $RuleId))
            }
            $rules = @($rules | Where-Object { $null -ne $_ })
            $auditRows = New-Object System.Collections.Generic.List[object]
            foreach ($rule in $rules) {
                $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'status' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue $null -AfterValue (Get-RooIndustriesPropertyValue $rule 'status' $null) -Reason 'Rule lifecycle status was queried.' -ProtectionCategory (Get-RooIndustriesPropertyValue $rule 'protectionCategory' 'unknown') -RestoreAvailable (@(Get-RooIndustriesPropertyArray $rule 'backupManifestPaths').Count -gt 0) -Outcome 'reported' -DryRun $true)) | Out-Null
            }
            if ($auditRows.Count -eq 0) {
                $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'status' -RuleId $RuleId -Target $null -Control 'ruleLifecycle' -BeforeValue $null -AfterValue $null -Reason 'No process policy rule matched the status query.' -ProtectionCategory 'unknown' -Outcome 'notFound' -DryRun $true)) | Out-Null
            }
            Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows @($auditRows.ToArray()) | Out-Null
            Write-LifecycleOutput -Status 'reported' -Rules $rules -AuditRows @($auditRows.ToArray())
        }
        'restore' {
            $resolved = Get-LifecycleRule -RequireStored
            $rule = $resolved.rule
            $restore = Invoke-LifecycleRestore -Rule $rule -ApplyRestore:$ConfirmApply
            if ($ConfirmApply -and [int](Get-RooIndustriesPropertyValue $restore 'failedControlCount' 0) -eq 0) {
                Set-RooIndustriesProcessPolicyObjectProperty $rule 'activeEffects' @()
                Set-RooIndustriesProcessPolicyObjectProperty $rule 'status' 'restored'
                Set-LifecycleRuleTimestamp $rule 'restoredAtUtc'
                Set-RooIndustriesProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            }
            Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows @(Get-RooIndustriesPropertyArray $restore 'auditRows') | Out-Null
            $status = if (-not $ConfirmApply) { 'confirmationRequired' } elseif ([int](Get-RooIndustriesPropertyValue $restore 'failedControlCount' 0) -gt 0) { 'partial' } else { 'restored' }
            Write-LifecycleOutput -Status $status -Rule $rule -Preview @(Get-RooIndustriesPropertyArray $restore 'preview') -RestoredItems @(Get-RooIndustriesPropertyArray $restore 'restoredItems') -SkippedItems @(Get-RooIndustriesPropertyArray $restore 'skippedItems') -AuditRows @(Get-RooIndustriesPropertyArray $restore 'auditRows')
        }
        'remove' {
            $resolved = Get-LifecycleRule -RequireStored
            $rule = $resolved.rule
            $activeCount = @(Get-RooIndustriesPropertyArray $rule 'activeEffects').Count
            if ($activeCount -gt 0 -and -not $ConfirmApply) {
                $restorePreview = Invoke-LifecycleRestore -Rule $rule
                $auditRows = @(Get-RooIndustriesPropertyArray $restorePreview 'auditRows')
                $auditRows += (New-RooIndustriesProcessPolicyAuditRow -Action 'remove' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue (Get-RooIndustriesPropertyValue $rule 'status' $null) -AfterValue (Get-RooIndustriesPropertyValue $rule 'status' $null) -Reason 'Remove requires restore confirmation while active effects exist.' -ProtectionCategory (Get-RooIndustriesPropertyValue $rule 'protectionCategory' 'unknown') -RestoreAvailable $true -Outcome 'confirmationRequired' -DryRun $true)
                Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows $auditRows | Out-Null
                Write-LifecycleOutput -Status 'confirmationRequired' -Rule $rule -Preview @(Get-RooIndustriesPropertyArray $restorePreview 'preview') -SkippedItems @(Get-RooIndustriesPropertyArray $restorePreview 'skippedItems') -AuditRows $auditRows
                exit 0
            }
            $restoreResult = $null
            $auditRows = New-Object System.Collections.Generic.List[object]
            if ($activeCount -gt 0) {
                $restoreResult = Invoke-LifecycleRestore -Rule $rule -ApplyRestore:$ConfirmApply
                foreach ($row in @(Get-RooIndustriesPropertyArray $restoreResult 'auditRows')) { $auditRows.Add($row) | Out-Null }
                if ([int](Get-RooIndustriesPropertyValue $restoreResult 'failedControlCount' 0) -gt 0) {
                    Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows @($auditRows.ToArray()) | Out-Null
                    Write-LifecycleOutput -Status 'partial' -Rule $rule -RestoredItems @(Get-RooIndustriesPropertyArray $restoreResult 'restoredItems') -SkippedItems @(Get-RooIndustriesPropertyArray $restoreResult 'skippedItems') -AuditRows @($auditRows.ToArray())
                    exit 1
                }
            }
            $beforeStatus = [string](Get-RooIndustriesPropertyValue $rule 'status' $null)
            Set-RooIndustriesProcessPolicyObjectProperty $rule 'activeEffects' @()
            Set-RooIndustriesProcessPolicyObjectProperty $rule 'status' 'removed'
            Set-RooIndustriesProcessPolicyObjectProperty $rule 'removed' $true
            Set-LifecycleRuleTimestamp $rule 'removedAtUtc'
            Set-RooIndustriesProcessPolicyStoredRule -StateRoot $StateRoot -Rule $rule | Out-Null
            $auditRows.Add((New-RooIndustriesProcessPolicyAuditRow -Action 'remove' -RuleId ([string](Get-RooIndustriesPropertyValue $rule 'id' '')) -Target $null -Control 'ruleLifecycle' -BeforeValue $beforeStatus -AfterValue 'removed' -Reason $(if ([string]::IsNullOrWhiteSpace($Reason)) { 'Rule was tombstoned after active effects were restored or found inactive.' } else { $Reason }) -ProtectionCategory (Get-RooIndustriesPropertyValue $rule 'protectionCategory' 'unknown') -RestoreAvailable $false -Outcome 'removed' -DryRun $false)) | Out-Null
            Add-RooIndustriesProcessPolicyAuditRows -StateRoot $StateRoot -Rows @($auditRows.ToArray()) | Out-Null
            Write-LifecycleOutput -Status 'removed' -Rule $rule -RestoredItems @(if ($restoreResult) { Get-RooIndustriesPropertyArray $restoreResult 'restoredItems' } else { @() }) -SkippedItems @(if ($restoreResult) { Get-RooIndustriesPropertyArray $restoreResult 'skippedItems' } else { @() }) -AuditRows @($auditRows.ToArray())
        }
    }
} catch {
    $issue = New-RooIndustriesIssue 'PROCESS_POLICY_RULE_LIFECYCLE_FAILED' $_.Exception.Message 'error' 'performance.policy' $RuleId $true 'Review the rule id, profile path, runtime state root, and confirmation flags.' $null
    Write-LifecycleOutput -Status 'failed' -Errors @($issue)
    exit 1
}
