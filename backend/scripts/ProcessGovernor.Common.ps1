. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$script:RooIndustriesProcessGovernorStateFolderName = 'process-governor-sessions'

function Invoke-RooIndustriesProcessGovernorRun {
    param(
        [scriptblock]$Action,
        [scriptblock]$Busy,
        [switch]$ConfirmApply,
        [string]$GateName = '',
        [TimeSpan]$Wait = [TimeSpan]::FromMinutes(2)
    )
    if (-not $ConfirmApply) {
        & $Action
        return
    }
    if ([string]::IsNullOrWhiteSpace($GateName)) {
        $GateName = 'Global\RooIndustriesGovernorRun-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $gate = $null
    $held = $false
    try {
        while ($null -eq $gate -and $clock.Elapsed -lt $Wait) {
            try {
                $gate = [Threading.Mutex]::new($false, $GateName)
            } catch {
                $failure = $_.Exception
                while ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
                if ($failure -isnot [UnauthorizedAccessException]) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
        if ($null -ne $gate) {
            $remaining = $Wait - $clock.Elapsed
            if ($remaining -lt [TimeSpan]::Zero) { $remaining = [TimeSpan]::Zero }
            try {
                $held = $gate.WaitOne($remaining)
            } catch {
                $failure = $_.Exception
                while ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
                if ($failure -isnot [Threading.AbandonedMutexException]) { throw }
                $held = $true
            }
        }
        if ($held) {
            & $Action
        } elseif ($Busy) {
            & $Busy
        } else {
            throw [TimeoutException]::new('Another Background limits run is still going, so this one did not start.')
        }
    } finally {
        try {
            if ($held) { $gate.ReleaseMutex() }
        } finally {
            if ($null -ne $gate) { $gate.Dispose() }
        }
    }
}

function Get-RooIndustriesProcessGovernorWorker {
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try {
        return [pscustomobject]@{
            processId = $self.Id
            startTimeUtc = $self.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
    } finally {
        $self.Dispose()
    }
}

function Test-RooIndustriesProcessGovernorWorkerEnded {
    param([object]$Worker)
    $processId = Get-RooIndustriesPropertyValue $Worker 'processId' 0
    $saved = [string](Get-RooIndustriesPropertyValue $Worker 'startTimeUtc' '')
    if (($processId -isnot [int] -and $processId -isnot [long]) -or $processId -le 0 -or [string]::IsNullOrWhiteSpace($saved)) { return $false }
    $live = Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
    if ($null -eq $live) { return $true }
    try {
        $started = $live.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $false
    } finally {
        $live.Dispose()
    }
    return -not (Test-RooIndustriesProcessStartTime $saved $started)
}

function Resolve-RooIndustriesProcessGovernorStateRoot {
    param([string]$StateRoot)
    $defaultStateRoot = Join-Path $PSScriptRoot '..\state'
    $resolvedStateRoot = Resolve-RooIndustriesPath $StateRoot $defaultStateRoot
    return [System.IO.Path]::GetFullPath((Join-Path $resolvedStateRoot $script:RooIndustriesProcessGovernorStateFolderName))
}

function New-RooIndustriesProcessGovernorSessionId {
    param([string]$ProfileId)
    $safeProfileId = if ([string]::IsNullOrWhiteSpace($ProfileId)) { 'profile' } else { $ProfileId.ToLowerInvariant() -replace '[^a-z0-9\-]+', '-' }
    # The name is a folder under process-governor-sessions, and every file saved in it has to fit the 260-character
    # path limit of Windows PowerShell 5.1, so it stays short: part of the profile name, the time and a random part.
    if ($safeProfileId.Length -gt 24) { $safeProfileId = $safeProfileId.Substring(0, 24).TrimEnd('-') }
    return "$safeProfileId-$(Get-RooIndustriesFileStamp)-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
}

function Get-RooIndustriesProcessGovernorSessionDirectory {
    param(
        [string]$ResolvedGovernorStateRoot,
        [string]$SessionId
    )
    return Join-Path $ResolvedGovernorStateRoot $SessionId
}

function Write-RooIndustriesProcessGovernorJsonFile {
    param(
        [object]$Value,
        [string]$Path
    )
    Ensure-RooIndustriesDirectory (Split-Path $Path -Parent)
    for ($attempt = 0; ; $attempt++) {
        try { Write-RooIndustriesOperationJson $Value $Path; return }
        catch {
            $failure = $_.Exception
            while ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
            $held = $failure -is [UnauthorizedAccessException] -or ($failure -is [IO.IOException] -and ($failure.HResult -band 0xffff) -in 32, 1175)
            if ($attempt -ge 80 -or -not $held) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Add-RooIndustriesProcessGovernorLogFileEntry {
    param(
        [string]$SessionDirectory,
        [object]$Entry
    )
    if ([string]::IsNullOrWhiteSpace($SessionDirectory)) { return }
    Ensure-RooIndustriesDirectory $SessionDirectory
    ($Entry | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath (Join-Path $SessionDirectory 'events.jsonl') -Encoding UTF8
}

function Get-RooIndustriesProcessGovernorSessionFileFromPath {
    param([string]$SessionPath)
    if ([string]::IsNullOrWhiteSpace($SessionPath)) { return $null }
    $resolved = Resolve-RooIndustriesPath $SessionPath $SessionPath
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        return Join-Path $resolved 'session.json'
    }
    return $resolved
}

function Get-RooIndustriesProcessGovernorLatestSessionFile {
    param([string]$ResolvedGovernorStateRoot)
    if (-not (Test-Path -LiteralPath $ResolvedGovernorStateRoot)) { return $null }
    $latest = Get-ChildItem -LiteralPath $ResolvedGovernorStateRoot -Filter 'session.json' -Recurse -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { return $null }
    return $latest.FullName
}

function Resolve-RooIndustriesProcessGovernorSessionFile {
    param(
        [string]$SessionId,
        [string]$SessionPath,
        [string]$StateRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($SessionPath)) {
        return Get-RooIndustriesProcessGovernorSessionFileFromPath $SessionPath
    }
    $resolvedStateRoot = Resolve-RooIndustriesProcessGovernorStateRoot $StateRoot
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return Join-Path (Get-RooIndustriesProcessGovernorSessionDirectory $resolvedStateRoot $SessionId) 'session.json'
    }
    $held = Get-RooIndustriesProcessGovernorHeldSession $resolvedStateRoot
    if ($null -ne $held) { return $held }
    return Get-RooIndustriesProcessGovernorLatestSessionFile $resolvedStateRoot
}

function Get-RooIndustriesGovernorNumber {
    param(
        [object]$Object,
        [string]$Name,
        [double]$DefaultValue
    )
    $value = Get-RooIndustriesPropertyValue $Object $Name $DefaultValue
    try { return [double]$value } catch { return $DefaultValue }
}

function Get-RooIndustriesGovernorInt {
    param(
        [object]$Object,
        [string]$Name,
        [int]$DefaultValue
    )
    $value = Get-RooIndustriesPropertyValue $Object $Name $DefaultValue
    try { return [int]$value } catch { return $DefaultValue }
}

function Get-RooIndustriesProcessGovernorConfig {
    param(
        [object]$Profile,
        [int]$MaxDurationSecondsOverride = 0
    )
    $governor = Get-RooIndustriesPropertyValue $Profile 'governor' $Profile
    $thresholds = Get-RooIndustriesPropertyValue $governor 'thresholds' $governor
    $restraint = Get-RooIndustriesPropertyValue $governor 'restraint' $governor
    $maxDuration = if ($MaxDurationSecondsOverride -gt 0) { $MaxDurationSecondsOverride } else { Get-RooIndustriesGovernorInt $thresholds 'maxSessionDurationSeconds' 60 }
    if ($maxDuration -lt 1) { $maxDuration = 1 }
    $poll = Get-RooIndustriesGovernorNumber $thresholds 'pollIntervalSeconds' 1
    if ($poll -lt 1) { $poll = 1 }
    return [pscustomobject]@{
        totalCpuPressureThresholdPercent = Get-RooIndustriesGovernorNumber $thresholds 'totalCpuPressureThresholdPercent' 35
        perProcessCpuThresholdPercent = Get-RooIndustriesGovernorNumber $thresholds 'perProcessCpuThresholdPercent' 8
        timeOverThresholdSeconds = Get-RooIndustriesGovernorNumber $thresholds 'timeOverThresholdSeconds' 8
        minimumRestraintSeconds = Get-RooIndustriesGovernorNumber $thresholds 'minimumRestraintSeconds' 15
        restoreCpuThresholdPercent = Get-RooIndustriesGovernorNumber $thresholds 'restoreCpuThresholdPercent' 3
        cooldownAfterRestoreSeconds = Get-RooIndustriesGovernorNumber $thresholds 'cooldownAfterRestoreSeconds' 20
        maxSessionDurationSeconds = $maxDuration
        pollIntervalSeconds = $poll
        priorityClass = [string](Get-RooIndustriesPropertyValue $restraint 'priorityClass' 'BelowNormal')
        affinityMask = Get-RooIndustriesPropertyValue $restraint 'affinityMask' $null
        ioPriority = Get-RooIndustriesPropertyValue $restraint 'ioPriority' $null
        memoryPriority = Get-RooIndustriesPropertyValue $restraint 'memoryPriority' 2
        gpuPriority = Get-RooIndustriesPropertyValue $restraint 'gpuPriority' $null
        excludeForegroundProcess = [bool](Get-RooIndustriesPropertyValue $governor 'excludeForegroundProcess' $true)
    }
}

function Resolve-RooIndustriesProcessGovernorProtectedCatalog {
    param(
        [object]$Profile,
        [string]$ProfilePath
    )
    $catalogPathValue = [string](Get-RooIndustriesPropertyValue $Profile 'protectedCatalogPath' 'protected-processes.json')
    if ([System.IO.Path]::IsPathRooted($catalogPathValue)) {
        return $catalogPathValue
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path $ProfilePath -Parent) $catalogPathValue))
}

function Ensure-RooIndustriesForegroundWindowNative {
    if ('RooIndustriesForegroundWindow' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesForegroundWindow {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@
}

function Get-RooIndustriesForegroundProcessId {
    param([int]$OverrideProcessId = 0)
    if ($OverrideProcessId -gt 0) { return $OverrideProcessId }
    try {
        Ensure-RooIndustriesForegroundWindowNative
        $foregroundProcessId = [uint32]0
        $handle = [RooIndustriesForegroundWindow]::GetForegroundWindow()
        if ($handle -eq [IntPtr]::Zero) { return $null }
        [RooIndustriesForegroundWindow]::GetWindowThreadProcessId($handle, [ref]$foregroundProcessId) | Out-Null
        if ($foregroundProcessId -gt 0) { return [int]$foregroundProcessId }
    } catch { }
    return $null
}

function Get-RooIndustriesGovernorProcessCategory {
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

function Get-RooIndustriesGovernorProcessSnapshot {
    param([switch]$IncludeCommandLine)
    $cimById = @{}
    if ($IncludeCommandLine) {
        foreach ($cim in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            $cimById[[int]$cim.ProcessId] = $cim
        }
    }
    $rawProcesses = @(Get-Process -ErrorAction SilentlyContinue)
    $processes = New-Object System.Collections.Generic.List[object]
    foreach ($live in $rawProcesses) {
        $processIdValue = [int]$live.Id
        $name = [string]$live.ProcessName
        if ($name -notin @('Idle','System') -and -not $name.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
            $name = "$name.exe"
        }
        $cim = $cimById[$processIdValue]
        $path = $null
        $query = $null
        try { $query = Get-RooIndustriesProcessQuerySnapshot $live; $path = $query.executablePath } catch { $path = $null }
        if ([string]::IsNullOrWhiteSpace([string]$path) -and $cim) { $path = $cim.ExecutablePath }
        $sessionId = $null
        try { $sessionId = [int]$live.SessionId } catch { $sessionId = $null }
        $category = Get-RooIndustriesGovernorProcessCategory $name
        $cpuSeconds = $null
        $priority = $null
        if($query){$cpuSeconds=$query.cpuSeconds;$priority=$query.priorityClass}
        $workingSetBytes = [uint64]0
        $privateBytes = [uint64]0
        try { $workingSetBytes = [uint64]$live.WorkingSet64 } catch { $workingSetBytes = [uint64]0 }
        try { $privateBytes = [uint64]$live.PrivateMemorySize64 } catch { $privateBytes = [uint64]0 }
        $processes.Add([pscustomobject]@{
            pid = $processIdValue
            name = $name
            displayName = $null
            executablePath = $path
            publisher = $null
            commandLine = if ($IncludeCommandLine -and $cim) { $cim.CommandLine } else { $null }
            category = $category
            sessionId = $sessionId
            priorityClass = $priority
            cpuSeconds = $cpuSeconds
            cpuPercent = 0.0
            workingSetBytes = $workingSetBytes
            privateBytes = $privateBytes
            canChangePriority = ($processIdValue -gt 4)
            risk = if ($category -in @('windowsCore','security','network','audioInput')) { 'protected' } else { 'low' }
        }) | Out-Null
    }
    return @($processes.ToArray())
}

function Get-RooIndustriesGovernorCpuSample {
    param(
        [int]$SampleIntervalMilliseconds = 500,
        [switch]$IncludeCommandLine
    )
    if ($SampleIntervalMilliseconds -lt 100) { $SampleIntervalMilliseconds = 100 }
    $processorCount = [Environment]::ProcessorCount
    if ($processorCount -lt 1) { $processorCount = 1 }
    $before = @(Get-RooIndustriesGovernorProcessSnapshot -IncludeCommandLine:$IncludeCommandLine)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds $SampleIntervalMilliseconds
    $after = @(Get-RooIndustriesGovernorProcessSnapshot -IncludeCommandLine:$IncludeCommandLine)
    $watch.Stop()
    $elapsed = $watch.Elapsed.TotalSeconds
    if ($elapsed -le 0) { $elapsed = [double]($SampleIntervalMilliseconds / 1000.0) }
    $beforeById = @{}
    foreach ($proc in $before) {
        $beforeById[[int](Get-RooIndustriesPropertyValue $proc 'pid' 0)] = $proc
    }
    $sampled = New-Object System.Collections.Generic.List[object]
    $totalCpu = 0.0
    foreach ($proc in $after) {
        $processIdValue = [int](Get-RooIndustriesPropertyValue $proc 'pid' 0)
        $prior = $beforeById[$processIdValue]
        $cpuPercent = 0.0
        if ($prior) {
            $beforeCpu = Get-RooIndustriesPropertyValue $prior 'cpuSeconds' $null
            $afterCpu = Get-RooIndustriesPropertyValue $proc 'cpuSeconds' $null
            if ($null -ne $beforeCpu -and $null -ne $afterCpu) {
                $delta = [double]$afterCpu - [double]$beforeCpu
                if ($delta -lt 0) { $delta = 0 }
                $cpuPercent = [math]::Round((($delta / $elapsed) / $processorCount) * 100, 2)
            }
        }
        $proc.cpuPercent = $cpuPercent
        $totalCpu += $cpuPercent
        $sampled.Add($proc) | Out-Null
    }
    if ($totalCpu -gt 100) { $totalCpu = 100 }
    return [pscustomobject]@{
        capturedAtUtc = Get-RooIndustriesUtcStamp
        sampleIntervalSeconds = [math]::Round($elapsed, 3)
        processorCount = $processorCount
        totalCpuPercent = [math]::Round($totalCpu, 2)
        processes = @($sampled.ToArray())
    }
}

function Get-RooIndustriesProcessGovernorRules {
    param([object]$Profile)
    $governor = Get-RooIndustriesPropertyValue $Profile 'governor' $Profile
    $rules = @(Get-RooIndustriesPropertyArray $governor 'candidateSelectors')
    if ($rules.Count -eq 0) { $rules = @(Get-RooIndustriesPropertyArray $Profile 'candidateSelectors') }
    if ($rules.Count -eq 0) {
        $rules = @(
            [pscustomobject]@{
                ruleId = 'default-background-apps'
                match = [pscustomobject]@{
                    processCategories = @('backgroundApp','browserWebView','launcher')
                    excludeProcessCategories = @('windowsCore','security','network','audioInput','foregroundGame','captureStreaming','voiceChat')
                }
                reason = 'Background process exceeded governor CPU thresholds.'
                reasonCodes = @('BACKGROUND_PROCESS_OVER_THRESHOLD')
                risk = 'low'
            }
        )
    }
    return @($rules)
}

function Get-RooIndustriesProcessGovernorCandidateMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    foreach ($rule in @(Get-RooIndustriesProcessGovernorRules $Profile)) {
        $enabled = [bool](Get-RooIndustriesPropertyValue $rule 'enabled' $true)
        if (-not $enabled) { continue }
        $match = Get-RooIndustriesPropertyValue $rule 'match' $rule
        if (Test-RooIndustriesProcessMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; rule = $rule }
        }
    }
    return [pscustomobject]@{ matched = $false; rule = $null }
}

function Get-RooIndustriesProcessGovernorProfileProtectedMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    $governor = Get-RooIndustriesPropertyValue $Profile 'governor' $Profile
    $protectedItems = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-RooIndustriesPropertyArray $governor 'protectedProcesses')) { $protectedItems.Add($item) | Out-Null }
    foreach ($item in @(Get-RooIndustriesPropertyArray $Profile 'protectedProcesses')) { $protectedItems.Add($item) | Out-Null }
    foreach ($item in @(Get-RooIndustriesPropertyArray $Profile 'protectedCompanions')) { $protectedItems.Add($item) | Out-Null }
    foreach ($item in @($protectedItems.ToArray())) {
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($name in @(Get-RooIndustriesPropertyArray $item 'names')) { $names.Add([string]$name) | Out-Null }
        foreach ($name in @(Get-RooIndustriesPropertyArray $item 'processNames')) { $names.Add([string]$name) | Out-Null }
        $singleName = [string](Get-RooIndustriesPropertyValue $item 'name' '')
        if (-not [string]::IsNullOrWhiteSpace($singleName)) { $names.Add($singleName) | Out-Null }
        $match = [pscustomobject]@{
            processNames = @($names.ToArray())
            namePatterns = @(Get-RooIndustriesPropertyArray $item 'namePatterns')
            pathPatterns = @(Get-RooIndustriesPropertyArray $item 'pathPatterns')
            processCategories = @(Get-RooIndustriesPropertyArray $item 'processCategories')
        }
        if (Test-RooIndustriesProcessMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; item = $item }
        }
    }
    return [pscustomobject]@{ matched = $false; item = $null }
}

function Add-RooIndustriesGovernorReason {
    param(
        [System.Collections.Generic.List[string]]$Reasons,
        [object]$Values
    )
    foreach ($value in @(Get-RooIndustriesArray $Values)) {
        if ($null -eq $value) { continue }
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text) -and -not $Reasons.Contains($text)) {
            $Reasons.Add($text) | Out-Null
        }
    }
}

