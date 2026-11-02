param(
    [ValidateSet('ListModules','Baseline','SmokeTest','ApplyModule','RollbackModule','Report','ToolInventory')]
    [string]$Action = 'ListModules',
    [string]$ModuleId = '',
    [string]$ManifestPath = '',
    [string]$BackupPath = '',
    [string]$PreviewPath = '',
    [string]$DataRoot = 'C:\ProgramData\LeanClientOptimizer',
    [int]$WaitSeconds = 0,
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $PSScriptRoot 'modules\tweak_manifest.json'
}
$PolicyEditionsPath = Join-Path $PSScriptRoot 'backend\catalogs\windows-policy-editions.json'

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
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
        $stream = [IO.File]::Open($temp, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) } else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Enter-ChangeLock {
    $lock = [Threading.Mutex]::new($false, 'Global\RooIndustries.LeanClientOptimizer.Changes')
    try { $owned = $lock.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if ($owned) { return $lock }
    $lock.Dispose()
    throw 'Another confirmed Apply or Undo is running on this PC. Wait for it to finish, then try again. Nothing was changed.'
}

function Exit-ChangeLock {
    param([Threading.Mutex]$Lock)
    if ($null -eq $Lock) { return }
    try { $Lock.ReleaseMutex() } finally { $Lock.Dispose() }
}

function Resolve-BackupFile {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    $item = Get-Item -LiteralPath $full -Force
    if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -eq 'HardLink') {
        throw "The selected backup $Path is a link or not a file. Select the backup.json file itself. Nothing was changed."
    }
    return $item.FullName
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
            uint kind,length=0;
            int error=Query(key.Handle,name,IntPtr.Zero,out kind,null,ref length);
            if(error!=0)throw new Win32Exception(error);
            byte[] data=new byte[checked((int)length)];
            uint readKind,readLength=length;
            error=Query(key.Handle,name,IntPtr.Zero,out readKind,data,ref readLength);
            if(error!=0)throw new Win32Exception(error);
            if(readKind!=kind||readLength!=length)throw new InvalidOperationException("Registry value changed during raw read");
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

function Test-RegistryRawLayout {
    param([string]$Kind, [byte[]]$Data)
    $length = $Data.Length
    switch ($Kind) {
        'DWord' { return $length -eq 4 }
        'QWord' { return $length -eq 8 }
        'Binary' { return $true }
    }
    if ($length -lt 2 -or $length % 2 -ne 0 -or $Data[$length-1] -ne 0 -or $Data[$length-2] -ne 0) { return $false }
    if ($Kind -eq 'MultiString' -and $length -ne 2) { return $length -ge 4 -and $Data[$length-3] -eq 0 -and $Data[$length-4] -eq 0 }
    return $true
}

function Test-RegistryChangedLayout {
    param([object]$Snapshot)
    return $Snapshot.PSObject.TypeNames.Contains('RooIndustries.LegacyRegistry.ChangedLayout')
}

function Get-RegistryValueSnapshot {
    param([object]$Item, [switch]$AllowChangedLayout)
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
                $native = Get-RegistryRawValue $key $name
                if ($null -eq $native -or $native.Data -isnot [byte[]] -or ($native.Kind -isnot [int] -and $native.Kind -isnot [uint32])) { throw "Invalid native registry read: $($Item.path)\$name" }
                if ($native.Kind -ne [int][Microsoft.Win32.RegistryValueKind]$kind) { throw "Registry kind changed while reading: $($Item.path)\$name" }
                if (-not (Test-RegistryRawLayout $kind $native.Data)) {
                    if (-not $AllowChangedLayout) { throw "Cannot back up registry raw layout exactly: $($Item.path)\$name" }
                    $changed = [pscustomobject]@{ valueExists=$true; kind=$kind; oldValue=$null }
                    $changed.PSObject.TypeNames.Insert(0, 'RooIndustries.LegacyRegistry.ChangedLayout')
                    return $changed
                }
                $oldValue = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -eq $oldValue) { throw "Registry value disappeared while reading $($Item.path)\$($Item.name)" }
                $managedType = switch ($kind) {
                    'String' { [string] }
                    'ExpandString' { [string] }
                    'MultiString' { [string[]] }
                    'Binary' { [byte[]] }
                    'DWord' { [int] }
                    'QWord' { [long] }
                }
                if ($oldValue.GetType() -ne $managedType) { throw "Registry managed type changed while reading: $($Item.path)\$name" }
                if ($kind -eq 'MultiString') { foreach ($part in $oldValue) { if ($null -eq $part) { throw "Invalid registry string array: $($Item.path)\$name" } } }
                $encoded = ConvertTo-RegistrySnapshotData $kind $oldValue
                if ($kind -in 'DWord','QWord') {
                    $number = if ($kind -eq 'DWord') { [BitConverter]::ToInt32($native.Data, 0) } else { [BitConverter]::ToInt64($native.Data, 0) }
                    if ($number -ne $oldValue) { throw "Registry value changed while reading: $($Item.path)\$name" }
                } elseif ($kind -eq 'Binary') {
                    if (-not [string]::Equals($encoded, [Convert]::ToBase64String($native.Data), [StringComparison]::Ordinal)) { throw "Registry binary data changed while reading: $($Item.path)\$name" }
                } elseif ($kind -in 'String','ExpandString','MultiString') {
                    $text = if ($kind -eq 'MultiString') { ((@($oldValue) | ForEach-Object { $_ + [char]0 }) -join '') + [char]0 } else { [string]$oldValue + [char]0 }
                    $bytes = [Text.Encoding]::Unicode.GetBytes($text)
                    if (-not [string]::Equals([Convert]::ToBase64String($bytes), [Convert]::ToBase64String($native.Data), [StringComparison]::Ordinal)) { throw "Cannot back up registry text bytes exactly: $($Item.path)\$name" }
                }
                $oldValue = $encoded
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
    if ((Test-RegistryChangedLayout $Expected) -or (Test-RegistryChangedLayout $Actual)) { return $false }
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

function Get-DependentServiceStates {
    param([object]$Service)
    $seen = @{}
    $states = New-Object System.Collections.Generic.List[object]
    $visit = {
        param([object]$Parent)
        foreach ($dependent in @($Parent.DependentServices)) {
            if (-not $dependent -or $seen.ContainsKey([string]$dependent.Name)) { continue }
            $seen[[string]$dependent.Name] = $true
            & $visit $dependent
            $states.Add([pscustomobject]@{ name=[string]$dependent.Name; status=[string]$dependent.Status; startType=[string]$dependent.StartType }) | Out-Null
        }
    }
    & $visit $Service
    return ,$states.ToArray()
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
            dependents = Get-DependentServiceStates $svc
        }) | Out-Null
    }
    return @($result.ToArray())
}

