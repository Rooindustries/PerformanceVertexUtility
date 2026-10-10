param(
    [switch]$IncludeCommandLine
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Convert-ToUInt64 {
    param([object]$Value)
    if ($null -eq $Value) { return [uint64]0 }
    try { return [uint64]$Value } catch { return [uint64]0 }
}

function Convert-ToHResultHex {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    try {
        $signed = [int]$Value
        return ('0x{0:X8}' -f [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes($signed), 0))
    } catch { return $null }
}

function Get-ProcessExecutablePath {
    param([System.Diagnostics.Process]$Process)
    try { return (Get-RooIndustriesProcessQuerySnapshot $Process).executablePath } catch { }

    return $null
}

function Get-ProcessInventoryName {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$ExecutablePath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExecutablePath)) {
        $fileName = [System.IO.Path]::GetFileName($ExecutablePath)
        if (-not [string]::IsNullOrWhiteSpace($fileName)) { return $fileName }
    }

    $name = [string]$Process.ProcessName
    if ([string]::IsNullOrWhiteSpace($name)) { return '' }
    if ($Process.Id -eq 0 -and $name -eq 'Idle') { return 'System Idle Process' }
    if (@('System', 'Registry', 'Secure System', 'Memory Compression') -contains $name) { return $name }
    if ($name.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { return $name }
    return "$name.exe"
}

function Get-ProcessSessionIdSafe {
    param([System.Diagnostics.Process]$Process)
    try { return [int]$Process.SessionId } catch { return $null }
}

function Get-ProcessInventoryFromGetProcess {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-Process -ErrorAction Stop)) {
        $path = Get-ProcessExecutablePath $proc
        $name = Get-ProcessInventoryName $proc $path
        $items.Add([pscustomobject]@{
            ProcessId = [int]$proc.Id
            Name = $name
            ExecutablePath = $path
            CommandLine = $null
            SessionId = Get-ProcessSessionIdSafe $proc
            WorkingSetSize = Convert-ToUInt64 $proc.WorkingSet64
            PrivatePageCount = Convert-ToUInt64 $proc.PrivateMemorySize64
        }) | Out-Null
    }
    return @($items.ToArray())
}

function Get-ProcessCategory {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    if (@('overwatch.exe','valorant-win64-shipping.exe','fortniteclient-win64-shipping.exe','cod.exe','r5apex.exe') -contains $n) { return 'foregroundGame' }
    if (@('obs64.exe','obs32.exe','streamlabs desktop.exe') -contains $n) { return 'captureStreaming' }
    if (@('discord.exe','teamspeak.exe','mumble.exe') -contains $n) { return 'voiceChat' }
    if (@('battle.net.exe','steam.exe','epicgameslauncher.exe','riotclientservices.exe','eadesktop.exe','ubisoftconnect.exe') -contains $n) { return 'launcher' }
    if ($n -match 'chrome|msedge|firefox|brave|webview|webhelper|cef|electron') { return 'browserWebView' }
    if ($n -match 'nvidia|nvcontainer|amd|radeon|intel|asus|armoury|samsung|logi|razer|nahimic|steelseries') { return 'vendorUtility' }
    if (@('msmpeng.exe','securityhealthservice.exe','senseir.exe') -contains $n) { return 'security' }
    if ($n -match 'tailscale|wireguard|openvpn|zerotier|wlanext|dns|dhcp') { return 'network' }
    if (@('audiodg.exe','wispr flow.exe') -contains $n) { return 'audioInput' }
    if (@('system','system idle process','registry','smss.exe','csrss.exe','wininit.exe','services.exe','lsass.exe','svchost.exe','fontdrvhost.exe','dwm.exe','winlogon.exe','explorer.exe','taskhostw.exe','sihost.exe','runtimebroker.exe','searchindexer.exe') -contains $n) { return 'windowsCore' }
    return 'backgroundApp'
}

function Get-RoleTags {
    param([string]$Category, [string]$Name)
    $tags = New-Object System.Collections.Generic.List[string]
    switch ($Category) {
        'foregroundGame' { $tags.Add('game'); $tags.Add('foreground-boost-target'); $tags.Add('frame-time-critical') }
        'captureStreaming' { $tags.Add('streaming'); $tags.Add('capture'); $tags.Add('do-not-demote') }
        'voiceChat' { $tags.Add('voice'); $tags.Add('stream-companion'); $tags.Add('do-not-demote') }
        'launcher' { $tags.Add('launcher'); $tags.Add('background-demotion-candidate') }
        'browserWebView' { $tags.Add('browser-webview'); $tags.Add('memory-pressure') }
        'vendorUtility' { $tags.Add('vendor-utility'); $tags.Add('manual-review') }
        'security' { $tags.Add('security'); $tags.Add('do-not-demote') }
        'network' { $tags.Add('network'); $tags.Add('do-not-demote') }
        'audioInput' { $tags.Add('audio-input'); $tags.Add('do-not-demote') }
        'windowsCore' { $tags.Add('windows-core'); $tags.Add('do-not-demote') }
        default { $tags.Add('background') }
    }
    if ($Name.ToLowerInvariant() -match 'webview|webhelper|cef') { $tags.Add('webview-helper') }
    return @($tags.ToArray() | Select-Object -Unique)
}

