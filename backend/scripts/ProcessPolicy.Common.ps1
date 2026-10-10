. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$script:RooIndustriesProcessPolicyStateFolderName = 'process-policy-sessions'
$script:RooIndustriesProcessPolicyProtectedCategories = @(
    'foregroundGame',
    'captureStreaming',
    'voiceChat',
    'vendorUtility',
    'windowsCore',
    'security',
    'network',
    'audioInput'
)
$script:RooIndustriesProcessPolicyProtectedNames = @(
    'overwatch.exe',
    'valorant-win64-shipping.exe',
    'fortniteclient-win64-shipping.exe',
    'cod.exe',
    'r5apex.exe',
    'obs64.exe',
    'obs32.exe',
    'discord.exe',
    'vgtray.exe',
    'vgc.exe',
    'easyanticheat.exe',
    'easyanticheat_eos.exe',
    'beservice.exe',
    'battleeye.exe',
    'nvdisplay.container.exe',
    'nvidia container.exe',
    'nvcontainer.exe',
    'radeonsoftware.exe',
    'amdow.exe',
    'igfxem.exe',
    'msedgewebview2.exe',
    'microsoftedgeupdate.exe',
    'mousocoreworker.exe',
    'usoclient.exe',
    'tiworker.exe',
    'trustedinstaller.exe',
    'winstore.app.exe',
    'wsappx.exe'
)

function Ensure-RooIndustriesProcessPolicyCommandLineReader {
    if ('RooIndustriesProcessPolicyCommandLineReader' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class RooIndustriesProcessPolicyCommandLineReader {
    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr processHandle, int processInformationClass, ref PROCESS_BASIC_INFORMATION processInformation, int processInformationLength, out int returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr processHandle, IntPtr baseAddress, byte[] buffer, int size, out IntPtr bytesRead);

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_BASIC_INFORMATION {
        public IntPtr Reserved1;
        public IntPtr PebBaseAddress;
        public IntPtr Reserved2_0;
        public IntPtr Reserved2_1;
        public IntPtr UniqueProcessId;
        public IntPtr Reserved3;
    }

    private static IntPtr ReadPointer(IntPtr processHandle, IntPtr address) {
        byte[] buffer = new byte[IntPtr.Size];
        IntPtr bytesRead;
        if (!ReadProcessMemory(processHandle, address, buffer, buffer.Length, out bytesRead)) {
            return IntPtr.Zero;
        }
        return IntPtr.Size == 8 ? (IntPtr)BitConverter.ToInt64(buffer, 0) : (IntPtr)BitConverter.ToInt32(buffer, 0);
    }

    private static ushort ReadUInt16(IntPtr processHandle, IntPtr address) {
        byte[] buffer = new byte[2];
        IntPtr bytesRead;
        if (!ReadProcessMemory(processHandle, address, buffer, buffer.Length, out bytesRead)) {
            return 0;
        }
        return BitConverter.ToUInt16(buffer, 0);
    }

    public static string TryGetCommandLine(int processId) {
        try {
            Process process = Process.GetProcessById(processId);
            PROCESS_BASIC_INFORMATION info = new PROCESS_BASIC_INFORMATION();
            int returnLength;
            int status = NtQueryInformationProcess(process.Handle, 0, ref info, Marshal.SizeOf(typeof(PROCESS_BASIC_INFORMATION)), out returnLength);
            if (status != 0 || info.PebBaseAddress == IntPtr.Zero) {
                return null;
            }

            int processParametersOffset = IntPtr.Size == 8 ? 0x20 : 0x10;
            int commandLineOffset = IntPtr.Size == 8 ? 0x70 : 0x40;
            IntPtr processParameters = ReadPointer(process.Handle, IntPtr.Add(info.PebBaseAddress, processParametersOffset));
            if (processParameters == IntPtr.Zero) {
                return null;
            }

            ushort byteLength = ReadUInt16(process.Handle, IntPtr.Add(processParameters, commandLineOffset));
            IntPtr bufferAddress = ReadPointer(process.Handle, IntPtr.Add(processParameters, commandLineOffset + (IntPtr.Size == 8 ? 8 : 4)));
            if (byteLength == 0 || bufferAddress == IntPtr.Zero) {
                return null;
            }

            byte[] commandLineBytes = new byte[byteLength];
            IntPtr bytesRead;
            if (!ReadProcessMemory(process.Handle, bufferAddress, commandLineBytes, commandLineBytes.Length, out bytesRead)) {
                return null;
            }
            return Encoding.Unicode.GetString(commandLineBytes);
        } catch {
            return null;
        }
    }
}
"@
}

function Get-RooIndustriesProcessPolicyCommandLineFallback {
    param([int]$ProcessId)
    try {
        Ensure-RooIndustriesProcessPolicyCommandLineReader
        return [RooIndustriesProcessPolicyCommandLineReader]::TryGetCommandLine($ProcessId)
    } catch {
        return $null
    }
}

function Resolve-RooIndustriesProcessPolicyStateRoot {
    param([string]$StateRoot)
    $defaultStateRoot = Join-Path $PSScriptRoot '..\state'
    $resolvedStateRoot = Resolve-RooIndustriesPath $StateRoot $defaultStateRoot
    return [System.IO.Path]::GetFullPath((Join-Path $resolvedStateRoot $script:RooIndustriesProcessPolicyStateFolderName))
}

function New-RooIndustriesProcessPolicySessionId {
    param([string]$ProfileId)
    $safeProfileId = if ([string]::IsNullOrWhiteSpace($ProfileId)) { 'profile' } else { $ProfileId.ToLowerInvariant() -replace '[^a-z0-9\-]+', '-' }
    return "process-policy-$safeProfileId-$(Get-RooIndustriesFileStamp)"
}

function Get-RooIndustriesProcessPolicySessionDirectory {
    param(
        [string]$ResolvedPolicyStateRoot,
        [string]$SessionId
    )
    return Join-Path $ResolvedPolicyStateRoot $SessionId
}

