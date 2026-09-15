param(
    [switch]$IncludeWinget
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstalledAppIdentity.Common.ps1')
$currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Convert-ToStableId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
    $id = $Value.ToLowerInvariant() -replace '[^a-z0-9]+','-'
    return $id.Trim('-')
}

function Convert-EstimatedSizeBytes {
    param([object]$EstimatedSizeKb)
    if ($null -eq $EstimatedSizeKb) { return $null }
    try { return [uint64]$EstimatedSizeKb * 1KB } catch { return $null }
}

function Get-AppRisk {
    param([string]$Name, [string]$Publisher)
    $text = (($Name + ' ' + $Publisher) -as [string]).ToLowerInvariant()
    if ($text -match 'visual c\+\+|redistributable|\.net|directx|webview2|windows desktop runtime|microsoft store|windows app runtime|graphics driver|audio driver|network driver|defender|security') { return 'advanced' }
    if ($text -match 'driver|nvidia|amd|intel|realtek|tailscale|vpn|anticheat|anti-cheat|battleye|easy anti-cheat|vanguard') { return 'medium' }
    if ($text -match 'overlay|overwolf|afterburner|rtss|uninstaller|cleanup') { return 'medium' }
    return 'low'
}

function Get-AppCategories {
    param([string]$Name, [string]$Publisher)
    $text = (($Name + ' ' + $Publisher) -as [string]).ToLowerInvariant()
    $tags = New-Object System.Collections.Generic.List[string]
    if ($text -match 'steam|battle\.net|epic games|riot|ubisoft|ea app|launcher') { $tags.Add('launcher') }
    if ($text -match 'obs|streamlabs|capture') { $tags.Add('capture') }
    if ($text -match 'discord|teamspeak|voice') { $tags.Add('voice-chat') }
    if ($text -match 'overwolf|overlay|geforce experience|nvidia app|rtss|afterburner') { $tags.Add('overlay') }
    if ($text -match 'intel|nvidia|amd|asus|realtek|samsung|logitech|razer') { $tags.Add('vendor-tool') }
    if ($text -match 'visual c\+\+|redistributable|\.net|directx|runtime|webview2') { $tags.Add('runtime') }
    if ($tags.Count -eq 0) { $tags.Add('application') }
    return @($tags.ToArray() | Select-Object -Unique)
}

function Get-StartupImpact {
    param([string]$Name, [string]$Publisher)
    $text = (($Name + ' ' + $Publisher) -as [string]).ToLowerInvariant()
    if ($text -match 'steam|epic|battle\.net|riot|discord|overwolf|teams|onedrive') { return 'high' }
    if ($text -match 'nvidia app|geforce|intel|asus|realtek|updater|launcher|overlay') { return 'medium' }
    if ($text -match 'runtime|redistributable|webview2|\.net|directx') { return 'none' }
    return 'unknown'
}

function New-AppRecord {
    param([object]$Item, [string]$SourceType, [object]$Identity)
    $name = [string]$Item.DisplayName
    $publisher = if ($Item.Publisher) { [string]$Item.Publisher } else { $null }
    $risk = Get-AppRisk $name $publisher
    $isMsi = ($Item.WindowsInstaller -eq 1 -and [string]$Item.PSChildName -match '^\{[0-9a-fA-F-]{36}\}$')
    [pscustomobject]@{
        appId = $Identity.stableId
        sourceIdentity = $Identity
        displayName = $name
        publisher = $publisher
        version = if ($Item.DisplayVersion) { [string]$Item.DisplayVersion } else { $null }
        installLocation = if ($Item.InstallLocation) { [string]$Item.InstallLocation } else { $null }
        uninstallString = if ($Item.UninstallString) { [string]$Item.UninstallString } else { $null }
        quietUninstallString = if ($Item.QuietUninstallString) { [string]$Item.QuietUninstallString } else { $null }
        sourceType = if ($isMsi) { 'msi' } else { $SourceType }
        packageId = if ($Item.PSChildName) { [string]$Item.PSChildName } else { $null }
        estimatedSizeBytes = Convert-EstimatedSizeBytes $Item.EstimatedSize
        installDate = if ($Item.InstallDate) { [string]$Item.InstallDate } else { $null }
        categories = @(Get-AppCategories $name $publisher)
        risk = $risk
        protected = $false
        protectionReasons = @(if ($risk -eq 'advanced') { 'Shared runtime, driver-adjacent component, security component, or Windows dependency requiring manual review' })
        startupImpact = Get-StartupImpact $name $publisher
    }
}

$apps = New-Object System.Collections.Generic.List[object]
$sources = New-Object System.Collections.Generic.List[string]
$sourceErrors = New-Object System.Collections.Generic.List[string]

