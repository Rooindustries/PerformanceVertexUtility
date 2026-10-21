param(
    [ValidateSet('ListModules','Baseline','SmokeTest','ApplyModule','RollbackModule','Report','ToolInventory')]
    [string]$Action = 'ListModules',
    [string]$ModuleId = '',
    [string]$ManifestPath = '',
    [string]$BackupPath = '',
    [string]$DataRoot = 'C:\ProgramData\LeanClientOptimizer',
    [int]$WaitSeconds = 0,
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $PSScriptRoot 'modules\tweak_manifest.json'
}

function Get-NowStamp {
    return (Get-Date).ToString('yyyyMMdd-HHmmssfff') + '-' + [guid]::NewGuid().ToString('N')
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-JsonFile {
    param([object]$Value, [string]$Path)
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Manifest not found: $ManifestPath"
    }
    return Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
}

function Convert-RegPath {
    param([string]$Path)
    $p = ($Path -replace '/', '\' -replace '\\+', '\').TrimEnd('\')
    if ($p -match '^HKLM\\(.+)$') { return "Registry::HKEY_LOCAL_MACHINE\$($Matches[1])" }
    if ($p -match '^HKCU\\(.+)$') { return "Registry::HKEY_CURRENT_USER\$($Matches[1])" }
    if ($p -match '^HKU\\(.+)$') { return "Registry::HKEY_USERS\$($Matches[1])" }
    if ($p -match '^HKCR\\(.+)$') { return "Registry::HKEY_CLASSES_ROOT\$($Matches[1])" }
    if ($p -match '^HKEY_') { return "Registry::$p" }
    return "Registry::$p"
}

function Test-ProtectedService {
    param([string]$Name, [object]$Manifest)
    foreach ($protected in @($Manifest.protected.services)) {
        if ($Name -ieq $protected -or $Name -ilike "$protected`_*") { return $true }
    }
    return $false
}

function Test-ProtectedRegistryPath {
    param([string]$Path, [object]$Manifest, [string]$Name = '')
    $normalizedPath = $Path -replace '/', '\'
    $canonicalPath = (Convert-RegPath $Path).Substring(10)
    $hive = ($canonicalPath -split '\\', 2)[0]
    $alias = switch ($hive) {
        'HKEY_LOCAL_MACHINE' { 'HKLM' }
        'HKEY_CURRENT_USER' { 'HKCU' }
        'HKEY_USERS' { 'HKU' }
        'HKEY_CLASSES_ROOT' { 'HKCR' }
        'HKEY_CURRENT_CONFIG' { 'HKCC' }
        default { $hive }
    }
    $paths = @($normalizedPath, $canonicalPath, ('Registry::' + $canonicalPath), ($alias + $canonicalPath.Substring($hive.Length)))
    foreach ($pattern in @($Manifest.protected.registryPathPatterns)) {
        foreach ($keyPath in $paths) {
            if ($keyPath -match $pattern -or ($keyPath + '\' + $Name) -match $pattern) { return $true }
        }
    }
    return $false
}

function Open-RegistryKey {
    param([string]$Path, [switch]$Writable, [switch]$Create)
    $parts = (Convert-RegPath $Path).Substring(10) -split '\\', 2
    $root = switch ($parts[0]) {
        'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_CURRENT_USER' { [Microsoft.Win32.Registry]::CurrentUser }
        'HKEY_USERS' { [Microsoft.Win32.Registry]::Users }
        'HKEY_CLASSES_ROOT' { [Microsoft.Win32.Registry]::ClassesRoot }
        'HKEY_CURRENT_CONFIG' { [Microsoft.Win32.Registry]::CurrentConfig }
        default { throw "Unsupported registry path: $Path" }
    }
    $subkey = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    if ($Create) { return $root.CreateSubKey($subkey) }
    return $root.OpenSubKey($subkey, [bool]$Writable)
}

function Get-RegistryRawValue {
    param([Microsoft.Win32.RegistryKey]$Key, [string]$Name)
    if (-not ('RooIndustries.LegacyRegistry.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
namespace RooIndustries.LegacyRegistry {
    public sealed class RawValue { public uint Kind; public byte[] Data; }
    public static class Native {
        [DllImport("advapi32.dll", EntryPoint="RegQueryValueExW", CharSet=CharSet.Unicode)]
        private static extern int Query(SafeRegistryHandle key,string name,IntPtr reserved,out uint kind,[Out] byte[] data,ref uint length);
        public static RawValue Read(RegistryKey key,string name) {
            uint kind,length=8;byte[] data=new byte[8];
            int error=Query(key.Handle,name,IntPtr.Zero,out kind,data,ref length);
            if(error!=0)throw new Win32Exception(error);
            Array.Resize(ref data,checked((int)length));
            return new RawValue{Kind=kind,Data=data};
        }
    }
}
'@
    }
    return [RooIndustries.LegacyRegistry.Native]::Read($Key, $Name)
}

function ConvertTo-RegistrySnapshotData {
    param([string]$Kind, [object]$Value)
    if ($Kind -in 'String','ExpandString','MultiString') {
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        foreach ($text in @($Value)) { $null = $encoding.GetByteCount([string]$text) }
    }
    switch ($Kind) {
        'DWord' { $Value = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Value), 0) }
        'QWord' { $Value = [BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$Value), 0).ToString([Globalization.CultureInfo]::InvariantCulture) }
        'Binary' { $Value = [Convert]::ToBase64String([byte[]]$Value) }
        'MultiString' { $Value = [string[]]$Value }
    }
    return ,$Value
}

function Get-RegistryValueSnapshot {
    param([object]$Item)
    $name = [string]$Item.name
    $key = Open-RegistryKey $Item.path
    $exists = $null -ne $key
    $valueExists = $false
    $oldValue = $null
    $kind = $null
    try {
        if ($key -and $name -in $key.GetValueNames()) {
            $valueExists = $true
            $kind = [string]$key.GetValueKind($name)
            if ($kind -in 'String','ExpandString','MultiString','DWord','QWord','Binary') {
                $oldValue = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -eq $oldValue) { throw "Registry value disappeared while reading $($Item.path)\$($Item.name)" }
                if ($kind -in 'DWord','QWord') {
                    if (($kind -eq 'DWord' -and $oldValue -isnot [int]) -or ($kind -eq 'QWord' -and $oldValue -isnot [long])) { throw "Cannot back up registry numeric data exactly: $($Item.path)\$name" }
                    $native = Get-RegistryRawValue $key $name
                    $width = if ($kind -eq 'DWord') { 4 } else { 8 }
                    if ($native.Kind -ne [int][Microsoft.Win32.RegistryValueKind]$kind -or $native.Data.Length -ne $width) { throw "Cannot back up registry numeric payload exactly: $($Item.path)\$name" }
                    $number = if ($kind -eq 'DWord') { [BitConverter]::ToInt32($native.Data, 0) } else { [BitConverter]::ToInt64($native.Data, 0) }
                    if ($number -ne $oldValue) { throw "Registry value changed while reading: $($Item.path)\$name" }
                }
                $oldValue = ConvertTo-RegistrySnapshotData $kind $oldValue
            }
        }
    } finally {
        if ($key) { $key.Dispose() }
    }
    return [pscustomobject]@{
        path = $Item.path
        name = $name
        type = $Item.type
        desiredData = $Item.data
        pathExists = $exists
        valueExists = $valueExists
        kind = $kind
        oldValue = $oldValue
    }
}