function Write-RooIndustriesProcessPolicyJsonFile {
    param(
        [object]$Value,
        [string]$Path
    )
    Ensure-RooIndustriesDirectory (Split-Path $Path -Parent)
    ($Value | ConvertTo-Json -Depth 40) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Add-RooIndustriesProcessPolicyLogFileEntry {
    param(
        [string]$SessionDirectory,
        [object]$Entry
    )
    if ([string]::IsNullOrWhiteSpace($SessionDirectory)) { return }
    Ensure-RooIndustriesDirectory $SessionDirectory
    ($Entry | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath (Join-Path $SessionDirectory 'events.jsonl') -Encoding UTF8
}

function Get-RooIndustriesProcessPolicySessionFileFromPath {
    param([string]$SessionPath)
    if ([string]::IsNullOrWhiteSpace($SessionPath)) { return $null }
    $resolved = Resolve-RooIndustriesPath $SessionPath $SessionPath
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        return Join-Path $resolved 'session.json'
    }
    return $resolved
}

function Get-RooIndustriesProcessPolicyLatestSessionFile {
    param([string]$ResolvedPolicyStateRoot)
    if (-not (Test-Path -LiteralPath $ResolvedPolicyStateRoot)) { return $null }
    $latest = Get-ChildItem -LiteralPath $ResolvedPolicyStateRoot -Filter 'session.json' -Recurse -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { return $null }
    return $latest.FullName
}

function Resolve-RooIndustriesProcessPolicySessionFile {
    param(
        [string]$SessionId,
        [string]$SessionPath,
        [string]$StateRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($SessionPath)) {
        return Get-RooIndustriesProcessPolicySessionFileFromPath $SessionPath
    }
    $resolvedStateRoot = Resolve-RooIndustriesProcessPolicyStateRoot $StateRoot
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return Join-Path (Get-RooIndustriesProcessPolicySessionDirectory $resolvedStateRoot $SessionId) 'session.json'
    }
    return Get-RooIndustriesProcessPolicyLatestSessionFile $resolvedStateRoot
}

function Get-RooIndustriesProcessPolicyProfileRoot {
    param([object]$Profile)
    $policy = Get-RooIndustriesPropertyValue $Profile 'policy' $null
    if ($null -ne $policy) { return $policy }
    return $Profile
}

function Get-RooIndustriesProcessPolicyConfig {
    param(
        [object]$Profile,
        [int]$MaxDurationSecondsOverride = 0,
        [int]$PollIntervalSecondsOverride = 0
    )
    $policy = Get-RooIndustriesProcessPolicyProfileRoot $Profile
    $session = Get-RooIndustriesPropertyValue $policy 'session' $policy
    $maxDuration = if ($MaxDurationSecondsOverride -gt 0) { $MaxDurationSecondsOverride } else { [int](Get-RooIndustriesPropertyValue $session 'maxSessionDurationSeconds' 60) }
    if ($maxDuration -lt 1) { $maxDuration = 1 }
    $poll = if ($PollIntervalSecondsOverride -gt 0) { $PollIntervalSecondsOverride } else { [int](Get-RooIndustriesPropertyValue $session 'pollIntervalSeconds' 1) }
    if ($poll -lt 1) { $poll = 1 }
    return [pscustomobject]@{
        maxSessionDurationSeconds = $maxDuration
        pollIntervalSeconds = $poll
    }
}

