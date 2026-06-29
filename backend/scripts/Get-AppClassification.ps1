param(
    [string]$InventoryPath = '',
    [string]$AppId = '',
    [string]$ProtectedAppsPath = '',
    [string]$PolicyPath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')

try {
    $inventory = Get-RooInstalledAppInventory $InventoryPath
    $policy = Read-RooUninstallPolicy $PolicyPath
    $protectedCatalog = Read-RooProtectedAppsCatalog $ProtectedAppsPath
    $apps = New-Object System.Collections.Generic.List[object]

    foreach ($app in @(Get-RooUninstallPropertyArray $inventory 'apps')) {
        if (-not [string]::IsNullOrWhiteSpace($AppId) -and [string](Get-RooUninstallPropertyValue $app 'appId' '') -ne $AppId) { continue }
        $apps.Add((Get-RooAppClassification $app $protectedCatalog $policy)) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($AppId) -and $apps.Count -eq 0) {
        throw "App id not found in inventory: $AppId"
    }

    $appArray = @($apps.ToArray())
    $summary = [pscustomobject]@{
        appCount = $appArray.Count
        normalAppCount = @($appArray | Where-Object { $_.primaryClassification -eq 'normal-app' }).Count
        launcherCount = @($appArray | Where-Object { $_.primaryClassification -eq 'launcher' }).Count
        overlayCount = @($appArray | Where-Object { $_.primaryClassification -eq 'overlay' }).Count
        vendorToolCount = @($appArray | Where-Object { $_.primaryClassification -eq 'vendor-tool' }).Count
        sharedRuntimeCount = @($appArray | Where-Object { $_.primaryClassification -eq 'shared-runtime' }).Count
        driverCount = @($appArray | Where-Object { $_.primaryClassification -eq 'driver' }).Count
        securityNetworkComponentCount = @($appArray | Where-Object { $_.primaryClassification -eq 'security-network-component' }).Count
        storeWebView2Count = @($appArray | Where-Object { $_.primaryClassification -eq 'store-webview2' }).Count
        antiCheatCount = @($appArray | Where-Object { $_.primaryClassification -eq 'anti-cheat' }).Count
        obsDiscordDependencyCount = @($appArray | Where-Object { $_.primaryClassification -eq 'obs-discord-dependency' }).Count
        protectedWindowsComponentCount = @($appArray | Where-Object { $_.primaryClassification -eq 'protected-windows-component' }).Count
        protectedCount = @($appArray | Where-Object { $_.protected }).Count
        blockedByDefaultCount = @($appArray | Where-Object { $_.blockByDefault }).Count
    }

    $result = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        source = 'local-read-only'
        inventoryPath = if ([string]::IsNullOrWhiteSpace($InventoryPath)) { $null } else { (Resolve-RooUninstallPath $InventoryPath $InventoryPath) }
        protectedCatalogPath = Get-RooProtectedAppsPath $ProtectedAppsPath
        policyPath = Get-RooUninstallPolicyPath $PolicyPath
        summary = $summary
        apps = $appArray
    }

    Write-RooUninstallJsonOutput $result $OutputPath
} catch {
    $result = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        source = 'local-read-only'
        inventoryPath = if ([string]::IsNullOrWhiteSpace($InventoryPath)) { $null } else { $InventoryPath }
        protectedCatalogPath = Get-RooProtectedAppsPath $ProtectedAppsPath
        policyPath = Get-RooUninstallPolicyPath $PolicyPath
        summary = [pscustomobject]@{ appCount = 0; protectedCount = 0; blockedByDefaultCount = 0 }
        apps = @()
        errors = @((New-RooUninstallIssue 'APP_CLASSIFICATION_FAILED' $_.Exception.Message 'error' 'apps.classification' $AppId $true 'Check the inventory and uninstall profile paths.' $null))
    }
    Write-RooUninstallJsonOutput $result $OutputPath
    exit 1
}
