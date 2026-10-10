. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$script:RooIndustriesProcessGovernorStateFolderName = 'process-governor-sessions'

function Resolve-RooIndustriesProcessGovernorStateRoot {
    param([string]$StateRoot)
    $defaultStateRoot = Join-Path $PSScriptRoot '..\state'
    $resolvedStateRoot = Resolve-RooIndustriesPath $StateRoot $defaultStateRoot
    return [System.IO.Path]::GetFullPath((Join-Path $resolvedStateRoot $script:RooIndustriesProcessGovernorStateFolderName))
}

function New-RooIndustriesProcessGovernorSessionId {
    param([string]$ProfileId)
    $safeProfileId = if ([string]::IsNullOrWhiteSpace($ProfileId)) { 'profile' } else { $ProfileId.ToLowerInvariant() -replace '[^a-z0-9\-]+', '-' }
    return "process-governor-$safeProfileId-$(Get-RooIndustriesFileStamp)"
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
    Write-RooIndustriesOperationJson $Value $Path
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

function Select-RooIndustriesGovernorOwnedRestoreChanges {
    param($Snapshot,[object[]]$Changes)
    $recorded=if($null -ne $Snapshot.PSObject.Properties['appliedControls']){@(Get-RooIndustriesPropertyArray $Snapshot 'appliedControls')}else{@(Get-RooIndustriesPropertyArray $Snapshot 'controlChanges' | Where-Object { (Get-RooIndustriesPropertyValue $_ 'outcome' '') -ne 'failed' })}
    foreach($change in $Changes) {
        $control=[string](Get-RooIndustriesPropertyValue $change 'control' '')
        $owned=@($recorded|Where-Object {[string](Get-RooIndustriesPropertyValue $_ 'control' '') -eq $control -and -not [bool](Get-RooIndustriesPropertyValue $_ 'blocked' $false)})
        if($owned.Count -ne 1){continue}
        if(-not(Test-RooIndustriesControlValueEqual $control (Get-RooIndustriesPropertyValue $change 'currentValue' $null) (Get-RooIndustriesPropertyValue $owned[0] 'proposedValue' $null))) {
            $change.blocked=$true
            $change.blockedReason='The control changed externally; its current value was preserved.'
        }
        $change
    }
}

function Get-RooIndustriesProcessGovernorLiveIdentity {
    param([object]$Entry)
    $processId = [int](Get-RooIndustriesPropertyValue $Entry 'processId' 0)
    $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $live) {
        return [pscustomobject]@{
            exists = $false
            matches = $false
            process = $null
            currentPath = $null
            reason = 'Process is no longer running.'
        }
    }
    $expectedName = [string](Get-RooIndustriesPropertyValue $Entry 'processName' '')
    $nameMatches = Test-RooIndustriesProcessNameEquals $live.ProcessName $expectedName
    $currentPath = $null
    try { $held = $live.Handle; $currentPath = $live.Path } catch { return [pscustomobject]@{ exists = $true; matches = $false; process = $null; currentPath = $null; reason = 'Live process identity could not be verified.' } }
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
    $reason = if ($matches) { $null } elseif (-not $nameMatches) { 'Live process name does not match the session entry.' } elseif (-not $pathMatches) { $pathReason } else { $startTimeReason }
    return [pscustomobject]@{
        exists = $true
        matches = $matches
        process = $live
        currentControlState = $controlState
        processStartTimeUtc = $controlState.startTimeUtc
        currentPath = $currentPath
        reason = $reason
    }
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
        forbiddenUtilityLaunches = @('ProcessLasso','ProcessGovernor.exe-external','Revo','FSOS','AME','NVIDIA Profile Inspector')
    }
}