function Resolve-RooIndustriesProcessPolicyProtectedCatalog {
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

function Get-RooIndustriesProcessPolicyCategory {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    if (@('overwatch.exe','valorant-win64-shipping.exe','fortniteclient-win64-shipping.exe','cod.exe','r5apex.exe') -contains $n) { return 'foregroundGame' }
    if (@('obs64.exe','obs32.exe','streamlabs desktop.exe') -contains $n) { return 'captureStreaming' }
    if (@('discord.exe','teamspeak.exe','mumble.exe') -contains $n) { return 'voiceChat' }
    if (@('battle.net.exe','steam.exe','epicgameslauncher.exe','riotclientservices.exe','eadesktop.exe','ubisoftconnect.exe') -contains $n) { return 'launcher' }
    if ($n -match 'chrome|msedge|firefox|brave|webview|webhelper|cef|electron') { return 'browserWebView' }
    if ($n -match 'nvidia|nvcontainer|amd|radeon|intel|asus|armoury|samsung|logi|razer|nahimic|steelseries') { return 'vendorUtility' }
    if (@('msmpeng.exe','securityhealthservice.exe','senseir.exe','mpssvc.exe') -contains $n) { return 'security' }
    if ($n -match 'tailscale|wireguard|openvpn|zerotier|wlanext|dns|dhcp') { return 'network' }
    if (@('audiodg.exe','wispr flow.exe','inputapp.exe','textinputhost.exe','ctfmon.exe') -contains $n) { return 'audioInput' }
    if (@('system','system idle process','registry','smss.exe','csrss.exe','wininit.exe','services.exe','lsass.exe','svchost.exe','fontdrvhost.exe','dwm.exe','winlogon.exe','explorer.exe','taskhostw.exe','sihost.exe','runtimebroker.exe','searchindexer.exe','mousocoreworker.exe','usoclient.exe','tiworker.exe','trustedinstaller.exe','winstore.app.exe','wsappx.exe') -contains $n) { return 'windowsCore' }
    return 'backgroundApp'
}

function Get-RooIndustriesProcessPolicySnapshot {
    param([switch]$IncludeCommandLine)
    $cimById = @{}
    if ($IncludeCommandLine) {
        foreach ($cim in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            $cimById[[int]$cim.ProcessId] = $cim
        }
    }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($live in @(Get-Process -ErrorAction SilentlyContinue)) {
        $processIdValue = [int]$live.Id
        $name = [string]$live.ProcessName
        if ($name -notin @('Idle','System') -and -not $name.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
            $name = "$name.exe"
        }
        $cim = $cimById[$processIdValue]
        $path = $null
        try { $path = $live.Path } catch { $path = $null }
        if ([string]::IsNullOrWhiteSpace([string]$path) -and $cim) { $path = $cim.ExecutablePath }
        $priority = $null
        try { $priority = [string]$live.PriorityClass } catch { $priority = $null }
        $sessionId = $null
        try { $sessionId = [int]$live.SessionId } catch { $sessionId = $null }
        $startTimeUtc = $null
        try { $startTimeUtc = $live.StartTime.ToUniversalTime().ToString('o') } catch { $startTimeUtc = $null }
        $commandLineValue = $null
        if ($IncludeCommandLine) {
            if ($cim) { $commandLineValue = $cim.CommandLine }
            if ([string]::IsNullOrWhiteSpace([string]$commandLineValue)) {
                $commandLineValue = Get-RooIndustriesProcessPolicyCommandLineFallback $processIdValue
            }
        }
        $category = Get-RooIndustriesProcessPolicyCategory $name
        $items.Add([pscustomobject]@{
            pid = $processIdValue
            name = $name
            displayName = $null
            executablePath = $path
            publisher = $null
            commandLine = $commandLineValue
            category = $category
            sessionId = $sessionId
            startTimeUtc = $startTimeUtc
            priorityClass = $priority
            canChangePriority = ($processIdValue -gt 4)
            risk = if ($category -in $script:RooIndustriesProcessPolicyProtectedCategories) { 'protected' } else { 'low' }
        }) | Out-Null
    }
    return @($items.ToArray())
}

function Test-RooIndustriesProcessPolicyAnyWildcard {
    param(
        [string]$Value,
        [object[]]$Patterns
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    foreach ($pattern in @(Get-RooIndustriesArray $Patterns)) {
        if ($Value -like [string]$pattern) { return $true }
    }
    return $false
}

function Test-RooIndustriesProcessPolicyRuleMatch {
    param(
        [object]$Process,
        [object]$Match
    )
    if ($null -eq $Process -or $null -eq $Match) { return $false }
    $hasSelector = $false
    $processName = [string](Get-RooIndustriesPropertyValue $Process 'name' '')
    $processPath = [string](Get-RooIndustriesPropertyValue $Process 'executablePath' '')
    $publisher = [string](Get-RooIndustriesPropertyValue $Process 'publisher' '')
    $commandLine = [string](Get-RooIndustriesPropertyValue $Process 'commandLine' '')
    $category = [string](Get-RooIndustriesPropertyValue $Process 'category' '')

    $names = @()
    $names += Get-RooIndustriesPropertyArray $Match 'names'
    $names += Get-RooIndustriesPropertyArray $Match 'processNames'
    if ($names.Count -gt 0) {
        $hasSelector = $true
        if (-not (Test-RooIndustriesAnyNameMatch $processName $names)) { return $false }
    }

    $namePatterns = Get-RooIndustriesPropertyArray $Match 'namePatterns'
    if ($namePatterns.Count -gt 0) {
        $hasSelector = $true
        if (-not (Test-RooIndustriesProcessPolicyAnyWildcard $processName $namePatterns)) { return $false }
    }

    $pathPatterns = Get-RooIndustriesPropertyArray $Match 'pathPatterns'
    if ($pathPatterns.Count -gt 0) {
        $hasSelector = $true
        if (-not (Test-RooIndustriesProcessPolicyAnyWildcard $processPath $pathPatterns)) { return $false }
    }

    $publishers = @()
    $publishers += Get-RooIndustriesPropertyArray $Match 'publishers'
    $publishers += Get-RooIndustriesPropertyArray $Match 'publisherNames'
    if ($publishers.Count -gt 0) {
        $hasSelector = $true
        $matchedPublisher = $false
        foreach ($candidate in $publishers) {
            if ($publisher -eq [string]$candidate) { $matchedPublisher = $true }
        }
        if (-not $matchedPublisher) { return $false }
    }

    $publisherPatterns = Get-RooIndustriesPropertyArray $Match 'publisherPatterns'
    if ($publisherPatterns.Count -gt 0) {
        $hasSelector = $true
        if (-not (Test-RooIndustriesProcessPolicyAnyWildcard $publisher $publisherPatterns)) { return $false }
    }

    $commandLinePatterns = Get-RooIndustriesPropertyArray $Match 'commandLinePatterns'
    if ($commandLinePatterns.Count -gt 0) {
        $hasSelector = $true
        if (-not (Test-RooIndustriesProcessPolicyAnyWildcard $commandLine $commandLinePatterns)) { return $false }
    }

    $categories = @()
    $categories += Get-RooIndustriesPropertyArray $Match 'processCategories'
    $categories += Get-RooIndustriesPropertyArray $Match 'categories'
    $singleCategory = [string](Get-RooIndustriesPropertyValue $Match 'category' '')
    if (-not [string]::IsNullOrWhiteSpace($singleCategory)) { $categories += $singleCategory }
    if ($categories.Count -gt 0) {
        $hasSelector = $true
        $matchedCategory = $false
        foreach ($candidate in $categories) {
            if ($category -eq [string]$candidate) { $matchedCategory = $true }
        }
        if (-not $matchedCategory) { return $false }
    }

    if (-not $hasSelector) { return $false }

    $excludeNames = Get-RooIndustriesPropertyArray $Match 'excludeProcessNames'
    if ($excludeNames.Count -gt 0 -and (Test-RooIndustriesAnyNameMatch $processName $excludeNames)) { return $false }

    $excludeNamePatterns = Get-RooIndustriesPropertyArray $Match 'excludeNamePatterns'
    if ($excludeNamePatterns.Count -gt 0 -and (Test-RooIndustriesProcessPolicyAnyWildcard $processName $excludeNamePatterns)) { return $false }

    $excludePathPatterns = Get-RooIndustriesPropertyArray $Match 'excludePathPatterns'
    if ($excludePathPatterns.Count -gt 0 -and (Test-RooIndustriesProcessPolicyAnyWildcard $processPath $excludePathPatterns)) { return $false }

    $excludePublishers = Get-RooIndustriesPropertyArray $Match 'excludePublisherNames'
    foreach ($candidate in $excludePublishers) {
        if ($publisher -eq [string]$candidate) { return $false }
    }

    $excludePublisherPatterns = Get-RooIndustriesPropertyArray $Match 'excludePublisherPatterns'
    if ($excludePublisherPatterns.Count -gt 0 -and (Test-RooIndustriesProcessPolicyAnyWildcard $publisher $excludePublisherPatterns)) { return $false }

    $excludeCommandLinePatterns = Get-RooIndustriesPropertyArray $Match 'excludeCommandLinePatterns'
    if ($excludeCommandLinePatterns.Count -gt 0 -and (Test-RooIndustriesProcessPolicyAnyWildcard $commandLine $excludeCommandLinePatterns)) { return $false }

    $excludeCategories = Get-RooIndustriesPropertyArray $Match 'excludeProcessCategories'
    foreach ($candidate in $excludeCategories) {
        if ($category -eq [string]$candidate) { return $false }
    }
    return $true
}

function Get-RooIndustriesProcessPolicyRules {
    param([object]$Profile)
    $policy = Get-RooIndustriesProcessPolicyProfileRoot $Profile
    $rules = @(Get-RooIndustriesPropertyArray $policy 'rules')
    if ($rules.Count -eq 0) { $rules = @(Get-RooIndustriesPropertyArray $Profile 'rules') }
    return @($rules)
}

function Get-RooIndustriesProcessPolicyRuleMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    foreach ($rule in @(Get-RooIndustriesProcessPolicyRules $Profile)) {
        $enabled = [bool](Get-RooIndustriesPropertyValue $rule 'enabled' $true)
        if (-not $enabled) { continue }
        $match = Get-RooIndustriesPropertyValue $rule 'match' $rule
        if (Test-RooIndustriesProcessPolicyRuleMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; rule = $rule }
        }
    }
    return [pscustomobject]@{ matched = $false; rule = $null }
}