function Get-RooIndustriesGovernorApplicableControlChanges {
    param([object[]]$ControlChanges)
    $applicable = New-Object System.Collections.Generic.List[object]
    foreach ($change in @(Get-RooIndustriesArray $ControlChanges)) {
        if (-not [bool](Get-RooIndustriesPropertyValue $change 'blocked' $false)) {
            $applicable.Add($change) | Out-Null
        }
    }
    return @($applicable.ToArray())
}

function Get-RooIndustriesProcessGovernorDecision {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog,
        [Nullable[int]]$ForegroundProcessId,
        [object]$Config
    )
    $reasonCodes = New-Object System.Collections.Generic.List[string]
    $skipReasons = New-Object System.Collections.Generic.List[string]
    $candidateMatch = Get-RooIndustriesProcessGovernorCandidateMatch $Process $Profile
    $catalogMatch = Get-RooIndustriesProtectedCatalogMatch $Process $ProtectedCatalog
    $profileProtectedMatch = Get-RooIndustriesProcessGovernorProfileProtectedMatch $Process $Profile
    $processIdValue = [int](Get-RooIndustriesPropertyValue $Process 'pid' 0)
    $category = [string](Get-RooIndustriesPropertyValue $Process 'category' 'unknown')
    $blocked = $false
    $protected = $false
    $categoryProtected = $false
    $catalogProtected = $false
    $profileProtected = $false
    $foregroundMatched = $false
    $classification = if ($candidateMatch.matched) { 'demotionCandidate' } else { 'unknown' }
    $matchedRuleId = if ($candidateMatch.matched) { [string](Get-RooIndustriesPropertyValue $candidateMatch.rule 'ruleId' 'governor-background-offender') } else { $null }

    if ($processIdValue -le 4) {
        $blocked = $true
        $protected = $true
        $classification = 'protected'
        $skipReasons.Add('System process IDs are excluded from process governor restraint.') | Out-Null
        Add-RooIndustriesGovernorReason $reasonCodes @('SYSTEM_PROCESS_EXCLUDED')
    }
    if ($category -in @('windowsCore','security','network','audioInput')) {
        $blocked = $true
        $protected = $true
        $categoryProtected = $true
        $classification = 'protected'
        $skipReasons.Add("Process category '$category' is protected from governor restraint.") | Out-Null
        Add-RooIndustriesGovernorReason $reasonCodes @('PROTECTED_CATEGORY')
    }
    if ($catalogMatch.matched) {
        $blocked = $true
        $protected = $true
        $catalogProtected = $true
        $classification = [string](Get-RooIndustriesPropertyValue $catalogMatch.item 'classification' 'protected')
        if ([string]::IsNullOrWhiteSpace($classification)) { $classification = 'protected' }
        $skipReasons.Add([string](Get-RooIndustriesPropertyValue $catalogMatch.item 'reason' 'Protected process catalog match.')) | Out-Null
        Add-RooIndustriesGovernorReason $reasonCodes (Get-RooIndustriesPropertyArray $catalogMatch.item 'reasonCodes')
    }
    if ($profileProtectedMatch.matched) {
        $blocked = $true
        $protected = $true
        $profileProtected = $true
        $classification = 'protectedCompanion'
        $skipReasons.Add([string](Get-RooIndustriesPropertyValue $profileProtectedMatch.item 'reason' 'Profile protected process match.')) | Out-Null
        Add-RooIndustriesGovernorReason $reasonCodes (Get-RooIndustriesPropertyArray $profileProtectedMatch.item 'reasonCodes')
        Add-RooIndustriesGovernorReason $reasonCodes @('PROFILE_PROTECTED_PROCESS')
    }
    if ($Config.excludeForegroundProcess -and $null -ne $ForegroundProcessId -and $processIdValue -eq [int]$ForegroundProcessId) {
        $blocked = $true
        $protected = $true
        $foregroundMatched = $true
        if ($classification -eq 'unknown') { $classification = 'protected' }
        $skipReasons.Add('Foreground process is excluded from governor restraint.') | Out-Null
        Add-RooIndustriesGovernorReason $reasonCodes @('FOREGROUND_PROCESS_EXCLUDED')
    }
    if (-not $candidateMatch.matched -and -not $blocked) {
        Add-RooIndustriesGovernorReason $reasonCodes @('NO_GOVERNOR_CANDIDATE_MATCH')
    }
    if ($candidateMatch.matched) {
        Add-RooIndustriesGovernorReason $reasonCodes (Get-RooIndustriesPropertyArray $candidateMatch.rule 'reasonCodes')
        if ($reasonCodes.Count -eq 0) { Add-RooIndustriesGovernorReason $reasonCodes @('GOVERNOR_CANDIDATE_MATCH') }
    }
    $canChange = [bool](Get-RooIndustriesPropertyValue $Process 'canChangePriority' $false)
    if ($candidateMatch.matched -and -not $canChange) {
        $blocked = $true
        $skipReasons.Add('Process control state is not safe to change from this session.') | Out-Null
        Add-RooIndustriesGovernorReason $reasonCodes @('PROCESS_CONTROL_NOT_ALLOWED')
    }
    return [pscustomobject]@{
        candidateMatched = [bool]$candidateMatch.matched
        candidateRule = $candidateMatch.rule
        matchedRuleId = $matchedRuleId
        categoryProtected = $categoryProtected
        catalogProtected = $catalogProtected
        profileProtected = $profileProtected
        foregroundMatched = $foregroundMatched
        blocked = $blocked
        protected = $protected
        classification = $classification
        skipReasons = @($skipReasons.ToArray())
        reasonCodes = @($reasonCodes.ToArray())
    }
}

