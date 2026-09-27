. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
$script:RooIndustriesUninstallProductName = 'Roo Industries Optimization Suite'

function Get-RooIndustriesUninstallUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-RooIndustriesUninstallFileStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
}

function ConvertTo-RooIndustriesStableId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
    $id = $Value.ToLowerInvariant() -replace '[^a-z0-9]+','-'
    return $id.Trim('-')
}

function Resolve-RooIndustriesUninstallPath {
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

function Read-RooIndustriesUninstallJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-RooIndustriesCleanupJournal {
    param([object]$Value, [string]$Path)
    Ensure-RooIndustriesUninstallDirectory (Split-Path $Path -Parent)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 32))
        $stream = [System.IO.File]::Open($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [System.IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Test-RooIndustriesCleanupPathWithin {
    param([string]$Path, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $parent = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return ($full.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-RooIndustriesCleanupReparsePath {
    param([string]$Path, [switch]$Recurse)
    $current = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $true }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    if ($Recurse -and (Test-Path -LiteralPath $Path -PathType Container)) {
        $pending = New-Object System.Collections.Generic.Stack[string]
        $pending.Push($Path)
        while ($pending.Count -gt 0) {
            foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
                if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
                if ($child.PSIsContainer) { $pending.Push($child.FullName) }
            }
        }
    }
    return $false
}

function Copy-RooIndustriesCleanupRestoreTree {
    param([string]$Source, [string]$Target)
    if ((Test-RooIndustriesCleanupReparsePath $Source) -or (Test-RooIndustriesCleanupReparsePath $Target)) { throw 'Restore encountered a reparse path.' }
    Ensure-RooIndustriesUninstallDirectory $Target
    foreach ($child in Get-ChildItem -LiteralPath $Source -Force) {
        if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Restore encountered a reparse path.' }
        $destination = Join-Path $Target $child.Name
        if ($child.PSIsContainer) { Copy-RooIndustriesCleanupRestoreTree $child.FullName $destination }
        else { Copy-Item -LiteralPath $child.FullName -Destination $destination -Force }
    }
}

function Ensure-RooIndustriesUninstallDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-RooIndustriesUninstallJsonOutput {
    param(
        [object]$Value,
        [string]$OutputPath
    )
    $json = $Value | ConvertTo-Json -Depth 32
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolved = Resolve-RooIndustriesUninstallPath $OutputPath (Join-Path (Get-Location) $OutputPath)
        Ensure-RooIndustriesUninstallDirectory (Split-Path $resolved -Parent)
        $json | Set-Content -LiteralPath $resolved -Encoding UTF8
    }
    return $json
}

function Get-RooIndustriesUninstallArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-RooIndustriesUninstallPropertyArray {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return @() }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return @() }
    return @(Get-RooIndustriesUninstallArray $prop.Value)
}