function Get-RooIndustriesProcessPolicyRuleById {
    param(
        [object]$Profile,
        [string]$RuleId
    )
    foreach ($rule in @(Get-RooIndustriesProcessPolicyRules $Profile)) {
        if ([string](Get-RooIndustriesPropertyValue $rule 'ruleId' '') -eq $RuleId) { return $rule }
    }
    return $null
}

function Get-RooIndustriesProcessPolicyProfileProtectedMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    $policy = Get-RooIndustriesProcessPolicyProfileRoot $Profile
    $protectedItems = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-RooIndustriesPropertyArray $policy 'protectedProcesses')) { $protectedItems.Add($item) | Out-Null }
    foreach ($item in @(Get-RooIndustriesPropertyArray $Profile 'protectedProcesses')) { $protectedItems.Add($item) | Out-Null }
    foreach ($item in @(Get-RooIndustriesPropertyArray $Profile 'protectedCompanions')) { $protectedItems.Add($item) | Out-Null }
    foreach ($item in @($protectedItems.ToArray())) {
        $match = Get-RooIndustriesPropertyValue $item 'match' $null
        if ($null -eq $match) {
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
                commandLinePatterns = @(Get-RooIndustriesPropertyArray $item 'commandLinePatterns')
            }
        }
        if (Test-RooIndustriesProcessPolicyRuleMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; item = $item }
        }
    }
    return [pscustomobject]@{ matched = $false; item = $null }
}