$registryPath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
$views = if ([Environment]::Is64BitOperatingSystem) { @('Registry64','Registry32') } else { @('Registry32') }
foreach ($hive in @('LocalMachine','CurrentUser')) {
    $hiveViews=if($hive -eq 'CurrentUser'){@('Registry32')}else{$views}
    foreach ($view in $hiveViews) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$hive, [Microsoft.Win32.RegistryView]::$view)
        $uninstall = $null
        try {
            $uninstall = $base.OpenSubKey($registryPath, $false)
            if ($null -eq $uninstall) { continue }
            foreach ($keyName in $uninstall.GetSubKeyNames()) {
                $key = $uninstall.OpenSubKey($keyName, $false)
                if ($null -eq $key) { continue }
                try {
                    $record = @{PSChildName=$keyName}
                    foreach ($valueName in $key.GetValueNames()) { $record[$valueName]=$key.GetValue($valueName) }
                    if ([string]::IsNullOrWhiteSpace([string]$record.DisplayName)) { continue }
                    $identity = New-RooRegistryAppIdentity $hive $view $keyName $currentUserSid
                    $apps.Add((New-AppRecord ([pscustomobject]$record) 'registry' $identity)) | Out-Null
                    if (-not $sources.Contains('registry')) { $sources.Add('registry') | Out-Null }
                } finally { $key.Dispose() }
            }
        } finally { if ($null -ne $uninstall) {$uninstall.Dispose()}; $base.Dispose() }
    }
}

if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
    $appxErrors = @()
    $appxItems = @(Get-AppxPackage -ErrorAction SilentlyContinue -ErrorVariable appxErrors)
    foreach($errorRecord in $appxErrors){$sourceErrors.Add([string]$errorRecord)}
    if ($appxItems.Count -gt 0) { $sources.Add('appx') | Out-Null }
    foreach ($pkg in $appxItems) {
        $identity = New-RooAppxIdentity $pkg.PackageFullName $pkg.PackageFamilyName $currentUserSid
        $risk = Get-AppRisk $pkg.Name $pkg.Publisher
        $reviewRequired = ($risk -eq 'advanced' -or $pkg.Publisher -match 'Microsoft')
        $apps.Add([pscustomobject]@{
            appId = $identity.stableId
            sourceIdentity = $identity
            displayName = [string]$pkg.Name
            publisher = [string]$pkg.Publisher
            version = [string]$pkg.Version
            installLocation = if ($pkg.InstallLocation) { [string]$pkg.InstallLocation } else { $null }
            uninstallString = $null
            quietUninstallString = $null
            sourceType = 'appx'
            packageId = [string]$pkg.PackageFullName
            packageFamilyName = [string]$pkg.PackageFamilyName
            estimatedSizeBytes = $null
            installDate = $null
            categories = @(Get-AppCategories $pkg.Name $pkg.Publisher)
            risk = if ($reviewRequired -and $risk -eq 'low') { 'advanced' } else { $risk }
            protected = $false
            protectionReasons = @(if ($reviewRequired) { 'Appx package requires dependency review before removal' })
            startupImpact = Get-StartupImpact $pkg.Name $pkg.Publisher
        }) | Out-Null
    }
} else {$sourceErrors.Add('The Appx inventory provider is unavailable.')}


if ($IncludeWinget) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        $sources.Add('winget') | Out-Null
        try {
            $wingetPath = [string]$winget.Source
            $lines = @(& $wingetPath list --accept-source-agreements --disable-interactivity 2>$null)
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line -match '^\s*Name\s+Id\s+Version') { continue }
                if ($line -match '^\s*-{3,}') { continue }
                $parts = @($line.Trim() -split '\s{2,}')
                if ($parts.Count -lt 3) { continue }
                $name = $parts[0]
                $packageId = $parts[1]
                $version = $parts[2]
                $risk = Get-AppRisk $name ''
                $apps.Add([pscustomobject]@{
                    appId = 'winget:' + (Convert-ToStableId $packageId)
                    displayName = $name
                    publisher = $null
                    version = $version
                    installLocation = $null
                    uninstallString = $null
                    quietUninstallString = $null
                    sourceType = 'winget'
                    packageId = $packageId
                    estimatedSizeBytes = $null
                    installDate = $null
                    categories = @(Get-AppCategories $name '')
                    risk = $risk
                    protected = $false
                    protectionReasons = @(if ($risk -eq 'advanced') { 'Runtime or driver classification needs manual review' })
                    startupImpact = Get-StartupImpact $name ''
                }) | Out-Null
            }
        } catch {
        }
    }
}

$appArray = @($apps.ToArray() | Sort-Object appId -Unique | Sort-Object displayName, sourceType, appId)
$sources = @($sources.ToArray() + @($appArray | Select-Object -ExpandProperty sourceType) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
$summary = [pscustomobject]@{
    appCount = $appArray.Count
    normalAppCount = @($appArray | Where-Object { $_.risk -in @('safe','low') }).Count
    launcherCount = @($appArray | Where-Object { $_.categories -contains 'launcher' }).Count
    overlayCount = @($appArray | Where-Object { $_.categories -contains 'overlay' }).Count
    vendorToolCount = @($appArray | Where-Object { $_.categories -contains 'vendor-tool' }).Count
    protectedRuntimeCount = 0
    startupHeavyCount = @($appArray | Where-Object { $_.startupImpact -eq 'high' }).Count
    estimatedSizeBytes = [uint64](($appArray | Where-Object { $null -ne $_.estimatedSizeBytes } | Measure-Object estimatedSizeBytes -Sum).Sum)
}

[pscustomobject]@{
    schemaVersion = 1
    productName = 'Roo Industries Optimization Suite'
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    summary = $summary
    sources = @($sources)
    complete = ($sourceErrors.Count -eq 0)
    errors = @($sourceErrors.ToArray())
    apps = $appArray
} | ConvertTo-Json -Depth 8
