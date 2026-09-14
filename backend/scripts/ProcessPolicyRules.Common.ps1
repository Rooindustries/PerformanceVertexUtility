if (-not (Get-Command Get-RooProcessPolicyPreview -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ProcessPolicy.Common.ps1')
}

$script:RooProcessPolicyRuleStoreFolderName = 'process-policy-rules'
$script:RooProcessPolicyAuditFolderName = 'process-policy-audit'
$script:RooProcessPolicyRuleBackupFolderName = 'process-policy-rule-backups'

function Resolve-RooProcessPolicyRuntimeStateRoot {
    param([string]$StateRoot)
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        return Resolve-RooPath $StateRoot $StateRoot
    }
    $envRoot = [Environment]::GetEnvironmentVariable('ROO_PROCESS_POLICY_STATE_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        return [System.IO.Path]::GetFullPath($envRoot)
    }
    return [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) 'roo-optimization-suite\process-policy-runtime'))
}

function Get-RooProcessPolicyRuleStorePath {
    param([string]$StateRoot)
    return Join-Path (Join-Path (Resolve-RooProcessPolicyRuntimeStateRoot $StateRoot) $script:RooProcessPolicyRuleStoreFolderName) 'rules.json'
}

function Get-RooProcessPolicyAuditPath {
    param([string]$StateRoot)
    return Join-Path (Join-Path (Resolve-RooProcessPolicyRuntimeStateRoot $StateRoot) $script:RooProcessPolicyAuditFolderName) 'audit.jsonl'
}

function Get-RooProcessPolicyRuleBackupRoot {
    param([string]$StateRoot)
    return Join-Path (Resolve-RooProcessPolicyRuntimeStateRoot $StateRoot) $script:RooProcessPolicyRuleBackupFolderName
}