function Get-ManifestRegistrySnapshot {
    param([object]$Item)
    $kind = switch ($Item.type) {
        'REG_DWORD' { 'DWord' }
        'REG_QWORD' { 'QWord' }
        'REG_SZ' { 'String' }
        default { 'String' }
    }
    $value = $Item.data
    if ($Item.type -eq 'REG_DWORD') { $value = [uint32]([uint64]$Item.data) }
    if ($Item.type -eq 'REG_QWORD') { $value = ([uint64]$Item.data).ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($kind -eq 'String') { $value = [string]$value }
    return [pscustomobject]@{ valueExists=$true; kind=$kind; oldValue=$value }
}

function Convert-RegistrySnapshotData {
    param([object]$Snapshot)
    $value = $Snapshot.oldValue
    switch ($Snapshot.kind) {
        'String' { $value = [string]$value }
        'ExpandString' { $value = [string]$value }
        'MultiString' { $value = [string[]]@($value) }
        'DWord' { $value = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]([uint64]$value)), 0) }
        'QWord' { $value = [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$value), 0) }
        'Binary' { $value = [Convert]::FromBase64String([string]$value) }
        default { throw "Unsupported registry value kind: $($Snapshot.kind)" }
    }
    return ,$value
}

function Set-RegistrySnapshotData {
    param([Microsoft.Win32.RegistryKey]$Key, [string]$Name, [object]$Snapshot)
    $Key.SetValue($Name, (Convert-RegistrySnapshotData $Snapshot), [Microsoft.Win32.RegistryValueKind]$Snapshot.kind)
}

function Test-RegistrySnapshotEqual {
    param([object]$Expected, [object]$Actual)
    if ($Expected.valueExists -ne $Actual.valueExists) { return $false }
    if (-not $Expected.valueExists) { return $true }
    if (-not [string]::Equals($Expected.kind, $Actual.kind, [StringComparison]::Ordinal)) { return $false }
    if ($Expected.kind -eq 'MultiString') {
        $wanted = @($Expected.oldValue)
        $current = @($Actual.oldValue)
        if ($wanted.Count -ne $current.Count) { return $false }
        for ($index = 0; $index -lt $wanted.Count; $index++) {
            if (-not [string]::Equals($wanted[$index], $current[$index], [StringComparison]::Ordinal)) { return $false }
        }
        return $true
    }
    return [string]::Equals([string]$Expected.oldValue, [string]$Actual.oldValue, [StringComparison]::Ordinal)
}

function Set-RegistryValueFromManifest {
    param([object]$Item)
    $expected = Get-ManifestRegistrySnapshot $Item
    $key = Open-RegistryKey $Item.path -Create
    try { Set-RegistrySnapshotData $key $Item.name $expected } finally { $key.Dispose() }
}

