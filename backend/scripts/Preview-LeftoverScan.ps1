param(
    [Parameter(Mandatory = $true)]
    [string]$AppId,
    [string]$InventoryPath = '',
    [string]$RulesPath = '',
    [string]$ProtectedAppsPath = '',
    [string]$PolicyPath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')

function Get-MatchingKnownRules {
    param(
        [object]$App,
        [object]$Rules
    )
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($rule in @(Get-RooIndustriesUninstallPropertyArray $Rules 'knownAppRules')) {
        if (Test-RooIndustriesAppMatch $App (Get-RooIndustriesUninstallPropertyValue $rule 'match' $null)) {
            $matches.Add($rule) | Out-Null
        }
    }
    return @($matches.ToArray())
}

function Test-MicrosoftOwnedRegistryPath {
    param([string]$Path)
    $segments = @($Path -split '\\')
    for ($index = 0; $index -lt $segments.Count; $index++) {
        if ($segments[$index] -in @('Microsoft', 'Policies', 'PolicyManager')) { return $true }
        $parent = if ($index -gt 0) { $segments[$index - 1] } else { '' }
        if ($parent -in @('Software', 'WOW6432Node') -and $segments[$index] -in @('Clients', 'RegisteredApplications', 'ODBC', 'DefaultUserEnvironment', 'OpenSSH')) { return $true }
        if ($parent -eq 'Classes' -and $segments[$index] -in @('CLSID', 'Interface', 'TypeLib', 'AppID', 'Installer', 'Folder', 'Directory', 'Drive', 'Unknown', '*', 'AllFilesystemObjects', 'SystemFileAssociations', 'Local Settings')) { return $true }
    }
    return $false
}

function Test-MicrosoftOwnedFilePath {
    param([string]$Command)
    $text = [Environment]::ExpandEnvironmentVariables(([string]$Command).Trim())
    if ($text.StartsWith('"')) { $text = $text.Substring(1).Split('"')[0] }
    elseif ($text -match '^(.+?\.(exe|dll|cmd|bat|ps1))(\s|$)') { $text = $Matches[1] }
    $text = $text.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    $roots = @([Environment]::GetFolderPath('Windows')) + @('CommonApplicationData', 'LocalApplicationData', 'ApplicationData' | ForEach-Object { [Environment]::GetFolderPath($_) } | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Microsoft' })
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $root = $root.TrimEnd('\')
        if ($text -ieq $root -or $text.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($programs in @('ProgramFiles', 'ProgramFilesX86', 'CommonProgramFiles', 'CommonProgramFilesX86' | ForEach-Object { [Environment]::GetFolderPath($_) })) {
        if ([string]::IsNullOrWhiteSpace($programs)) { continue }
        $prefix = $programs.TrimEnd('\') + '\'
        if (-not $text.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $first = $text.Substring($prefix.Length).Split('\')[0]
        if ($first -like 'Microsoft*' -or $first -like 'Windows*') { return $true }
    }
    return $text -match '^[A-Za-z]:\\WindowsApps(\\|$)'
}

function Add-UniqueLeftoverItem {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [object]$Item
    )
    foreach ($existing in @($Items.ToArray())) {
        if ([string](Get-RooIndustriesUninstallPropertyValue $existing 'type' '') -eq [string](Get-RooIndustriesUninstallPropertyValue $Item 'type' '') -and [string](Get-RooIndustriesUninstallPropertyValue $existing 'target' '') -eq [string](Get-RooIndustriesUninstallPropertyValue $Item 'target' '')) {
            return
        }
    }
    $Items.Add($Item) | Out-Null
}

function New-PathCandidate {
    param(
        [object]$Rules,
        [string]$Path,
        [string[]]$MatchedBy,
        [string]$Reason,
        [string]$ItemSeed
    )
    $expanded = Resolve-RooIndustriesEnvironmentPath $Path
    $protected = Test-RooIndustriesProtectedPath $expanded $Rules
    $exists = if ([string]::IsNullOrWhiteSpace($expanded)) { $false } else { Test-Path -LiteralPath $expanded -ErrorAction SilentlyContinue }
    return New-RooIndustriesLeftoverItem `
        -ItemId ("folder:" + (ConvertTo-RooIndustriesStableId $ItemSeed)) `
        -Type 'folder' `
        -Target $expanded `
        -MatchedBy $MatchedBy `
        -Confidence $(if ($protected) { 'low' } else { 'high' }) `
        -Risk $(if ($protected) { 'protected' } else { 'low' }) `
        -DefaultSelected (-not $protected) `
        -Protected $protected `
        -Reason $Reason `
        -Metadata ([pscustomobject]@{ existsNow = $exists; previewOnly = $true })
}

function Add-ServiceCandidates {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [object]$App,
        [object[]]$Rules
    )
    $patterns = New-Object System.Collections.Generic.List[string]
    foreach ($rule in @($Rules)) {
        foreach ($pattern in @(Get-RooIndustriesUninstallPropertyArray $rule 'serviceNamePatterns')) { $patterns.Add([string]$pattern) | Out-Null }
    }
    if ($patterns.Count -eq 0) { return }
    try {
        $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)
        foreach ($svc in $services) {
            if (Test-MicrosoftOwnedFilePath ([string]$svc.PathName)) { continue }
            $haystack = ([string]$svc.Name + ' ' + [string]$svc.DisplayName + ' ' + [string]$svc.PathName)
            if (Test-RooIndustriesPatternMatch $haystack @($patterns.ToArray())) {
                Add-UniqueLeftoverItem $Items (New-RooIndustriesLeftoverItem `
                    -ItemId ("service:" + (ConvertTo-RooIndustriesStableId ([string]$svc.Name))) `
                    -Type 'service' `
                    -Target ([string]$svc.Name) `
                    -MatchedBy @('serviceReference', 'knownServicePattern') `
                    -Confidence 'high' `
                    -Risk 'medium' `
                    -DefaultSelected $false `
                    -Protected $false `
                    -Reason 'Service reference matched selected app metadata; service state backup is required before any future cleanup.' `
                    -Metadata ([pscustomobject]@{ displayName = [string]$svc.DisplayName; state = [string]$svc.State; startMode = [string]$svc.StartMode; pathName = [string]$svc.PathName; previewOnly = $true }))
            }
        }
    } catch {
    }
}

function Add-TaskCandidates {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [object[]]$Rules
    )
    $patterns = New-Object System.Collections.Generic.List[string]
    foreach ($rule in @($Rules)) {
        foreach ($pattern in @(Get-RooIndustriesUninstallPropertyArray $rule 'scheduledTaskPatterns')) { $patterns.Add([string]$pattern) | Out-Null }
    }
    if ($patterns.Count -eq 0 -or -not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return }
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
        foreach ($task in $tasks) {
            $target = ([string]$task.TaskPath + [string]$task.TaskName)
            if (([string]$task.TaskPath).StartsWith('\Microsoft\', [StringComparison]::OrdinalIgnoreCase) -or [string]$task.Author -match '^(Microsoft|\$\(@%SystemRoot%)' -or
                @($task.Actions | Where-Object { $_.Execute -and (Test-MicrosoftOwnedFilePath ([string]$_.Execute)) }).Count -gt 0) { continue }
            if (Test-RooIndustriesPatternMatch $target @($patterns.ToArray())) {
                Add-UniqueLeftoverItem $Items (New-RooIndustriesLeftoverItem `
                    -ItemId ("task:" + (ConvertTo-RooIndustriesStableId $target)) `
                    -Type 'scheduledTask' `
                    -Target $target `
                    -MatchedBy @('scheduledTaskReference', 'knownTaskPattern') `
                    -Confidence 'high' `
                    -Risk 'medium' `
                    -DefaultSelected $false `
                    -Protected $false `
                    -Reason 'Scheduled task matched selected app metadata; task export is required before any future cleanup.' `
                    -Metadata ([pscustomobject]@{ state = [string]$task.State; previewOnly = $true }))
            }
        }
    } catch {
    }
}

try {
    $inventory = Get-RooIndustriesInstalledAppInventory $InventoryPath
    $policy = Read-RooIndustriesUninstallPolicy $PolicyPath
    $protectedCatalog = Read-RooIndustriesProtectedAppsCatalog $ProtectedAppsPath
    $rules = Read-RooIndustriesLeftoverRules $RulesPath
    $app = Find-RooIndustriesInstalledApp $inventory $AppId
    if ($null -eq $app) { throw "App id not found in inventory: $AppId" }

    $classification = Get-RooIndustriesAppClassification $app $protectedCatalog $policy
    $knownRules = @(Get-MatchingKnownRules $app $rules)
    $items = New-Object System.Collections.Generic.List[object]
    $installLocation = Get-RooIndustriesUninstallPropertyValue $app 'installLocation' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$installLocation) -and -not (Test-MicrosoftOwnedFilePath ([string]$installLocation))) {
        Add-UniqueLeftoverItem $items (New-PathCandidate $rules ([string]$installLocation) @('installLocation') 'Install location candidate from official uninstall metadata.' ([string]$installLocation))
    }

    foreach ($rule in $knownRules) {
        foreach ($path in @(Get-RooIndustriesUninstallPropertyArray $rule 'knownAppDataPaths')) {
            if (Test-MicrosoftOwnedFilePath ([string]$path)) { continue }
            Add-UniqueLeftoverItem $items (New-PathCandidate $rules ([string]$path) @('knownAppDataPath', 'packageId', 'publisher') 'Known app data path for selected app.' ([string]$path))
        }
        foreach ($key in @(Get-RooIndustriesUninstallPropertyArray $rule 'vendorRegistryKeys')) {
            if (Test-MicrosoftOwnedRegistryPath ([string]$key)) { continue }
            $protectedRegistry = $false
            foreach ($pattern in @(Get-RooIndustriesUninstallPropertyArray $rules 'protectedRegistryPatterns')) {
                if ([string]$key -match [string]$pattern) { $protectedRegistry = $true }
            }
            Add-UniqueLeftoverItem $items (New-RooIndustriesLeftoverItem `
                -ItemId ("registry:" + (ConvertTo-RooIndustriesStableId ([string]$key))) `
                -Type 'registryKey' `
                -Target ([string]$key) `
                -MatchedBy @('vendorRegistryKey', 'publisher') `
                -Confidence $(if ($protectedRegistry) { 'low' } else { 'medium' }) `
                -Risk $(if ($protectedRegistry) { 'protected' } else { 'medium' }) `
                -DefaultSelected $false `
                -Protected $protectedRegistry `
                -Reason 'Vendor registry key candidate; registry export is required before any future cleanup.' `
                -Metadata ([pscustomobject]@{ previewOnly = $true }))
        }
    }

    Add-ServiceCandidates $items $app $knownRules
    Add-TaskCandidates $items $knownRules

    $itemArray = @($items.ToArray())
    $summary = [pscustomobject]@{
        itemCount = $itemArray.Count
        highConfidenceCount = @($itemArray | Where-Object { $_.confidence -eq 'high' }).Count
        mediumConfidenceCount = @($itemArray | Where-Object { $_.confidence -eq 'medium' }).Count
        lowConfidenceCount = @($itemArray | Where-Object { $_.confidence -eq 'low' }).Count
        defaultSelectedCount = @($itemArray | Where-Object { $_.defaultSelected }).Count
        protectedCount = @($itemArray | Where-Object { $_.protected }).Count
        estimatedRecoverableBytes = $null
        deletionMode = 'preview-only'
        willDeleteLeftovers = $false
        matchedRuleIds = @($knownRules | ForEach-Object { [string](Get-RooIndustriesUninstallPropertyValue $_ 'ruleId' '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $result = [pscustomobject]@{
        scanId = 'leftover-scan-preview-' + (ConvertTo-RooIndustriesStableId $AppId) + '-' + (Get-RooIndustriesUninstallFileStamp)
        productName = $script:RooIndustriesUninstallProductName
        schemaVersion = 1
        appId = $AppId
        displayName = [string](Get-RooIndustriesUninstallPropertyValue $app 'displayName' '')
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        classification = $classification
        summary = $summary
        items = $itemArray
        warnings = @((New-RooIndustriesUninstallIssue 'LEFTOVER_SCAN_PREVIEW_ONLY' 'Leftover scan generated candidates without deleting files, folders, services, tasks, startup entries, or registry keys.' 'info' 'apps.leftoverScan' $AppId $false 'Review candidates and backup requirements before creating a cleanup manifest.' $null))
        errors = @()
    }
    Write-RooIndustriesUninstallJsonOutput $result $OutputPath
} catch {
    $result = [pscustomobject]@{
        scanId = 'leftover-scan-preview-' + (ConvertTo-RooIndustriesStableId $AppId) + '-' + (Get-RooIndustriesUninstallFileStamp)
        productName = $script:RooIndustriesUninstallProductName
        schemaVersion = 1
        appId = $AppId
        displayName = ''
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        summary = [pscustomobject]@{ itemCount = 0; defaultSelectedCount = 0; protectedCount = 0; deletionMode = 'preview-only'; willDeleteLeftovers = $false }
        items = @()
        warnings = @()
        errors = @((New-RooIndustriesUninstallIssue 'LEFTOVER_SCAN_PREVIEW_FAILED' $_.Exception.Message 'error' 'apps.leftoverScan' $AppId $true 'Check inventory and scan rule paths.' $null))
    }
    Write-RooIndustriesUninstallJsonOutput $result $OutputPath
    exit 1
}