function Add-RooIndustriesProcessPolicyReason {
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

function Get-RooIndustriesProcessPolicyProtection {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $messages = New-Object System.Collections.Generic.List[string]
    $processId = [int](Get-RooIndustriesPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooIndustriesPropertyValue $Process 'name' '')
    $category = [string](Get-RooIndustriesPropertyValue $Process 'category' '')
    $profileProtected = Get-RooIndustriesProcessPolicyProfileProtectedMatch $Process $Profile
    $catalogProtected = Get-RooIndustriesProtectedCatalogMatch $Process $ProtectedCatalog

    if ($processId -le 4) {
        Add-RooIndustriesProcessPolicyReason $reasons @('SYSTEM_PROCESS_EXCLUDED')
        $messages.Add('System process IDs are excluded from persistent policy control.') | Out-Null
    }
    if ($category -in $script:RooIndustriesProcessPolicyProtectedCategories) {
        Add-RooIndustriesProcessPolicyReason $reasons @('PROTECTED_CATEGORY')
        $messages.Add("Process category '$category' is protected from persistent policy control.") | Out-Null
    }
    if ((Get-RooIndustriesNormalizedProcessName $processName) -in $script:RooIndustriesProcessPolicyProtectedNames) {
        Add-RooIndustriesProcessPolicyReason $reasons @('PROTECTED_PROCESS_NAME')
        $messages.Add('Process name is in the hard protected process list.') | Out-Null
    }
    if ($catalogProtected.matched) {
        Add-RooIndustriesProcessPolicyReason $reasons (Get-RooIndustriesPropertyArray $catalogProtected.item 'reasonCodes')
        Add-RooIndustriesProcessPolicyReason $reasons @('PROTECTED_CATALOG_MATCH')
        $messages.Add([string](Get-RooIndustriesPropertyValue $catalogProtected.item 'reason' 'Protected process catalog match.')) | Out-Null
    }
    if ($profileProtected.matched) {
        Add-RooIndustriesProcessPolicyReason $reasons (Get-RooIndustriesPropertyArray $profileProtected.item 'reasonCodes')
        Add-RooIndustriesProcessPolicyReason $reasons @('PROFILE_PROTECTED_PROCESS')
        $messages.Add([string](Get-RooIndustriesPropertyValue $profileProtected.item 'reason' 'Profile protected process match.')) | Out-Null
    }

    return [pscustomobject]@{
        blocked = ($reasons.Count -gt 0)
        profileProtected = [bool]$profileProtected.matched
        catalogProtected = [bool]$catalogProtected.matched
        reasonCodes = @($reasons.ToArray())
        reason = ($messages.ToArray() -join ' ')
    }
}

function Get-RooIndustriesProcessPolicyControls {
    param([object]$Rule)
    $controls = Get-RooIndustriesPropertyValue $Rule 'controls' $null
    if ($null -eq $controls) { $controls = Get-RooIndustriesPropertyValue $Rule 'action' $null }
    if ($null -eq $controls) { $controls = $Rule }
    return [pscustomobject]@{
        priorityClass = Get-RooIndustriesPropertyValue $controls 'priorityClass' $null
        affinityMask = Get-RooIndustriesPropertyValue $controls 'affinityMask' $null
        ioPriority = Get-RooIndustriesPropertyValue $controls 'ioPriority' $null
        gpuPriority = Get-RooIndustriesPropertyValue $controls 'gpuPriority' $null
        restraint = Get-RooIndustriesPropertyValue $controls 'restraint' $null
    }
}

function New-RooIndustriesProcessPolicyControlChanges {
    param(
        [object]$Controls,
        [object]$CurrentState
    )
    $changes = New-Object System.Collections.Generic.List[object]
    $blocked = $false
    $blockedReason = $null
    $priority = Get-RooIndustriesPropertyValue $Controls 'priorityClass' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$priority) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'priorityClass' $null) -ne [string]$priority) {
        if (Test-RooIndustriesPriorityAllowed ([string]$priority)) {
            $changes.Add((New-RooIndustriesControlChange 'priorityClass' (Get-RooIndustriesPropertyValue $CurrentState 'priorityClass' $null) ([string]$priority) 'setPriority' 'Apply saved process policy priority class.')) | Out-Null
        } else {
            $blocked = $true
            $blockedReason = "Priority class '$priority' is outside the allow-list."
        }
    }

    $affinity = Get-RooIndustriesPropertyValue $Controls 'affinityMask' $null
    if ($null -ne $affinity) {
        if (-not (Test-RooIndustriesAffinityMaskAllowed $affinity)) {
            $blocked = $true
            $blockedReason = "Affinity mask '$affinity' is invalid."
        } elseif ($null -eq (Get-RooIndustriesPropertyValue $CurrentState 'affinityMask' $null) -or [int64](Get-RooIndustriesPropertyValue $CurrentState 'affinityMask' 0) -ne [int64]$affinity) {
            $changes.Add((New-RooIndustriesControlChange 'affinityMask' (Get-RooIndustriesPropertyValue $CurrentState 'affinityMask' $null) ([int64]$affinity) 'setAffinity' 'Apply saved process policy CPU affinity.')) | Out-Null
        }
    }

    $ioPriority = Get-RooIndustriesPropertyValue $Controls 'ioPriority' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$ioPriority) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'ioPriority' $null) -ne [string]$ioPriority) {
        if (Test-RooIndustriesIoPriorityAllowed ([string]$ioPriority)) {
            $changes.Add((New-RooIndustriesControlChange 'ioPriority' (Get-RooIndustriesPropertyValue $CurrentState 'ioPriority' $null) ([string]$ioPriority) 'setIoPriority' 'Apply saved process policy I/O priority.')) | Out-Null
        } else {
            $blocked = $true
            $blockedReason = "I/O priority '$ioPriority' is outside the allow-list."
        }
    }

    $gpuPriority = Get-RooIndustriesPropertyValue $Controls 'gpuPriority' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$gpuPriority) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'gpuPriority' $null) -ne [string]$gpuPriority) {
        if (Test-RooIndustriesGpuPriorityAllowed ([string]$gpuPriority)) {
            $changes.Add((New-RooIndustriesControlChange 'gpuPriority' (Get-RooIndustriesPropertyValue $CurrentState 'gpuPriority' $null) ([string]$gpuPriority) 'setGpuPriority' 'Apply saved process policy GPU scheduling priority.')) | Out-Null
        } else {
            $blocked = $true
            $blockedReason = "GPU priority '$gpuPriority' is outside the allow-list."
        }
    }

    return [pscustomobject]@{
        changes = @($changes.ToArray())
        blocked = $blocked
        blockedReason = $blockedReason
    }
}