function Set-RooProcessPolicyObjectProperty {
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

function Read-RooProcessPolicyRuleStore {
    param([string]$StateRoot)
    $path = Get-RooProcessPolicyRuleStorePath $StateRoot
    if (Test-Path -LiteralPath $path) {
        $store = Read-RooJsonFile $path
        if ($null -eq $store.PSObject.Properties['rules']) {
            Set-RooProcessPolicyObjectProperty $store 'rules' @()
        }
        return $store
    }
    return [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooProcessProductName
        storeId = 'process-policy-rule-store'
        createdAtUtc = Get-RooUtcStamp
        updatedAtUtc = $null
        rules = @()
    }
}

function Write-RooProcessPolicyRuleStore {
    param(
        [string]$StateRoot,
        [object]$Store
    )
    Set-RooProcessPolicyObjectProperty $Store 'updatedAtUtc' (Get-RooUtcStamp)
    Write-RooProcessPolicyJsonFile $Store (Get-RooProcessPolicyRuleStorePath $StateRoot)
}

function Get-RooProcessPolicyStoredRule {
    param(
        [string]$StateRoot,
        [string]$RuleId
    )
    $store = Read-RooProcessPolicyRuleStore $StateRoot
    foreach ($rule in @(Get-RooPropertyArray $store 'rules')) {
        if ([string](Get-RooPropertyValue $rule 'id' '') -eq $RuleId -or [string](Get-RooPropertyValue $rule 'ruleId' '') -eq $RuleId) {
            return $rule
        }
    }
    return $null
}

function Set-RooProcessPolicyStoredRule {
    param(
        [string]$StateRoot,
        [object]$Rule
    )
    $store = Read-RooProcessPolicyRuleStore $StateRoot
    $ruleId = [string](Get-RooPropertyValue $Rule 'id' (Get-RooPropertyValue $Rule 'ruleId' ''))
    $rules = New-Object System.Collections.Generic.List[object]
    $replaced = $false
    foreach ($existing in @(Get-RooPropertyArray $store 'rules')) {
        $existingId = [string](Get-RooPropertyValue $existing 'id' (Get-RooPropertyValue $existing 'ruleId' ''))
        if ($existingId -eq $ruleId) {
            $rules.Add($Rule) | Out-Null
            $replaced = $true
        } else {
            $rules.Add($existing) | Out-Null
        }
    }
    if (-not $replaced) { $rules.Add($Rule) | Out-Null }
    Set-RooProcessPolicyObjectProperty $store 'rules' @($rules.ToArray())
    Write-RooProcessPolicyRuleStore $StateRoot $store
    return $store
}

function Get-RooProcessPolicyRuleControlValue {
    param(
        [object]$Controls,
        [string]$Name,
        [string[]]$Aliases = @()
    )
    $value = Get-RooPropertyValue $Controls $Name $null
    if ($null -ne $value) { return $value }
    foreach ($alias in @(Get-RooArray $Aliases)) {
        $value = Get-RooPropertyValue $Controls ([string]$alias) $null
        if ($null -ne $value) { return $value }
    }
    return $null
}

function ConvertTo-RooProcessPolicyStoredRule {
    param(
        [object]$Rule,
        [string]$CreatedBy = 'local-user',
        [object]$ExistingRule = $null
    )
    $ruleId = [string](Get-RooPropertyValue $Rule 'id' (Get-RooPropertyValue $Rule 'ruleId' ''))
    if ([string]::IsNullOrWhiteSpace($ruleId)) {
        throw 'Process policy rule requires an id or ruleId.'
    }
    $match = Get-RooPropertyValue $Rule 'match' $Rule
    $controls = Get-RooPropertyValue $Rule 'requestedControls' (Get-RooPropertyValue $Rule 'controls' $null)
    if ($null -eq $controls) { $controls = [pscustomobject]@{} }
    $now = Get-RooUtcStamp
    $existingTimestamps = Get-RooPropertyValue $ExistingRule 'timestamps' $null
    $existingApproval = Get-RooPropertyValue $ExistingRule 'approval' $null
    $createdAt = Get-RooPropertyValue $existingTimestamps 'createdAtUtc' (Get-RooPropertyValue $Rule 'createdAtUtc' $now)

    return [pscustomobject]@{
        schemaVersion = 1
        id = $ruleId
        ruleId = $ruleId
        match = [pscustomobject]@{
            processNames = @(Get-RooPropertyArray $match 'processNames') + @(Get-RooPropertyArray $match 'names')
            namePatterns = @(Get-RooPropertyArray $match 'namePatterns')
            pathPatterns = @(Get-RooPropertyArray $match 'pathPatterns')
            publisherNames = @(Get-RooPropertyArray $match 'publisherNames') + @(Get-RooPropertyArray $match 'publishers')
            publisherPatterns = @(Get-RooPropertyArray $match 'publisherPatterns')
            processCategories = @(Get-RooPropertyArray $match 'processCategories') + @(Get-RooPropertyArray $match 'categories')
            commandLinePatterns = @(Get-RooPropertyArray $match 'commandLinePatterns')
            excludeProcessNames = @(Get-RooPropertyArray $match 'excludeProcessNames')
            excludeNamePatterns = @(Get-RooPropertyArray $match 'excludeNamePatterns')
            excludePathPatterns = @(Get-RooPropertyArray $match 'excludePathPatterns')
            excludePublisherNames = @(Get-RooPropertyArray $match 'excludePublisherNames')
            excludePublisherPatterns = @(Get-RooPropertyArray $match 'excludePublisherPatterns')
            excludeProcessCategories = @(Get-RooPropertyArray $match 'excludeProcessCategories')
            excludeCommandLinePatterns = @(Get-RooPropertyArray $match 'excludeCommandLinePatterns')
        }
        requestedControls = [pscustomobject]@{
            priorityClass = Get-RooProcessPolicyRuleControlValue $controls 'priorityClass' @('priority')
            affinityMask = Get-RooProcessPolicyRuleControlValue $controls 'affinityMask' @('affinity')
            ioPriority = Get-RooProcessPolicyRuleControlValue $controls 'ioPriority' @('io')
            gpuPriority = Get-RooProcessPolicyRuleControlValue $controls 'gpuPriority' @('gpu')
            restraint = Get-RooProcessPolicyRuleControlValue $controls 'restraint' @('restraintMode')
        }
        protectionCategory = [string](Get-RooPropertyValue $Rule 'protectionCategory' (Get-RooPropertyValue $Rule 'category' 'backgroundApp'))
        createdBy = [string](Get-RooPropertyValue $Rule 'createdBy' $CreatedBy)
        status = [string](Get-RooPropertyValue $ExistingRule 'status' 'previewed')
        timestamps = [pscustomobject]@{
            createdAtUtc = $createdAt
            updatedAtUtc = $now
            previewedAtUtc = Get-RooPropertyValue $existingTimestamps 'previewedAtUtc' $null
            approvedAtUtc = Get-RooPropertyValue $existingTimestamps 'approvedAtUtc' $null
            appliedAtUtc = Get-RooPropertyValue $existingTimestamps 'appliedAtUtc' $null
            restoredAtUtc = Get-RooPropertyValue $existingTimestamps 'restoredAtUtc' $null
            removedAtUtc = Get-RooPropertyValue $existingTimestamps 'removedAtUtc' $null
        }
        approval = $existingApproval
        allowConfirmedApply = [bool](Get-RooPropertyValue $Rule 'allowConfirmedApply' (Get-RooPropertyValue $ExistingRule 'allowConfirmedApply' $false))
        safety = Get-RooPropertyValue $Rule 'safety' (Get-RooPropertyValue $ExistingRule 'safety' $null)
        reason = [string](Get-RooPropertyValue $Rule 'reason' (Get-RooPropertyValue $ExistingRule 'reason' 'Persistent process policy rule.'))
        reasonCodes = @(Get-RooPropertyArray $Rule 'reasonCodes')
        tags = @(Get-RooPropertyArray $Rule 'tags') + @(Get-RooPropertyArray $Rule 'scenarioTags')
        risk = [string](Get-RooPropertyValue $Rule 'risk' (Get-RooPropertyValue $ExistingRule 'risk' 'low'))
        lastPreview = Get-RooPropertyValue $ExistingRule 'lastPreview' $null
        activeEffects = @(Get-RooPropertyArray $ExistingRule 'activeEffects')
        backupManifestPaths = @(Get-RooPropertyArray $ExistingRule 'backupManifestPaths')
        removed = [bool](Get-RooPropertyValue $ExistingRule 'removed' $false)
    }
}

function ConvertTo-RooProcessPolicyRuleForProfile {
    param([object]$StoredRule)
    return [pscustomobject]@{
        ruleId = [string](Get-RooPropertyValue $StoredRule 'id' '')
        enabled = (-not [bool](Get-RooPropertyValue $StoredRule 'removed' $false))
        allowConfirmedApply = [bool](Get-RooPropertyValue $StoredRule 'allowConfirmedApply' $false)
        safety = Get-RooPropertyValue $StoredRule 'safety' $null
        match = Get-RooPropertyValue $StoredRule 'match' $null
        controls = Get-RooPropertyValue $StoredRule 'requestedControls' $null
        reason = [string](Get-RooPropertyValue $StoredRule 'reason' 'Persistent process policy rule.')
        reasonCodes = @(Get-RooPropertyArray $StoredRule 'reasonCodes')
        scenarioTags = @(Get-RooPropertyArray $StoredRule 'tags')
        risk = [string](Get-RooPropertyValue $StoredRule 'risk' 'low')
    }
}

function New-RooProcessPolicyProfileForRule {
    param(
        [object]$Profile,
        [object]$StoredRule
    )
    $policy = Get-RooProcessPolicyProfileRoot $Profile
    return [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooProcessProductName
        profileId = [string](Get-RooPropertyValue $Profile 'profileId' 'persistent-policy')
        profileKind = 'persistent-process-policy'
        risk = [string](Get-RooPropertyValue $StoredRule 'risk' (Get-RooPropertyValue $Profile 'risk' 'medium'))
        protectedCatalogPath = Get-RooPropertyValue $Profile 'protectedCatalogPath' 'protected-processes.json'
        policy = [pscustomobject]@{
            session = Get-RooPropertyValue $policy 'session' $null
            safety = Get-RooPropertyValue $policy 'safety' (Get-RooPropertyValue $Profile 'safety' $null)
            protectedProcesses = @(Get-RooPropertyArray $policy 'protectedProcesses')
            rules = @((ConvertTo-RooProcessPolicyRuleForProfile $StoredRule))
        }
        protectedProcesses = @(Get-RooPropertyArray $Profile 'protectedProcesses')
        protectedCompanions = @(Get-RooPropertyArray $Profile 'protectedCompanions')
    }
}

function New-RooProcessPolicyTargetIdentity {
    param([object]$Target)
    $processId = Get-RooPropertyValue $Target 'processId' (Get-RooPropertyValue $Target 'pid' $null)
    $processName = [string](Get-RooPropertyValue $Target 'processName' (Get-RooPropertyValue $Target 'name' ''))
    $path = Get-RooPropertyValue $Target 'executablePath' $null
    $publisher = Get-RooPropertyValue $Target 'publisher' $null
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

function New-RooProcessPolicyAuditRow {
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
    $targetIdentity = New-RooProcessPolicyTargetIdentity $Target
    return [pscustomobject]@{
        schemaVersion = 1
        auditId = "process-policy-audit-$([guid]::NewGuid().ToString('N'))"
        timestampUtc = Get-RooUtcStamp
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

function Add-RooProcessPolicyAuditRows {
    param(
        [string]$StateRoot,
        [object[]]$Rows
    )
    $items = @(Get-RooArray $Rows)
    if ($items.Count -eq 0) { return $null }
    $path = Get-RooProcessPolicyAuditPath $StateRoot
    Ensure-RooDirectory (Split-Path $path -Parent)
    foreach ($row in $items) {
        ($row | ConvertTo-Json -Depth 24 -Compress) | Add-Content -LiteralPath $path -Encoding UTF8
    }
    return $path
}

function Read-RooProcessPolicyAuditRows {
    param([string]$StateRoot)
    $path = Get-RooProcessPolicyAuditPath $StateRoot
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    foreach ($line in @(Get-Content -LiteralPath $path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $rows.Add(($line | ConvertFrom-Json)) | Out-Null } catch { }
    }
    return @($rows.ToArray())
}

function Get-RooProcessPolicyBackupManifestPath {
    param(
        [string]$StateRoot,
        [string]$BackupId
    )
    return Join-Path (Get-RooProcessPolicyRuleBackupRoot $StateRoot) "$BackupId.json"
}

function New-RooProcessPolicyRuleBackupManifest {
    param(
        [string]$StateRoot,
        [object]$Rule,
        [string]$ActionId,
        [object[]]$Snapshots
    )
    $ruleId = [string](Get-RooPropertyValue $Rule 'id' '')
    $backupId = "process-policy-rule-$ruleId-$(Get-RooFileStamp)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $path = Get-RooProcessPolicyBackupManifestPath $StateRoot $backupId
    $manifest = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooProcessProductName
        manifestKind = 'processControlBackupManifest'
        backupId = $backupId
        actionId = $ActionId
        ruleId = $ruleId
        createdAtUtc = Get-RooUtcStamp
        stateRoot = Resolve-RooProcessPolicyRuntimeStateRoot $StateRoot
        dryRun = $false
        restore = [pscustomobject]@{
            available = $true
            status = 'available'
            path = $path
        }
        snapshots = @(Get-RooArray $Snapshots)
    }
    Write-RooProcessPolicyJsonFile $manifest $path
    return [pscustomobject]@{
        manifest = $manifest
        path = $path
    }
}