function New-RooIndustriesProcessGovernorPreviewEntry {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog,
        [Nullable[int]]$ForegroundProcessId,
        [object]$Config,
        [double]$TotalCpuPercent,
        [string]$LifecycleState = 'preview',
        [double]$SustainedSeconds = 0
    )
    $decision = Get-RooIndustriesProcessGovernorDecision $Process $Profile $ProtectedCatalog $ForegroundProcessId $Config
    $processId = [int](Get-RooIndustriesPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooIndustriesPropertyValue $Process 'name' '')
    $cpuPercent = [double](Get-RooIndustriesPropertyValue $Process 'cpuPercent' 0)
    $thresholdMet = ($TotalCpuPercent -ge [double]$Config.totalCpuPressureThresholdPercent -and $cpuPercent -ge [double]$Config.perProcessCpuThresholdPercent)
    $readGpu = -not $decision.blocked -and $decision.candidateMatched -and $thresholdMet -and (Test-RooIndustriesGpuPriorityAllowed ([string]$Config.gpuPriority))
    $currentControls = Get-RooIndustriesProcessControlState $processId (Get-RooIndustriesPropertyValue $Process 'priorityClass' $null) -ReadGpu:$readGpu
    $currentPriority = $currentControls.priorityClass
    $currentAffinity = $currentControls.affinityMask
    $currentIoPriority = $currentControls.ioPriority
    $currentMemoryPriority = $currentControls.memoryPriority
    $currentGpuPriority = $currentControls.gpuPriority
    $proposedPriority = $currentPriority
    $proposedAffinity = $currentAffinity
    $proposedIoPriority = $currentIoPriority
    $proposedMemoryPriority = $currentMemoryPriority
    $proposedGpuPriority = $currentGpuPriority
    $controlChanges = New-Object System.Collections.Generic.List[object]
    $blocked = [bool]$decision.blocked
    $reason = $null
    if ($blocked) {
        $reason = ($decision.skipReasons -join ' ')
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'Process is protected from governor restraint.' }
    } elseif (-not $decision.candidateMatched) {
        $blocked = $true
        $reason = 'No governor candidate rule matched this process.'
    } elseif (-not $thresholdMet) {
        $reason = "Process did not cross governor thresholds. Total CPU $TotalCpuPercent%, process CPU $cpuPercent%."
    } else {
        $ruleReason = [string](Get-RooIndustriesPropertyValue $decision.candidateRule 'reason' '')
        if ([string]::IsNullOrWhiteSpace($ruleReason)) { $ruleReason = 'Sustained background CPU pressure candidate.' }
        $reason = "$ruleReason Total CPU $TotalCpuPercent%, process CPU $cpuPercent%."
        if ($SustainedSeconds -gt 0) {
            $reason = "$reason Sustained for $([math]::Round($SustainedSeconds, 2)) second(s)."
        } else {
            $reason = "$reason Governor would apply restraint after the configured grace period if sustained."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Config.priorityClass)) {
            if (Test-RooIndustriesPriorityAllowed ([string]$Config.priorityClass)) {
                $proposedPriority = [string]$Config.priorityClass
                $controlChanges.Add((New-RooIndustriesControlChange 'priorityClass' $currentPriority $proposedPriority 'setPriority' 'Temporarily lower background offender priority.')) | Out-Null
            } else {
                $blocked = $true
                $reason = "Priority class '$($Config.priorityClass)' is outside the allow-list."
            }
        }
        $configuredAffinity = Get-RooIndustriesPropertyValue $Config 'affinityMask' $null
        if (-not $blocked -and $null -ne $configuredAffinity -and -not [string]::IsNullOrWhiteSpace([string]$configuredAffinity) -and [string]$currentAffinity -ne [string]$configuredAffinity) {
            if (Test-RooIndustriesAffinityMaskAllowed $configuredAffinity) {
                $proposedAffinity = [int64]$configuredAffinity
                $controlChanges.Add((New-RooIndustriesControlChange 'affinityMask' $currentAffinity $proposedAffinity 'setAffinity' 'Temporarily set background offender CPU affinity.')) | Out-Null
            } else {
                $blocked = $true
                $reason = "Affinity mask '$configuredAffinity' is invalid."
                $controlChanges.Add((New-RooIndustriesControlChange 'affinityMask' $currentAffinity $configuredAffinity 'setAffinity' 'Requested CPU affinity is invalid.' $true $reason)) | Out-Null
            }
        }
        if (-not $blocked -and -not [string]::IsNullOrWhiteSpace([string]$Config.ioPriority)) {
            if (Test-RooIndustriesIoPriorityAllowed ([string]$Config.ioPriority)) {
                $proposedIoPriority = [string]$Config.ioPriority
                $controlChanges.Add((New-RooIndustriesControlChange 'ioPriority' $currentIoPriority $proposedIoPriority 'setIoPriority' 'Temporarily lower background offender I/O priority.')) | Out-Null
            } else {
                $blocked = $true
                $reason = "I/O priority '$($Config.ioPriority)' is outside the allow-list."
            }
        }
        if (-not $blocked -and $null -ne $Config.memoryPriority) {
            $memoryChange = New-RooIndustriesControlChange 'memoryPriority' $currentMemoryPriority $Config.memoryPriority 'setMemoryPriority' 'Temporarily lower background offender memory priority.'
            $memoryReason = Get-RooIndustriesControlChangeValidationReason $memoryChange $currentControls
            if ($memoryReason) {
                $memoryChange.blocked = $true
                $memoryChange.blockedReason = $memoryReason
            } else {
                $proposedMemoryPriority = [int]$Config.memoryPriority
            }
            $controlChanges.Add($memoryChange) | Out-Null
        }
        if (-not $blocked -and -not [string]::IsNullOrWhiteSpace([string]$Config.gpuPriority) -and [string]$currentGpuPriority -ne [string]$Config.gpuPriority) {
            if (-not (Test-RooIndustriesGpuPriorityAllowed ([string]$Config.gpuPriority))) {
                $blocked = $true
                $reason = "GPU priority '$($Config.gpuPriority)' is outside the allow-list."
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority ([string]$Config.gpuPriority) 'setGpuPriority' 'Requested GPU scheduling priority is outside the allow-list.' $true $reason)) | Out-Null
            } elseif (-not [bool](Get-RooIndustriesPropertyValue $currentControls 'gpuPriorityAvailable' $false)) {
                $blocked = $true
                $reason = "GPU scheduling priority is unavailable for this process."
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority ([string]$Config.gpuPriority) 'setGpuPriority' 'Native GPU scheduling priority is unavailable for this process.' $true $reason)) | Out-Null
            } else {
                $proposedGpuPriority = [string]$Config.gpuPriority
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority $proposedGpuPriority 'setGpuPriority' 'Temporarily set background offender GPU scheduling priority.')) | Out-Null
            }
        }
    }

    $directed = Select-RooIndustriesPriorityDirection @($controlChanges.ToArray()) 'lower'
    $controlChanges.Clear()
    foreach ($change in $directed.changes) { $controlChanges.Add($change) | Out-Null }
    foreach ($skip in $directed.skippedControls) {
        $reason += ' ' + $skip.reason
        switch ($skip.control) {
            'priorityClass' { $proposedPriority = $currentPriority }
            'ioPriority' { $proposedIoPriority = $currentIoPriority }
            'memoryPriority' { $proposedMemoryPriority = $currentMemoryPriority }
        }
    }

    $applicableControlChanges = @(Get-RooIndustriesGovernorApplicableControlChanges @($controlChanges.ToArray()))
    $proposedAction = if ($blocked -or $controlChanges.Count -eq 0) {
        'noChange'
    } elseif ($applicableControlChanges.Count -eq 1 -and [string](Get-RooIndustriesPropertyValue $applicableControlChanges[0] 'control' '') -eq 'priorityClass') {
        'setPriority'
    } else {
        'setProcessControls'
    }
    $ruleId = [string]$decision.matchedRuleId
    if ([string]::IsNullOrWhiteSpace($ruleId)) { $ruleId = if ($blocked) { 'governor-skip' } else { 'governor-threshold' } }
    $previewId = (($ruleId, $processName, $processId) -join '-').ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'

    return [pscustomobject]@{
        previewId = $previewId
        type = 'processGovernorRestraint'
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooIndustriesPropertyValue $Process 'executablePath' $null
        currentPriorityClass = $currentPriority
        proposedPriorityClass = $proposedPriority
        currentAffinityMask = $currentAffinity
        proposedAffinityMask = $proposedAffinity
        currentIoPriority = $currentIoPriority
        currentMemoryPriority = $currentMemoryPriority
        proposedIoPriority = $proposedIoPriority
        proposedMemoryPriority = $proposedMemoryPriority
        currentGpuPriority = $currentGpuPriority
        proposedGpuPriority = $proposedGpuPriority
        gpuPriorityAvailable = Get-RooIndustriesPropertyValue $currentControls 'gpuPriorityAvailable' $false
        gpuPriorityStatus = Get-RooIndustriesPropertyValue $currentControls 'gpuPriorityStatus' $null
        proposedAction = $proposedAction
        controlChanges = @($controlChanges.ToArray())
        skippedControls = $directed.skippedControls
        ruleId = $ruleId
        reason = $reason
        reasonCodes = @($decision.reasonCodes)
        classification = $decision.classification
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = if ($blocked) { 'protected' } else { 'low' }
        confidence = if ($blocked) { 'high' } else { 'medium' }
        protected = [bool]$decision.protected
        requiresConfirmation = ($applicableControlChanges.Count -gt 0 -and -not $blocked)
        rollbackSupported = ($applicableControlChanges.Count -gt 0 -and -not $blocked)
        lifecycleState = $LifecycleState
        currentState = [pscustomobject]@{
            priorityClass = $currentPriority
            affinityMask = $currentAffinity
            ioPriority = $currentIoPriority
            memoryPriority = $currentMemoryPriority
            gpuPriority = $currentGpuPriority
            cpuPercent = $cpuPercent
            totalCpuPercent = $TotalCpuPercent
            sustainedSeconds = $SustainedSeconds
            category = Get-RooIndustriesPropertyValue $Process 'category' 'unknown'
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = $proposedPriority
            affinityMask = $proposedAffinity
            ioPriority = $proposedIoPriority
            memoryPriority = $proposedMemoryPriority
            gpuPriority = $proposedGpuPriority
            reason = $reason
        }
        impact = [pscustomobject]@{
            expectedMemoryEffectBytes = 0
            expectedCpuWakeupEffect = if ($proposedAction -eq 'noChange') { 'neutral' } else { 'lower' }
            targetMetrics = @('system-responsiveness','foreground-frame-time-stability','background-cpu-pressure')
        }
        rollback = if ($applicableControlChanges.Count -gt 0 -and -not $blocked) {
            [pscustomobject]@{
                restorePriorityClass = $currentPriority
                restoreAffinityMask = $currentAffinity
                restoreIoPriority = $currentIoPriority
                restoreMemoryPriority = $currentMemoryPriority
                restoreGpuPriority = $currentGpuPriority
                captureOriginalState = $true
            }
        } else {
            $null
        }
    }
}