function New-RooIndustriesProcessPolicyPreviewEntry {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog
    )
    $ruleMatch = Get-RooIndustriesProcessPolicyRuleMatch $Process $Profile
    $protection = Get-RooIndustriesProcessPolicyProtection $Process $Profile $ProtectedCatalog
    if (-not $ruleMatch.matched -and -not $protection.profileProtected) { return $null }

    $processId = [int](Get-RooIndustriesPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooIndustriesPropertyValue $Process 'name' '')
    $rule = $ruleMatch.rule
    $ruleId = if ($ruleMatch.matched) { [string](Get-RooIndustriesPropertyValue $rule 'ruleId' 'process-policy-rule') } else { 'process-policy-protected-skip' }
    $controls = if ($ruleMatch.matched) { Get-RooIndustriesProcessPolicyControls $rule } else { [pscustomobject]@{} }
    $currentControls = Get-RooIndustriesProcessControlState $processId (Get-RooIndustriesPropertyValue $Process 'priorityClass' $null) -ReadGpu:($ruleMatch.matched -and -not $protection.blocked -and -not [string]::IsNullOrWhiteSpace([string]$controls.gpuPriority))
    $controlState = [pscustomobject]@{
        priorityClass = $currentControls.priorityClass
        affinityMask = $currentControls.affinityMask
        ioPriority = $currentControls.ioPriority
        gpuPriority = $currentControls.gpuPriority
    }
    $changeResult = if ($ruleMatch.matched -and -not $protection.blocked) {
        New-RooIndustriesProcessPolicyControlChanges $controls $controlState
    } else {
        [pscustomobject]@{ changes = @(); blocked = $false; blockedReason = $null }
    }

    $blocked = [bool]$protection.blocked
    $blockedReason = if ($blocked) { [string]$protection.reason } else { $null }
    if (-not $blocked -and [bool]$changeResult.blocked) {
        $blocked = $true
        $blockedReason = [string]$changeResult.blockedReason
    }
    $changes = if ($blocked) { @() } else { @(Get-RooIndustriesPropertyArray $changeResult 'changes') }
    $changes = @($changes)
    $changeCount = @($changes).Count
    $reasonCodes = New-Object System.Collections.Generic.List[string]
    Add-RooIndustriesProcessPolicyReason $reasonCodes (Get-RooIndustriesPropertyArray $rule 'reasonCodes')
    Add-RooIndustriesProcessPolicyReason $reasonCodes $protection.reasonCodes
    if ($reasonCodes.Count -eq 0) {
        Add-RooIndustriesProcessPolicyReason $reasonCodes @(if ($ruleMatch.matched) { 'PROCESS_POLICY_RULE_MATCH' } else { 'PROCESS_POLICY_PROTECTED_SKIP' })
    }

    $reason = if ($blocked) {
        $blockedReason
    } elseif ($changeCount -eq 0) {
        'Process already matches the saved policy controls.'
    } else {
        [string](Get-RooIndustriesPropertyValue $rule 'reason' 'Saved process policy controls would apply.')
    }
    $proposedAction = if ($blocked -or $changeCount -eq 0) {
        'noChange'
    } elseif ($changeCount -eq 1) {
        switch ([string](Get-RooIndustriesPropertyValue $changes[0] 'control' '')) {
            'priorityClass' { 'setPriority' }
            'affinityMask' { 'setAffinity' }
            'ioPriority' { 'setIoPriority' }
            'gpuPriority' { 'setGpuPriority' }
            default { 'setProcessControls' }
        }
    } else {
        'setProcessControls'
    }

    $tags = @()
    $tags += Get-RooIndustriesPropertyArray $rule 'tags'
    $tags += Get-RooIndustriesPropertyArray $rule 'scenarioTags'

    return [pscustomobject]@{
        previewId = (($ruleId, $processName, $processId) -join '-').ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = 'persistentProcessPolicy'
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooIndustriesPropertyValue $Process 'executablePath' $null
        currentPriorityClass = $currentControls.priorityClass
        proposedPriorityClass = if ($blocked -or $null -eq (Get-RooIndustriesPropertyValue $controls 'priorityClass' $null)) { $currentControls.priorityClass } else { Get-RooIndustriesPropertyValue $controls 'priorityClass' $currentControls.priorityClass }
        currentAffinityMask = $currentControls.affinityMask
        proposedAffinityMask = if ($blocked -or $null -eq (Get-RooIndustriesPropertyValue $controls 'affinityMask' $null)) { $currentControls.affinityMask } else { [int64](Get-RooIndustriesPropertyValue $controls 'affinityMask' $currentControls.affinityMask) }
        currentIoPriority = $currentControls.ioPriority
        proposedIoPriority = if ($blocked -or $null -eq (Get-RooIndustriesPropertyValue $controls 'ioPriority' $null)) { $currentControls.ioPriority } else { Get-RooIndustriesPropertyValue $controls 'ioPriority' $currentControls.ioPriority }
        currentGpuPriority = $currentControls.gpuPriority
        proposedGpuPriority = if ($blocked -or $null -eq (Get-RooIndustriesPropertyValue $controls 'gpuPriority' $null)) { $currentControls.gpuPriority } else { Get-RooIndustriesPropertyValue $controls 'gpuPriority' $currentControls.gpuPriority }
        proposedAction = $proposedAction
        controlChanges = @($changes)
        ruleId = $ruleId
        reason = $reason
        reasonCodes = @($reasonCodes.ToArray())
        classification = if ($blocked) { 'protected' } elseif ($ruleMatch.matched) { 'safeCandidate' } else { 'unknown' }
        blocked = $blocked
        blockedReason = if ($blocked) { $blockedReason } else { $null }
        risk = if ($blocked) { 'protected' } else { [string](Get-RooIndustriesPropertyValue $rule 'risk' 'low') }
        confidence = if ($blocked) { 'high' } else { 'medium' }
        protected = $blocked
        requiresConfirmation = ($changeCount -gt 0 -and -not $blocked)
        rollbackSupported = ($changeCount -gt 0 -and -not $blocked)
        lifecycleState = 'preview'
        currentState = [pscustomobject]@{
            priorityClass = $currentControls.priorityClass
            affinityMask = $currentControls.affinityMask
            ioPriority = $currentControls.ioPriority
            gpuPriority = $currentControls.gpuPriority
            category = Get-RooIndustriesPropertyValue $Process 'category' 'unknown'
            startTimeUtc = Get-RooIndustriesPropertyValue $Process 'startTimeUtc' $null
            commandLinePresent = -not [string]::IsNullOrWhiteSpace([string](Get-RooIndustriesPropertyValue $Process 'commandLine' ''))
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked -or $null -eq (Get-RooIndustriesPropertyValue $controls 'priorityClass' $null)) { $currentControls.priorityClass } else { Get-RooIndustriesPropertyValue $controls 'priorityClass' $currentControls.priorityClass }
            affinityMask = if ($blocked -or $null -eq (Get-RooIndustriesPropertyValue $controls 'affinityMask' $null)) { $currentControls.affinityMask } else { [int64](Get-RooIndustriesPropertyValue $controls 'affinityMask' $currentControls.affinityMask) }
            ioPriority = if ($blocked -or $null -eq (Get-RooIndustriesPropertyValue $controls 'ioPriority' $null)) { $currentControls.ioPriority } else { Get-RooIndustriesPropertyValue $controls 'ioPriority' $currentControls.ioPriority }
            gpuPriority = if ($blocked -or $null -eq (Get-RooIndustriesPropertyValue $controls 'gpuPriority' $null)) { $currentControls.gpuPriority } else { Get-RooIndustriesPropertyValue $controls 'gpuPriority' $currentControls.gpuPriority }
            reason = $reason
        }
        impact = [pscustomobject]@{
            expectedMemoryEffectBytes = 0
            expectedCpuWakeupEffect = 'neutral'
            targetMetrics = @('persistent-policy-enforcement','launch-watcher-coverage')
        }
        policyTags = @($tags)
        rollback = if ($changeCount -gt 0 -and -not $blocked) {
            [pscustomobject]@{
                captureOriginalState = $true
                restorePriorityClass = $currentControls.priorityClass
                restoreAffinityMask = $currentControls.affinityMask
                restoreIoPriority = $currentControls.ioPriority
                restoreGpuPriority = $currentControls.gpuPriority
            }
        } else {
            $null
        }
    }
}