function Get-Protection {
    param([string]$Category, [string]$Name)
    $n = $Name.ToLowerInvariant()
    if (@('obs64.exe','obs32.exe','discord.exe','msedgewebview2.exe','tailscale.exe','msmpeng.exe','securityhealthservice.exe','audiodg.exe','wispr flow.exe') -contains $n) { return 'protected' }
    if (@('windowsCore','security','network','audioInput') -contains $Category) { return 'protected' }
    if ($Category -eq 'vendorUtility') { return 'warn' }
    return 'candidate'
}

function Get-Risk {
    param([string]$Protection, [string]$Category)
    if ($Protection -eq 'protected') { return 'protected' }
    if ($Category -eq 'foregroundGame') { return 'medium' }
    if ($Category -eq 'vendorUtility') { return 'medium' }
    return 'low'
}

$warnings = New-Object System.Collections.Generic.List[object]
try {
    $rawProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop)
} catch {
    $rawProcesses = @(Get-ProcessInventoryFromGetProcess)
    $cimHResult = Convert-ToHResultHex $_.Exception.HResult
    if ($_.FullyQualifiedErrorId -match '(0x[0-9A-Fa-f]{8})') {
        $cimHResult = '0x' + $Matches[1].Substring(2).ToUpperInvariant()
    }
    $warnings.Add([pscustomobject]@{
        code = 'PROCESS_INVENTORY_DEGRADED'
        message = 'Win32_Process CIM enumeration failed; process inventory used Get-Process fallback with commandLine unavailable and executablePath populated only when accessible.'
        severity = 'warning'
        source = 'performance.processInventory'
        target = 'Win32_Process'
        blocking = $false
        recommendedAction = 'Run elevated or adjust WMI permissions if command-line inventory is required.'
        details = [pscustomobject]@{
            errorId = $_.FullyQualifiedErrorId
            exceptionType = $_.Exception.GetType().FullName
            hresult = $cimHResult
            message = $_.Exception.Message
        }
    }) | Out-Null
}
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$processes = New-Object System.Collections.Generic.List[object]

foreach ($proc in $rawProcesses) {
    $category = Get-ProcessCategory $proc.Name
    $protection = Get-Protection $category $proc.Name
    $priorityClass = $null
    try {
        $gp = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
        if ($null -ne $gp) { $priorityClass = (Get-RooIndustriesProcessQuerySnapshot $gp).priorityClass }
    } catch {
        $priorityClass = $null
    }
    $processes.Add([pscustomobject]@{
        pid = [int]$proc.ProcessId
        name = [string]$proc.Name
        displayName = $null
        executablePath = $proc.ExecutablePath
        publisher = $null
        commandLine = if ($IncludeCommandLine) { $proc.CommandLine } else { $null }
        category = $category
        protection = $protection
        roleTags = @(Get-RoleTags $category $proc.Name)
        sessionId = if ($null -ne $proc.SessionId) { [int]$proc.SessionId } else { $null }
        priorityClass = $priorityClass
        cpuPercent = $null
        workingSetBytes = Convert-ToUInt64 $proc.WorkingSetSize
        privateBytes = Convert-ToUInt64 $proc.PrivatePageCount
        gpuDedicatedBytes = $null
        gpuSharedBytes = $null
        isForegroundCandidate = ($category -eq 'foregroundGame')
        canChangePriority = ($protection -ne 'protected' -and [int]$proc.ProcessId -gt 4)
        risk = Get-Risk $protection $category
    }) | Out-Null
}

$processArray = @($processes.ToArray())
$summary = [pscustomobject]@{
    processCount = $processArray.Count
    backgroundProcessCount = @($processArray | Where-Object { $_.category -notin @('foregroundGame','windowsCore','security','network') }).Count
    protectedProcessCount = @($processArray | Where-Object { $_.protection -eq 'protected' }).Count
    browserWebViewProcessCount = @($processArray | Where-Object { $_.category -eq 'browserWebView' }).Count
    gameProcessCount = @($processArray | Where-Object { $_.category -eq 'foregroundGame' }).Count
    captureStreamingProcessCount = @($processArray | Where-Object { $_.category -eq 'captureStreaming' }).Count
    launcherProcessCount = @($processArray | Where-Object { $_.category -eq 'launcher' }).Count
    vendorUtilityProcessCount = @($processArray | Where-Object { $_.category -eq 'vendorUtility' }).Count
    workingSetBytes = [uint64](($processArray | Measure-Object workingSetBytes -Sum).Sum)
    privateBytes = [uint64](($processArray | Measure-Object privateBytes -Sum).Sum)
    availableMemoryBytes = if ($os) { [uint64]$os.FreePhysicalMemory * 1KB } else { $null }
    commitUsedBytes = if ($os) { ([uint64]($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) * 1KB) } else { $null }
}

$result = [pscustomobject]@{
    schemaVersion = 1
    productName = 'Roo Industries Optimization Suite'
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    source = 'local-read-only'
    summary = $summary
    processes = $processArray
}

if ($warnings.Count -gt 0) {
    $result | Add-Member -MemberType NoteProperty -Name warnings -Value @($warnings.ToArray())
}

$result | ConvertTo-Json -Depth 8