function Save-DependentStopEvidence {
    param([string]$Name, [object]$Backup, [string]$Path)
    foreach ($snapshot in @($Backup.services)) {
        if ($snapshot.name -ine $Name) { continue }
        foreach ($dependent in @($snapshot.dependents)) {
            if ($null -eq $dependent -or [string]$dependent.status -cne 'Running') { continue }
            $current = @(Get-ServiceSnapshot $dependent.name | Where-Object { $_.exists -and $_.name -ieq $dependent.name })
            $dependent | Add-Member -MemberType NoteProperty -Name stoppedByApply -Value ($current.Count -eq 1 -and $current[0].status -eq 'Stopped') -Force
        }
    }
    Write-JsonFile $Backup $Path
}

function Set-ServiceFromManifest {
    param([object]$Item, [object]$Backup, [string]$BackupPath)
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
            $stopError = $null
            try { Stop-Service -Name $svc.Name -Force -ErrorAction Stop } catch { $stopError = $_ }
            try { Save-DependentStopEvidence $svc.Name $Backup $BackupPath } catch { if (-not $stopError) { throw } }
            if ($stopError) { throw $stopError }
        }
    }
}

function Test-ServiceRestoreComplete {
    param([object]$Snapshot, [object]$Current)
    return ($Current.startType -eq $Snapshot.startType -and (-not ($Snapshot.status -eq 'Running') -or $Current.status -eq 'Running'))
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
        Start-Service -Name $Snapshot.name -ErrorAction Stop
    }
}

function Test-DependentRestore {
    param([object]$Dependent, [hashtable]$States, [object]$Manifest, [switch]$Planning)
    $name = [string]$Dependent.name
    if (Test-ProtectedService $name $Manifest) { return [pscustomobject]@{ state='leftAsChanged'; reason='dependent service is protected' } }
    $current = @(Get-ServiceSnapshot $name | Where-Object { $_.exists -and $_.name -ieq $name })
    if ($current.Count -ne 1) { return [pscustomobject]@{ state='leftAsChanged'; reason='dependent service missing' } }
    if ($current[0].startType -ne $Dependent.startType) { return [pscustomobject]@{ state='leftAsChanged'; reason='dependent startup or state changed' } }
    if ($Dependent.PSObject.Properties['restoreComplete'] -and $Dependent.restoreComplete -isnot [bool]) { return [pscustomobject]@{ state='leftAsChanged'; reason='dependent restore completion evidence is invalid' } }
    if ($Dependent.PSObject.Properties['restoreAttempted'] -and $Dependent.restoreAttempted -isnot [bool]) { return [pscustomobject]@{ state='leftAsChanged'; reason='dependent restore attempt evidence is invalid' } }
    if ($current[0].status -eq 'Running') { return [pscustomobject]@{ state='alreadyAtOriginal'; reason=$null } }
    if ($Dependent.stoppedByApply -isnot [bool] -or -not $Dependent.stoppedByApply) { return [pscustomobject]@{ state='leftAsChanged'; reason='apply did not confirm that it stopped this service; another program may have stopped it' } }
    if ($Dependent.restoreComplete -eq $true) { return [pscustomobject]@{ state='leftAsChanged'; reason='dependent was already restored; runtime ownership released' } }
    if ($Dependent.restoreAttempted -eq $true) { return [pscustomobject]@{ state='leftAsChanged'; reason='a previous Undo tried to start it without a confirmed result; another program may have stopped it' } }
    if ($current[0].status -ne 'Stopped') { return [pscustomobject]@{ state='leftAsChanged'; reason='dependent startup or state changed' } }
    foreach ($required in @($current[0].dependsOn)) {
        if (-not $required) { continue }
        $running = @(Get-ServiceSnapshot $required | Where-Object { $_.exists -and $_.name -ieq $required -and $_.status -eq 'Running' }).Count -eq 1
        $state = $States[[string]$required]
        if (-not $running -and -not ($Planning -and $state -and $state.status -in 'planned','alreadyAtOriginal')) {
            return [pscustomobject]@{ state='leftAsChanged'; reason="a service it depends on is not running: $required" }
        }
    }
    return [pscustomobject]@{ state='stopped'; reason=$null }
}

