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
    $p = $Path -replace '/', '\'
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
    param([string]$Path, [object]$Manifest)
    foreach ($pattern in @($Manifest.protected.registryPathPatterns)) {
        if ($Path -match $pattern) { return $true }
    }
    return $false
}

function Get-RegistryValueSnapshot {
    param([object]$Item)
    $psPath = Convert-RegPath $Item.path
    $exists = Test-Path -LiteralPath $psPath
    $valueExists = $false
    $oldValue = $null
    if ($exists) {
        $props = Get-ItemProperty -LiteralPath $psPath -ErrorAction SilentlyContinue
        $prop = $props.PSObject.Properties | Where-Object { $_.Name -eq $Item.name } | Select-Object -First 1
        if ($null -ne $prop) {
            $valueExists = $true
            $oldValue = $prop.Value
        }
    }
    return [pscustomobject]@{
        path = $Item.path
        name = $Item.name
        type = $Item.type
        desiredData = $Item.data
        pathExists = $exists
        valueExists = $valueExists
        oldValue = $oldValue
    }
}

function Set-RegistryValueFromManifest {
    param([object]$Item)
    $psPath = Convert-RegPath $Item.path
    if (-not (Test-Path -LiteralPath $psPath)) {
        New-Item -Path $psPath -Force | Out-Null
    }
    $propertyType = switch ($Item.type) {
        'REG_DWORD' { 'DWord' }
        'REG_QWORD' { 'QWord' }
        'REG_SZ' { 'String' }
        default { 'String' }
    }
    $value = $Item.data
    if ($Item.type -eq 'REG_DWORD') { $value = [uint32]([uint64]$Item.data) }
    if ($Item.type -eq 'REG_QWORD') { $value = [uint64]$Item.data }
    $existing = Get-ItemProperty -LiteralPath $psPath -ErrorAction SilentlyContinue
    $prop = $existing.PSObject.Properties | Where-Object { $_.Name -eq $Item.name } | Select-Object -First 1
    if ($null -eq $prop) {
        New-ItemProperty -LiteralPath $psPath -Name $Item.name -PropertyType $propertyType -Value $value -Force | Out-Null
    } else {
        Set-ItemProperty -LiteralPath $psPath -Name $Item.name -Value $value -Force
    }
}

function Restore-RegistryValue {
    param([object]$Snapshot)
    $psPath = Convert-RegPath $Snapshot.path
    if (-not $Snapshot.valueExists) {
        if (Test-Path -LiteralPath $psPath) {
            Remove-ItemProperty -LiteralPath $psPath -Name $Snapshot.name -ErrorAction SilentlyContinue
        }
        return
    }
    if (-not (Test-Path -LiteralPath $psPath)) {
        New-Item -Path $psPath -Force | Out-Null
    }
    $propertyType = switch ($Snapshot.type) {
        'REG_DWORD' { 'DWord' }
        'REG_QWORD' { 'QWord' }
        'REG_SZ' { 'String' }
        default { 'String' }
    }
    $value = $Snapshot.oldValue
    if ($Snapshot.type -eq 'REG_DWORD') { $value = [uint32]([uint64]$value) }
    New-ItemProperty -LiteralPath $psPath -Name $Snapshot.name -PropertyType $propertyType -Value $value -Force | Out-Null
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
    foreach ($svcName in @('WlanSvc','bthserv','Tailscale','WinDefend','BFE','mpssvc','WpnService')) {
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
    $wispr = @(Get-Process -Name 'Wispr Flow' -ErrorAction SilentlyContinue)
    Add-Result 'process:Wispr Flow' ($wispr.Count -gt 0) "Count=$($wispr.Count)"
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
        $regSnapshots.Add((Get-RegistryValueSnapshot $rv)) | Out-Null
    }
    $svcSnapshots = New-Object System.Collections.Generic.List[object]
    foreach ($svc in @($Module.services)) {
        foreach ($snap in @(Get-ServiceSnapshot $svc.name)) {
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
        $blocked = Test-ProtectedRegistryPath $rv.path $manifest
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
    [void]$manifest
    $backupRoot = Join-Path $DataRoot ("backups\" + $ModuleId)
    if (-not (Test-Path -LiteralPath $backupRoot)) { throw "No backups found for $ModuleId in $backupRoot" }
    $backupPath = $BackupPath
    if ([string]::IsNullOrWhiteSpace($backupPath)) {
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
    if ($ConfirmApply) {
        foreach ($rv in @($backup.registry)) { Restore-RegistryValue $rv }
        foreach ($svc in @($backup.services)) { Restore-ServiceSnapshot $svc }
    }
    return [pscustomobject]@{
        moduleId = $ModuleId
        dryRun = -not $ConfirmApply
        backupPath = $backupPath
        restoredRegistry = @($backup.registry).Count
        restoredServices = @($backup.services).Count
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
<head><meta charset="utf-8"><title>Lean Client Optimizer Report</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1f2937}table{border-collapse:collapse;width:100%;margin:16px 0}th,td{border:1px solid #d1d5db;padding:8px;text-align:left}th{background:#f3f4f6}.muted{color:#6b7280}</style></head>
<body>
<h1>Lean Client Optimizer Report</h1>
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
        Invoke-RollbackModule
    }
    'Report' {
        New-Report
    }
}
