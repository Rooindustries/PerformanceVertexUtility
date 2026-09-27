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
. (Join-Path $PSScriptRoot 'AppxInventory.Common.ps1')

function Get-OfficialCommandPreview {
    param(
        [object]$App,
        [object]$Classification
    )
    $sourceType = [string](Get-RooIndustriesUninstallPropertyValue $App 'sourceType' '')
    $uninstallString = Get-RooIndustriesUninstallPropertyValue $App 'uninstallString' $null
    $quietUninstallString = Get-RooIndustriesUninstallPropertyValue $App 'quietUninstallString' $null
    $packageId = Get-RooIndustriesUninstallPropertyValue $App 'packageId' $null
    $commandType = 'unavailable'
    $rawCommand = $uninstallString
    $quietCommand = $quietUninstallString
    $metadata = [pscustomobject]@{}

    if ($sourceType -eq 'msi') {
        $productCode = [guid]::Empty
        if (-not [guid]::TryParseExact([string]$packageId, 'B', [ref]$productCode)) {
            throw 'MSI removal requires the exact ProductCode in the installed app identity.'
        }
        $commandType = 'msi-uninstall-string'
        $msiexec = Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
        $rawCommand = '"'+$msiexec+'" '+(Get-RooIndustriesMsiUninstallArguments $productCode)
        $quietCommand = '"'+$msiexec+'" '+(Get-RooIndustriesMsiUninstallArguments $productCode -Quiet)
        $metadata = [pscustomobject]@{ productCode=$productCode.ToString('B').ToUpperInvariant(); exitCodePolicy='windows-installer'; automaticRestartAllowed=$false }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$uninstallString)) {
        $commandType = 'registry-uninstall-string'
    } elseif ($sourceType -eq 'appx') {
        if ([string]$packageId -notmatch '^[^_]+_[^_]+_[^_]+_[^_]*_[^_]+$') { throw 'Appx removal requires PackageFullName, not PackageFamilyName. Refresh inventory.' }
        $commandType = 'appx-package-removal-preview'
        $identity=Get-RooIndustriesUninstallPropertyValue $App 'sourceIdentity' $null
        if($null -eq $identity -or $identity.userSid -notmatch '^S-1-\d+(?:-\d+)+$'){throw 'Appx preview requires an exact Windows user SID.'}
        $rawCommand = Get-RooIndustriesAppxRemoveCommand $identity
        $metadata = [pscustomobject]@{
            previewExecution = 'disabled'
            packageFullName = $packageId
            scope = $identity.scope
            userSid = $identity.userSid
            reason = 'Review the exact package and Windows account. This removes the selected registration; provisioning for new users is separate.'
        }
    } elseif ($sourceType -eq 'winget' -and -not [string]::IsNullOrWhiteSpace([string]$packageId)) {
        $commandType = 'winget-uninstall-preview'
        $rawCommand = "winget uninstall --id $packageId"
        $metadata = [pscustomobject]@{
            previewExecution = 'disabled'
            reason = 'winget uninstall is metadata-only until the user confirms an uninstall path.'
        }
    }

    $parsed = Resolve-RooIndustriesUninstallCommandLine $rawCommand
    if ($null -eq $parsed) { $parsed = Split-RooIndustriesUninstallCommandLine $rawCommand }
    $parsedQuiet = Resolve-RooIndustriesUninstallCommandLine $quietCommand
    if ($null -eq $parsedQuiet) { $parsedQuiet = Split-RooIndustriesUninstallCommandLine $quietCommand }
    $blocked = [bool](Get-RooIndustriesUninstallPropertyValue $Classification 'blockByDefault' $false)
    $protected = [bool](Get-RooIndustriesUninstallPropertyValue $Classification 'protected' $false)
    $warnings = New-Object System.Collections.Generic.List[object]
    if ($blocked) {
        $warnings.Add((New-RooIndustriesUninstallIssue 'REMOVAL_REVIEW_REQUIRED' 'This app route needs review before it can run.' 'warning' 'apps.officialUninstall' ([string](Get-RooIndustriesUninstallPropertyValue $App 'appId' '')) $true 'Review the exact app, route, and cleanup list before applying anything.' $null)) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace([string]$rawCommand)) {
        $warnings.Add((New-RooIndustriesUninstallIssue 'ROO_INDUSTRIES_ROUTE_REQUIRED' 'The app did not publish its own removal command. Roo Industries can still build the run from app traces and leftovers.' 'warning' 'apps.officialUninstall' ([string](Get-RooIndustriesUninstallPropertyValue $App 'appId' '')) $false 'Scan leftovers and build the Roo Industries removal run before applying anything.' $null)) | Out-Null
    }

    return [pscustomobject]@{
        appId = [string](Get-RooIndustriesUninstallPropertyValue $App 'appId' '')
        displayName = [string](Get-RooIndustriesUninstallPropertyValue $App 'displayName' '')
        publisher = Get-RooIndustriesUninstallPropertyValue $App 'publisher' $null
        sourceType = $sourceType
        packageId = $packageId
        sourceIdentity = Get-RooIndustriesUninstallPropertyValue $App 'sourceIdentity' $null
        primaryClassification = [string](Get-RooIndustriesUninstallPropertyValue $Classification 'primaryClassification' '')
        commandType = $commandType
        rawCommand = $rawCommand
        commandLine = Get-RooIndustriesReviewedUninstallCommandLine ([string](Get-RooIndustriesUninstallPropertyValue $parsed 'executable' $null)) ([string](Get-RooIndustriesUninstallPropertyValue $parsed 'arguments' $null))
        executable = Get-RooIndustriesUninstallPropertyValue $parsed 'executable' $null
        executableSha256 = Get-RooIndustriesReviewedUninstallExecutableHash ([string](Get-RooIndustriesUninstallPropertyValue $parsed 'executable' $null))
        arguments = Get-RooIndustriesUninstallPropertyValue $parsed 'arguments' $null
        quietRawCommand = $quietCommand
        quietExecutable = Get-RooIndustriesUninstallPropertyValue $parsedQuiet 'executable' $null
        quietArguments = Get-RooIndustriesUninstallPropertyValue $parsedQuiet 'arguments' $null
        hasQuietCommand = (-not [string]::IsNullOrWhiteSpace([string]$quietCommand))
        requiresElevation = $true
        protected = $protected
        reviewRequired = [bool](Get-RooIndustriesUninstallPropertyValue $Classification 'reviewRequired' $true)
        blocked = $blocked
        risk = [string](Get-RooIndustriesUninstallPropertyValue $Classification 'risk' 'medium')
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
    $inventory = Get-RooIndustriesInstalledAppInventory $InventoryPath
    $policy = Read-RooIndustriesUninstallPolicy $PolicyPath
    $protectedCatalog = Read-RooIndustriesProtectedAppsCatalog $ProtectedAppsPath
    $commands = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    foreach ($id in $AppId) {
        $app = Find-RooIndustriesInstalledApp $inventory $id
        if ($null -eq $app) {
            $errors.Add((New-RooIndustriesUninstallIssue 'APP_NOT_FOUND' "App id not found in inventory: $id" 'error' 'apps.officialUninstall' $id $true 'Refresh inventory and retry.' $null)) | Out-Null
            continue
        }
        $classification = Get-RooIndustriesAppClassification $app $protectedCatalog $policy
        $commands.Add((Get-OfficialCommandPreview $app $classification)) | Out-Null
    }

    $result = [pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = $script:RooIndustriesUninstallProductName
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        status = if ($errors.Count -gt 0 -and $commands.Count -eq 0) { 'failed' } elseif ($errors.Count -gt 0) { 'partial' } else { 'preview' }
        policyPath = Get-RooIndustriesUninstallPolicyPath $PolicyPath
        commands = @($commands.ToArray())
        summary = [pscustomobject]@{
            requestedCount = @($AppId).Count
            commandPreviewCount = $commands.Count
            blockedCount = @($commands.ToArray() | Where-Object { $_.blocked }).Count
            executionAllowedCount = 0
            willRunUninstallers = $false
        }
        warnings = @((New-RooIndustriesUninstallIssue 'REMOVAL_PATH_PREVIEW_ONLY' 'Removal path metadata was returned without executing commands.' 'info' 'apps.officialUninstall' $null $false 'Review the path, scan leftovers, and build the Roo Industries removal plan before apply.' $null))
        errors = @($errors.ToArray())
        logs = @((New-RooIndustriesUninstallLog 'Removal path preview completed without command execution.'))
    }
    Write-RooIndustriesUninstallJsonOutput $result $OutputPath
    if ($errors.Count -gt 0 -and $commands.Count -eq 0) { exit 1 }
} catch {
    $result = [pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = $script:RooIndustriesUninstallProductName
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        status = 'failed'
        commands = @()
        summary = [pscustomobject]@{ requestedCount = @($AppId).Count; commandPreviewCount = 0; executionAllowedCount = 0; willRunUninstallers = $false }
        warnings = @()
        errors = @((New-RooIndustriesUninstallIssue 'OFFICIAL_UNINSTALL_PREVIEW_FAILED' $_.Exception.Message 'error' 'apps.officialUninstall' $null $true 'Check selected app ids and inventory path.' $null))
        logs = @((New-RooIndustriesUninstallLog 'Removal path preview failed.' 'error'))
    }
    Write-RooIndustriesUninstallJsonOutput $result $OutputPath
    exit 1
}