function Get-RooIndustriesProcessGovernorPreview {
    param(
        [object]$Profile,
        [string]$ProfilePath,
        [object]$ProtectedCatalog,
        [int]$SampleIntervalMilliseconds = 500,
        [int]$ForegroundProcessId = 0,
        [int]$MaxDurationSecondsOverride = 0,
        [switch]$IncludeCommandLine
    )
    $config = Get-RooIndustriesProcessGovernorConfig $Profile $MaxDurationSecondsOverride
    $foregroundPid = Get-RooIndustriesForegroundProcessId $ForegroundProcessId
    $sample = Get-RooIndustriesGovernorCpuSample -SampleIntervalMilliseconds $SampleIntervalMilliseconds -IncludeCommandLine:$IncludeCommandLine
    $preview = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-RooIndustriesPropertyArray $sample 'processes')) {
        $decision = Get-RooIndustriesProcessGovernorDecision $proc $Profile $ProtectedCatalog $foregroundPid $config
        $cpuPercent = [double](Get-RooIndustriesPropertyValue $proc 'cpuPercent' 0)
        $highCpu = ($sample.totalCpuPercent -ge $config.totalCpuPressureThresholdPercent -and $cpuPercent -ge $config.perProcessCpuThresholdPercent)
        $explicitSkip = $decision.profileProtected -or $decision.foregroundMatched
        $include = $decision.candidateMatched -or $explicitSkip -or ($decision.categoryProtected -and $highCpu) -or $highCpu
        if (-not $include) { continue }
        $preview.Add((New-RooIndustriesProcessGovernorPreviewEntry $proc $Profile $ProtectedCatalog $foregroundPid $config ([double]$sample.totalCpuPercent))) | Out-Null
    }
    return [pscustomobject]@{
        profileId = [string](Get-RooIndustriesPropertyValue $Profile 'profileId' '')
        profilePath = $ProfilePath
        config = $config
        foregroundProcessId = $foregroundPid
        sample = $sample
        preview = @($preview.ToArray())
    }
}

$script:RooIndustriesGovernorControlUnreadable = 'Windows couldn''t read this setting, so it was left alone. Restore again, or it resets when that app restarts.'
$script:RooIndustriesGovernorRestoreInterrupted = 'Restore stopped part-way while putting this setting back, so it can''t tell whether the value now is still from Background limits. It was left alone. It resets when that app restarts.'
$script:RooIndustriesGovernorReadbackFailed = 'Windows couldn''t read this setting back after Restore put it back, so it can''t tell whether the value now is still from Background limits. It was left alone. It resets when that app restarts.'
$script:RooIndustriesGovernorNotKept = 'Windows didn''t keep the value Restore put back, so it can''t tell whether the value now is still from Background limits. It was left alone. It resets when that app restarts.'
$script:RooIndustriesGovernorRecordChanged = 'The saved record for this setting changed while Restore was working, so it was left alone. Try Restore again.'
$script:RooIndustriesGovernorSaveFailed = 'Background limits couldn''t save its record for this setting, so Restore stopped there. Try Restore again.'
$script:RooIndustriesGovernorNewerRunHolds = 'A newer Background limits run still holds this setting. Restore that run first.'
$script:RooIndustriesGovernorUnreadableRunHolds = 'A newer Background limits run whose saved files couldn''t be read may have changed this setting, so it was left alone. It resets when that app restarts.'
$script:RooIndustriesGovernorUnreadableRun = 'Its saved files couldn''t be read, so Restore leaves alone every setting it may have changed. They go back to normal when those apps restart.'