function Get-RegistryRestoreSnapshot {
    param([object]$Snapshot)
    $expected = $Snapshot
    if ($Snapshot.valueExists) {
        if (-not $Snapshot.kind) {
            $legacyValue = $Snapshot.oldValue
            if ($Snapshot.type -eq 'REG_DWORD') {
                try {
                    $signedValue = [System.Management.Automation.LanguagePrimitives]::ConvertTo($legacyValue, [int], [Globalization.CultureInfo]::CurrentCulture)
                    $legacyValue = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$signedValue), 0)
                } catch [System.Management.Automation.PSInvalidCastException] {
                    $legacyValue = [System.Management.Automation.LanguagePrimitives]::ConvertTo($legacyValue, [uint32], [Globalization.CultureInfo]::CurrentCulture)
                }
            } elseif ($Snapshot.type -eq 'REG_QWORD') {
                try {
                    $signedValue = [System.Management.Automation.LanguagePrimitives]::ConvertTo($legacyValue, [long], [Globalization.CultureInfo]::CurrentCulture)
                    $legacyValue = [BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$signedValue), 0)
                } catch [System.Management.Automation.PSInvalidCastException] {
                    $legacyValue = [System.Management.Automation.LanguagePrimitives]::ConvertTo($legacyValue, [uint64], [Globalization.CultureInfo]::CurrentCulture)
                }
            }
            $expected = Get-ManifestRegistrySnapshot ([pscustomobject]@{ type=$Snapshot.type; data=$legacyValue })
        }
        $evidenceError = "Missing or invalid original value evidence: $($Snapshot.path)\$($Snapshot.name)"
        $kinds = [string[]]@('String','ExpandString','MultiString','DWord','QWord','Binary')
        if ($expected.kind -isnot [string] -or [Array]::IndexOf($kinds, $expected.kind) -lt 0 -or -not $expected.PSObject.Properties['oldValue'] -or $null -eq $expected.oldValue) { throw $evidenceError }
        $value = $expected.oldValue
        if ($expected.kind -ceq 'MultiString') {
            if ($value -isnot [array]) { throw $evidenceError }
            foreach ($part in $value) { if ($part -isnot [string]) { throw $evidenceError } }
        } elseif ($expected.kind -ceq 'DWord') {
            if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [uint32] -and $value -isnot [uint64]) { throw $evidenceError }
        } elseif ($value -isnot [string]) { throw $evidenceError }
        try {
            $decoded = Convert-RegistrySnapshotData $expected
            $canonical = [pscustomobject]@{ valueExists=$true; kind=$expected.kind; oldValue=(ConvertTo-RegistrySnapshotData $expected.kind $decoded) }
            if (-not (Test-RegistrySnapshotEqual $expected $canonical)) { throw 'Noncanonical original encoding' }
        } catch { throw ($evidenceError + ': ' + $_.Exception.Message) }
    }
    return $expected
}

function Restore-RegistryValue {
    param([object]$Snapshot, [object]$Expected = $null)
    if ($null -eq $Expected) { $Expected = Get-RegistryRestoreSnapshot $Snapshot }
    if (-not $Snapshot.valueExists) {
        $key = Open-RegistryKey $Snapshot.path -Writable
        if ($key) {
            try { $key.DeleteValue($Snapshot.name, $false) } finally { $key.Dispose() }
        }
    } else {
        $key = Open-RegistryKey $Snapshot.path -Create
        try { Set-RegistrySnapshotData $key $Snapshot.name $Expected } finally { $key.Dispose() }
    }
    if (-not (Test-RegistrySnapshotEqual $Expected (Get-RegistryValueSnapshot $Snapshot))) {
        throw "Registry restore verification failed: $($Snapshot.path)\$($Snapshot.name)"
    }
}

function Resolve-ServiceTargets {
    param([string]$Name)
    $exact = @(Get-Service -Name $Name -ErrorAction SilentlyContinue)
    if ($exact.Count -gt 0) { return $exact }
    return @(Get-Service -Name "$Name`_*" -ErrorAction SilentlyContinue)
}