function Get-RooIndustriesUninstallPropertyValue {
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

function New-RooIndustriesUninstallIssue {
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

function New-RooIndustriesUninstallLog {
    param(
        [string]$Message,
        [string]$Level = 'info'
    )
    return [pscustomobject]@{
        timestampUtc = Get-RooIndustriesUninstallUtcStamp
        level = $Level
        message = $Message
    }
}

function Get-RooIndustriesUninstallPolicyPath {
    param([string]$PolicyPath)
    return Resolve-RooIndustriesUninstallPath $PolicyPath (Join-Path $PSScriptRoot '..\uninstall\uninstall-policy.json')
}

function Get-RooIndustriesProtectedAppsPath {
    param([string]$ProtectedAppsPath)
    return Resolve-RooIndustriesUninstallPath $ProtectedAppsPath (Join-Path $PSScriptRoot '..\uninstall\protected-apps.json')
}

function Get-RooIndustriesLeftoverRulesPath {
    param([string]$RulesPath)
    return Resolve-RooIndustriesUninstallPath $RulesPath (Join-Path $PSScriptRoot '..\uninstall\leftover-scan-rules.json')
}

function Read-RooIndustriesUninstallPolicy {
    param([string]$PolicyPath)
    return Read-RooIndustriesUninstallJsonFile (Get-RooIndustriesUninstallPolicyPath $PolicyPath)
}

function Read-RooIndustriesProtectedAppsCatalog {
    param([string]$ProtectedAppsPath)
    return Read-RooIndustriesUninstallJsonFile (Get-RooIndustriesProtectedAppsPath $ProtectedAppsPath)
}

function Read-RooIndustriesLeftoverRules {
    param([string]$RulesPath)
    return Read-RooIndustriesUninstallJsonFile (Get-RooIndustriesLeftoverRulesPath $RulesPath)
}

function Test-RooIndustriesPatternMatch {
    param(
        [string]$Value,
        [object[]]$Patterns
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    foreach ($pattern in @(Get-RooIndustriesUninstallArray $Patterns)) {
        $p = [string]$pattern
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($Value -like $p) { return $true }
    }
    return $false
}

function Test-RooIndustriesAnyExactOrPatternMatch {
    param(
        [string]$Value,
        [object[]]$Patterns
    )
    return Test-RooIndustriesPatternMatch $Value $Patterns
}

function Test-RooIndustriesAnyCategoryMatch {
    param(
        [object]$App,
        [object[]]$Tags
    )
    $categories = @(Get-RooIndustriesUninstallPropertyArray $App 'categories')
    foreach ($tag in @(Get-RooIndustriesUninstallArray $Tags)) {
        foreach ($category in $categories) {
            if ([string]$category -ieq [string]$tag) { return $true }
        }
    }
    return $false
}

function Test-RooIndustriesAppMatch {
    param(
        [object]$App,
        [object]$Match
    )
    if ($null -eq $App -or $null -eq $Match) { return $false }

    $hasPrimarySelector = $false
    $primaryMatched = $false
    $publisherMatched = $false
    $displayName = [string](Get-RooIndustriesUninstallPropertyValue $App 'displayName' '')
    $publisher = [string](Get-RooIndustriesUninstallPropertyValue $App 'publisher' '')
    $packageId = [string](Get-RooIndustriesUninstallPropertyValue $App 'packageId' '')
    $sourceType = [string](Get-RooIndustriesUninstallPropertyValue $App 'sourceType' '')

    $displayNamePatterns = Get-RooIndustriesUninstallPropertyArray $Match 'displayNamePatterns'
    if ($displayNamePatterns.Count -gt 0) {
        $hasPrimarySelector = $true
        if (Test-RooIndustriesAnyExactOrPatternMatch $displayName $displayNamePatterns) { $primaryMatched = $true }
    }

    $publisherPatterns = Get-RooIndustriesUninstallPropertyArray $Match 'publisherPatterns'
    if ($publisherPatterns.Count -gt 0) {
        if (Test-RooIndustriesAnyExactOrPatternMatch $publisher $publisherPatterns) { $publisherMatched = $true }
    }

    $packageIdPatterns = Get-RooIndustriesUninstallPropertyArray $Match 'packageIdPatterns'
    if ($packageIdPatterns.Count -gt 0) {
        $hasPrimarySelector = $true
        if ((Test-RooIndustriesAnyExactOrPatternMatch $packageId $packageIdPatterns) -or
            (Test-RooIndustriesAnyExactOrPatternMatch ([string](Get-RooIndustriesUninstallPropertyValue $App 'packageFamilyName' '')) $packageIdPatterns)) { $primaryMatched = $true }
    }

    $sourceTypes = Get-RooIndustriesUninstallPropertyArray $Match 'sourceTypes'
    if ($sourceTypes.Count -gt 0) {
        $hasPrimarySelector = $true
        foreach ($candidate in $sourceTypes) {
            if ($sourceType -ieq [string]$candidate) { $primaryMatched = $true }
        }
    }

    $categoryTags = Get-RooIndustriesUninstallPropertyArray $Match 'categoryTags'
    if ($categoryTags.Count -gt 0) {
        $hasPrimarySelector = $true
        if (Test-RooIndustriesAnyCategoryMatch $App $categoryTags) { $primaryMatched = $true }
    }

    if ($hasPrimarySelector) {
        if (-not $primaryMatched) { return $false }
        if ($publisherPatterns.Count -gt 0 -and -not $publisherMatched) { return $false }
        return $true
    }

    if ($publisherPatterns.Count -gt 0) { return $publisherMatched }
    return $false
}

function Get-RooIndustriesInstalledAppInventory {
    param([string]$InventoryPath,[switch]$IncludeAllAppxUsers)
    if (-not [string]::IsNullOrWhiteSpace($InventoryPath)) {
        $resolved = Resolve-RooIndustriesUninstallPath $InventoryPath $InventoryPath
        return Read-RooIndustriesUninstallJsonFile $resolved
    }
    $output = & (Join-Path $PSScriptRoot 'Get-InstalledAppInventory.ps1') -IncludeAllAppxUsers:$IncludeAllAppxUsers
    return $output | ConvertFrom-Json
}

function Find-RooIndustriesInstalledApp {
    param(
        [object]$Inventory,
        [string]$AppId
    )
    $matches=@(Get-RooIndustriesUninstallPropertyArray $Inventory 'apps' | Where-Object { [string](Get-RooIndustriesUninstallPropertyValue $_ 'appId' '') -eq $AppId })
    if($matches.Count -gt 1){throw "Inventory contains multiple records for app ID $AppId. Refresh inventory before selecting a removal target."}
    if($matches.Count -eq 1){return $matches[0]}
    return $null
}

function Get-RooIndustriesProtectedAppMatches {
    param(
        [object]$App,
        [object]$ProtectedCatalog
    )
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-RooIndustriesUninstallPropertyArray $ProtectedCatalog 'protectedApps')) {
        if (Test-RooIndustriesAppMatch $App (Get-RooIndustriesUninstallPropertyValue $item 'match' $null)) {
            $matches.Add($item) | Out-Null
        }
    }
    return @($matches.ToArray())
}

function Get-RooIndustriesDerivedAppType {
    param([object]$App)
    $name = [string](Get-RooIndustriesUninstallPropertyValue $App 'displayName' '')
    $publisher = [string](Get-RooIndustriesUninstallPropertyValue $App 'publisher' '')
    $packageId = [string](Get-RooIndustriesUninstallPropertyValue $App 'packageId' '')
    $sourceType = [string](Get-RooIndustriesUninstallPropertyValue $App 'sourceType' '')
    $text = ($name + ' ' + $publisher + ' ' + $packageId).ToLowerInvariant()
    $categories = @(Get-RooIndustriesUninstallPropertyArray $App 'categories' | ForEach-Object { ([string]$_).ToLowerInvariant() })

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

function Get-RooIndustriesAppTypeRank {
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

function Get-RooIndustriesRiskRank {
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

function Select-RooIndustriesHigherRisk {
    param(
        [string]$Left,
        [string]$Right
    )
    if ((Get-RooIndustriesRiskRank $Right) -gt (Get-RooIndustriesRiskRank $Left)) { return $Right }
    return $Left
}

function Get-RooIndustriesAppClassification {
    param(
        [object]$App,
        [object]$ProtectedCatalog,
        [object]$Policy
    )
    $appType = Get-RooIndustriesDerivedAppType $App
    $protectedMatches = @(Get-RooIndustriesProtectedAppMatches $App $ProtectedCatalog)
    $risk = [string](Get-RooIndustriesUninstallPropertyValue $App 'risk' 'low')
    if ([string]::IsNullOrWhiteSpace($risk)) { $risk = 'low' }
    $reviewRequired = [bool](Get-RooIndustriesUninstallPropertyValue $App 'protected' $false)
    $protected = $false
    $blockByDefault = $false
    $reasonCodes = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]
    $matchedRuleIds = New-Object System.Collections.Generic.List[string]
    $recommendedAction = 'Eligible for uninstall queue preview. Official uninstall must be reviewed before any future execution.'

    foreach ($reason in @(Get-RooIndustriesUninstallPropertyArray $App 'protectionReasons')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$reason)) { $reasons.Add([string]$reason) | Out-Null }
    }

    foreach ($match in $protectedMatches) {
        $reviewRequired = $true
        $matchRisk = [string](Get-RooIndustriesUninstallPropertyValue $match 'risk' 'advanced')
        if ($matchRisk -eq 'protected') { $matchRisk = 'advanced' }
        $risk = Select-RooIndustriesHigherRisk $risk $matchRisk
        $matchedRuleIds.Add([string](Get-RooIndustriesUninstallPropertyValue $match 'itemId' '')) | Out-Null
        $reasons.Add([string](Get-RooIndustriesUninstallPropertyValue $match 'reason' 'Manual review required by uninstall catalog.')) | Out-Null
        $matchedAppType = [string](Get-RooIndustriesUninstallPropertyValue $match 'appType' $appType)
        if ((Get-RooIndustriesAppTypeRank $matchedAppType) -ge (Get-RooIndustriesAppTypeRank $appType)) {
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
        appId = [string](Get-RooIndustriesUninstallPropertyValue $App 'appId' '')
        displayName = [string](Get-RooIndustriesUninstallPropertyValue $App 'displayName' '')
        publisher = Get-RooIndustriesUninstallPropertyValue $App 'publisher' $null
        sourceType = [string](Get-RooIndustriesUninstallPropertyValue $App 'sourceType' '')
        packageId = Get-RooIndustriesUninstallPropertyValue $App 'packageId' $null
        categories = @(Get-RooIndustriesUninstallPropertyArray $App 'categories')
        primaryClassification = $appType
        risk = $risk
        protected = $false
        blockByDefault = $blockByDefault
        reviewRequired = $reviewRequired
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

function Get-RooIndustriesMsiUninstallArguments {
    param([guid]$ProductCode,[switch]$Quiet)
    $code = $ProductCode.ToString('B').ToUpperInvariant()
    if ($Quiet) { return "/x $code /qn /norestart" }
    return "/x $code /norestart"
}

function Get-RooIndustriesUninstallCommandLine {
    param([string]$Executable, [string]$Arguments)
    return '"' + $Executable + '"' + $(if ($Arguments) { ' ' + $Arguments } else { '' })
}

function Get-RooIndustriesReviewedUninstallCommandLine {
    param([string]$Executable, [string]$Arguments)
    try {
        if ([string]::IsNullOrWhiteSpace($Executable) -or -not [IO.Path]::IsPathRooted($Executable)) { return $null }
        return Get-RooIndustriesUninstallCommandLine ([IO.Path]::GetFullPath($Executable)) $Arguments
    } catch { return $null }
}

function Get-RooIndustriesUninstallExecutableFacts {
    param([string]$Executable)
    try {
        if ([string]::IsNullOrWhiteSpace($Executable) -or -not [IO.Path]::IsPathRooted($Executable)) { return [pscustomobject]@{ state = 'unresolved'; sha256 = $null } }
        $full = [IO.Path]::GetFullPath($Executable)
        if (-not [IO.File]::Exists($full)) { return [pscustomobject]@{ state = 'missing'; sha256 = $null } }
        return [pscustomobject]@{ state = 'present'; sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
    } catch { return [pscustomobject]@{ state = 'unreadable'; sha256 = $null } }
}

function Get-RooIndustriesReviewedUninstallExecutableHash {
    param([string]$Executable)
    return (Get-RooIndustriesUninstallExecutableFacts $Executable).sha256
}

function Split-RooIndustriesUninstallCommandLine {
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

function Resolve-RooIndustriesUninstallCommandLine {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $trimmed = $CommandLine.Trim()
    if ($trimmed.StartsWith('"')) {
        $parsed = Split-RooIndustriesUninstallCommandLine $trimmed
        $candidates = @([pscustomobject]@{ path = [string]$parsed.executable; arguments = [string]$parsed.arguments })
    } else {
        $candidates = @()
        $index = 0
        while ($index -le $trimmed.Length) {
            $space = $trimmed.IndexOf(' ', $index)
            if ($space -lt 0) { $space = $trimmed.Length }
            $candidates += [pscustomobject]@{ path = $trimmed.Substring(0, $space); arguments = $trimmed.Substring($space).Trim() }
            $index = $space + 1
        }
    }
    foreach ($candidate in $candidates) {
        $path = [Environment]::ExpandEnvironmentVariables($candidate.path)
        try {
            if ([IO.Path]::GetExtension($path) -eq '') { $path += '.exe' }
            if ([IO.Path]::IsPathRooted($path) -and [IO.File]::Exists($path)) {
                return [pscustomobject]@{ executable = [IO.Path]::GetFullPath($path); arguments = if ([string]::IsNullOrWhiteSpace($candidate.arguments)) { $null } else { $candidate.arguments } }
            }
        } catch [ArgumentException] { }
    }
    return $null
}

function Resolve-RooIndustriesEnvironmentPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Test-RooIndustriesProtectedPath {
    param(
        [string]$Path,
        [object]$Rules
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $expandedPath = Resolve-RooIndustriesEnvironmentPath $Path
    foreach ($item in @(Get-RooIndustriesUninstallPropertyArray $Rules 'protectedPaths')) {
        $pattern = Resolve-RooIndustriesEnvironmentPath ([string](Get-RooIndustriesUninstallPropertyValue $item 'pathPattern' ''))
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $expandedPath -like $pattern) { return $true }
    }
    return $false
}

function New-RooIndustriesLeftoverItem {
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
        matchedBy = @(Get-RooIndustriesUninstallArray $MatchedBy)
        confidence = $Confidence
        risk = $Risk
        defaultSelected = ($DefaultSelected -and -not $Protected)
        protected = $Protected
        reason = $Reason
        metadata = $Metadata
    }
}
function Assert-RooIndustriesCleanupExclusions {
    param([string[]]$Targets,[string]$DataRoot=(Get-RooIndustriesLocalDataRoot))
    $policy=Join-Path $DataRoot 'cleanup-exclusions.json'
    if(@($Targets).Count -eq 0){return}
    try {Get-Item -LiteralPath $policy -Force -ErrorAction Stop|Out-Null}
    catch [System.Management.Automation.ItemNotFoundException] {return}
    $saved=$null
    try {$saved=[IO.File]::ReadAllText($policy)|ConvertFrom-Json} catch {$saved=$null}
    if($null -ne $saved -and $saved.schemaVersion -eq 1 -and $null -ne $saved.owner -and [string]$saved.owner.userSid -ceq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -and [string]$saved.owner.machine -ieq $env:COMPUTERNAME -and $null -ne $saved.exclusions -and $null -ne $saved.exclusions.paths -and $null -ne $saved.exclusions.registry -and @($saved.exclusions.paths).Count -eq 0 -and @($saved.exclusions.registry).Count -eq 0){return}
    & (Join-Path $PSScriptRoot 'Invoke-CleanupExclusions.ps1') -Action Check -FileTarget $Targets|Out-Null
}
