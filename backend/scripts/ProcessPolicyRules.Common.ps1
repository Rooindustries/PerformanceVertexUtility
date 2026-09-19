if (-not (Get-Command Get-RooIndustriesProcessPolicyPreview -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ProcessPolicy.Common.ps1')
}

$script:RooIndustriesProcessPolicyRuleStoreFolderName = 'process-policy-rules'
$script:RooIndustriesProcessPolicyAuditFolderName = 'process-policy-audit'
$script:RooIndustriesProcessPolicyRuleBackupFolderName = 'process-policy-rule-backups'

function Resolve-RooIndustriesProcessPolicyRuntimeStateRoot {
    param([string]$StateRoot)
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        return Resolve-RooIndustriesPath $StateRoot $StateRoot
    }
    $envRoot = [Environment]::GetEnvironmentVariable('ROO_INDUSTRIES_PROCESS_POLICY_STATE_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        return [System.IO.Path]::GetFullPath($envRoot)
    }
    return [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) 'roo-industries-optimization-suite\process-policy-runtime'))
}

function Get-RooIndustriesProcessPolicyRuleStorePath {
    param([string]$StateRoot)
    return Join-Path (Join-Path (Resolve-RooIndustriesProcessPolicyRuntimeStateRoot $StateRoot) $script:RooIndustriesProcessPolicyRuleStoreFolderName) 'rules.json'
}

function Get-RooIndustriesProcessPolicyAuditPath {
    param([string]$StateRoot)
    return Join-Path (Join-Path (Resolve-RooIndustriesProcessPolicyRuntimeStateRoot $StateRoot) $script:RooIndustriesProcessPolicyAuditFolderName) 'audit.jsonl'
}

function Get-RooIndustriesProcessPolicyRuleBackupRoot {
    param([string]$StateRoot)
    return Join-Path (Resolve-RooIndustriesProcessPolicyRuntimeStateRoot $StateRoot) $script:RooIndustriesProcessPolicyRuleBackupFolderName
}

function Set-RooIndustriesProcessPolicyObjectProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )
    if ($null -eq $Object) { return }
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Read-RooIndustriesProcessPolicyRuleStore {
    param([string]$StateRoot)
    $path = Get-RooIndustriesProcessPolicyRuleStorePath $StateRoot
    if (Test-Path -LiteralPath $path) {
        $store = Read-RooIndustriesJsonFile $path
        if ($null -eq $store.PSObject.Properties['rules']) {
            Set-RooIndustriesProcessPolicyObjectProperty $store 'rules' @()
        }
        return $store
    }
    return [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        storeId = 'process-policy-rule-store'
        createdAtUtc = Get-RooIndustriesUtcStamp
        updatedAtUtc = $null
        rules = @()
    }
}

function Write-RooIndustriesProcessPolicyRuleStore {
    param(
        [string]$StateRoot,
        [object]$Store
    )
    Set-RooIndustriesProcessPolicyObjectProperty $Store 'updatedAtUtc' (Get-RooIndustriesUtcStamp)
    Write-RooIndustriesProcessPolicyJsonFile $Store (Get-RooIndustriesProcessPolicyRuleStorePath $StateRoot)
}

function Get-RooIndustriesProcessPolicyStoredRule {
    param(
        [string]$StateRoot,
        [string]$RuleId
    )
    $store = Read-RooIndustriesProcessPolicyRuleStore $StateRoot
    foreach ($rule in @(Get-RooIndustriesPropertyArray $store 'rules')) {
        if ([string](Get-RooIndustriesPropertyValue $rule 'id' '') -eq $RuleId -or [string](Get-RooIndustriesPropertyValue $rule 'ruleId' '') -eq $RuleId) {
            return $rule
        }
    }
    return $null
}

function Set-RooIndustriesProcessPolicyStoredRule {
    param(
        [string]$StateRoot,
        [object]$Rule
    )
    $store = Read-RooIndustriesProcessPolicyRuleStore $StateRoot
    $ruleId = [string](Get-RooIndustriesPropertyValue $Rule 'id' (Get-RooIndustriesPropertyValue $Rule 'ruleId' ''))
    $rules = New-Object System.Collections.Generic.List[object]
    $replaced = $false
    foreach ($existing in @(Get-RooIndustriesPropertyArray $store 'rules')) {
        $existingId = [string](Get-RooIndustriesPropertyValue $existing 'id' (Get-RooIndustriesPropertyValue $existing 'ruleId' ''))
        if ($existingId -eq $ruleId) {
            $rules.Add($Rule) | Out-Null
            $replaced = $true
        } else {
            $rules.Add($existing) | Out-Null
        }
    }
    if (-not $replaced) { $rules.Add($Rule) | Out-Null }
    Set-RooIndustriesProcessPolicyObjectProperty $store 'rules' @($rules.ToArray())
    Write-RooIndustriesProcessPolicyRuleStore $StateRoot $store
    return $store
}