function Get-ServiceSnapshot {
    param([string]$Name)
    $targets = @(Resolve-ServiceTargets $Name)
    if ($targets.Count -eq 0) {
        return @([pscustomobject]@{ name=$Name; exists=$false })
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($svc in $targets) {
        $cim = Get-CimInstance Win32_Service -Filter ("Name='" + $svc.Name.Replace("'","''") + "'") -ErrorAction SilentlyContinue
        $deps = @(Get-Service -Name $svc.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServicesDependedOn | Select-Object -ExpandProperty Name)
        $result.Add([pscustomobject]@{
            name = $svc.Name
            displayName = $svc.DisplayName
            exists = $true
            status = [string]$svc.Status
            startType = [string]$svc.StartType
            startMode = if ($cim) { $cim.StartMode } else { $null }
            processId = if ($cim) { $cim.ProcessId } else { 0 }
            pathName = if ($cim) { $cim.PathName } else { $null }
            dependsOn = $deps
        }) | Out-Null
    }
    return @($result.ToArray())
}

function Set-ServiceFromManifest {
    param([object]$Item)
    $targets = @(Resolve-ServiceTargets $Item.name)
    foreach ($svc in $targets) {
        if ($Item.startup -eq 'Disabled') {
            Set-Service -Name $svc.Name -StartupType Disabled
        } elseif ($Item.startup -eq 'Manual') {
            Set-Service -Name $svc.Name -StartupType Manual
        } elseif ($Item.startup -eq 'Automatic') {
            Set-Service -Name $svc.Name -StartupType Automatic
        }
        if ($Item.targetState -eq 'Stopped') {
            Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-ServiceSnapshot {
    param([object]$Snapshot)
    if (-not $Snapshot.exists) { return }
    $startup = switch ($Snapshot.startType) {
        'Disabled' { 'Disabled' }
        'Manual' { 'Manual' }
        'Automatic' { 'Automatic' }
        default { $null }
    }
    if ($startup) {
        Set-Service -Name $Snapshot.name -StartupType $startup
    }
    if ($Snapshot.status -eq 'Running') {
        Start-Service -Name $Snapshot.name -ErrorAction SilentlyContinue
    }
}

function Get-ToolInventory {
    $roots = @('C:\Program Files','C:\Program Files (x86)', $env:LOCALAPPDATA, $env:APPDATA) | Where-Object { $_ -and (Test-Path $_) }
    $patterns = @('CapFrameX*','RTSS*','RivaTuner*','MSIAfterburner*','PresentMon*','OCAT*','HWiNFO*')
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        foreach ($item in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
            foreach ($pattern in $patterns) {
                if ($item.Name -like $pattern) {
                    $found.Add([pscustomobject]@{ name=$item.Name; path=$item.FullName }) | Out-Null
                }
            }
        }
    }
    return @($found | Sort-Object path -Unique)
}

function Get-BenchmarkSnapshot {
    param([string]$Label)
    if ($WaitSeconds -gt 0) { Start-Sleep -Seconds $WaitSeconds }
    $procs = @(Get-CimInstance Win32_Process)
    $services = @(Get-CimInstance Win32_Service)
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $gpu = @(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,DriverDate,VideoProcessor,AdapterRAM)
    $cpuSample = $null
    try {
        $counter = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5
        $cpuSample = [math]::Round((($counter.CounterSamples | Measure-Object CookedValue -Average).Average), 2)
    } catch {
        $cpuSample = $null
    }
    $snapshot = [pscustomobject]@{
        label = $Label
        timestamp = (Get-Date).ToString('o')
        computer = [pscustomobject]@{
            manufacturer = $cs.Manufacturer
            model = $cs.Model
            totalMemoryBytes = [uint64]$cs.TotalPhysicalMemory
            osCaption = $os.Caption
            osVersion = $os.Version
            osBuild = $os.BuildNumber
            lastBootUpTime = $os.LastBootUpTime
            gpu = $gpu
        }
        metrics = [pscustomobject]@{
            processCount = $procs.Count
            svchostCount = @($procs | Where-Object { $_.Name -eq 'svchost.exe' }).Count
            userSessionProcesses = @($procs | Where-Object { $_.SessionId -ne 0 }).Count
            session0Processes = @($procs | Where-Object { $_.SessionId -eq 0 }).Count
            runningServices = @($services | Where-Object { $_.State -eq 'Running' }).Count
            autoRunningServices = @($services | Where-Object { $_.State -eq 'Running' -and $_.StartMode -eq 'Auto' }).Count
            workingSetBytes = [uint64](($procs | Measure-Object WorkingSetSize -Sum).Sum)
            privateBytes = [uint64](($procs | Measure-Object PrivatePageCount -Sum).Sum)
            totalVirtualMemoryKb = [uint64]$os.TotalVirtualMemorySize
            freeVirtualMemoryKb = [uint64]$os.FreeVirtualMemory
            availableMemoryKb = [uint64]$os.FreePhysicalMemory
            cpuPercentAverage5s = $cpuSample
        }
        processTop = @($procs | Group-Object Name | Sort-Object Count -Descending | Select-Object -First 40 Count,Name)
        serviceStartSummary = @($services | Group-Object State,StartMode | ForEach-Object {
            $parts = $_.Name -split ', '
            [pscustomobject]@{ state=$parts[0]; startMode=$parts[1]; count=$_.Count }
        })
        toolInventory = @(Get-ToolInventory)
    }
    return $snapshot
}

function Invoke-SmokeTest {
    $results = New-Object System.Collections.Generic.List[object]
    function Add-Result([string]$Name, [bool]$Pass, [string]$Detail) {
        $results.Add([pscustomobject]@{ name=$Name; pass=$Pass; detail=$Detail }) | Out-Null
    }
    try {
        $profile = @(Get-NetConnectionProfile -ErrorAction Stop)
        Add-Result 'network-profile' ($profile.Count -gt 0) (($profile | Select-Object -First 1 -ExpandProperty Name) -join ',')
    } catch { Add-Result 'network-profile' $false $_.Exception.Message }
    try {
        $dns = Resolve-DnsName 'www.microsoft.com' -ErrorAction Stop | Select-Object -First 1
        Add-Result 'dns' ($null -ne $dns) 'www.microsoft.com resolves'
    } catch { Add-Result 'dns' $false $_.Exception.Message }
    try { $bluetooth = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue).Count -gt 0 } catch { $bluetooth = $true }
    foreach ($svcName in @('WlanSvc','bthserv','WinDefend','BFE','mpssvc','WpnService')) {
        if ($svcName -eq 'bthserv' -and -not $bluetooth) { continue }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Add-Result "service:$svcName" $false 'Service missing'
        } else {
            Add-Result "service:$svcName" ($svc.Status -eq 'Running') "Status=$($svc.Status), StartType=$($svc.StartType)"
        }
    }
    foreach ($optional in @('SamsungContinuityWindowsService','Samsung Multi Control Service','SamsungQuickShareService','SamsungCameraShareService','SamsungStorageShareService','SamsungAccountService')) {
        $svc = Get-Service -Name $optional -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            Add-Result "samsung:$optional" ($svc.Status -eq 'Running') "Status=$($svc.Status), StartType=$($svc.StartType)"
        }
    }
    $uninstallKeys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $installedApps = @(Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] } | ForEach-Object { [string]$_.DisplayName })
    $tailscale = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    if ($null -ne $tailscale) {
        Add-Result 'service:Tailscale' ($tailscale.Status -eq 'Running') "Status=$($tailscale.Status), StartType=$($tailscale.StartType)"
    } elseif (@($installedApps | Where-Object { $_ -like 'Tailscale*' }).Count -gt 0) {
        Add-Result 'service:Tailscale' $false 'Service missing'
    }
    if (@($installedApps | Where-Object { $_ -like 'Wispr Flow*' }).Count -gt 0) {
        $wispr = @(Get-Process -Name 'Wispr Flow' -ErrorAction SilentlyContinue)
        Add-Result 'process:Wispr Flow' ($wispr.Count -gt 0) "Count=$($wispr.Count)"
    }
    $webview = @(Get-ChildItem 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application' -Directory -ErrorAction SilentlyContinue)
    Add-Result 'webview2-runtime' ($webview.Count -gt 0) "Versions=$($webview.Count)"
    $overall = -not (@($results | Where-Object { -not $_.pass }).Count -gt 0)
    return [pscustomobject]@{ timestamp=(Get-Date).ToString('o'); pass=$overall; results=@($results.ToArray()) }
}