$script:RooIndustriesGovernorRestorePlan = @(
    @('priorityClass', 'originalPriorityClass', 'restorePriority', 'Restore original process priority after governor restraint.'),
    @('affinityMask', 'originalAffinityMask', 'restoreAffinity', 'Restore original CPU affinity after governor restraint.'),
    @('ioPriority', 'originalIoPriority', 'restoreIoPriority', 'Restore original I/O priority after governor restraint.'),
    @('memoryPriority', 'originalMemoryPriority', 'restoreMemoryPriority', 'Restore original memory priority after governor restraint.'),
    @('gpuPriority', 'originalGpuPriority', 'restoreGpuPriority', 'Restore original GPU scheduling priority after governor restraint.'))

# Background limits ownership. Each control a run lowered is in one state, kept in its record in backup.json:
#   owned          the lowered value may still be the run's, and only this run may put it back
#   restoreIntent  a write putting it back may have happened (saved before that write)
#   released       the run let go of it: it was put back, left as another program set it, or found at its original
# Every path asks Get-RooIndustriesGovernorControlStep what it may do, and every state change is saved before
# the action it guards. A failed save undoes the change in memory and stops before anything is written.

function Get-RooIndustriesGovernorRestorePlanRow {
    param([string]$Control)
    foreach ($plan in $script:RooIndustriesGovernorRestorePlan) {
        if ($plan[0] -ceq $Control) { return ,$plan }
    }
    return $null
}

function Get-RooIndustriesGovernorRecordedControls {
    param($Snapshot)
    if ($null -eq $Snapshot) { return @() }
    if ($null -ne $Snapshot.PSObject.Properties['appliedControls']) { return @(Get-RooIndustriesPropertyArray $Snapshot 'appliedControls') }
    return @(Get-RooIndustriesPropertyArray $Snapshot 'controlChanges' | Where-Object { (Get-RooIndustriesPropertyValue $_ 'outcome' '') -ne 'failed' })
}

function Get-RooIndustriesGovernorControlRecord {
    param($Snapshot,[string]$Control)
    $records = @(Get-RooIndustriesGovernorRecordedControls $Snapshot | Where-Object {
        [string](Get-RooIndustriesPropertyValue $_ 'control' '') -ceq $Control -and -not [bool](Get-RooIndustriesPropertyValue $_ 'blocked' $false)
    })
    if ($records.Count -ne 1) { return $null }
    return $records[0]
}

function Get-RooIndustriesGovernorControlOwnership {
    param($Record)
    if ($null -eq $Record) { return 'none' }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-RooIndustriesPropertyValue $Record 'restoredAtUtc' ''))) { return 'released' }
    if ($null -ne (Get-RooIndustriesPropertyValue $Record 'restoreIntent' $null)) { return 'restoreIntent' }
    return 'owned'
}

function Save-RooIndustriesGovernorControlOwnership {
    param($Backup,[string]$BackupPath,$Record,[string]$State,[object]$Intent = $null,[string]$Because = '')
    $before = foreach ($name in 'restoreIntent', 'restoredAtUtc', 'releasedBecause') {
        [pscustomobject]@{ name = $name; present = $null -ne $Record.PSObject.Properties[$name]; value = Get-RooIndustriesPropertyValue $Record $name $null }
    }
    switch ($State) {
        'owned' {
            $Record.PSObject.Properties.Remove('restoreIntent')
        }
        'restoreIntent' {
            $Record | Add-Member -NotePropertyName restoreIntent -NotePropertyValue $Intent -Force
        }
        'released' {
            $Record.PSObject.Properties.Remove('restoreIntent')
            $Record | Add-Member -NotePropertyName restoredAtUtc -NotePropertyValue (Get-RooIndustriesUtcStamp) -Force
            $Record | Add-Member -NotePropertyName releasedBecause -NotePropertyValue $Because -Force
        }
        default { throw "Unknown Background limits ownership state '$State'." }
    }
    try {
        Write-RooIndustriesProcessGovernorJsonFile $Backup $BackupPath
    } catch {
        foreach ($field in $before) {
            $Record.PSObject.Properties.Remove($field.name)
            if ($field.present) { $Record | Add-Member -NotePropertyName $field.name -NotePropertyValue $field.value }
        }
        throw [IO.IOException]::new($script:RooIndustriesGovernorSaveFailed, $_.Exception)
    }
}

function Get-RooIndustriesGovernorSnapshotOriginal {
    param([object]$Snapshot,[object[]]$Plan)
    $original = Get-RooIndustriesPropertyValue $Snapshot $Plan[1] $null
    if ([string]::IsNullOrWhiteSpace([string]$original)) { return $null }
    $allowed = switch ($Plan[0]) {
        'priorityClass' { Test-RooIndustriesPriorityAllowed ([string]$original) -Restoring }
        'affinityMask' { Test-RooIndustriesAffinityMaskAllowed $original }
        'ioPriority' { Test-RooIndustriesIoPriorityAllowed ([string]$original) -Restoring }
        'memoryPriority' { Test-RooIndustriesMemoryPriorityAllowed ([string]$original) }
        'gpuPriority' { Test-RooIndustriesGpuPriorityAllowed ([string]$original) }
    }
    if (-not $allowed) { return $null }
    if ($Plan[0] -eq 'affinityMask') { return [int64]$original }
    return $original
}

# Whether a newer run owns or may own this control of the app instance the snapshot names. A newer run whose
# backup can't be read may own every setting of each app its session names. A newer run whose session can't be
# read could have lowered any app, so no setting may be let go of while it stays unreadable; a value that reads
# exactly as this run left it is still this run's to put back.
function Get-RooIndustriesGovernorNewerClaim {
    param([object[]]$NewerRuns,$Snapshot,[string]$Control)
    $processId = [string](Get-RooIndustriesPropertyValue $Snapshot 'processId' 0)
    $startTime = [string](Get-RooIndustriesPropertyValue $Snapshot 'processStartTimeUtc' '')
    $claim = $null
    foreach ($run in @($NewerRuns)) {
        if ($null -ne $run.error) {
            if ($null -eq $run.session) {
                $claim = [pscustomobject]@{ blocksWrite = $false; holds = $false; reason = $script:RooIndustriesGovernorUnreadableRunHolds }
            } elseif (@(Get-RooIndustriesProcessGovernorSessionProcessIds $run.session) -contains $processId) {
                return [pscustomobject]@{ blocksWrite = $true; holds = $false; reason = $script:RooIndustriesGovernorUnreadableRunHolds }
            }
            continue
        }
        foreach ($snapshot in @(Get-RooIndustriesProcessGovernorLatestSnapshots $run.backup)) {
            if ([string](Get-RooIndustriesPropertyValue $snapshot 'processId' 0) -ne $processId -or [string](Get-RooIndustriesPropertyValue $snapshot 'processStartTimeUtc' '') -ne $startTime) { continue }
            if ((Get-RooIndustriesGovernorControlOwnership (Get-RooIndustriesGovernorControlRecord $snapshot $Control)) -in 'owned', 'restoreIntent') {
                return [pscustomobject]@{ blocksWrite = $true; holds = $true; reason = $script:RooIndustriesGovernorNewerRunHolds }
            }
        }
    }
    return $claim
}

# The one decision for a control: what this run may do with it now. Kinds:
#   restore  owned, reads exactly as the run left it, and nothing newer claims it
#   release  let go: back at its original (because restored or alreadyOriginal) or another program's value (leftAsSet)
#   keep     left alone with a reason; holds says whether Restore can still act on it (status offers Restore)
# Returns $null when the run doesn't hold the control.
function Get-RooIndustriesGovernorControlStep {
    param($Snapshot,[string]$Control,[object]$Current,[object[]]$NewerRuns,[System.Diagnostics.Process]$Process = $null)
    $plan = Get-RooIndustriesGovernorRestorePlanRow $Control
    $record = Get-RooIndustriesGovernorControlRecord $Snapshot $Control
    $ownership = Get-RooIndustriesGovernorControlOwnership $record
    if ($ownership -notin 'owned', 'restoreIntent') { return $null }
    if (Test-RooIndustriesSnapshotReleased $Snapshot $Control 'Background limits') { return $null }
    $original = Get-RooIndustriesGovernorSnapshotOriginal $Snapshot $plan
    if ($null -eq $original) { return $null }
    $left = Get-RooIndustriesPropertyValue $record 'proposedValue' $null
    $step = [pscustomobject]@{
        control = $Control
        kind = 'keep'
        because = $null
        reason = $null
        holds = $false
        currentValue = $Current
        originalValue = $original
        appliedValue = $left
        record = $record
    }
    if ([string]::IsNullOrWhiteSpace([string]$Current)) {
        $step.reason = $script:RooIndustriesGovernorControlUnreadable
        $step.holds = $true
        return $step
    }
    $claim = Get-RooIndustriesGovernorNewerClaim $NewerRuns $Snapshot $Control
    if ($null -eq $claim -and $null -ne $Process) {
        $owner = Get-RooIndustriesRestoreControlOwnershipReason $Process $Control
        if (-not [string]::IsNullOrWhiteSpace($owner)) { $claim = [pscustomobject]@{ blocksWrite = $true; holds = $true; reason = $owner } }
    }
    $intent = $ownership -eq 'restoreIntent'
    if (Test-RooIndustriesControlValueEqual $Control $Current $original) {
        if ($intent -and ($null -eq $claim -or -not $claim.blocksWrite)) {
            $step.kind = 'release'
            $step.because = 'restored'
        } elseif ($null -eq $claim) {
            $step.kind = 'release'
            $step.because = 'alreadyOriginal'
        } else {
            $step.reason = $claim.reason
            $step.holds = $claim.holds
        }
        return $step
    }
    if (Test-RooIndustriesControlValueEqual $Control $Current $left) {
        if ($intent) {
            # An earlier restore may have written this control before it stopped. The lowered value it reads
            # now could be another program's, so it is never overwritten.
            $step.reason = $script:RooIndustriesGovernorRestoreInterrupted
        } elseif ($null -ne $claim -and $claim.blocksWrite) {
            $step.reason = $claim.reason
            $step.holds = $claim.holds
        } else {
            $step.kind = 'restore'
            $step.holds = $true
        }
        return $step
    }
    if ($null -ne $claim) {
        $step.reason = $claim.reason
        $step.holds = $claim.holds
        return $step
    }
    $step.kind = 'release'
    $step.because = 'leftAsSet'
    return $step
}

