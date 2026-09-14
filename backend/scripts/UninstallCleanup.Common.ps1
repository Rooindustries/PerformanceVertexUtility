$script:RooUninstallProductName = 'Roo Industries Optimization Suite'

function Get-RooUninstallUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-RooUninstallFileStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
}

function ConvertTo-RooStableId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
    $id = $Value.ToLowerInvariant() -replace '[^a-z0-9]+','-'
    return $id.Trim('-')
}

function Resolve-RooUninstallPath {
    param(
        [string]$Path,
        [string]$DefaultPath
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [System.IO.Path]::GetFullPath($DefaultPath)
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Read-RooUninstallJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Ensure-RooUninstallDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-RooUninstallJsonOutput {
    param(
        [object]$Value,
        [string]$OutputPath
    )
    $json = $Value | ConvertTo-Json -Depth 32
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolved = Resolve-RooUninstallPath $OutputPath (Join-Path (Get-Location) $OutputPath)
        Ensure-RooUninstallDirectory (Split-Path $resolved -Parent)
        $json | Set-Content -LiteralPath $resolved -Encoding UTF8
    }
    return $json
}

function Get-RooUninstallArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-RooUninstallPropertyArray {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return @() }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return @() }
    return @(Get-RooUninstallArray $prop.Value)
}

function Get-RooUninstallPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )
    if ($null -eq $Object) { return $DefaultValue }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $DefaultValue }
    if ($null -eq $prop.Value) { return $DefaultValue }
    return $prop.Value
}

function New-RooUninstallIssue {
    param(
        [string]$Code,
        [string]$Message,
        [string]$Severity = 'warning',
        [string]$Source = 'apps.uninstallCleanup',
        [string]$Target = $null,
        [bool]$Blocking = $false,
        [string]$RecommendedAction = $null,
        [object]$Details = $null
    )
    return [pscustomobject]@{
        code = $Code
        message = $Message
        severity = $Severity
        source = $Source
        target = $Target
        blocking = $Blocking
        recommendedAction = $RecommendedAction
        details = $Details
    }
}

function New-RooUninstallLog {
    param(
        [string]$Message,
        [string]$Level = 'info'
    )
    return [pscustomobject]@{
        timestampUtc = Get-RooUninstallUtcStamp
        level = $Level
        message = $Message
    }
}

function Get-RooUninstallPolicyPath {
    param([string]$PolicyPath)
    return Resolve-RooUninstallPath $PolicyPath (Join-Path $PSScriptRoot '..\uninstall\uninstall-policy.json')
}

function Get-RooProtectedAppsPath {
    param([string]$ProtectedAppsPath)
    return Resolve-RooUninstallPath $ProtectedAppsPath (Join-Path $PSScriptRoot '..\uninstall\protected-apps.json')
}

function Get-RooLeftoverRulesPath {
    param([string]$RulesPath)
    return Resolve-RooUninstallPath $RulesPath (Join-Path $PSScriptRoot '..\uninstall\leftover-scan-rules.json')
}

function Read-RooUninstallPolicy {
    param([string]$PolicyPath)
    return Read-RooUninstallJsonFile (Get-RooUninstallPolicyPath $PolicyPath)
}

function Read-RooProtectedAppsCatalog {
    param([string]$ProtectedAppsPath)
    return Read-RooUninstallJsonFile (Get-RooProtectedAppsPath $ProtectedAppsPath)
}

function Read-RooLeftoverRules {
    param([string]$RulesPath)
    return Read-RooUninstallJsonFile (Get-RooLeftoverRulesPath $RulesPath)
}

