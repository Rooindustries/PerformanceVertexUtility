param(
    [Parameter(Mandatory = $true)]
    [string[]]$AppId,
    [string]$InventoryPath = '',
    [string]$ProtectedAppsPath = '',
    [string]$PolicyPath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')

function Get-OfficialCommandPreview {
    param(
        [object]$App,
        [object]$Classification
    )
    $sourceType = [string](Get-RooUninstallPropertyValue $App 'sourceType' '')
    $uninstallString = Get-RooUninstallPropertyValue $App 'uninstallString' $null
    $quietUninstallString = Get-RooUninstallPropertyValue $App 'quietUninstallString' $null
    $packageId = Get-RooUninstallPropertyValue $App 'packageId' $null
    $commandType = 'unavailable'
    $rawCommand = $uninstallString
    $quietCommand = $quietUninstallString
    $metadata = [pscustomobject]@{}

    if (-not [string]::IsNullOrWhiteSpace([string]$uninstallString)) {
        if ([string]$uninstallString -match 'msiexec') {
            $commandType = 'msi-uninstall-string'
        } else {
            $commandType = 'registry-uninstall-string'
        }
    } elseif ($sourceType -eq 'appx') {
        $commandType = 'appx-package-removal-preview'
        $rawCommand = "Remove-AppxPackage -Package $packageId"
        $metadata = [pscustomobject]@{
            previewExecution = 'disabled'
            reason = 'Appx package removal is metadata-only until the user confirms an uninstall path.'
        }
    } elseif ($sourceType -eq 'winget' -and -not [string]::IsNullOrWhiteSpace([string]$packageId)) {
        $commandType = 'winget-uninstall-preview'
        $rawCommand = "winget uninstall --id $packageId"
        $metadata = [pscustomobject]@{
            previewExecution = 'disabled'
            reason = 'winget uninstall is metadata-only until the user confirms an uninstall path.'
        }
    }

    $parsed = Split-RooUninstallCommandLine $rawCommand
    $parsedQuiet = Split-RooUninstallCommandLine $quietCommand
    $blocked = [bool](Get-RooUninstallPropertyValue $Classification 'blockByDefault' $false)
    $protected = [bool](Get-RooUninstallPropertyValue $Classification 'protected' $false)
    $warnings = New-Object System.Collections.Generic.List[object]
    if ($blocked) {
        $warnings.Add((New-RooUninstallIssue 'PROTECTED_APP_BLOCKED' 'Official uninstall preview is blocked by protected app policy.' 'warning' 'apps.officialUninstall' ([string](Get-RooUninstallPropertyValue $App 'appId' '')) $true 'Do not include this app in bulk uninstall unless a future policy explicitly allows it.' $null)) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace([string]$rawCommand)) {
        $warnings.Add((New-RooUninstallIssue 'NO_OFFICIAL_UNINSTALL_COMMAND' 'No official uninstall command was found in inventory metadata.' 'warning' 'apps.officialUninstall' ([string](Get-RooUninstallPropertyValue $App 'appId' '')) $true 'Use installed app settings or vendor documentation for this app.' $null)) | Out-Null
    }

    return [pscustomobject]@{
        appId = [string](Get-RooUninstallPropertyValue $App 'appId' '')
        displayName = [string](Get-RooUninstallPropertyValue $App 'displayName' '')
        publisher = Get-RooUninstallPropertyValue $App 'publisher' $null
        sourceType = $sourceType
        packageId = $packageId
        primaryClassification = [string](Get-RooUninstallPropertyValue $Classification 'primaryClassification' '')
        commandType = $commandType
        rawCommand = $rawCommand
        executable = Get-RooUninstallPropertyValue $parsed 'executable' $null
        arguments = Get-RooUninstallPropertyValue $parsed 'arguments' $null
        quietRawCommand = $quietCommand
        quietExecutable = Get-RooUninstallPropertyValue $parsedQuiet 'executable' $null
        quietArguments = Get-RooUninstallPropertyValue $parsedQuiet 'arguments' $null
        hasQuietCommand = (-not [string]::IsNullOrWhiteSpace([string]$quietCommand))
        requiresElevation = $true
        protected = $protected
        blocked = $blocked
        risk = [string](Get-RooUninstallPropertyValue $Classification 'risk' 'medium')
        confidence = if ([string]::IsNullOrWhiteSpace([string]$rawCommand)) { 'low' } else { 'high' }
        executionAllowed = $false
        executionMode = 'preview-only'
        rollbackPrerequisites = [pscustomobject]@{
            restorePointRequired = $true
            appInventoryExportRequired = $true
            leftoverScanAfterUninstall = $true
        }
        metadata = $metadata
        warnings = @($warnings.ToArray())
    }
}

try {
    $inventory = Get-RooInstalledAppInventory $InventoryPath
    $policy = Read-RooUninstallPolicy $PolicyPath
    $protectedCatalog = Read-RooProtectedAppsCatalog $ProtectedAppsPath
    $commands = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    foreach ($id in $AppId) {
        $app = Find-RooInstalledApp $inventory $id
        if ($null -eq $app) {
            $errors.Add((New-RooUninstallIssue 'APP_NOT_FOUND' "App id not found in inventory: $id" 'error' 'apps.officialUninstall' $id $true 'Refresh inventory and retry.' $null)) | Out-Null
            continue
        }
        $classification = Get-RooAppClassification $app $protectedCatalog $policy
        $commands.Add((Get-OfficialCommandPreview $app $classification)) | Out-Null
    }

    $result = [pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        dryRun = $true
        status = if ($errors.Count -gt 0 -and $commands.Count -eq 0) { 'failed' } elseif ($errors.Count -gt 0) { 'partial' } else { 'preview' }
        policyPath = Get-RooUninstallPolicyPath $PolicyPath
        commands = @($commands.ToArray())
        summary = [pscustomobject]@{
            requestedCount = @($AppId).Count
            commandPreviewCount = $commands.Count
            blockedCount = @($commands.ToArray() | Where-Object { $_.blocked }).Count
            executionAllowedCount = 0
            willRunUninstallers = $false
        }
        warnings = @((New-RooUninstallIssue 'OFFICIAL_UNINSTALL_PREVIEW_ONLY' 'Official uninstall command metadata was returned without executing commands.' 'info' 'apps.officialUninstall' $null $false 'Use this output for review before any uninstall command is allowed.' $null))
        errors = @($errors.ToArray())
        logs = @((New-RooUninstallLog 'Official uninstall command preview completed without command execution.'))
    }
    Write-RooUninstallJsonOutput $result $OutputPath
    if ($errors.Count -gt 0 -and $commands.Count -eq 0) { exit 1 }
} catch {
    $result = [pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        dryRun = $true
        status = 'failed'
        commands = @()
        summary = [pscustomobject]@{ requestedCount = @($AppId).Count; commandPreviewCount = 0; executionAllowedCount = 0; willRunUninstallers = $false }
        warnings = @()
        errors = @((New-RooUninstallIssue 'OFFICIAL_UNINSTALL_PREVIEW_FAILED' $_.Exception.Message 'error' 'apps.officialUninstall' $null $true 'Check selected app ids and inventory path.' $null))
        logs = @((New-RooUninstallLog 'Official uninstall command preview failed.' 'error'))
    }
    Write-RooUninstallJsonOutput $result $OutputPath
    exit 1
}