function Get-RooIndustriesGovernorSnapshotSteps {
    param($Snapshot,[object]$CurrentState,[object[]]$NewerRuns,[System.Diagnostics.Process]$Process = $null)
    foreach ($plan in $script:RooIndustriesGovernorRestorePlan) {
        $step = Get-RooIndustriesGovernorControlStep $Snapshot $plan[0] (Get-RooIndustriesControlStateValue $CurrentState $plan[0]) $NewerRuns $Process
        if ($null -ne $step) { $step }
    }
}

# Restore's preview of one app: the steps it would take now, as control changes. A control back at its
# original isn't listed; one another program changed is listed as kept.
function Get-RooIndustriesGovernorRestoreChanges {
    param([object]$Snapshot,[object]$CurrentState,[object[]]$NewerRuns)
    foreach ($step in @(Get-RooIndustriesGovernorSnapshotSteps $Snapshot $CurrentState $NewerRuns)) {
        $plan = Get-RooIndustriesGovernorRestorePlanRow $step.control
        if ($step.kind -eq 'restore') {
            New-RooIndustriesControlChange $step.control $step.currentValue $step.originalValue $plan[2] $plan[3]
        } elseif ($step.kind -eq 'keep') {
            New-RooIndustriesControlChange $step.control $step.currentValue $step.originalValue $plan[2] $plan[3] $true $step.reason
        } elseif ($step.because -eq 'leftAsSet') {
            $change = New-RooIndustriesControlChange $step.control $step.currentValue $step.originalValue $plan[2] $plan[3] $true $script:RooIndustriesChangedExternally
            $change | Add-Member -NotePropertyName appliedValue -NotePropertyValue $step.appliedValue -Force
            $change
        }
    }
}

function Find-RooIndustriesGovernorSavedSnapshot {
    param($Backup,$Snapshot)
    foreach ($saved in @(Get-RooIndustriesPropertyArray $Backup 'snapshots')) {
        $same = $true
        foreach ($field in 'processId', 'processStartTimeUtc', 'capturedAtUtc') {
            if ([string](Get-RooIndustriesPropertyValue $saved $field '') -cne [string](Get-RooIndustriesPropertyValue $Snapshot $field '')) { $same = $false }
        }
        if ($same) { return $saved }
    }
    return $null
}

# Takes the one step a control allows now, under the run lock, from the record on disk and a fresh read of the
# value. A write needs the record to say owned on disk, the value to read exactly as the run left it, and no
# newer run owning or possibly owning it. Returns the step taken (kind restored after a write), or $null.
function Invoke-RooIndustriesGovernorControlStep {
    param($Backup,[string]$BackupPath,$Snapshot,[string]$Control,[System.Diagnostics.Process]$Process,[object[]]$NewerRuns,[switch]$SettleOnly)
    $record = Get-RooIndustriesGovernorControlRecord $Snapshot $Control
    $ownership = Get-RooIndustriesGovernorControlOwnership $record
    if ($ownership -notin 'owned', 'restoreIntent') { return $null }
    $saved = Find-RooIndustriesGovernorSavedSnapshot (Read-RooIndustriesProcessGovernorBackup $BackupPath) $Snapshot
    if ((Get-RooIndustriesGovernorControlOwnership (Get-RooIndustriesGovernorControlRecord $saved $Control)) -cne $ownership) {
        $plan = Get-RooIndustriesGovernorRestorePlanRow $Control
        return [pscustomobject]@{ control = $Control; kind = 'keep'; because = $null; reason = $script:RooIndustriesGovernorRecordChanged; holds = $true; currentValue = $null; originalValue = Get-RooIndustriesGovernorSnapshotOriginal $Snapshot $plan; appliedValue = Get-RooIndustriesPropertyValue $record 'proposedValue' $null; record = $record }
    }
    $current = $null
    try { $current = Get-RooIndustriesProcessControlReadback $Process $Control } catch { $current = $null }
    $step = Get-RooIndustriesGovernorControlStep $Snapshot $Control $current $NewerRuns $Process
    if ($null -eq $step -or $step.kind -eq 'keep') { return $step }
    if ($step.kind -eq 'release') {
        Save-RooIndustriesGovernorControlOwnership $Backup $BackupPath $record 'released' -Because $step.because
        return $step
    }
    if ($SettleOnly) { return $null }
    $intent = [pscustomobject]@{ fromValue = $current; toValue = $step.originalValue; startedAtUtc = Get-RooIndustriesUtcStamp }
    Save-RooIndustriesGovernorControlOwnership $Backup $BackupPath $record 'restoreIntent' -Intent $intent
    try {
        Set-RooIndustriesProcessControlValue $Process $Control $step.originalValue -Restoring
    } catch {
        # Windows refused the write, so nothing changed and the lowered value is still the run's.
        $step.kind = 'keep'
        $step.reason = $_.Exception.Message
        Save-RooIndustriesGovernorControlOwnership $Backup $BackupPath $record 'owned'
        return $step
    }
    $after = $null
    try { $after = Get-RooIndustriesProcessControlReadback $Process $Control } catch { $after = $null }
    $step.kind = 'keep'
    $step.holds = $false
    if ([string]::IsNullOrWhiteSpace([string]$after)) {
        # The write may have happened, so the intent stays and a later lowered value is never taken as the run's.
        $step.reason = $script:RooIndustriesGovernorReadbackFailed
        return $step
    }
    if (Test-RooIndustriesControlValueEqual $Control $after $step.originalValue) {
        Save-RooIndustriesGovernorControlOwnership $Backup $BackupPath $record 'released' -Because 'restored'
        $step.kind = 'restored'
        return $step
    }
    if (Test-RooIndustriesControlValueEqual $Control $after $current) {
        $step.reason = $script:RooIndustriesGovernorNotKept
        return $step
    }
    $step.currentValue = $after
    Save-RooIndustriesGovernorControlOwnership $Backup $BackupPath $record 'released' -Because 'leftAsSet'
    $step.kind = 'release'
    $step.because = 'leftAsSet'
    return $step
}

# Every step one app instance allows now, one control at a time. A failed save throws and stops here.
function Invoke-RooIndustriesGovernorSnapshotSteps {
    param($Backup,[string]$BackupPath,$Snapshot,[System.Diagnostics.Process]$Process,[object[]]$NewerRuns,[switch]$SettleOnly)
    foreach ($plan in $script:RooIndustriesGovernorRestorePlan) {
        $step = Invoke-RooIndustriesGovernorControlStep $Backup $BackupPath $Snapshot $plan[0] $Process $NewerRuns -SettleOnly:$SettleOnly
        if ($null -ne $step) { $step }
    }
}

function New-RooIndustriesGovernorKeptItem {
    param($Snapshot,$Step)
    return New-RooIndustriesLeftAsSetItem $Snapshot ([pscustomobject]@{ control = $Step.control; currentValue = $Step.currentValue; appliedValue = $Step.appliedValue; originalValue = $Step.originalValue })
}

function Get-RooIndustriesProcessGovernorLiveIdentity {
    param([object]$Entry)
    $processId = [int](Get-RooIndustriesPropertyValue $Entry 'processId' 0)
    $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $live) {
        return [pscustomobject]@{
            exists = $false
            matches = $false
            instanceEnded = $true
            process = $null
            currentPath = $null
            reason = 'Process is no longer running.'
        }
    }
    $expectedName = [string](Get-RooIndustriesPropertyValue $Entry 'processName' '')
    $nameMatches = Test-RooIndustriesProcessNameEquals $live.ProcessName $expectedName
    $currentPath = $null
    try { $held = $live.Handle; $currentPath = $live.Path } catch {
        $gone = $false; try { $gone = $live.HasExited } catch { $gone = $null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue) }
        $replaced = -not $nameMatches
        $savedStart = [string](Get-RooIndustriesPropertyValue $Entry 'processStartTimeUtc' (Get-RooIndustriesPropertyValue $Entry 'startTimeUtc' ''))
        if (-not $replaced -and -not [string]::IsNullOrWhiteSpace($savedStart)) {
            $liveStart = Get-RooIndustriesProcessStartTimeUtc $live
            $replaced = -not [string]::IsNullOrWhiteSpace([string]$liveStart) -and -not (Test-RooIndustriesProcessStartTime $savedStart $liveStart)
        }
        return [pscustomobject]@{ exists = $true; matches = $false; instanceEnded = ($gone -or $replaced); process = $null; currentPath = $null; reason = 'Live process identity could not be verified.' }
    }
    $expectedPath = Get-RooIndustriesPropertyValue $Entry 'executablePath' $null
    $pathMatches = $true
    $pathReason = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$expectedPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$currentPath)) {
            $pathMatches = $false
            $pathReason = 'Live process path could not be verified.'
        } else {
            $pathMatches = ([string]$expectedPath -eq [string]$currentPath)
            if (-not $pathMatches) { $pathReason = 'Live process path does not match the session entry.' }
        }
    }
    $controlState = Get-RooIndustriesProcessControlState $processId $null $live -ReadGpu:(Test-RooIndustriesEntryHasGpuControl $Entry)
    $expectedStartTimeUtc = [string](Get-RooIndustriesPropertyValue $Entry 'processStartTimeUtc' (Get-RooIndustriesPropertyValue $Entry 'startTimeUtc' ''))
    $currentStartTimeUtc = [string](Get-RooIndustriesPropertyValue $controlState 'startTimeUtc' '')
    $startTimeMatches = $true
    $startTimeReason = $null
    if (-not [string]::IsNullOrWhiteSpace($expectedStartTimeUtc)) {
        if ([string]::IsNullOrWhiteSpace($currentStartTimeUtc)) {
            $startTimeMatches = $false
            $startTimeReason = 'Live process start time could not be verified.'
        } elseif (-not (Test-RooIndustriesProcessStartTime $expectedStartTimeUtc $currentStartTimeUtc)) {
            $startTimeMatches = $false
            $startTimeReason = 'Live process start time does not match the session entry.'
        }
    }
    $matches = ($nameMatches -and $pathMatches -and $startTimeMatches)
    $knownPathMismatch = -not $pathMatches -and -not [string]::IsNullOrWhiteSpace([string]$currentPath)
    $exitedNow = -not $controlState.exists
    if (-not $exitedNow) { try { $exitedNow = $live.HasExited } catch { $exitedNow = $false } }
    $savedTime = [datetime]::MinValue
    $currentTime = [datetime]::MinValue
    $knownStartMismatch = -not $startTimeMatches -and [datetime]::TryParse($expectedStartTimeUtc, [ref]$savedTime) -and [datetime]::TryParse($currentStartTimeUtc, [ref]$currentTime)
    $reason = if ($matches) { $null } elseif (-not $nameMatches) { 'Live process name does not match the session entry.' } elseif (-not $pathMatches) { $pathReason } else { $startTimeReason }
    return [pscustomobject]@{
        exists = $true
        matches = $matches
        instanceEnded = ($exitedNow -or -not $nameMatches -or $knownPathMismatch -or $knownStartMismatch)
        process = $live
        currentControlState = $controlState
        processStartTimeUtc = $controlState.startTimeUtc
        currentPath = $currentPath
        reason = $reason
    }
}