function Test-RooPatternMatch {
    param(
        [string]$Value,
        [object[]]$Patterns
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    foreach ($pattern in @(Get-RooUninstallArray $Patterns)) {
        $p = [string]$pattern
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($Value -like $p) { return $true }
    }
    return $false
}

function Test-RooAnyExactOrPatternMatch {
    param(
        [string]$Value,
        [object[]]$Patterns
    )
    return Test-RooPatternMatch $Value $Patterns
}

function Test-RooAnyCategoryMatch {
    param(
        [object]$App,
        [object[]]$Tags
    )
    $categories = @(Get-RooUninstallPropertyArray $App 'categories')
    foreach ($tag in @(Get-RooUninstallArray $Tags)) {
        foreach ($category in $categories) {
            if ([string]$category -ieq [string]$tag) { return $true }
        }
    }
    return $false
}

function Test-RooAppMatch {
    param(
        [object]$App,
        [object]$Match
    )
    if ($null -eq $App -or $null -eq $Match) { return $false }

    $hasPrimarySelector = $false
    $primaryMatched = $false
    $publisherMatched = $false
    $displayName = [string](Get-RooUninstallPropertyValue $App 'displayName' '')
    $publisher = [string](Get-RooUninstallPropertyValue $App 'publisher' '')
    $packageId = [string](Get-RooUninstallPropertyValue $App 'packageId' '')
    $sourceType = [string](Get-RooUninstallPropertyValue $App 'sourceType' '')

    $displayNamePatterns = Get-RooUninstallPropertyArray $Match 'displayNamePatterns'
    if ($displayNamePatterns.Count -gt 0) {
        $hasPrimarySelector = $true
        if (Test-RooAnyExactOrPatternMatch $displayName $displayNamePatterns) { $primaryMatched = $true }
    }

    $publisherPatterns = Get-RooUninstallPropertyArray $Match 'publisherPatterns'
    if ($publisherPatterns.Count -gt 0) {
        if (Test-RooAnyExactOrPatternMatch $publisher $publisherPatterns) { $publisherMatched = $true }
    }

    $packageIdPatterns = Get-RooUninstallPropertyArray $Match 'packageIdPatterns'
    if ($packageIdPatterns.Count -gt 0) {
        $hasPrimarySelector = $true
        if (Test-RooAnyExactOrPatternMatch $packageId $packageIdPatterns) { $primaryMatched = $true }
    }

    $sourceTypes = Get-RooUninstallPropertyArray $Match 'sourceTypes'
    if ($sourceTypes.Count -gt 0) {
        $hasPrimarySelector = $true
        foreach ($candidate in $sourceTypes) {
            if ($sourceType -ieq [string]$candidate) { $primaryMatched = $true }
        }
    }

    $categoryTags = Get-RooUninstallPropertyArray $Match 'categoryTags'
    if ($categoryTags.Count -gt 0) {
        $hasPrimarySelector = $true
        if (Test-RooAnyCategoryMatch $App $categoryTags) { $primaryMatched = $true }
    }

    if ($hasPrimarySelector) {
        if (-not $primaryMatched) { return $false }
        if ($publisherPatterns.Count -gt 0 -and -not $publisherMatched) { return $false }
        return $true
    }

    if ($publisherPatterns.Count -gt 0) { return $publisherMatched }
    return $false
}

function Get-RooInstalledAppInventory {
    param([string]$InventoryPath)
    if (-not [string]::IsNullOrWhiteSpace($InventoryPath)) {
        $resolved = Resolve-RooUninstallPath $InventoryPath $InventoryPath
        return Read-RooUninstallJsonFile $resolved
    }
    $output = & (Join-Path $PSScriptRoot 'Get-InstalledAppInventory.ps1')
    return $output | ConvertFrom-Json
}

function Find-RooInstalledApp {
    param(
        [object]$Inventory,
        [string]$AppId
    )
    foreach ($app in @(Get-RooUninstallPropertyArray $Inventory 'apps')) {
        if ([string](Get-RooUninstallPropertyValue $app 'appId' '') -eq $AppId) { return $app }
    }
    return $null
}

function Get-RooProtectedAppMatches {
    param(
        [object]$App,
        [object]$ProtectedCatalog
    )
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-RooUninstallPropertyArray $ProtectedCatalog 'protectedApps')) {
        if (Test-RooAppMatch $App (Get-RooUninstallPropertyValue $item 'match' $null)) {
            $matches.Add($item) | Out-Null
        }
    }
    return @($matches.ToArray())
}