function Get-RooIndustriesProcessPolicyPreview {
    param(
        [object]$Profile,
        [string]$ProfilePath,
        [object]$ProtectedCatalog,
        [switch]$IncludeCommandLine
    )
    $processes = @(Get-RooIndustriesProcessPolicySnapshot -IncludeCommandLine:$IncludeCommandLine)
    $preview = New-Object System.Collections.Generic.List[object]
    foreach ($proc in $processes) {
        $entry = New-RooIndustriesProcessPolicyPreviewEntry $proc $Profile $ProtectedCatalog
        if ($null -ne $entry) { $preview.Add($entry) | Out-Null }
    }
    return [pscustomobject]@{
        profileId = [string](Get-RooIndustriesPropertyValue $Profile 'profileId' '')
        profilePath = $ProfilePath
        capturedAtUtc = Get-RooIndustriesUtcStamp
        processCount = $processes.Count
        preview = @($preview.ToArray())
    }
}

function Get-RooIndustriesProcessPolicyEntryKey {
    param([object]$Entry)
    return "$([int](Get-RooIndustriesPropertyValue $Entry 'processId' 0))|$([string](Get-RooIndustriesPropertyValue $Entry 'processName' ''))|$([string](Get-RooIndustriesPropertyValue $Entry 'executablePath' ''))|$([string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Entry 'currentState' $null) 'startTimeUtc' ''))"
}

function Test-RooIndustriesProcessPolicyPathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullRoot = [System.IO.Path]::GetFullPath($Root)
        if (-not $fullRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $fullRoot = "$fullRoot$([System.IO.Path]::DirectorySeparatorChar)"
        }
        return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-RooIndustriesProcessPolicyConfirmedAllowed {
    param(
        [object]$Entry,
        [object]$Rule,
        [object]$Profile
    )
    if ([bool](Get-RooIndustriesPropertyValue $Entry 'blocked' $false) -or -not [bool](Get-RooIndustriesPropertyValue $Entry 'requiresConfirmation' $false)) {
        return [pscustomobject]@{ allowed = $false; reason = 'Policy entry is blocked or has no process control change.' }
    }
    $policy = Get-RooIndustriesProcessPolicyProfileRoot $Profile
    $safety = Get-RooIndustriesPropertyValue $policy 'safety' (Get-RooIndustriesPropertyValue $Profile 'safety' $null)
    $requireRuleAllow = [bool](Get-RooIndustriesPropertyValue $safety 'confirmedApplyRequiresRuleAllow' $true)
    $ruleAllowsApply = [bool](Get-RooIndustriesPropertyValue $Rule 'allowConfirmedApply' $false)
    $ruleSafety = Get-RooIndustriesPropertyValue $Rule 'safety' $null
    if (-not $ruleAllowsApply -and $null -ne $ruleSafety) {
        $ruleAllowsApply = [bool](Get-RooIndustriesPropertyValue $ruleSafety 'confirmedApplyAllowed' $false)
    }
    if ($requireRuleAllow -and -not $ruleAllowsApply) {
        return [pscustomobject]@{ allowed = $false; reason = 'Rule is not explicitly allowed for confirmed policy application.' }
    }
    $pathRoots = @(Get-RooIndustriesPropertyArray $safety 'confirmedApplyPathRoots')
    $requirePathRoot = [bool](Get-RooIndustriesPropertyValue $safety 'confirmedApplyRequiresPathRoot' $true)
    if ($requirePathRoot) {
        if ($pathRoots.Count -eq 0) {
            return [pscustomobject]@{ allowed = $false; reason = 'Confirmed policy application requires an allowed process path root.' }
        }
        $pathAllowed = $false
        $entryPath = [string](Get-RooIndustriesPropertyValue $Entry 'executablePath' '')
        foreach ($root in $pathRoots) {
            if (Test-RooIndustriesProcessPolicyPathUnderRoot $entryPath ([string]$root)) { $pathAllowed = $true }
        }
        if (-not $pathAllowed) {
            return [pscustomobject]@{ allowed = $false; reason = 'Process executable path is outside the confirmed policy apply roots.' }
        }
    }
    return [pscustomobject]@{ allowed = $true; reason = $null }
}

function Get-RooIndustriesProcessPolicyLiveIdentity {
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
    try { $currentPath = $live.Path } catch { $currentPath = $null }
    $expectedPath = Get-RooIndustriesPropertyValue $Entry 'executablePath' $null
    $pathMatches = $true
    $pathReason = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$expectedPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$currentPath)) {
            $pathMatches = $false
            $pathReason = 'Live process path could not be verified.'
        } else {
            $pathMatches = ([string]$expectedPath -eq [string]$currentPath)
            if (-not $pathMatches) { $pathReason = 'Live process path does not match the policy entry.' }
        }
    }
    $matches = ($nameMatches -and $pathMatches)
    $reason = if ($matches) { $null } elseif (-not $nameMatches) { 'Live process name does not match the policy entry.' } else { $pathReason }
    return [pscustomobject]@{
        exists = $true
        matches = $matches
        process = $live
        currentPath = $currentPath
        reason = $reason
    }
}