function Get-RooIndustriesProcessGovernorLatestSnapshots {
    param([object]$Backup)
    $seen = @{}
    $snapshots = @(Get-RooIndustriesPropertyArray $Backup 'snapshots')
    for ($index = $snapshots.Count - 1; $index -ge 0; $index--) {
        $snapshot = $snapshots[$index]
        $identityKey = ([string](Get-RooIndustriesPropertyValue $snapshot 'processId' 0)) + '|' + ([string](Get-RooIndustriesPropertyValue $snapshot 'processStartTimeUtc' '')) + '|' + ([string](Get-RooIndustriesPropertyValue $snapshot 'executablePath' ''))
        if ($seen.ContainsKey($identityKey)) { continue }
        $seen[$identityKey] = $true
        $snapshot
    }
}

function Get-RooIndustriesProcessGovernorSnapshotIdentity {
    param([object]$Snapshot)
    return Get-RooIndustriesProcessGovernorLiveIdentity ([pscustomobject]@{
        processId = Get-RooIndustriesPropertyValue $Snapshot 'processId' 0
        processName = Get-RooIndustriesPropertyValue $Snapshot 'processName' ''
        executablePath = Get-RooIndustriesPropertyValue $Snapshot 'executablePath' $null
        processStartTimeUtc = Get-RooIndustriesPropertyValue $Snapshot 'processStartTimeUtc' $null
        controlChanges = @(Get-RooIndustriesPreviewControlChanges $Snapshot)
    })
}

function Get-RooIndustriesProcessGovernorSessionProcessIds {
    param([object]$Session)
    if ($null -eq $Session) { return }
    foreach ($field in 'activeRestraints', 'changedItems', 'leftAsSetItems') {
        foreach ($item in @(Get-RooIndustriesPropertyArray $Session $field)) {
            $processId = [string](Get-RooIndustriesPropertyValue $item 'processId' '')
            if (-not [string]::IsNullOrWhiteSpace($processId)) { $processId }
        }
    }
}

function Read-RooIndustriesProcessGovernorSharedText {
    param([string]$Path)
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    for ($attempt = 0; ; $attempt++) {
        try {
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
                return $reader.ReadToEnd()
            } finally { $stream.Dispose() }
        } catch {
            $failure = $_.Exception
            while ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
            $transient = $failure -is [UnauthorizedAccessException] -or $failure -is [IO.FileNotFoundException] -or ($failure -is [IO.IOException] -and ($failure.HResult -band 0xffff) -eq 32)
            if ($attempt -ge 40 -or -not $transient) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Read-RooIndustriesProcessGovernorJson {
    param([string]$Path)
    $value = (Read-RooIndustriesProcessGovernorSharedText $Path) | ConvertFrom-Json
    if ($null -eq $value -or $value -isnot [pscustomobject]) { throw "The saved Background limits file $([IO.Path]::GetFileName($Path)) is not a JSON object." }
    return $value
}

function Test-RooIndustriesGovernorArrayField {
    param($Object,[string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    return $null -ne $property -and $property.Value -is [array]
}

function Test-RooIndustriesGovernorJsonObject {
    param($Value)
    return $Value -is [Management.Automation.PSCustomObject]
}

# A saved file with a required field missing or of the wrong type can't be read. It is never taken as a run
# with nothing to restore.
function Read-RooIndustriesProcessGovernorSession {
    param([string]$Path)
    $session = Read-RooIndustriesProcessGovernorJson $Path
    $restorable = Get-RooIndustriesPropertyValue $session 'restorable' $null
    $valid = -not [string]::IsNullOrWhiteSpace([string](Get-RooIndustriesPropertyValue $session 'sessionId' '')) -and $restorable -is [bool]
    if ($valid -and $restorable) {
        $backupPath = Get-RooIndustriesPropertyValue $session 'backupManifestPath' $null
        $valid = $backupPath -is [string] -and -not [string]::IsNullOrWhiteSpace($backupPath)
    }
    foreach ($field in 'activeRestraints', 'changedItems', 'leftAsSetItems') {
        $property = $session.PSObject.Properties[$field]
        if ($null -ne $property -and $null -ne $property.Value -and $property.Value -isnot [array]) { $valid = $false }
    }
    if (-not $valid) { throw [IO.InvalidDataException]::new("The saved Background limits file $([IO.Path]::GetFileName($Path)) is incomplete or damaged.") }
    return $session
}

function Read-RooIndustriesProcessGovernorBackup {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw [IO.FileNotFoundException]::new("The saved Background limits file $([IO.Path]::GetFileName($Path)) is missing.") }
    $backup = Read-RooIndustriesProcessGovernorJson $Path
    $valid = [string](Get-RooIndustriesPropertyValue $backup 'actionId' '') -ceq 'performance.governor.startSession' -and
        (Get-RooIndustriesPropertyValue $backup 'dryRun' $null) -is [bool] -and
        -not [string]::IsNullOrWhiteSpace([string](Get-RooIndustriesPropertyValue $backup 'sessionId' '')) -and
        -not [string]::IsNullOrWhiteSpace([string](Get-RooIndustriesPropertyValue $backup 'profileId' '')) -and
        (Test-RooIndustriesGovernorArrayField $backup 'snapshots')
    if ($valid) {
        foreach ($snapshot in $backup.snapshots) {
            $processId = Get-RooIndustriesPropertyValue $snapshot 'processId' $null
            # A snapshot from an older build may list no controls; one that lists them must list them whole.
            $records = if ($null -ne $snapshot.PSObject.Properties['appliedControls']) { 'appliedControls' } else { 'controlChanges' }
            if (-not (Test-RooIndustriesGovernorJsonObject $snapshot) -or ($processId -isnot [int] -and $processId -isnot [long]) -or
                [string]::IsNullOrWhiteSpace([string](Get-RooIndustriesPropertyValue $snapshot 'processName' '')) -or
                ($null -ne $snapshot.PSObject.Properties[$records] -and -not (Test-RooIndustriesGovernorArrayField $snapshot $records))) {
                $valid = $false
                break
            }
            foreach ($record in @(Get-RooIndustriesPropertyArray $snapshot $records)) {
                if (-not (Test-RooIndustriesGovernorJsonObject $record) -or [string]::IsNullOrWhiteSpace([string](Get-RooIndustriesPropertyValue $record 'control' ''))) { $valid = $false }
            }
            if (-not $valid) { break }
        }
    }
    if (-not $valid) { throw [IO.InvalidDataException]::new("The saved Background limits file $([IO.Path]::GetFileName($Path)) is incomplete or damaged.") }
    return $backup
}

# Every confirmed run still marked restorable, newest first. A run whose files can't be read comes back with
# its error (and its session, when only the backup failed) instead of being skipped.
function Get-RooIndustriesProcessGovernorRestorableSessions {
    param([string]$ResolvedGovernorStateRoot,[Nullable[datetime]]$CreatedAfterUtc = $null)
    if (-not (Test-Path -LiteralPath $ResolvedGovernorStateRoot)) { return }
    foreach ($directory in @(Get-ChildItem -LiteralPath $ResolvedGovernorStateRoot -Directory | Where-Object { $null -eq $CreatedAfterUtc -or $_.CreationTimeUtc -gt $CreatedAfterUtc } | Sort-Object CreationTimeUtc -Descending)) {
        $sessionPath = Join-Path $directory.FullName 'session.json'
        if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) { continue }
        $run = [pscustomobject]@{ sessionId = $directory.Name; sessionPath = $sessionPath; backupPath = $null; createdAtUtc = $directory.CreationTimeUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture); session = $null; backup = $null; error = $null }
        try {
            $session = Read-RooIndustriesProcessGovernorSession $sessionPath
            $dryRun = Get-RooIndustriesPropertyValue $session 'dryRun' $false
            if (-not $session.restorable -or ($dryRun -is [bool] -and $dryRun)) { continue }
            $run.session = $session
            $run.backupPath = Resolve-RooIndustriesPath $session.backupManifestPath $session.backupManifestPath
            $run.backup = Read-RooIndustriesProcessGovernorBackup $run.backupPath
        } catch {
            $run.error = $_.Exception.Message
        }
        $run
    }
}

# Whether Restore can still act on this run: it holds a value it can put back, or one it can't read or that a
# newer run or another saved change holds first. Settings it only waits to let go of don't count.
function Test-RooIndustriesProcessGovernorRunHolds {
    param([object]$Backup,[object[]]$NewerRuns)
    foreach ($snapshot in @(Get-RooIndustriesProcessGovernorLatestSnapshots $Backup)) {
        $candidate = Get-RooIndustriesProcessGovernorSnapshotIdentity $snapshot
        if (-not $candidate.exists) { continue }
        if (-not $candidate.matches) {
            if (-not $candidate.instanceEnded) { return $true }
            continue
        }
        foreach ($step in @(Get-RooIndustriesGovernorSnapshotSteps $snapshot $candidate.currentControlState $NewerRuns)) {
            if ($step.holds) { return $true }
        }
    }
    return $false
}

function Get-RooIndustriesProcessGovernorNewerRuns {
    param([object[]]$Runs,[int]$Index)
    if ($Index -le 0) { return @() }
    return @($Runs[0..($Index - 1)])
}

# The newest readable run that still holds an app. A run whose files can't be read is never picked:
# Restore can't act on it, so it would stop every older run from being restored.
function Get-RooIndustriesProcessGovernorHeldSession {
    param([string]$ResolvedGovernorStateRoot)
    $runs = @(Get-RooIndustriesProcessGovernorRestorableSessions $ResolvedGovernorStateRoot)
    for ($index = 0; $index -lt $runs.Count; $index++) {
        if ($null -ne $runs[$index].error) { continue }
        $holds = $true
        try { $holds = Test-RooIndustriesProcessGovernorRunHolds $runs[$index].backup (Get-RooIndustriesProcessGovernorNewerRuns $runs $index) } catch { $holds = $true }
        if ($holds) { return $runs[$index].sessionPath }
    }
    return $null
}

function Get-RooIndustriesProcessGovernorUnreadableSessions {
    param([string]$ResolvedGovernorStateRoot)
    foreach ($run in @(Get-RooIndustriesProcessGovernorRestorableSessions $ResolvedGovernorStateRoot | Where-Object { $null -ne $_.error })) {
        [pscustomobject]@{
            sessionId = $run.sessionId
            sessionPath = $run.sessionPath
            createdAtUtc = $run.createdAtUtc
            reason = $script:RooIndustriesGovernorUnreadableRun
            error = $run.error
        }
    }
}

# A confirmed Restore first lets go of every setting each other saved run no longer holds, newest run first,
# so a run the walk passes over never takes a later value as its own. Nothing is written to any app here.
# Returns the settings it found another program had set.
function Invoke-RooIndustriesProcessGovernorSettleRuns {
    param([string]$ResolvedGovernorStateRoot,[string]$ExceptBackupPath)
    $runs = @(Get-RooIndustriesProcessGovernorRestorableSessions $ResolvedGovernorStateRoot)
    for ($index = 0; $index -lt $runs.Count; $index++) {
        $run = $runs[$index]
        if ($null -ne $run.error -or [string]::Equals($run.backupPath, $ExceptBackupPath, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $newer = Get-RooIndustriesProcessGovernorNewerRuns $runs $index
        foreach ($snapshot in @(Get-RooIndustriesProcessGovernorLatestSnapshots $run.backup)) {
            $candidate = Get-RooIndustriesProcessGovernorSnapshotIdentity $snapshot
            if (-not ($candidate.exists -and $candidate.matches)) { continue }
            try {
                foreach ($step in @(Invoke-RooIndustriesGovernorSnapshotSteps $run.backup $run.backupPath $snapshot $candidate.process $newer -SettleOnly)) {
                    if ($step.kind -eq 'release' -and $step.because -eq 'leftAsSet') { New-RooIndustriesGovernorKeptItem $snapshot $step }
                }
            } catch {
                # A run whose release couldn't be saved keeps owning the setting, which only makes older runs wait.
            }
        }
    }
}

function Close-RooIndustriesProcessGovernorEndedSessions {
    param([string]$ResolvedGovernorStateRoot)
    foreach ($run in @(Get-RooIndustriesProcessGovernorRestorableSessions $ResolvedGovernorStateRoot)) {
        if ($null -ne $run.error) { continue }
        try { Close-RooIndustriesProcessGovernorEndedSession $run } catch { }
    }
}

function Close-RooIndustriesProcessGovernorEndedSession {
    param([object]$Run)
    foreach ($snapshot in @(Get-RooIndustriesProcessGovernorLatestSnapshots $Run.backup)) {
        $candidate = Get-RooIndustriesProcessGovernorSnapshotIdentity $snapshot
        if ($candidate.exists -and ($candidate.matches -or -not $candidate.instanceEnded)) { return }
    }
    $session = Read-RooIndustriesProcessGovernorSession $Run.sessionPath
    if (-not [bool](Get-RooIndustriesPropertyValue $session 'restorable' $false)) { return }
    $session.restorable = $false
    foreach ($field in 'sessionStatus', 'status') { if ([string](Get-RooIndustriesPropertyValue $session $field '') -eq 'running') { $session.$field = 'completed' } }
    if ($null -eq (Get-RooIndustriesPropertyValue $session 'completedAtUtc' $null)) { $session.completedAtUtc = Get-RooIndustriesUtcStamp }
    Write-RooIndustriesProcessGovernorJsonFile $session $Run.sessionPath
    Add-RooIndustriesProcessGovernorLogFileEntry (Split-Path $Run.sessionPath -Parent) (New-RooIndustriesLog 'Every app this run lowered has closed, so nothing remains to restore.')
}

function Test-RooIndustriesProcessGovernorSessionOverdue {
    param([object]$Session)
    $started = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string](Get-RooIndustriesPropertyValue $Session 'startedAtUtc' ''), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$started)) { return $false }
    $limit = [double](Get-RooIndustriesPropertyValue $Session 'maxDurationSeconds' 0)
    if ($limit -le 0) { return $false }
    return [DateTime]::UtcNow -gt $started.ToUniversalTime().AddSeconds($limit + 300)
}