function Get-RooDerivedAppType {
    param([object]$App)
    $name = [string](Get-RooUninstallPropertyValue $App 'displayName' '')
    $publisher = [string](Get-RooUninstallPropertyValue $App 'publisher' '')
    $packageId = [string](Get-RooUninstallPropertyValue $App 'packageId' '')
    $sourceType = [string](Get-RooUninstallPropertyValue $App 'sourceType' '')
    $text = ($name + ' ' + $publisher + ' ' + $packageId).ToLowerInvariant()
    $categories = @(Get-RooUninstallPropertyArray $App 'categories' | ForEach-Object { ([string]$_).ToLowerInvariant() })

    if ($text -match 'easy anti-cheat|easyanticheat|battleye|battl[e]?eye|vanguard|faceit') { return 'anti-cheat' }
    if ($text -match 'defender|security|firewall|tailscale|wireguard|openvpn|zerotier|vpn|network driver|wi-fi driver|ethernet driver') { return 'security-network-component' }
    if ($text -match 'webview2|microsoft store|gaming services|xbox|windows app runtime|vclibs|ui\.xaml') { return 'store-webview2' }
    if ($sourceType -eq 'appx' -and $publisher -match 'Microsoft') { return 'windows-component' }
    if ($text -match 'visual c\+\+|redistributable|microsoft \.net|\.net runtime|asp\.net|windows desktop runtime|directx|\bruntime\b') { return 'shared-runtime' }
    if ($text -match 'driver.*support assistant|support assistant|updater|update-helper') { return 'vendor-tool' }
    if ($text -match 'graphics driver|display driver|audio driver|bluetooth driver|chipset driver|realtek|nvidia.*driver|amd.*driver|intel.*driver') { return 'driver' }
    if ($text -match 'obs studio|discord' -or $categories -contains 'stream-companion' -or $categories -contains 'target-scenario') { return 'obs-discord-dependency' }
    if ($categories -contains 'overlay' -or $text -match 'overwolf|overlay|rtss|rivatuner|afterburner|nvidia app|geforce experience') { return 'overlay' }
    if ($categories -contains 'launcher' -or $text -match 'steam|battle\.net|epic games launcher|riot client|ubisoft connect|ea app|launcher') { return 'launcher' }
    if ($categories -contains 'vendor-tool' -or $text -match 'asus|armoury|intel driver.*support assistant|logitech|razer|samsung|corsair|steelseries') { return 'vendor-tool' }
    return 'normal-app'
}

function Get-RooAppTypeRank {
    param([string]$AppType)
    switch ($AppType) {
        'normal-app' { return 0 }
        'launcher' { return 1 }
        'overlay' { return 1 }
        'vendor-tool' { return 1 }
        'windows-component' { return 2 }
        'protected-windows-component' { return 2 }
        'shared-runtime' { return 3 }
        'driver' { return 3 }
        'security-network-component' { return 3 }
        'store-webview2' { return 4 }
        'anti-cheat' { return 4 }
        'obs-discord-dependency' { return 4 }
        default { return 0 }
    }
}

function Get-RooRiskRank {
    param([string]$Risk)
    switch ($Risk) {
        'safe' { return 0 }
        'low' { return 1 }
        'medium' { return 2 }
        'high' { return 3 }
        'advanced' { return 4 }
        'protected' { return 4 }
        default { return 2 }
    }
}

function Select-RooHigherRisk {
    param(
        [string]$Left,
        [string]$Right
    )
    if ((Get-RooRiskRank $Right) -gt (Get-RooRiskRank $Left)) { return $Right }
    return $Left
}