function Save-DependentRestoreComplete {
    param([object]$Dependent, [object]$Backup, [string]$Path)
    if ($Dependent.restoreComplete -eq $true) { return }
    $Dependent | Add-Member -MemberType NoteProperty -Name restoreComplete -Value $true -Force
    Write-JsonFile $Backup $Path
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
    $profile = @()
    try {
        $profile = @(Get-NetConnectionProfile -ErrorAction Stop)
        Add-Result 'network-profile' ($profile.Count -gt 0) (($profile | Select-Object -First 1 -ExpandProperty Name) -join ',')
    } catch { Add-Result 'network-profile' $false $_.Exception.Message }
    try {
        $dnsInterfaces = @(Get-DnsClientServerAddress -ErrorAction Stop | Where-Object { $null -ne $_.InterfaceIndex -and $_.InterfaceIndex -in @($profile.InterfaceIndex) -and @($_.ServerAddresses).Count -gt 0 })
        $dnsClient = Get-Service -Name 'Dnscache' -ErrorAction SilentlyContinue
        $dnsStatus = if ($dnsClient) { [string]$dnsClient.Status } else { 'missing' }
        Add-Result 'dns-client' ($dnsStatus -eq 'Running' -and $dnsInterfaces.Count -gt 0) "Dnscache=$dnsStatus, interfaces with DNS servers=$($dnsInterfaces.Count)"
    } catch { Add-Result 'dns-client' $false $_.Exception.Message }
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

function Read-PolicyEditions {
    try { $limits = Get-Content -LiteralPath $PolicyEditionsPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { throw "Cannot read the Windows edition limits in $PolicyEditionsPath`: $($_.Exception.Message) Nothing was changed." }
    $policies = if ($limits -is [System.Management.Automation.PSCustomObject] -and $limits.PSObject.Properties['policies']) { $limits.policies } else { $null }
    if ($policies -isnot [array] -or $policies.Count -eq 0) { throw "The Windows edition limits in $PolicyEditionsPath have no policies list. Nothing was changed." }
    $number = 1
    foreach ($policy in $policies) {
        $valid = $policy -is [System.Management.Automation.PSCustomObject] -and $policy.hive -is [string] -and $policy.hive -in 'LocalMachine','CurrentUser','Users','ClassesRoot'
        foreach ($field in 'keyPath','valueName') { $valid = $valid -and $policy.$field -is [string] -and -not [string]::IsNullOrWhiteSpace($policy.$field) }
        $valid = $valid -and $policy.editions -is [array] -and $policy.editions.Count -gt 0 -and @($policy.editions | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -eq 0
        foreach ($field in @{ name='minimumBuild'; max=[int]::MaxValue }, @{ name='dword'; max=[uint32]::MaxValue }) {
            if ($valid -and $policy.PSObject.Properties[$field.name]) { $value = $policy.($field.name); $valid = ($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le $field.max }
        }
        if (-not $valid) { throw "Policy $number in the Windows edition limits in $PolicyEditionsPath needs a known hive, a keyPath, a valueName, a list of editions, and whole numbers for minimumBuild and dword when given. Nothing was changed." }
        $number++
    }
    return $policies
}

function Get-PcEdition {
    $machine = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $version = $machine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
        if ($version) { try { $edition = $version.GetValue('EditionID'); $build = $version.GetValue('CurrentBuildNumber') } finally { $version.Dispose() } }
    } finally { $machine.Dispose() }
    $number = 0
    if ($edition -isnot [string] -or [string]::IsNullOrWhiteSpace($edition) -or $build -isnot [string] -or -not [int]::TryParse($build, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        throw "EditionID or CurrentBuildNumber under HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion is missing or not valid."
    }
    return [pscustomobject]@{ edition=$edition; build=$number }
}

function Get-EditionSkip {
    param([object]$Item, [string]$Type, [string]$Data, [object[]]$Policies, [ref]$Windows)
    $parts = (Convert-RegPath $Item.path).Substring(10) -split '\\', 2
    $hive = @{ HKEY_LOCAL_MACHINE='LocalMachine'; HKEY_CURRENT_USER='CurrentUser'; HKEY_USERS='Users'; HKEY_CLASSES_ROOT='ClassesRoot' }[$parts[0]]
    $keyPath = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    foreach ($policy in $Policies) {
        if (-not [string]::Equals($policy.hive, $hive, [StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($policy.keyPath, $keyPath, [StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($policy.valueName, [string]$Item.name, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($policy.PSObject.Properties['dword'] -and ($Type -cne 'REG_DWORD' -or $Data -cne ([string]$policy.dword))) { continue }
        if ($null -eq $Windows.Value) {
            try { $Windows.Value = Get-PcEdition } catch { throw "Cannot read this PC's Windows edition and build, which decide whether $($Item.path)\$($Item.name) applies: $($_.Exception.Message) Nothing was changed." }
        }
        $pc = $Windows.Value
        $allowed = @($policy.editions | Where-Object { if ($_.EndsWith('*')) { $pc.edition.StartsWith($_.Substring(0, $_.Length - 1), [StringComparison]::OrdinalIgnoreCase) } else { [string]::Equals($_, $pc.edition, [StringComparison]::OrdinalIgnoreCase) } })
        if ($allowed.Count -eq 0) { return "Windows ignores this policy on the $($pc.edition) edition." }
        if ($policy.minimumBuild -and $pc.build -lt [int]$policy.minimumBuild) { return "Windows ignores this policy before build $($policy.minimumBuild)." }
    }
    return $null
}

function Get-ModulePlan {
    param([object]$Manifest, [object]$Module)
    $plan = New-Object System.Collections.Generic.List[object]
    $policies = @()
    if (@($Module.registryValues).Count -gt 0) {
        $policies = @(Read-PolicyEditions)
    }
    $windows = $null
    foreach ($rv in @($Module.registryValues)) {
        $target = "$($rv.path)\$($rv.name)"
        $type = $null
        if ($rv.type -is [string]) {
            foreach ($supported in 'REG_DWORD','REG_QWORD','REG_SZ') {
                if ([string]::Equals($supported, $rv.type, [StringComparison]::OrdinalIgnoreCase)) { $type = $supported }
            }
        }
        if (-not $type) {
            $shown = if ($rv.type -is [string]) { "'" + $rv.type + "'" } elseif ($null -eq $rv.type) { 'none' } else { ConvertTo-Json -InputObject $rv.type -Compress }
            throw "Unsupported registry type $shown for $target. This harness writes only REG_DWORD, REG_QWORD and REG_SZ. Nothing was changed."
        }
        try { $data = [string](Get-ManifestRegistrySnapshot $rv).oldValue } catch { throw "Cannot write $target as ${type}: $($_.Exception.Message) Nothing was changed." }
        $entry = [pscustomobject]@{ kind='registry'; path=[string]$rv.path; name=[string]$rv.name; type=$type; data=$data; blocked=[bool](Test-ProtectedRegistryPath $rv.path $Manifest $rv.name) }
        $skipped = Get-EditionSkip $rv $type $data $policies ([ref]$windows)
        if ($skipped) { $entry | Add-Member -NotePropertyName skipped -NotePropertyValue $skipped }
        $plan.Add($entry) | Out-Null
    }
    foreach ($svc in @($Module.services)) {
        $blocked = [bool](Test-ProtectedService $svc.name $Manifest)
        if (-not $blocked -and $svc.targetState -eq 'Stopped') {
            foreach ($snap in @(Get-ServiceSnapshot $svc.name)) {
                foreach ($dependent in @($snap.dependents)) {
                    if ($dependent -and (Test-ProtectedService $dependent.name $Manifest)) {
                        throw "Cannot stop service $($snap.name): the protected service $($dependent.name) depends on it, and Undo does not restart protected services. Nothing was changed."
                    }
                }
            }
        }
        $plan.Add([pscustomobject]@{ kind='service'; name=[string]$svc.name; startup=[string]$svc.startup; targetState=[string]$svc.targetState; blocked=$blocked }) | Out-Null
    }
    return ,$plan.ToArray()
}

function Get-ModulePlanHash {
    param([object[]]$Plan)
    $text = New-Object System.Text.StringBuilder
    [void]$text.Append('module-plan-v1;')
    foreach ($entry in $Plan) {
        foreach ($property in $entry.PSObject.Properties) {
            $value = [string]$property.Value
            [void]$text.Append($property.Name).Append('=').Append($value.Length.ToString([Globalization.CultureInfo]::InvariantCulture)).Append(':').Append($value).Append(';')
        }
        [void]$text.Append('|')
    }
    $chars = $text.ToString().ToCharArray()
    $bytes = New-Object byte[] ($chars.Length * 2)
    [Buffer]::BlockCopy($chars, 0, $bytes, 0, $bytes.Length)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-ModulePlanChanges {
    param([object[]]$Previewed, [object[]]$Current)
    $keys = New-Object System.Collections.Generic.List[string]
    $targets = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $before = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $after = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($side in @(@{ entries=$Previewed; details=$before }, @{ entries=$Current; details=$after })) {
        foreach ($entry in @($side.entries)) {
            if ($null -eq $entry) { continue }
            $service = [string]$entry.kind -ceq 'service'
            $key = [string]$entry.kind + [char]0 + [string]$entry.path + [char]0 + [string]$entry.name
            $detail = if ($entry.blocked -eq $true) { 'protected, skipped' } elseif ($entry.skipped) { 'skipped: ' + [string]$entry.skipped } elseif ($service) { 'startup=' + [string]$entry.startup + ', state=' + [string]$entry.targetState } else { [string]$entry.type + ' ' + [string]$entry.data }
            if (-not $targets.ContainsKey($key)) {
                $keys.Add($key)
                $targets[$key] = if ($service) { 'service ' + [string]$entry.name } else { [string]$entry.path + '\' + [string]$entry.name }
            }
            $side.details[$key] = if ($side.details.ContainsKey($key)) { $side.details[$key] + ' then ' + $detail } else { $detail }
        }
    }
    $changes = New-Object System.Collections.Generic.List[string]
    foreach ($key in $keys) {
        if (-not $after.ContainsKey($key)) { $changes.Add('removed ' + $targets[$key] + ' (' + $before[$key] + ')') }
        elseif (-not $before.ContainsKey($key)) { $changes.Add('added ' + $targets[$key] + ' (' + $after[$key] + ')') }
        elseif (-not [string]::Equals($before[$key], $after[$key], [StringComparison]::Ordinal)) { $changes.Add($targets[$key] + ': ' + $before[$key] + ' -> ' + $after[$key]) }
    }
    if ($changes.Count -eq 0) { $changes.Add('the settings are in a different order') }
    if ($changes.Count -gt 10) { return @($changes.GetRange(0, 10)) + ('and ' + ($changes.Count - 10) + ' more') }
    return @($changes.ToArray())
}

function Assert-ModulePreview {
    param([object]$Module, [object[]]$Plan, [string]$PlanHash)
    $next = "Nothing was changed. Preview $($Module.id) without -ConfirmApply, review it, then pass its previewPath with -PreviewPath."
    if ([string]::IsNullOrWhiteSpace($PreviewPath)) { throw "A confirmed apply needs the preview you reviewed. $next" }
    try { $preview = Get-Content -LiteralPath $PreviewPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { throw "Cannot read the preview $PreviewPath. $next" }
    if ($null -eq $preview -or $preview.dryRun -isnot [bool] -or -not $preview.dryRun) { throw "$PreviewPath is not a preview. $next" }
    if (-not [string]::Equals([string]$preview.moduleId, [string]$Module.id, [StringComparison]::Ordinal)) { throw "The preview $PreviewPath is for module '$($preview.moduleId)', not '$($Module.id)'. $next" }
    if ($preview.previewHash -isnot [string] -or $preview.previewHash -cnotmatch '^[0-9a-f]{64}$') { throw "The preview $PreviewPath has no plan hash, so it was made by an earlier version or edited. $next" }
    if ($preview.plan -isnot [array] -or -not [string]::Equals((Get-ModulePlanHash @($preview.plan)), $preview.previewHash, [StringComparison]::Ordinal)) { throw "The preview plan does not match its hash. $next" }
    if (-not [string]::Equals($preview.previewHash, $PlanHash, [StringComparison]::Ordinal)) {
        $changes = Get-ModulePlanChanges @($preview.plan) $Plan
        throw "What $($Module.id) would change is different from the preview $PreviewPath`: $($changes -join '; '). $next"
    }
    $actionsError = "The preview actions do not match its plan. $next"
    if ($preview.actions -isnot [array] -or $preview.actions.Count -ne $Plan.Count) { throw $actionsError }
    for ($index = 0; $index -lt $Plan.Count; $index++) {
        $entry = $Plan[$index]
        $action = $preview.actions[$index]
        $service = $entry.kind -ceq 'service'
        $target = if ($service) { $entry.name } else { $entry.path + '\' + $entry.name }
        $verb = if ($service) { 'startup=' + $entry.startup + ', state=' + $entry.targetState } else { 'set' }
        if ($action.type -isnot [string] -or $action.type -cne $entry.kind -or $action.target -isnot [string] -or $action.target -cne $target -or $action.action -isnot [string] -or $action.action -cne $verb -or $action.blocked -isnot [bool] -or $action.blocked -ne $entry.blocked) { throw $actionsError }
        if (($entry.skipped -or $action.PSObject.Properties['skipped']) -and ($action.skipped -isnot [string] -or $action.skipped -cne $entry.skipped)) { throw $actionsError }
        if (-not $service) {
            if (-not $action.PSObject.Properties['value']) { throw $actionsError }
            try { $data = [string](Get-ManifestRegistrySnapshot ([pscustomobject]@{type=$entry.type;data=$action.value})).oldValue } catch { throw $actionsError }
            if (-not [string]::Equals($data, $entry.data, [StringComparison]::Ordinal)) { throw $actionsError }
        }
    }
}

function New-ModuleBackup {
    param([object]$Manifest, [object]$Module, [object[]]$Plan)
    $moduleDir = Join-Path $DataRoot ("backups\" + $Module.id + "\" + (Get-NowStamp))
    $regSnapshots = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($rv in @($Module.registryValues)) {
        if ($Plan[$index++].skipped) { continue }
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
            $snap | Add-Member -NotePropertyName appliedTargetState -NotePropertyValue ([string]$svc.targetState)
            $svcSnapshots.Add($snap) | Out-Null
        }
    }
    $backup = [pscustomobject]@{
        moduleId = $Module.id
        moduleName = $Module.name
        timestamp = (Get-Date).ToString('o')
        applyRequested = $true
        applyCompleted = $false
        registry = @($regSnapshots.ToArray())
        services = @($svcSnapshots.ToArray())
        baseline = Get-BenchmarkSnapshot ("pre-" + $Module.id)
    }
    Ensure-Dir $moduleDir
    $path = Join-Path $moduleDir 'backup.json'
    Write-JsonFile $backup $path
    return [pscustomobject]@{ path=$path; backup=$backup }
}

function Assert-LastApplyFinished {
    param([object]$Module)
    $backupRoot = Join-Path $DataRoot ("backups\" + $Module.id)
    if (-not (Test-Path -LiteralPath $backupRoot)) { return }
    $newest = @(foreach ($directory in Get-ChildItem -LiteralPath $backupRoot -Directory) {
        $candidatePath = Join-Path $directory.FullName 'backup.json'
        if (-not (Test-Path -LiteralPath $candidatePath)) { continue }
        $candidate = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json
        if ($candidate.moduleId -eq $Module.id) { [pscustomobject]@{ path = $candidatePath; timestamp = [datetime]$candidate.timestamp; backup = $candidate } }
    }) | Sort-Object timestamp -Descending | Select-Object -First 1
    if ($newest.backup.applyCompleted -is [bool] -and -not $newest.backup.applyCompleted -and $newest.backup.undoCompleted -ne $true) {
        throw "The last Apply of $($Module.id) stopped before it finished, so this PC may be partly changed. Run Undo with -BackupPath `"$($newest.path)`" before applying again. Nothing was changed."
    }
}

function Invoke-ApplyModule {
    $manifest = Read-Manifest
    $module = Get-ModuleById $manifest $ModuleId
    $plan = Get-ModulePlan $manifest $module
    $planHash = Get-ModulePlanHash $plan
    if ($ConfirmApply) { Assert-ModulePreview $module $plan $planHash }
    Ensure-Dir $DataRoot
    $changeLock = if ($ConfirmApply) { Enter-ChangeLock } else { $null }
    try {
        if ($ConfirmApply) { Assert-LastApplyFinished $module }
        $created = if ($ConfirmApply) { New-ModuleBackup $manifest $module $plan } else { $null }
        $backupPath = $created.path
        $actions = New-Object System.Collections.Generic.List[object]
        try {
            $index = 0
            foreach ($rv in @($module.registryValues)) {
                $blocked = Test-ProtectedRegistryPath $rv.path $manifest $rv.name
                $skipped = $plan[$index++].skipped
                $action = [pscustomobject]@{ type='registry'; target=($rv.path + '\' + $rv.name); blocked=$blocked; action='set'; value=$rv.data }
                if ($skipped) { $action | Add-Member -NotePropertyName skipped -NotePropertyValue $skipped }
                $actions.Add($action) | Out-Null
                if ($blocked -or $skipped) { continue }
                if ($ConfirmApply) { Set-RegistryValueFromManifest $rv }
            }
            foreach ($svc in @($module.services)) {
                $blocked = Test-ProtectedService $svc.name $manifest
                $actions.Add([pscustomobject]@{ type='service'; target=$svc.name; blocked=$blocked; action=('startup=' + $svc.startup + ', state=' + $svc.targetState) }) | Out-Null
                if ($blocked) { continue }
                if ($ConfirmApply) { Set-ServiceFromManifest $svc $created.backup $backupPath }
            }
            if ($ConfirmApply) {
                $created.backup.applyCompleted = $true
                Write-JsonFile $created.backup $backupPath
            }
        } catch {
            if (-not $ConfirmApply) { throw }
            throw [InvalidOperationException]::new("Apply of $($module.id) stopped before it finished, so this PC may be partly changed. Run Undo with -BackupPath `"$backupPath`" before applying again. The error was: $($_.Exception.Message)", $_.Exception)
        }
    } finally {
        Exit-ChangeLock $changeLock
    }
    $after = if ($ConfirmApply) { Get-BenchmarkSnapshot ("post-" + $module.id) } else { $null }
    $smoke = if ($ConfirmApply) { Invoke-SmokeTest } else { $null }
    $runPath = Join-Path $DataRoot ("runs\apply-" + $module.id + "-" + (Get-NowStamp) + ".json")
    $result = [pscustomobject]@{
        moduleId = $module.id
        dryRun = -not $ConfirmApply
        previewPath = if ($ConfirmApply) { $PreviewPath } else { $runPath }
        previewHash = $planHash
        backupPath = $backupPath
        plan = $plan
        actions = @($actions.ToArray())
        after = $after
        smoke = $smoke
    }
    Ensure-Dir (Split-Path $runPath -Parent)
    Write-JsonFile $result $runPath
    return $result
}

function Invoke-RollbackModule {
    $manifest = Read-Manifest
    $changeLock = if ($ConfirmApply) { Enter-ChangeLock } else { $null }
    try {
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
        $backupPath = Resolve-BackupFile $backupPath
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
                $null = ConvertTo-RegistrySnapshotData $expected.kind (Convert-RegistrySnapshotData $expected)
                $current = Get-RegistryValueSnapshot $rv -AllowChangedLayout
                $original = $null
                try { $original = Get-RegistryRestoreSnapshot $rv } catch { if (Test-RegistrySnapshotEqual $expected $current) { throw } }
                if ($null -ne $original -and (Test-RegistrySnapshotEqual $original $current)) {
                    $alreadyAtOriginal.Add([pscustomobject]$target) | Out-Null
                    Write-Host "Already at original value: $($rv.path)\$($rv.name)"
                } elseif (-not (Test-RegistrySnapshotEqual $expected $current)) {
                    $reason = if (Test-RegistryChangedLayout $current) { 'current raw layout cannot have been applied' } else { 'current kind or data changed' }
                    $leftAsChanged.Add([pscustomobject]($target + @{ reason=$reason })) | Out-Null
                    Write-Host "Left as changed: $($rv.path)\$($rv.name) ($reason)"
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
        $serviceStates = @{}
        foreach ($svc in @($backup.services)) {
            $target = @{ type='service'; name=$svc.name }
            if ($svc.exists -isnot [bool]) {
                $leftAsChanged.Add([pscustomobject]($target + @{ reason='missing original existence evidence' })) | Out-Null
                $serviceStates[[string]$svc.name] = [pscustomobject]@{ status='leftAsChanged' }
                Write-Host "Left as changed: service $($svc.name) (missing original existence evidence)"
                continue
            }
            if (-not $svc.exists) { continue }
            try {
                $blocked = Test-ProtectedService $svc.name $manifest
                $current = @(if (-not $blocked) { Get-ServiceSnapshot $svc.name | Where-Object { $_.exists -and $_.name -ieq $svc.name } })
                if ($blocked -or $svc.appliedStartup -notin 'Disabled','Manual','Automatic' -or $current.Count -ne 1) {
                    $leftAsChanged.Add([pscustomobject]($target + @{ reason='protected, missing, or applied startup evidence unavailable' })) | Out-Null
                    $serviceStates[[string]$svc.name] = [pscustomobject]@{ status='leftAsChanged' }
                    Write-Host "Left as changed: service $($svc.name) (applied startup unavailable or changed)"
                } elseif (Test-ServiceRestoreComplete $svc $current[0]) {
                    $alreadyAtOriginal.Add([pscustomobject]$target) | Out-Null
                    $serviceStates[[string]$svc.name] = [pscustomobject]@{ status='alreadyAtOriginal' }
                    Write-Host "Already at original service settings: $($svc.name)"
                } elseif ($current[0].startType -eq $svc.startType) {
                    $reason = 'original startup matches; recorded Running state is unverified and runtime ownership is unavailable'
                    $leftAsChanged.Add([pscustomobject]($target + @{ reason=$reason })) | Out-Null
                    $serviceStates[[string]$svc.name] = [pscustomobject]@{ status='leftAsChanged' }
                    Write-Host "Left as changed: service $($svc.name) ($reason)"
                } elseif ($current[0].startType -eq $svc.appliedStartup) {
                    if ($svc.startType -notin 'Disabled','Manual','Automatic') { throw "Unsupported original service startup: $($svc.name)" }
                    $action = [pscustomobject]($target + @{ action='restore'; status='planned' })
                    $actions.Add($action) | Out-Null
                    $work.Add([pscustomobject]@{ target=$target; snapshot=$svc; action=$action }) | Out-Null
                    $serviceStates[[string]$svc.name] = $action
                } else {
                    $leftAsChanged.Add([pscustomobject]($target + @{ reason='current startup changed' })) | Out-Null
                    $serviceStates[[string]$svc.name] = [pscustomobject]@{ status='leftAsChanged' }
                    Write-Host "Left as changed: service $($svc.name)"
                }
            } catch {
                $failures.Add([pscustomobject]($target + @{ phase='preflight'; error=$_.Exception.Message; mayHaveChanged=$false })) | Out-Null
                $actions.Add([pscustomobject]($target + @{ action='restore'; status='failed' })) | Out-Null
                $serviceStates[[string]$svc.name] = [pscustomobject]@{ status='failed' }
            }
        }
        foreach ($svc in @($backup.services)) {
            if ($svc.appliedTargetState -ne 'Stopped') { continue }
            $dependents = @($svc.dependents)
            for ($index = $dependents.Count - 1; $index -ge 0; $index--) {
                $dependent = $dependents[$index]
                if ($null -eq $dependent -or [string]$dependent.status -cne 'Running' -or $serviceStates.ContainsKey([string]$dependent.name)) { continue }
                $target = @{ type='dependent'; name=[string]$dependent.name; of=[string]$svc.name }
                try {
                    $check = Test-DependentRestore $dependent $serviceStates $manifest -Planning
                    if ($check.state -eq 'alreadyAtOriginal') {
                        if ($ConfirmApply) { Save-DependentRestoreComplete $dependent $backup $backupPath }
                        $alreadyAtOriginal.Add([pscustomobject]$target) | Out-Null
                        $serviceStates[$target.name] = [pscustomobject]@{ status='alreadyAtOriginal' }
                    } elseif ($check.state -eq 'leftAsChanged') {
                        $leftAsChanged.Add([pscustomobject]($target + @{ reason=$check.reason })) | Out-Null
                        $serviceStates[$target.name] = [pscustomobject]@{ status='leftAsChanged' }
                        Write-Host "Left as changed: dependent service $($target.name) of $($target.of) ($($check.reason))"
                    } else {
                        $action = [pscustomobject]($target + @{ action='start'; status='planned' })
                        $actions.Add($action) | Out-Null
                        $work.Add([pscustomobject]@{ target=$target; snapshot=$dependent; action=$action }) | Out-Null
                        $serviceStates[$target.name] = $action
                    }
                } catch {
                    $failures.Add([pscustomobject]($target + @{ phase='preflight'; error=$_.Exception.Message; mayHaveChanged=$false })) | Out-Null
                    $actions.Add([pscustomobject]($target + @{ action='start'; status='failed' })) | Out-Null
                    $serviceStates[$target.name] = [pscustomobject]@{ status='failed' }
                }
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
                    $current = Get-RegistryValueSnapshot $item.snapshot -AllowChangedLayout
                    if (Test-RegistrySnapshotEqual $item.original $current) {
                        $alreadyAtOriginal.Add([pscustomobject]$item.target) | Out-Null
                        $item.action.status = 'alreadyAtOriginal'
                        continue
                    }
                    if (-not (Test-RegistrySnapshotEqual $item.applied $current)) {
                        $reason = if (Test-RegistryChangedLayout $current) { 'current raw layout cannot have been applied' } else { 'changed after preflight' }
                        $leftAsChanged.Add([pscustomobject]($item.target + @{ reason=$reason })) | Out-Null
                        $item.action.status = 'leftAsChanged'
                        Write-Host "Left as changed: $($item.target.path)\$($item.target.name) ($reason)"
                        continue
                    }
                    $attempted++
                    $writing = $true
                    Restore-RegistryValue $item.snapshot $item.original
                    $registryCount++
                } elseif ($item.target.type -eq 'dependent') {
                    $check = Test-DependentRestore $item.snapshot $serviceStates $manifest
                    if ($check.state -eq 'alreadyAtOriginal') {
                        Save-DependentRestoreComplete $item.snapshot $backup $backupPath
                        $alreadyAtOriginal.Add([pscustomobject]$item.target) | Out-Null
                        $item.action.status = 'alreadyAtOriginal'
                        continue
                    }
                    if ($check.state -eq 'leftAsChanged') {
                        $leftAsChanged.Add([pscustomobject]($item.target + @{ reason=$check.reason })) | Out-Null
                        $item.action.status = 'leftAsChanged'
                        Write-Host "Left as changed: dependent service $($item.target.name) of $($item.target.of) ($($check.reason))"
                        continue
                    }
                    $item.snapshot | Add-Member -MemberType NoteProperty -Name restoreAttempted -Value $true -Force
                    Write-JsonFile $backup $backupPath
                    $attempted++
                    $writing = $true
                    Start-Service -Name $item.target.name -ErrorAction Stop
                    $verified = @(Get-ServiceSnapshot $item.target.name | Where-Object { $_.exists -and $_.name -ieq $item.target.name -and $_.status -eq 'Running' -and $_.startType -eq $item.snapshot.startType })
                    if ($verified.Count -ne 1) { throw "Dependent service start verification failed: $($item.target.name)" }
                    Save-DependentRestoreComplete $item.snapshot $backup $backupPath
                    $serviceCount++
                } else {
                    $svc = $item.snapshot
                    $current = @(Get-ServiceSnapshot $svc.name | Where-Object { $_.exists -and $_.name -ieq $svc.name })
                    if ($current.Count -eq 1 -and (Test-ServiceRestoreComplete $svc $current[0])) {
                        $alreadyAtOriginal.Add([pscustomobject]$item.target) | Out-Null
                        $item.action.status = 'alreadyAtOriginal'
                        continue
                    }
                    if ($current.Count -ne 1 -or $current[0].startType -ne $svc.appliedStartup -or $current[0].startType -eq $svc.startType) {
                        $reason = if ($current.Count -eq 1 -and $current[0].startType -eq $svc.startType) {
                            'original startup matches; recorded Running state is unverified and runtime ownership is unavailable'
                        } else { 'changed after preflight' }
                        $leftAsChanged.Add([pscustomobject]($item.target + @{ reason=$reason })) | Out-Null
                        $item.action.status = 'leftAsChanged'
                        Write-Host "Left as changed: service $($svc.name) ($reason)"
                        continue
                    }
                    $attempted++
                    $writing = $true
                    Restore-ServiceSnapshot $svc
                    $verified = @(Get-ServiceSnapshot $svc.name | Where-Object { $_.exists -and $_.name -ieq $svc.name })
                    if ($verified.Count -ne 1 -or -not (Test-ServiceRestoreComplete $svc $verified[0])) { throw "Service restore verification failed: $($svc.name)" }
                    $serviceCount++
                }
                $item.action.status = 'restored'
            } catch {
                $item.action.status = 'failed'
                $failures.Add([pscustomobject]($item.target + @{ phase='restore'; error=$_.Exception.Message; mayHaveChanged=$writing })) | Out-Null
                $stopped = $true
            }
        }
        if ($ConfirmApply -and $failures.Count -eq 0 -and $backup.applyCompleted -is [bool] -and -not $backup.applyCompleted -and $backup.undoCompleted -ne $true) {
            $backup | Add-Member -MemberType NoteProperty -Name undoCompleted -Value $true -Force
            Write-JsonFile $backup $backupPath
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
    } finally {
        Exit-ChangeLock $changeLock
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