function Get-RooIndustriesProcessPolicyRuleControlValue {
    param(
        [object]$Controls,
        [string]$Name,
        [string[]]$Aliases = @()
    )
    $value = Get-RooIndustriesPropertyValue $Controls $Name $null
    if ($null -ne $value) { return $value }
    foreach ($alias in @(Get-RooIndustriesArray $Aliases)) {
        $value = Get-RooIndustriesPropertyValue $Controls ([string]$alias) $null
        if ($null -ne $value) { return $value }
    }
    return $null
}

function ConvertTo-RooIndustriesProcessPolicyStoredRule {
    param(
        [object]$Rule,
        [string]$CreatedBy = 'local-user',
        [object]$ExistingRule = $null
    )
    $ruleId = [string](Get-RooIndustriesPropertyValue $Rule 'id' (Get-RooIndustriesPropertyValue $Rule 'ruleId' ''))
    if ([string]::IsNullOrWhiteSpace($ruleId)) {
        throw 'Process policy rule requires an id or ruleId.'
    }
    $match = Get-RooIndustriesPropertyValue $Rule 'match' $Rule
    $controls = Get-RooIndustriesPropertyValue $Rule 'requestedControls' (Get-RooIndustriesPropertyValue $Rule 'controls' $null)
    if ($null -eq $controls) { $controls = [pscustomobject]@{} }
    $now = Get-RooIndustriesUtcStamp
    $existingTimestamps = Get-RooIndustriesPropertyValue $ExistingRule 'timestamps' $null
    $existingApproval = Get-RooIndustriesPropertyValue $ExistingRule 'approval' $null
    $createdAt = Get-RooIndustriesPropertyValue $existingTimestamps 'createdAtUtc' (Get-RooIndustriesPropertyValue $Rule 'createdAtUtc' $now)

    return [pscustomobject]@{
        schemaVersion = 1
        id = $ruleId
        ruleId = $ruleId
        match = [pscustomobject]@{
            processNames = @(Get-RooIndustriesPropertyArray $match 'processNames') + @(Get-RooIndustriesPropertyArray $match 'names')
            namePatterns = @(Get-RooIndustriesPropertyArray $match 'namePatterns')
            pathPatterns = @(Get-RooIndustriesPropertyArray $match 'pathPatterns')
            publisherNames = @(Get-RooIndustriesPropertyArray $match 'publisherNames') + @(Get-RooIndustriesPropertyArray $match 'publishers')
            publisherPatterns = @(Get-RooIndustriesPropertyArray $match 'publisherPatterns')
            processCategories = @(Get-RooIndustriesPropertyArray $match 'processCategories') + @(Get-RooIndustriesPropertyArray $match 'categories')
            commandLinePatterns = @(Get-RooIndustriesPropertyArray $match 'commandLinePatterns')
            excludeProcessNames = @(Get-RooIndustriesPropertyArray $match 'excludeProcessNames')
            excludeNamePatterns = @(Get-RooIndustriesPropertyArray $match 'excludeNamePatterns')
            excludePathPatterns = @(Get-RooIndustriesPropertyArray $match 'excludePathPatterns')
            excludePublisherNames = @(Get-RooIndustriesPropertyArray $match 'excludePublisherNames')
            excludePublisherPatterns = @(Get-RooIndustriesPropertyArray $match 'excludePublisherPatterns')
            excludeProcessCategories = @(Get-RooIndustriesPropertyArray $match 'excludeProcessCategories')
            excludeCommandLinePatterns = @(Get-RooIndustriesPropertyArray $match 'excludeCommandLinePatterns')
        }
        requestedControls = [pscustomobject]@{
            priorityClass = Get-RooIndustriesProcessPolicyRuleControlValue $controls 'priorityClass' @('priority')
            affinityMask = Get-RooIndustriesProcessPolicyRuleControlValue $controls 'affinityMask' @('affinity')
            ioPriority = Get-RooIndustriesProcessPolicyRuleControlValue $controls 'ioPriority' @('io')
            gpuPriority = Get-RooIndustriesProcessPolicyRuleControlValue $controls 'gpuPriority' @('gpu')
            restraint = Get-RooIndustriesProcessPolicyRuleControlValue $controls 'restraint' @('restraintMode')
        }
        protectionCategory = [string](Get-RooIndustriesPropertyValue $Rule 'protectionCategory' (Get-RooIndustriesPropertyValue $Rule 'category' 'backgroundApp'))
        createdBy = [string](Get-RooIndustriesPropertyValue $Rule 'createdBy' $CreatedBy)
        status = [string](Get-RooIndustriesPropertyValue $ExistingRule 'status' 'previewed')
        timestamps = [pscustomobject]@{
            createdAtUtc = $createdAt
            updatedAtUtc = $now
            previewedAtUtc = Get-RooIndustriesPropertyValue $existingTimestamps 'previewedAtUtc' $null
            approvedAtUtc = Get-RooIndustriesPropertyValue $existingTimestamps 'approvedAtUtc' $null
            appliedAtUtc = Get-RooIndustriesPropertyValue $existingTimestamps 'appliedAtUtc' $null
            restoredAtUtc = Get-RooIndustriesPropertyValue $existingTimestamps 'restoredAtUtc' $null
            removedAtUtc = Get-RooIndustriesPropertyValue $existingTimestamps 'removedAtUtc' $null
        }
        approval = $existingApproval
        allowConfirmedApply = [bool](Get-RooIndustriesPropertyValue $Rule 'allowConfirmedApply' (Get-RooIndustriesPropertyValue $ExistingRule 'allowConfirmedApply' $false))
        safety = Get-RooIndustriesPropertyValue $Rule 'safety' (Get-RooIndustriesPropertyValue $ExistingRule 'safety' $null)
        reason = [string](Get-RooIndustriesPropertyValue $Rule 'reason' (Get-RooIndustriesPropertyValue $ExistingRule 'reason' 'Persistent process policy rule.'))
        reasonCodes = @(Get-RooIndustriesPropertyArray $Rule 'reasonCodes')
        tags = @(Get-RooIndustriesPropertyArray $Rule 'tags') + @(Get-RooIndustriesPropertyArray $Rule 'scenarioTags')
        risk = [string](Get-RooIndustriesPropertyValue $Rule 'risk' (Get-RooIndustriesPropertyValue $ExistingRule 'risk' 'low'))
        lastPreview = Get-RooIndustriesPropertyValue $ExistingRule 'lastPreview' $null
        activeEffects = @(Get-RooIndustriesPropertyArray $ExistingRule 'activeEffects')
        backupManifestPaths = @(Get-RooIndustriesPropertyArray $ExistingRule 'backupManifestPaths')
        removed = [bool](Get-RooIndustriesPropertyValue $ExistingRule 'removed' $false)
    }
}