function New-RooIndustriesProcessGovernorBackupMetadata {
    param(
        [object]$BackupManifest,
        [string]$BackupPath
    )
    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($snap in @(Get-RooIndustriesPropertyArray $BackupManifest 'snapshots')) {
        $snapshots.Add([pscustomobject]@{
            type = 'processGovernorRestraint'
            target = "$([string](Get-RooIndustriesPropertyValue $snap 'processName' ''))`:$([int](Get-RooIndustriesPropertyValue $snap 'processId' 0))"
            originalState = [pscustomobject]@{
                priorityClass = Get-RooIndustriesPropertyValue $snap 'originalPriorityClass' $null
                affinityMask = Get-RooIndustriesPropertyValue $snap 'originalAffinityMask' $null
                ioPriority = Get-RooIndustriesPropertyValue $snap 'originalIoPriority' $null
                memoryPriority = Get-RooIndustriesPropertyValue $snap 'originalMemoryPriority' $null
                gpuPriority = Get-RooIndustriesPropertyValue $snap 'originalGpuPriority' $null
                executablePath = Get-RooIndustriesPropertyValue $snap 'executablePath' $null
            }
        }) | Out-Null
    }
    return [pscustomobject]@{
        backupId = [string](Get-RooIndustriesPropertyValue $BackupManifest 'backupId' '')
        scope = 'process-governor-process-controls'
        createdAtUtc = [string](Get-RooIndustriesPropertyValue $BackupManifest 'createdAtUtc' '')
        location = $BackupPath
        restorePoint = [pscustomobject]@{
            requested = $false
            status = 'not-required-for-process-restraint'
            id = $null
        }
        snapshots = @($snapshots.ToArray())
        rollbackActionId = 'performance.governor.stopSession'
        rollbackSupported = $true
        retentionPolicy = [pscustomobject]@{
            keepLatestCount = 10
            minimumDays = 14
        }
    }
}

function New-RooIndustriesProcessGovernorRuntimeEvidence {
    param(
        [object]$Session = $null,
        [string]$StateRoot = $null,
        [string]$SessionPath = $null,
        [string]$BackupManifestPath = $null
    )

    $resolvedSessionPath = if (-not [string]::IsNullOrWhiteSpace($SessionPath)) { $SessionPath } else { Get-RooIndustriesPropertyValue $Session 'sessionPath' $null }
    $resolvedBackupPath = if (-not [string]::IsNullOrWhiteSpace($BackupManifestPath)) { $BackupManifestPath } else { Get-RooIndustriesPropertyValue $Session 'backupManifestPath' $null }
    $dryRun = [bool](Get-RooIndustriesPropertyValue $Session 'dryRun' $true)
    return [pscustomobject]@{
        runtimeKind = 'native-powershell-process-governor'
        productionRuntimeCapable = $true
        confirmedApplyAvailable = $true
        dryRunWritesState = $false
        confirmedSessionWritesState = $true
        stateBacked = (-not [string]::IsNullOrWhiteSpace([string]$resolvedSessionPath))
        stateRoot = $StateRoot
        sessionPath = $resolvedSessionPath
        backupManifestPath = $resolvedBackupPath
        restoreContractAvailable = (-not [string]::IsNullOrWhiteSpace([string]$resolvedBackupPath)) -or [bool](Get-RooIndustriesPropertyValue $Session 'restorable' $false)
        boundedSession = $true
        externalProcessGovernorDependencyRequired = $false
        processLassoRequired = $false
        processLassoLaunched = $false
        frontendProcessRequired = $false
        frontendProcessLaunched = $false
        realSystemScope = if ($dryRun) { 'preview-only' } else { 'disposable-or-user-confirmed-process-controls' }
        supportedControls = @('priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority-when-available')
        forbiddenUtilityLaunches = @('ProcessLasso','ProcessGovernor.exe-external','Revo','Gaming toggles','AME','NVIDIA Profile Inspector')
    }
}