function Get-RooAppClassification {
    param(
        [object]$App,
        [object]$ProtectedCatalog,
        [object]$Policy
    )
    $appType = Get-RooDerivedAppType $App
    $protectedMatches = @(Get-RooProtectedAppMatches $App $ProtectedCatalog)
    $risk = [string](Get-RooUninstallPropertyValue $App 'risk' 'low')
    if ([string]::IsNullOrWhiteSpace($risk)) { $risk = 'low' }
    $reviewRequired = [bool](Get-RooUninstallPropertyValue $App 'protected' $false)
    $protected = $false
    $blockByDefault = $false
    $reasonCodes = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]
    $matchedRuleIds = New-Object System.Collections.Generic.List[string]
    $recommendedAction = 'Eligible for uninstall queue preview. Official uninstall must be reviewed before any future execution.'

    foreach ($reason in @(Get-RooUninstallPropertyArray $App 'protectionReasons')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$reason)) { $reasons.Add([string]$reason) | Out-Null }
    }

    foreach ($match in $protectedMatches) {
        $reviewRequired = $true
        $matchRisk = [string](Get-RooUninstallPropertyValue $match 'risk' 'advanced')
        if ($matchRisk -eq 'protected') { $matchRisk = 'advanced' }
        $risk = Select-RooHigherRisk $risk $matchRisk
        $matchedRuleIds.Add([string](Get-RooUninstallPropertyValue $match 'itemId' '')) | Out-Null
        $reasons.Add([string](Get-RooUninstallPropertyValue $match 'reason' 'Manual review required by uninstall catalog.')) | Out-Null
        $matchedAppType = [string](Get-RooUninstallPropertyValue $match 'appType' $appType)
        if ((Get-RooAppTypeRank $matchedAppType) -ge (Get-RooAppTypeRank $appType)) {
            $appType = $matchedAppType
        }
    }

    if ($reviewRequired) {
        if ($risk -eq 'protected') { $risk = 'advanced' }
        $recommendedAction = 'Needs manual review before apply. Queue preview can still show the route and cleanup list.'
    }

    if ($protectedMatches.Count -gt 0) {
        $reasonCodes.Add('MANUAL_REVIEW_CATALOG_MATCH') | Out-Null
    }
    if ($reviewRequired -and $reasonCodes.Count -eq 0) {
        $reasonCodes.Add('INVENTORY_REVIEW_REQUIRED') | Out-Null
    }
    if ($reasonCodes.Count -eq 0) {
        $reasonCodes.Add('APP_CLASSIFIED') | Out-Null
    }

    return [pscustomobject]@{
        appId = [string](Get-RooUninstallPropertyValue $App 'appId' '')
        displayName = [string](Get-RooUninstallPropertyValue $App 'displayName' '')
        publisher = Get-RooUninstallPropertyValue $App 'publisher' $null
        sourceType = [string](Get-RooUninstallPropertyValue $App 'sourceType' '')
        packageId = Get-RooUninstallPropertyValue $App 'packageId' $null
        categories = @(Get-RooUninstallPropertyArray $App 'categories')
        primaryClassification = $appType
        risk = $risk
        protected = $false
        blockByDefault = $blockByDefault
        matchedProtectedRuleIds = @($matchedRuleIds.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        reasonCodes = @($reasonCodes.ToArray() | Select-Object -Unique)
        protectionReasons = @($reasons.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        recommendedAction = $recommendedAction
        uninstallSafety = [pscustomobject]@{
            officialUninstallPreviewOnly = $true
            queueAllowedByDefault = $true
            leftoverDeletionPreviewOnly = $true
            confirmedExecutionEnabled = $false
        }
    }
}

function Split-RooUninstallCommandLine {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return [pscustomobject]@{ executable = $null; arguments = $null; rawCommand = $null }
    }
    $trimmed = $CommandLine.Trim()
    $executable = $trimmed
    $arguments = ''
    if ($trimmed.StartsWith('"')) {
        $end = $trimmed.IndexOf('"', 1)
        if ($end -gt 0) {
            $executable = $trimmed.Substring(1, $end - 1)
            $arguments = $trimmed.Substring($end + 1).Trim()
        }
    } else {
        $firstSpace = $trimmed.IndexOf(' ')
        if ($firstSpace -gt 0) {
            $executable = $trimmed.Substring(0, $firstSpace)
            $arguments = $trimmed.Substring($firstSpace + 1).Trim()
        }
    }
    return [pscustomobject]@{
        executable = $executable
        arguments = if ([string]::IsNullOrWhiteSpace($arguments)) { $null } else { $arguments }
        rawCommand = $trimmed
    }
}

function Resolve-RooEnvironmentPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Test-RooProtectedPath {
    param(
        [string]$Path,
        [object]$Rules
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $expandedPath = Resolve-RooEnvironmentPath $Path
    foreach ($item in @(Get-RooUninstallPropertyArray $Rules 'protectedPaths')) {
        $pattern = Resolve-RooEnvironmentPath ([string](Get-RooUninstallPropertyValue $item 'pathPattern' ''))
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $expandedPath -like $pattern) { return $true }
    }
    return $false
}

function New-RooLeftoverItem {
    param(
        [string]$ItemId,
        [string]$Type,
        [string]$Target,
        [string[]]$MatchedBy,
        [string]$Confidence,
        [string]$Risk,
        [bool]$DefaultSelected,
        [bool]$Protected,
        [string]$Reason,
        [object]$Metadata = $null
    )
    return [pscustomobject]@{
        itemId = $ItemId
        type = $Type
        target = $Target
        matchedBy = @(Get-RooUninstallArray $MatchedBy)
        confidence = $Confidence
        risk = $Risk
        defaultSelected = ($DefaultSelected -and -not $Protected)
        protected = $Protected
        reason = $Reason
        metadata = $Metadata
    }
}