function ConvertTo-RooIndustriesProcessPolicyRuleForProfile {
    param([object]$StoredRule)
    return [pscustomobject]@{
        ruleId = [string](Get-RooIndustriesPropertyValue $StoredRule 'id' '')
        enabled = (-not [bool](Get-RooIndustriesPropertyValue $StoredRule 'removed' $false))
        allowConfirmedApply = [bool](Get-RooIndustriesPropertyValue $StoredRule 'allowConfirmedApply' $false)
        safety = Get-RooIndustriesPropertyValue $StoredRule 'safety' $null
        match = Get-RooIndustriesPropertyValue $StoredRule 'match' $null
        controls = Get-RooIndustriesPropertyValue $StoredRule 'requestedControls' $null
        reason = [string](Get-RooIndustriesPropertyValue $StoredRule 'reason' 'Persistent process policy rule.')
        reasonCodes = @(Get-RooIndustriesPropertyArray $StoredRule 'reasonCodes')
        scenarioTags = @(Get-RooIndustriesPropertyArray $StoredRule 'tags')
        risk = [string](Get-RooIndustriesPropertyValue $StoredRule 'risk' 'low')
    }
}

function New-RooIndustriesProcessPolicyProfileForRule {
    param(
        [object]$Profile,
        [object]$StoredRule
    )
    $policy = Get-RooIndustriesProcessPolicyProfileRoot $Profile
    return [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        profileId = [string](Get-RooIndustriesPropertyValue $Profile 'profileId' 'persistent-policy')
        profileKind = 'persistent-process-policy'
        risk = [string](Get-RooIndustriesPropertyValue $StoredRule 'risk' (Get-RooIndustriesPropertyValue $Profile 'risk' 'medium'))
        protectedCatalogPath = Get-RooIndustriesPropertyValue $Profile 'protectedCatalogPath' 'protected-processes.json'
        policy = [pscustomobject]@{
            session = Get-RooIndustriesPropertyValue $policy 'session' $null
            safety = Get-RooIndustriesPropertyValue $policy 'safety' (Get-RooIndustriesPropertyValue $Profile 'safety' $null)
            protectedProcesses = @(Get-RooIndustriesPropertyArray $policy 'protectedProcesses')
            rules = @((ConvertTo-RooIndustriesProcessPolicyRuleForProfile $StoredRule))
        }
        protectedProcesses = @(Get-RooIndustriesPropertyArray $Profile 'protectedProcesses')
        protectedCompanions = @(Get-RooIndustriesPropertyArray $Profile 'protectedCompanions')
    }
}

