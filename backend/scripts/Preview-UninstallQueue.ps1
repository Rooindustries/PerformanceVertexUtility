param(
    [Parameter(Mandatory = $true)]
    [Alias('SelectedAppIds')]
    [string[]]$AppId,
    [string]$InventoryPath = '',
    [string]$ProtectedAppsPath = '',
    [string]$PolicyPath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')

function New-QueueWarning {
    param([object]$Classification)
    $class = [string](Get-RooIndustriesUninstallPropertyValue $Classification 'primaryClassification' 'normal-app')
    $appIdValue = [string](Get-RooIndustriesUninstallPropertyValue $Classification 'appId' '')
    if ($class -eq 'overlay') {
        return New-RooIndustriesUninstallIssue 'OVERLAY_APP' 'This app may be tied to game overlays or companion widgets.' 'warning' 'apps.uninstallQueue' $appIdValue $false 'Close games and launchers before uninstalling in a future confirmed flow.' $null
    }
    if ($class -eq 'vendor-tool') {
        return New-RooIndustriesUninstallIssue 'VENDOR_TOOL' 'Vendor utilities can manage drivers, firmware, lighting, audio, or hotkeys.' 'warning' 'apps.uninstallQueue' $appIdValue $false 'Review device impact before any future uninstall execution.' $null
    }
    if ($class -eq 'launcher') {
        return New-RooIndustriesUninstallIssue 'GAME_LAUNCHER' 'Game launchers may own installed game repair, update, and login workflows.' 'info' 'apps.uninstallQueue' $appIdValue $false 'Confirm installed games and saves are accounted for before uninstalling.' $null
    }
    return $null
}

try {
    $inventory = Get-RooIndustriesInstalledAppInventory $InventoryPath
    $policy = Read-RooIndustriesUninstallPolicy $PolicyPath
    $protectedCatalog = Read-RooIndustriesProtectedAppsCatalog $ProtectedAppsPath
    $selectedApps = New-Object System.Collections.Generic.List[object]
    $blockedApps = New-Object System.Collections.Generic.List[object]
    $missingApps = New-Object System.Collections.Generic.List[object]

    foreach ($id in $AppId) {
        $app = Find-RooIndustriesInstalledApp $inventory $id
        if ($null -eq $app) {
            $missingApps.Add([pscustomobject]@{
                appId = $id
                reason = 'App id not found in inventory.'
            }) | Out-Null
            continue
        }

        $classification = Get-RooIndustriesAppClassification $app $protectedCatalog $policy
        if ([bool](Get-RooIndustriesUninstallPropertyValue $classification 'blockByDefault' $false)) {
            $blockedApps.Add([pscustomobject]@{
                appId = $id
                displayName = [string](Get-RooIndustriesUninstallPropertyValue $app 'displayName' '')
                primaryClassification = [string](Get-RooIndustriesUninstallPropertyValue $classification 'primaryClassification' '')
                risk = [string](Get-RooIndustriesUninstallPropertyValue $classification 'risk' 'protected')
                protected = $true
                reason = (@(Get-RooIndustriesUninstallPropertyArray $classification 'protectionReasons') -join '; ')
                matchedProtectedRuleIds = @(Get-RooIndustriesUninstallPropertyArray $classification 'matchedProtectedRuleIds')
            }) | Out-Null
            continue
        }

        $warnings = New-Object System.Collections.Generic.List[object]
        $warning = New-QueueWarning $classification
        if ($null -ne $warning) { $warnings.Add($warning) | Out-Null }
        $selectedApps.Add([pscustomobject]@{
            appId = $id
            displayName = [string](Get-RooIndustriesUninstallPropertyValue $app 'displayName' '')
            publisher = Get-RooIndustriesUninstallPropertyValue $app 'publisher' $null
            sourceType = [string](Get-RooIndustriesUninstallPropertyValue $app 'sourceType' '')
            packageId = Get-RooIndustriesUninstallPropertyValue $app 'packageId' $null
            primaryClassification = [string](Get-RooIndustriesUninstallPropertyValue $classification 'primaryClassification' '')
            officialUninstallFirst = [bool](Get-RooIndustriesUninstallPropertyValue (Get-RooIndustriesUninstallPropertyValue $policy 'queue' $null) 'officialUninstallFirst' $true)
            leftoverScan = [bool](Get-RooIndustriesUninstallPropertyValue (Get-RooIndustriesUninstallPropertyValue $policy 'queue' $null) 'leftoverScanAfterOfficialUninstall' $true)
            risk = [string](Get-RooIndustriesUninstallPropertyValue $classification 'risk' 'low')
            requiresElevation = [bool](Get-RooIndustriesUninstallPropertyValue (Get-RooIndustriesUninstallPropertyValue $policy 'queue' $null) 'requiresElevation' $true)
            protected = $false
            warnings = @($warnings.ToArray())
        }) | Out-Null
    }

    $queue = [pscustomobject]@{
        schemaVersion = 1
        queueId = 'uninstall-queue-preview-' + (Get-RooIndustriesUninstallFileStamp)
        productName = $script:RooIndustriesUninstallProductName
        createdAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        status = 'preview'
        selectedApps = @($selectedApps.ToArray())
        blockedApps = @($blockedApps.ToArray())
        missingApps = @($missingApps.ToArray())
        policy = [pscustomobject]@{
            confirmationRequired = $true
            restorePointRequired = [bool](Get-RooIndustriesUninstallPropertyValue (Get-RooIndustriesUninstallPropertyValue $policy 'officialUninstall' $null) 'restorePointRequiredBeforeFutureExecution' $true)
            leftoverDeletionDefault = 'preview-only'
            protectedAppsBlocked = [bool](Get-RooIndustriesUninstallPropertyValue $policy 'blockProtectedAppsByDefault' $true)
            officialUninstallOnlyUntilConfirmed = $true
            confirmedExecutionEnabled = $false
            dryRunWritesState = $false
        }
        summary = [pscustomobject]@{
            requestedCount = @($AppId).Count
            selectedCount = $selectedApps.Count
            blockedCount = $blockedApps.Count
            missingCount = $missingApps.Count
            willRunUninstallers = $false
            willDeleteLeftovers = $false
        }
        warnings = @((New-RooIndustriesUninstallIssue 'QUEUE_PREVIEW_ONLY' 'Queue preview created without running uninstallers or cleanup actions.' 'info' 'apps.uninstallQueue' $null $false 'Review official uninstall command previews before any future confirmed workflow.' $null))
        errors = @()
    }

    Write-RooIndustriesUninstallJsonOutput $queue $OutputPath
} catch {
    $queue = [pscustomobject]@{
        schemaVersion = 1
        queueId = 'uninstall-queue-preview-' + (Get-RooIndustriesUninstallFileStamp)
        productName = $script:RooIndustriesUninstallProductName
        createdAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        status = 'failed'
        selectedApps = @()
        blockedApps = @()
        missingApps = @()
        policy = [pscustomobject]@{ confirmationRequired = $true; confirmedExecutionEnabled = $false }
        summary = [pscustomobject]@{ requestedCount = @($AppId).Count; selectedCount = 0; blockedCount = 0; willRunUninstallers = $false; willDeleteLeftovers = $false }
        warnings = @()
        errors = @((New-RooIndustriesUninstallIssue 'UNINSTALL_QUEUE_PREVIEW_FAILED' $_.Exception.Message 'error' 'apps.uninstallQueue' $null $true 'Check selected app ids and inventory path.' $null))
    }
    Write-RooIndustriesUninstallJsonOutput $queue $OutputPath
    exit 1
}
