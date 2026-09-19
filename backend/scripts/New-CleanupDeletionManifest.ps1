param(
    [string]$ScanPath = '',
    [string]$AppId = '',
    [string]$InventoryPath = '',
    [string[]]$ItemId = @(),
    [switch]$IncludeNonDefault,
    [string]$PolicyPath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')

function Get-ScanResult {
    param(
        [string]$ScanPath,
        [string]$AppId,
        [string]$InventoryPath
    )
    if (-not [string]::IsNullOrWhiteSpace($ScanPath)) {
        return Read-RooIndustriesUninstallJsonFile (Resolve-RooIndustriesUninstallPath $ScanPath $ScanPath)
    }
    if ([string]::IsNullOrWhiteSpace($AppId)) {
        throw 'Either -ScanPath or -AppId is required.'
    }
    $args = @{ AppId = $AppId }
    if (-not [string]::IsNullOrWhiteSpace($InventoryPath)) { $args['InventoryPath'] = $InventoryPath }
    $output = & (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') @args
    return $output | ConvertFrom-Json
}

function Test-ItemIncluded {
    param(
        [object]$Item,
        [string[]]$ItemIds,
        [bool]$IncludeNonDefault
    )
    if ([bool](Get-RooIndustriesUninstallPropertyValue $Item 'protected' $false)) { return $false }
    if ($ItemIds.Count -gt 0) {
        return ($ItemIds -contains [string](Get-RooIndustriesUninstallPropertyValue $Item 'itemId' ''))
    }
    if ($IncludeNonDefault) { return $true }
    return [bool](Get-RooIndustriesUninstallPropertyValue $Item 'defaultSelected' $false)
}

function New-BackupRequirement {
    param(
        [object]$Item,
        [string]$Mode
    )
    return [pscustomobject]@{
        itemId = [string](Get-RooIndustriesUninstallPropertyValue $Item 'itemId' '')
        type = [string](Get-RooIndustriesUninstallPropertyValue $Item 'type' '')
        target = [string](Get-RooIndustriesUninstallPropertyValue $Item 'target' '')
        mode = $Mode
        required = $true
        completed = $false
        previewOnly = $true
    }
}

try {
    $policy = Read-RooIndustriesUninstallPolicy $PolicyPath
    $scan = Get-ScanResult $ScanPath $AppId $InventoryPath
    $selected = New-Object System.Collections.Generic.List[object]
    $excluded = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-RooIndustriesUninstallPropertyArray $scan 'items')) {
        if (Test-ItemIncluded $item $ItemId ([bool]$IncludeNonDefault)) {
            $selected.Add($item) | Out-Null
        } else {
            $excluded.Add([pscustomobject]@{
                itemId = [string](Get-RooIndustriesUninstallPropertyValue $item 'itemId' '')
                target = [string](Get-RooIndustriesUninstallPropertyValue $item 'target' '')
                reason = if ([bool](Get-RooIndustriesUninstallPropertyValue $item 'protected' $false)) { 'Shared runtime. Leave it alone unless you approve a dedicated runtime cleanup.' } else { 'Left out until you approve the cleanup.' }
            }) | Out-Null
        }
    }

    Assert-RooIndustriesCleanupExclusions @($selected.ToArray() | Where-Object { $_.type -in @('file','folder') } | ForEach-Object { [string]$_.target })
    $fileBackups = New-Object System.Collections.Generic.List[object]
    $registryExports = New-Object System.Collections.Generic.List[object]
    $serviceBackups = New-Object System.Collections.Generic.List[object]
    $taskBackups = New-Object System.Collections.Generic.List[object]
    $startupBackups = New-Object System.Collections.Generic.List[object]

    foreach ($item in @($selected.ToArray())) {
        switch ([string](Get-RooIndustriesUninstallPropertyValue $item 'type' '')) {
            'file' { $fileBackups.Add((New-BackupRequirement $item 'copy-before-delete')) | Out-Null }
            'folder' { $fileBackups.Add((New-BackupRequirement $item 'copy-before-delete')) | Out-Null }
            'registryKey' { $registryExports.Add((New-BackupRequirement $item 'reg-export-before-delete')) | Out-Null }
            'registryValue' { $registryExports.Add((New-BackupRequirement $item 'reg-export-before-delete')) | Out-Null }
            'service' { $serviceBackups.Add((New-BackupRequirement $item 'service-cim-state-export')) | Out-Null }
            'scheduledTask' { $taskBackups.Add((New-BackupRequirement $item 'scheduled-task-export')) | Out-Null }
            'startupEntry' { $startupBackups.Add((New-BackupRequirement $item 'startup-registry-export')) | Out-Null }
        }
    }

    $manifestId = 'cleanup-manifest-preview-' + (ConvertTo-RooIndustriesStableId ([string](Get-RooIndustriesUninstallPropertyValue $scan 'appId' $AppId))) + '-' + (Get-RooIndustriesUninstallFileStamp)
    $backupRoot = [string](Get-RooIndustriesUninstallPropertyValue (Get-RooIndustriesUninstallPropertyValue $policy 'cleanupDeletion' $null) 'backupRoot' 'C:\ProgramData\RooIndustriesOptimizationSuite\backups\cleanup')
    $manifest = [pscustomobject]@{
        manifestId = $manifestId
        productName = $script:RooIndustriesUninstallProductName
        schemaVersion = 1
        appId = [string](Get-RooIndustriesUninstallPropertyValue $scan 'appId' $AppId)
        displayName = [string](Get-RooIndustriesUninstallPropertyValue $scan 'displayName' '')
        createdAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        executionMode = 'preview-only'
        sourceScanId = [string](Get-RooIndustriesUninstallPropertyValue $scan 'scanId' '')
        items = @($selected.ToArray())
        excludedItems = @($excluded.ToArray())
        rollback = [pscustomobject]@{
            backupRoot = (Join-Path $backupRoot $manifestId)
            rollbackActionId = [string](Get-RooIndustriesUninstallPropertyValue (Get-RooIndustriesUninstallPropertyValue $policy 'cleanupDeletion' $null) 'rollbackActionId' 'apps.rollbackCleanup')
            rollbackSupported = $true
            restorePoint = [pscustomobject]@{
                requiredBeforeFutureApply = $true
                created = $false
                previewOnly = $true
            }
            fileBackupRequirements = @($fileBackups.ToArray())
            registryExportRequirements = @($registryExports.ToArray())
            serviceStateBackupRequirements = @($serviceBackups.ToArray())
            scheduledTaskBackupRequirements = @($taskBackups.ToArray())
            startupEntryBackupRequirements = @($startupBackups.ToArray())
            manifestExportRequired = $true
        }
        summary = [pscustomobject]@{
            itemCount = $selected.Count
            excludedCount = $excluded.Count
            lowRiskCount = @($selected.ToArray() | Where-Object { $_.risk -eq 'low' }).Count
            mediumRiskCount = @($selected.ToArray() | Where-Object { $_.risk -eq 'medium' }).Count
            highRiskCount = @($selected.ToArray() | Where-Object { $_.risk -eq 'high' }).Count
            protectedCount = @($selected.ToArray() | Where-Object { $_.protected }).Count
            highConfidenceCount = @($selected.ToArray() | Where-Object { $_.confidence -eq 'high' }).Count
            mediumConfidenceCount = @($selected.ToArray() | Where-Object { $_.confidence -eq 'medium' }).Count
            requiresElevation = $true
            confirmationRequired = $true
            willDeleteOnApply = $false
            willEditRegistry = $false
            willEditServices = $false
            willEditScheduledTasks = $false
            dryRunWritesState = $false
        }
        warnings = @((New-RooIndustriesUninstallIssue 'CLEANUP_MANIFEST_PREVIEW_ONLY' 'Delete plan is review-only. No files, folders, registry keys, services, tasks, or startup entries were changed.' 'info' 'apps.cleanupManifest' ([string](Get-RooIndustriesUninstallPropertyValue $scan 'appId' $AppId)) $false 'Review the backup and restore-point plan before approving cleanup.' $null))
        errors = @()
    }

    Write-RooIndustriesUninstallJsonOutput $manifest $OutputPath
} catch {
    $manifest = [pscustomobject]@{
        manifestId = 'cleanup-manifest-preview-' + (Get-RooIndustriesUninstallFileStamp)
        productName = $script:RooIndustriesUninstallProductName
        schemaVersion = 1
        appId = $AppId
        createdAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        executionMode = 'preview-only'
        items = @()
        excludedItems = @()
        rollback = [pscustomobject]@{
            rollbackSupported = $true
            fileBackupRequirements = @()
            registryExportRequirements = @()
            serviceStateBackupRequirements = @()
            scheduledTaskBackupRequirements = @()
            startupEntryBackupRequirements = @()
        }
        summary = [pscustomobject]@{ itemCount = 0; willDeleteOnApply = $false; dryRunWritesState = $false }
        warnings = @()
        errors = @((New-RooIndustriesUninstallIssue 'CLEANUP_MANIFEST_PREVIEW_FAILED' $_.Exception.Message 'error' 'apps.cleanupManifest' $AppId $true 'Check the leftover scan path or selected app id.' $null))
    }
    Write-RooIndustriesUninstallJsonOutput $manifest $OutputPath
    exit 1
}