function New-RooIndustriesProcessPolicyTargetIdentity {
    param([object]$Target)
    $processId = Get-RooIndustriesPropertyValue $Target 'processId' (Get-RooIndustriesPropertyValue $Target 'pid' $null)
    $processName = [string](Get-RooIndustriesPropertyValue $Target 'processName' (Get-RooIndustriesPropertyValue $Target 'name' ''))
    $path = Get-RooIndustriesPropertyValue $Target 'executablePath' $null
    $publisher = Get-RooIndustriesPropertyValue $Target 'publisher' $null
    $identity = if ($null -ne $processId -and -not [string]::IsNullOrWhiteSpace($processName)) {
        "$processName`:$processId"
    } elseif (-not [string]::IsNullOrWhiteSpace($processName)) {
        $processName
    } else {
        $null
    }
    return [pscustomobject]@{
        identity = $identity
        processId = $processId
        processName = if ([string]::IsNullOrWhiteSpace($processName)) { $null } else { $processName }
        executablePath = $path
        publisher = $publisher
    }
}

function New-RooIndustriesProcessPolicyAuditRow {
    param(
        [string]$Action,
        [string]$RuleId = $null,
        [string]$SessionId = $null,
        [object]$Target = $null,
        [string]$Control = 'ruleLifecycle',
        [object]$BeforeValue = $null,
        [object]$AfterValue = $null,
        [string]$Reason = '',
        [string]$ProtectionCategory = 'unknown',
        [string]$RestorePath = $null,
        [bool]$RestoreAvailable = $false,
        [string]$Outcome = 'recorded',
        [bool]$DryRun = $true,
        [string]$Source = 'processPolicyRuleLifecycle'
    )
    $targetIdentity = New-RooIndustriesProcessPolicyTargetIdentity $Target
    return [pscustomobject]@{
        schemaVersion = 1
        auditId = "process-policy-audit-$([guid]::NewGuid().ToString('N'))"
        timestampUtc = Get-RooIndustriesUtcStamp
        action = $Action
        source = $Source
        ruleId = $RuleId
        sessionId = $SessionId
        targetProcessIdentity = $targetIdentity.identity
        targetProcess = $targetIdentity
        control = $Control
        beforeValue = $BeforeValue
        afterValue = $AfterValue
        reason = $Reason
        protectionCategory = $ProtectionCategory
        restore = [pscustomobject]@{
            available = $RestoreAvailable
            path = $RestorePath
        }
        outcome = $Outcome
        dryRun = $DryRun
    }
}

function Add-RooIndustriesProcessPolicyAuditRows {
    param(
        [string]$StateRoot,
        [object[]]$Rows
    )
    $items = @(Get-RooIndustriesArray $Rows)
    if ($items.Count -eq 0) { return $null }
    $path = Get-RooIndustriesProcessPolicyAuditPath $StateRoot
    Ensure-RooIndustriesDirectory (Split-Path $path -Parent)
    foreach ($row in $items) {
        ($row | ConvertTo-Json -Depth 24 -Compress) | Add-Content -LiteralPath $path -Encoding UTF8
    }
    return $path
}

function Read-RooIndustriesProcessPolicyAuditRows {
    param([string]$StateRoot)
    $path = Get-RooIndustriesProcessPolicyAuditPath $StateRoot
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    foreach ($line in @(Get-Content -LiteralPath $path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $rows.Add(($line | ConvertFrom-Json)) | Out-Null } catch { }
    }
    return @($rows.ToArray())
}

function Get-RooIndustriesProcessPolicyBackupManifestPath {
    param(
        [string]$StateRoot,
        [string]$BackupId
    )
    return Join-Path (Get-RooIndustriesProcessPolicyRuleBackupRoot $StateRoot) "$BackupId.json"
}

function New-RooIndustriesProcessPolicyRuleBackupManifest {
    param(
        [string]$StateRoot,
        [object]$Rule,
        [string]$ActionId,
        [object[]]$Snapshots
    )
    $ruleId = [string](Get-RooIndustriesPropertyValue $Rule 'id' '')
    $backupId = "process-policy-rule-$ruleId-$(Get-RooIndustriesFileStamp)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $path = Get-RooIndustriesProcessPolicyBackupManifestPath $StateRoot $backupId
    $manifest = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        manifestKind = 'processControlBackupManifest'
        backupId = $backupId
        actionId = $ActionId
        ruleId = $ruleId
        createdAtUtc = Get-RooIndustriesUtcStamp
        stateRoot = Resolve-RooIndustriesProcessPolicyRuntimeStateRoot $StateRoot
        dryRun = $false
        restore = [pscustomobject]@{
            available = $true
            status = 'available'
            path = $path
        }
        snapshots = @(Get-RooIndustriesArray $Snapshots)
    }
    Write-RooIndustriesProcessPolicyJsonFile $manifest $path
    return [pscustomobject]@{
        manifest = $manifest
        path = $path
    }
}