function Get-ModuleById {
    param([object]$Manifest, [string]$Id)
    $module = @($Manifest.modules | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if ($null -eq $module) { throw "Unknown module id: $Id" }
    return $module
}

function New-ModuleBackup {
    param([object]$Manifest, [object]$Module)
    $moduleDir = Join-Path $DataRoot ("backups\" + $Module.id + "\" + (Get-NowStamp))
    Ensure-Dir $moduleDir
    $regSnapshots = New-Object System.Collections.Generic.List[object]
    foreach ($rv in @($Module.registryValues)) {
        if (Test-ProtectedRegistryPath $rv.path $Manifest $rv.name) { continue }
        $snap = Get-RegistryValueSnapshot $rv
        if ($snap.valueExists -and $snap.kind -notin 'String','ExpandString','MultiString','DWord','QWord','Binary') {
            throw "Unsupported registry value kind: $($snap.kind) at $($rv.path)\$($rv.name)"
        }
        $regSnapshots.Add($snap) | Out-Null
    }
    $svcSnapshots = New-Object System.Collections.Generic.List[object]
    foreach ($svc in @($Module.services)) {
        if (Test-ProtectedService $svc.name $Manifest) { continue }
        foreach ($snap in @(Get-ServiceSnapshot $svc.name)) {
            $startup = if ($svc.startup -in 'Disabled','Manual','Automatic') { $svc.startup } else { $snap.startType }
            $snap | Add-Member -NotePropertyName appliedStartup -NotePropertyValue $startup
            $svcSnapshots.Add($snap) | Out-Null
        }
    }
    $backup = [pscustomobject]@{
        moduleId = $Module.id
        moduleName = $Module.name
        timestamp = (Get-Date).ToString('o')
        applyRequested = $true
        registry = @($regSnapshots.ToArray())
        services = @($svcSnapshots.ToArray())
        baseline = Get-BenchmarkSnapshot ("pre-" + $Module.id)
    }
    $path = Join-Path $moduleDir 'backup.json'
    Write-JsonFile $backup $path
    return $path
}

function Invoke-ApplyModule {
    $manifest = Read-Manifest
    $module = Get-ModuleById $manifest $ModuleId
    Ensure-Dir $DataRoot
    $backupPath = if ($ConfirmApply) { New-ModuleBackup $manifest $module } else { $null }
    $actions = New-Object System.Collections.Generic.List[object]
    foreach ($rv in @($module.registryValues)) {
        $blocked = Test-ProtectedRegistryPath $rv.path $manifest $rv.name
        $actions.Add([pscustomobject]@{ type='registry'; target=($rv.path + '\' + $rv.name); blocked=$blocked; action='set'; value=$rv.data }) | Out-Null
        if ($blocked) { continue }
        if ($ConfirmApply) { Set-RegistryValueFromManifest $rv }
    }
    foreach ($svc in @($module.services)) {
        $blocked = Test-ProtectedService $svc.name $manifest
        $actions.Add([pscustomobject]@{ type='service'; target=$svc.name; blocked=$blocked; action=('startup=' + $svc.startup + ', state=' + $svc.targetState) }) | Out-Null
        if ($blocked) { continue }
        if ($ConfirmApply) { Set-ServiceFromManifest $svc }
    }
    $after = if ($ConfirmApply) { Get-BenchmarkSnapshot ("post-" + $module.id) } else { $null }
    $smoke = if ($ConfirmApply) { Invoke-SmokeTest } else { $null }
    $result = [pscustomobject]@{
        moduleId = $module.id
        dryRun = -not $ConfirmApply
        backupPath = $backupPath
        actions = @($actions.ToArray())
        after = $after
        smoke = $smoke
    }
    $runPath = Join-Path $DataRoot ("runs\apply-" + $module.id + "-" + (Get-NowStamp) + ".json")
    Ensure-Dir (Split-Path $runPath -Parent)
    Write-JsonFile $result $runPath
    return $result
}

function Invoke-RollbackModule {
    $manifest = Read-Manifest
    $backupRoot = Join-Path $DataRoot ("backups\" + $ModuleId)
    $backupPath = $BackupPath
    if ([string]::IsNullOrWhiteSpace($backupPath)) {
        if (-not (Test-Path -LiteralPath $backupRoot)) { throw "No backups found for $ModuleId in $backupRoot" }
        $appliedPaths = @{}
        $runRoot = Join-Path $DataRoot 'runs'
        if (Test-Path -LiteralPath $runRoot) {
            foreach ($runFile in Get-ChildItem -LiteralPath $runRoot -Filter 'apply-*.json' -File) {
                $run = Get-Content -LiteralPath $runFile.FullName -Raw | ConvertFrom-Json
                if ($run.moduleId -eq $ModuleId -and $run.dryRun -eq $false -and $run.backupPath) {
                    $appliedPaths[[System.IO.Path]::GetFullPath($run.backupPath)] = $true
                }
            }
        }
        $eligible = @(foreach ($directory in Get-ChildItem -LiteralPath $backupRoot -Directory) {
            $candidatePath = Join-Path $directory.FullName 'backup.json'
            if (-not (Test-Path -LiteralPath $candidatePath)) { continue }
            $candidate = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json
            if ($candidate.moduleId -eq $ModuleId -and ($candidate.applyRequested -eq $true -or $appliedPaths.ContainsKey([System.IO.Path]::GetFullPath($candidatePath)))) {
                [pscustomobject]@{ path = $candidatePath; timestamp = [datetime]$candidate.timestamp }
            }
        })
        $latest = $eligible | Sort-Object timestamp -Descending | Select-Object -First 1
        if ($null -eq $latest) { throw "No confirmed-apply backup found for $ModuleId. Select a reviewed legacy backup explicitly with -BackupPath." }
        $backupPath = $latest.path
    }
    $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    if ($backup.moduleId -ne $ModuleId) { throw 'The selected backup belongs to a different module.' }
    $actions = New-Object System.Collections.Generic.List[object]
    $leftAsChanged = New-Object System.Collections.Generic.List[object]
    $alreadyAtOriginal = New-Object System.Collections.Generic.List[object]
    $failures = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[object]
    $work = New-Object System.Collections.Generic.List[object]
    $registryCount = 0
    $serviceCount = 0
    foreach ($rv in @($backup.registry)) {
        $target = @{ type='registry'; path=$rv.path; name=$rv.name }
        try {
            $reason = if (Test-ProtectedRegistryPath $rv.path $manifest $rv.name) { 'protected setting' }
                elseif ($rv.valueExists -isnot [bool]) { 'missing original existence evidence' }
                elseif (-not $rv.PSObject.Properties['kind'] -and ([string]::IsNullOrEmpty([string]$rv.name) -or [Globalization.CultureInfo]::CurrentCulture.CompareInfo.Compare([string]$rv.name, '(default)', [Globalization.CompareOptions]::IgnoreCase) -eq 0)) { 'missing original existence evidence for legacy default alias' }
                elseif ($rv.valueExists -and -not $rv.kind) { 'missing applied kind evidence in legacy backup' }
                elseif (-not $rv.PSObject.Properties['desiredData'] -or -not $rv.type) { 'missing applied value evidence' }
                else { $null }
            if ($reason) {
                $leftAsChanged.Add([pscustomobject]($target + @{ reason=$reason })) | Out-Null
                Write-Host "Left as changed: $($rv.path)\$($rv.name) ($reason)"
                continue
            }
            $expected = Get-ManifestRegistrySnapshot ([pscustomobject]@{ type=$rv.type; data=$rv.desiredData })
            $current = Get-RegistryValueSnapshot $rv
            $original = $null
            try { $original = Get-RegistryRestoreSnapshot $rv } catch { if (Test-RegistrySnapshotEqual $expected $current) { throw } }
            if ($null -ne $original -and (Test-RegistrySnapshotEqual $original $current)) {
                $alreadyAtOriginal.Add([pscustomobject]$target) | Out-Null
                Write-Host "Already at original value: $($rv.path)\$($rv.name)"
            } elseif (-not (Test-RegistrySnapshotEqual $expected $current)) {
                $leftAsChanged.Add([pscustomobject]($target + @{ reason='current kind or data changed' })) | Out-Null
                Write-Host "Left as changed: $($rv.path)\$($rv.name)"
            } else {
                $action = [pscustomobject]($target + @{ action='restore'; status='planned' })
                $actions.Add($action) | Out-Null
                $work.Add([pscustomobject]@{ target=$target; snapshot=$rv; applied=$expected; original=$original; action=$action }) | Out-Null
            }
        } catch {
            $failures.Add([pscustomobject]($target + @{ phase='preflight'; error=$_.Exception.Message; mayHaveChanged=$false })) | Out-Null
            $actions.Add([pscustomobject]($target + @{ action='restore'; status='failed' })) | Out-Null
        }
    }
    foreach ($svc in @($backup.services)) {
        $target = @{ type='service'; name=$svc.name }
        if ($svc.exists -isnot [bool]) {
            $leftAsChanged.Add([pscustomobject]($target + @{ reason='missing original existence evidence' })) | Out-Null
            Write-Host "Left as changed: service $($svc.name) (missing original existence evidence)"
            continue
        }
        if (-not $svc.exists) { continue }
        try {
            $blocked = Test-ProtectedService $svc.name $manifest
            $current = @(if (-not $blocked) { Get-ServiceSnapshot $svc.name | Where-Object { $_.exists -and $_.name -ieq $svc.name } })
            if ($blocked -or $svc.appliedStartup -notin 'Disabled','Manual','Automatic' -or $current.Count -ne 1) {
                $leftAsChanged.Add([pscustomobject]($target + @{ reason='protected, missing, or applied startup evidence unavailable' })) | Out-Null
                Write-Host "Left as changed: service $($svc.name) (applied startup unavailable or changed)"
            } elseif ($current[0].startType -eq $svc.appliedStartup) {
                if ($svc.startType -notin 'Disabled','Manual','Automatic') { throw "Unsupported original service startup: $($svc.name)" }
                $action = [pscustomobject]($target + @{ action='restore'; status='planned' })
                $actions.Add($action) | Out-Null
                $work.Add([pscustomobject]@{ target=$target; snapshot=$svc; action=$action }) | Out-Null
            } elseif ($current[0].startType -eq $svc.startType) {
                $alreadyAtOriginal.Add([pscustomobject]$target) | Out-Null
                Write-Host "Already at original startup: service $($svc.name)"
            } else {
                $leftAsChanged.Add([pscustomobject]($target + @{ reason='current startup changed' })) | Out-Null
                Write-Host "Left as changed: service $($svc.name)"
            }
        } catch {
            $failures.Add([pscustomobject]($target + @{ phase='preflight'; error=$_.Exception.Message; mayHaveChanged=$false })) | Out-Null
            $actions.Add([pscustomobject]($target + @{ action='restore'; status='failed' })) | Out-Null
        }
    }
    $stopped = $failures.Count -gt 0
    $attempted = 0
    foreach ($item in $work) {
        if ($stopped) {
            $item.action.status = 'pending'
            $pending.Add([pscustomobject]$item.target) | Out-Null
            continue
        }
        if (-not $ConfirmApply) {
            if ($item.target.type -eq 'registry') { $registryCount++ } else { $serviceCount++ }
            continue
        }
        $writing = $false
        try {
            if ($item.target.type -eq 'registry') {
                $current = Get-RegistryValueSnapshot $item.snapshot
                if (Test-RegistrySnapshotEqual $item.original $current) {
                    $alreadyAtOriginal.Add([pscustomobject]$item.target) | Out-Null
                    $item.action.status = 'alreadyAtOriginal'
                    continue
                }
                if (-not (Test-RegistrySnapshotEqual $item.applied $current)) {
                    $leftAsChanged.Add([pscustomobject]($item.target + @{ reason='changed after preflight' })) | Out-Null
                    $item.action.status = 'leftAsChanged'
                    Write-Host "Left as changed: $($item.target.path)\$($item.target.name)"
                    continue
                }
                $attempted++
                $writing = $true
                Restore-RegistryValue $item.snapshot $item.original
                $registryCount++
            } else {
                $svc = $item.snapshot
                $current = @(Get-ServiceSnapshot $svc.name | Where-Object { $_.exists -and $_.name -ieq $svc.name })
                if ($current.Count -ne 1 -or $current[0].startType -ne $svc.appliedStartup) {
                    if ($current.Count -eq 1 -and $current[0].startType -eq $svc.startType) {
                        $alreadyAtOriginal.Add([pscustomobject]$item.target) | Out-Null
                        $item.action.status = 'alreadyAtOriginal'
                    } else {
                        $leftAsChanged.Add([pscustomobject]($item.target + @{ reason='changed after preflight' })) | Out-Null
                        $item.action.status = 'leftAsChanged'
                        Write-Host "Left as changed: service $($svc.name)"
                    }
                    continue
                }
                $attempted++
                $writing = $true
                Restore-ServiceSnapshot $svc
                $verified = @(Get-ServiceSnapshot $svc.name | Where-Object { $_.exists -and $_.name -ieq $svc.name })
                if ($verified.Count -ne 1 -or $verified[0].startType -ne $svc.startType) { throw "Service restore verification failed: $($svc.name)" }
                $serviceCount++
            }
            $item.action.status = 'restored'
        } catch {
            $item.action.status = 'failed'
            $failures.Add([pscustomobject]($item.target + @{ phase='restore'; error=$_.Exception.Message; mayHaveChanged=$writing })) | Out-Null
            $stopped = $true
        }
    }
    if ($failures.Count) { Write-Host "Rollback incomplete. Backup retained: $backupPath. Review failures and pending settings before retrying." }
    return [pscustomobject]@{
        moduleId = $ModuleId
        dryRun = -not $ConfirmApply
        backupPath = $backupPath
        success = $failures.Count -eq 0
        partial = $failures.Count -gt 0 -and $attempted -gt 0
        restoredRegistry = $registryCount
        restoredServices = $serviceCount
        actions = @($actions.ToArray())
        leftAsChanged = @($leftAsChanged.ToArray())
        alreadyAtOriginal = @($alreadyAtOriginal.ToArray())
        failures = @($failures.ToArray())
        pending = @($pending.ToArray())
    }
}

function New-Report {
    Ensure-Dir (Join-Path $DataRoot 'reports')
    $snapshots = @()
    $baselineDir = Join-Path $DataRoot 'baselines'
    if (Test-Path -LiteralPath $baselineDir) {
        foreach ($file in Get-ChildItem -LiteralPath $baselineDir -Filter '*.json' -ErrorAction SilentlyContinue) {
            $snapshots += Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        }
    }
    $latest = $snapshots | Sort-Object timestamp | Select-Object -Last 1
    $html = @"
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Performance Vertex Utility Report</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1f2937}table{border-collapse:collapse;width:100%;margin:16px 0}th,td{border:1px solid #d1d5db;padding:8px;text-align:left}th{background:#f3f4f6}.muted{color:#6b7280}</style></head>
<body>
<h1>Performance Vertex Utility Report</h1>
<p class="muted">Generated $(Get-Date)</p>
<h2>Latest Baseline</h2>
"@
    if ($latest) {
        $m = $latest.metrics
        $html += "<table><tr><th>Metric</th><th>Value</th></tr>"
        foreach ($pair in @(
            @('Processes',$m.processCount), @('svchost.exe',$m.svchostCount), @('Running services',$m.runningServices),
            @('Auto running services',$m.autoRunningServices), @('Working set GB',[math]::Round($m.workingSetBytes/1GB,2)),
            @('Private bytes GB',[math]::Round($m.privateBytes/1GB,2)), @('CPU avg 5s %',$m.cpuPercentAverage5s)
        )) {
            $html += "<tr><td>$($pair[0])</td><td>$($pair[1])</td></tr>"
        }
        $html += "</table>"
    } else {
        $html += "<p>No baseline snapshots found.</p>"
    }
    $html += "</body></html>"
    $path = Join-Path $DataRoot ("reports\report-" + (Get-NowStamp) + ".html")
    $html | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

switch ($Action) {
    'ListModules' {
        $manifest = Read-Manifest
        $manifest.modules | Select-Object id,name,risk,defaultProfile,requiresReboot,description
    }
    'ToolInventory' {
        Get-ToolInventory
    }
    'Baseline' {
        Ensure-Dir $DataRoot
        $snapshot = Get-BenchmarkSnapshot 'baseline'
        $path = Join-Path $DataRoot ("baselines\baseline-" + (Get-NowStamp) + ".json")
        Ensure-Dir (Split-Path $path -Parent)
        Write-JsonFile $snapshot $path
        [pscustomobject]@{ path=$path; metrics=$snapshot.metrics; tools=$snapshot.toolInventory }
    }
    'SmokeTest' {
        Ensure-Dir $DataRoot
        $smoke = Invoke-SmokeTest
        $path = Join-Path $DataRoot ("smoke\smoke-" + (Get-NowStamp) + ".json")
        Ensure-Dir (Split-Path $path -Parent)
        Write-JsonFile $smoke $path
        $smoke
    }
    'ApplyModule' {
        Ensure-Dir $DataRoot
        if ([string]::IsNullOrWhiteSpace($ModuleId)) { throw 'ModuleId is required.' }
        Invoke-ApplyModule
    }
    'RollbackModule' {
        Ensure-Dir $DataRoot
        if ([string]::IsNullOrWhiteSpace($ModuleId)) { throw 'ModuleId is required.' }
        $result = Invoke-RollbackModule
        $result
        if (-not $result.success) {
            $failure = [InvalidOperationException]::new("Rollback incomplete. Original backup retained: $($result.backupPath)")
            $failure.Data['RollbackResult'] = $result
            throw $failure
        }
    }
    'Report' {
        New-Report
    }
}