function New-RooIndustriesProcessPolicyChangedItem {
    param(
        [object]$Entry,
        [object]$OriginalState,
        [object]$AppliedState,
        [object[]]$AppliedControls,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = [int](Get-RooIndustriesPropertyValue $Entry 'processId' 0)
        processName = [string](Get-RooIndustriesPropertyValue $Entry 'processName' '')
        executablePath = Get-RooIndustriesPropertyValue $Entry 'executablePath' $null
        originalPriorityClass = Get-RooIndustriesPropertyValue $OriginalState 'priorityClass' $null
        appliedPriorityClass = Get-RooIndustriesPropertyValue $AppliedState 'priorityClass' $null
        originalAffinityMask = Get-RooIndustriesPropertyValue $OriginalState 'affinityMask' $null
        appliedAffinityMask = Get-RooIndustriesPropertyValue $AppliedState 'affinityMask' $null
        originalIoPriority = Get-RooIndustriesPropertyValue $OriginalState 'ioPriority' $null
        appliedIoPriority = Get-RooIndustriesPropertyValue $AppliedState 'ioPriority' $null
        originalGpuPriority = Get-RooIndustriesPropertyValue $OriginalState 'gpuPriority' $null
        appliedGpuPriority = Get-RooIndustriesPropertyValue $AppliedState 'gpuPriority' $null
        appliedControls = @(Get-RooIndustriesArray $AppliedControls)
        ruleId = [string](Get-RooIndustriesPropertyValue $Entry 'ruleId' '')
        reason = [string](Get-RooIndustriesPropertyValue $Entry 'reason' '')
        pollIndex = $PollIndex
        changedAtUtc = Get-RooIndustriesUtcStamp
    }
}

function New-RooIndustriesProcessPolicySkippedItem {
    param(
        [object]$Entry,
        [string]$Reason,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = Get-RooIndustriesPropertyValue $Entry 'processId' $null
        processName = Get-RooIndustriesPropertyValue $Entry 'processName' $null
        executablePath = Get-RooIndustriesPropertyValue $Entry 'executablePath' $null
        ruleId = Get-RooIndustriesPropertyValue $Entry 'ruleId' $null
        reason = $Reason
        reasonCodes = @(Get-RooIndustriesPropertyArray $Entry 'reasonCodes')
        pollIndex = $PollIndex
        skippedAtUtc = Get-RooIndustriesUtcStamp
    }
}

function New-RooIndustriesProcessPolicyBackupMetadata {
    param(
        [object]$BackupManifest,
        [string]$BackupPath
    )
    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($snap in @(Get-RooIndustriesPropertyArray $BackupManifest 'snapshots')) {
        $snapshots.Add([pscustomobject]@{
            type = 'persistentProcessPolicy'
            target = "$([string](Get-RooIndustriesPropertyValue $snap 'processName' ''))`:$([int](Get-RooIndustriesPropertyValue $snap 'processId' 0))"
            originalState = [pscustomobject]@{
                priorityClass = Get-RooIndustriesPropertyValue $snap 'originalPriorityClass' $null
                affinityMask = Get-RooIndustriesPropertyValue $snap 'originalAffinityMask' $null
                ioPriority = Get-RooIndustriesPropertyValue $snap 'originalIoPriority' $null
                gpuPriority = Get-RooIndustriesPropertyValue $snap 'originalGpuPriority' $null
                executablePath = Get-RooIndustriesPropertyValue $snap 'executablePath' $null
                startTimeUtc = Get-RooIndustriesPropertyValue $snap 'startTimeUtc' $null
            }
        }) | Out-Null
    }
    return [pscustomobject]@{
        backupId = [string](Get-RooIndustriesPropertyValue $BackupManifest 'backupId' '')
        scope = 'persistent-process-policy-controls'
        createdAtUtc = [string](Get-RooIndustriesPropertyValue $BackupManifest 'createdAtUtc' '')
        location = $BackupPath
        restorePoint = [pscustomobject]@{
            requested = $false
            status = 'not-required-for-process-policy'
            id = $null
        }
        snapshots = @($snapshots.ToArray())
        rollbackActionId = 'performance.policy.stopSession'
        rollbackSupported = $true
        retentionPolicy = [pscustomobject]@{
            keepLatestCount = 10
            minimumDays = 14
        }
    }
}

function Get-RooIndustriesProcessPolicyRestoreChanges {
    param(
        [object]$Snapshot,
        [object]$CurrentState
    )
    $changes = New-Object System.Collections.Generic.List[object]
    $originalPriority = Get-RooIndustriesPropertyValue $Snapshot 'originalPriorityClass' $null
    $originalAffinity = Get-RooIndustriesPropertyValue $Snapshot 'originalAffinityMask' $null
    $originalIo = Get-RooIndustriesPropertyValue $Snapshot 'originalIoPriority' $null
    $originalGpu = Get-RooIndustriesPropertyValue $Snapshot 'originalGpuPriority' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$originalPriority) -and (Test-RooIndustriesPriorityAllowed ([string]$originalPriority)) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'priorityClass' $null) -ne [string]$originalPriority) {
        $changes.Add((New-RooIndustriesControlChange 'priorityClass' (Get-RooIndustriesPropertyValue $CurrentState 'priorityClass' $null) $originalPriority 'restorePriority' 'Restore original process priority after policy session.')) | Out-Null
    }
    if ($null -ne $originalAffinity -and (Test-RooIndustriesAffinityMaskAllowed $originalAffinity) -and [int64](Get-RooIndustriesPropertyValue $CurrentState 'affinityMask' 0) -ne [int64]$originalAffinity) {
        $changes.Add((New-RooIndustriesControlChange 'affinityMask' (Get-RooIndustriesPropertyValue $CurrentState 'affinityMask' $null) ([int64]$originalAffinity) 'restoreAffinity' 'Restore original CPU affinity after policy session.')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$originalIo) -and (Test-RooIndustriesIoPriorityAllowed ([string]$originalIo)) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'ioPriority' $null) -ne [string]$originalIo) {
        $changes.Add((New-RooIndustriesControlChange 'ioPriority' (Get-RooIndustriesPropertyValue $CurrentState 'ioPriority' $null) $originalIo 'restoreIoPriority' 'Restore original I/O priority after policy session.')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$originalGpu) -and (Test-RooIndustriesGpuPriorityAllowed ([string]$originalGpu)) -and [string](Get-RooIndustriesPropertyValue $CurrentState 'gpuPriority' $null) -ne [string]$originalGpu) {
        $changes.Add((New-RooIndustriesControlChange 'gpuPriority' (Get-RooIndustriesPropertyValue $CurrentState 'gpuPriority' $null) $originalGpu 'restoreGpuPriority' 'Restore original GPU scheduling priority after policy session.')) | Out-Null
    }
    return @($changes.ToArray())
}
