. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$script:RooProcessPolicyStateFolderName = 'process-policy-sessions'
$script:RooProcessPolicyProtectedCategories = @(
    'foregroundGame',
    'captureStreaming',
    'voiceChat',
    'vendorUtility',
    'windowsCore',
    'security',
    'network',
    'audioInput'
)
$script:RooProcessPolicyProtectedNames = @(
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

function Resolve-RooProcessPolicyStateRoot {
    param([string]$StateRoot)
    $defaultStateRoot = Join-Path $PSScriptRoot '..\state'
    $resolvedStateRoot = Resolve-RooPath $StateRoot $defaultStateRoot
    return [System.IO.Path]::GetFullPath((Join-Path $resolvedStateRoot $script:RooProcessPolicyStateFolderName))
}

function New-RooProcessPolicySessionId {
    param([string]$ProfileId)
    $safeProfileId = if ([string]::IsNullOrWhiteSpace($ProfileId)) { 'profile' } else { $ProfileId.ToLowerInvariant() -replace '[^a-z0-9\-]+', '-' }
    return "process-policy-$safeProfileId-$(Get-RooFileStamp)"
}

function Get-RooProcessPolicySessionDirectory {
    param(
        [string]$ResolvedPolicyStateRoot,
        [string]$SessionId
    )
    return Join-Path $ResolvedPolicyStateRoot $SessionId
}

function Write-RooProcessPolicyJsonFile {
    param(
        [object]$Value,
        [string]$Path
    )
    Ensure-RooDirectory (Split-Path $Path -Parent)
    ($Value | ConvertTo-Json -Depth 40) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Add-RooProcessPolicyLogFileEntry {
    param(
        [string]$SessionDirectory,
        [object]$Entry
    )
    if ([string]::IsNullOrWhiteSpace($SessionDirectory)) { return }
    Ensure-RooDirectory $SessionDirectory
    ($Entry | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath (Join-Path $SessionDirectory 'events.jsonl') -Encoding UTF8
}

function Get-RooProcessPolicySessionFileFromPath {
    param([string]$SessionPath)
    if ([string]::IsNullOrWhiteSpace($SessionPath)) { return $null }
    $resolved = Resolve-RooPath $SessionPath $SessionPath
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        return Join-Path $resolved 'session.json'
    }
    return $resolved
}

function Get-RooProcessPolicyLatestSessionFile {
    param([string]$ResolvedPolicyStateRoot)
    if (-not (Test-Path -LiteralPath $ResolvedPolicyStateRoot)) { return $null }
    $latest = Get-ChildItem -LiteralPath $ResolvedPolicyStateRoot -Filter 'session.json' -Recurse -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { return $null }
    return $latest.FullName
}

function Resolve-RooProcessPolicySessionFile {
    param(
        [string]$SessionId,
        [string]$SessionPath,
        [string]$StateRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($SessionPath)) {
        return Get-RooProcessPolicySessionFileFromPath $SessionPath
    }
    $resolvedStateRoot = Resolve-RooProcessPolicyStateRoot $StateRoot
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return Join-Path (Get-RooProcessPolicySessionDirectory $resolvedStateRoot $SessionId) 'session.json'
    }
    return Get-RooProcessPolicyLatestSessionFile $resolvedStateRoot
}

function Get-RooProcessPolicyProfileRoot {
    param([object]$Profile)
    $policy = Get-RooPropertyValue $Profile 'policy' $null
    if ($null -ne $policy) { return $policy }
    return $Profile
}

function Get-RooProcessPolicyConfig {
    param(
        [object]$Profile,
        [int]$MaxDurationSecondsOverride = 0,
        [int]$PollIntervalSecondsOverride = 0
    )
    $policy = Get-RooProcessPolicyProfileRoot $Profile
    $session = Get-RooPropertyValue $policy 'session' $policy
    $maxDuration = if ($MaxDurationSecondsOverride -gt 0) { $MaxDurationSecondsOverride } else { [int](Get-RooPropertyValue $session 'maxSessionDurationSeconds' 60) }
    if ($maxDuration -lt 1) { $maxDuration = 1 }
    $poll = if ($PollIntervalSecondsOverride -gt 0) { $PollIntervalSecondsOverride } else { [int](Get-RooPropertyValue $session 'pollIntervalSeconds' 1) }
    if ($poll -lt 1) { $poll = 1 }
    return [pscustomobject]@{
        maxSessionDurationSeconds = $maxDuration
        pollIntervalSeconds = $poll
    }
}

function Resolve-RooProcessPolicyProtectedCatalog {
    param(
        [object]$Profile,
        [string]$ProfilePath
    )
    $catalogPathValue = [string](Get-RooPropertyValue $Profile 'protectedCatalogPath' 'protected-processes.json')
    if ([System.IO.Path]::IsPathRooted($catalogPathValue)) {
        return $catalogPathValue
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path $ProfilePath -Parent) $catalogPathValue))
}

function Get-RooProcessPolicyCategory {
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

function Get-RooProcessPolicySnapshot {
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
        $category = Get-RooProcessPolicyCategory $name
        $items.Add([pscustomobject]@{
            pid = $processIdValue
            name = $name
            displayName = $null
            executablePath = $path
            publisher = $null
            commandLine = if ($IncludeCommandLine -and $cim) { $cim.CommandLine } else { $null }
            category = $category
            sessionId = $sessionId
            startTimeUtc = $startTimeUtc
            priorityClass = $priority
            canChangePriority = ($processIdValue -gt 4)
            risk = if ($category -in $script:RooProcessPolicyProtectedCategories) { 'protected' } else { 'low' }
        }) | Out-Null
    }
    return @($items.ToArray())
}

function Test-RooProcessPolicyAnyWildcard {
    param(
        [string]$Value,
        [object[]]$Patterns
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    foreach ($pattern in @(Get-RooArray $Patterns)) {
        if ($Value -like [string]$pattern) { return $true }
    }
    return $false
}

function Test-RooProcessPolicyRuleMatch {
    param(
        [object]$Process,
        [object]$Match
    )
    if ($null -eq $Process -or $null -eq $Match) { return $false }
    $hasSelector = $false
    $processName = [string](Get-RooPropertyValue $Process 'name' '')
    $processPath = [string](Get-RooPropertyValue $Process 'executablePath' '')
    $commandLine = [string](Get-RooPropertyValue $Process 'commandLine' '')
    $category = [string](Get-RooPropertyValue $Process 'category' '')

    $names = @()
    $names += Get-RooPropertyArray $Match 'names'
    $names += Get-RooPropertyArray $Match 'processNames'
    if ($names.Count -gt 0) {
        $hasSelector = $true
        if (-not (Test-RooAnyNameMatch $processName $names)) { return $false }
    }

    $namePatterns = Get-RooPropertyArray $Match 'namePatterns'
    if ($namePatterns.Count -gt 0) {
        $hasSelector = $true
        if (-not (Test-RooProcessPolicyAnyWildcard $processName $namePatterns)) { return $false }
    }

    $pathPatterns = Get-RooPropertyArray $Match 'pathPatterns'
    if ($pathPatterns.Count -gt 0) {
        $hasSelector = $true
        if (-not (Test-RooProcessPolicyAnyWildcard $processPath $pathPatterns)) { return $false }
    }

    $commandLinePatterns = Get-RooPropertyArray $Match 'commandLinePatterns'
    if ($commandLinePatterns.Count -gt 0) {
        $hasSelector = $true
        if (-not (Test-RooProcessPolicyAnyWildcard $commandLine $commandLinePatterns)) { return $false }
    }

    $categories = @()
    $categories += Get-RooPropertyArray $Match 'processCategories'
    $categories += Get-RooPropertyArray $Match 'categories'
    $singleCategory = [string](Get-RooPropertyValue $Match 'category' '')
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

    $excludeNames = Get-RooPropertyArray $Match 'excludeProcessNames'
    if ($excludeNames.Count -gt 0 -and (Test-RooAnyNameMatch $processName $excludeNames)) { return $false }

    $excludeNamePatterns = Get-RooPropertyArray $Match 'excludeNamePatterns'
    if ($excludeNamePatterns.Count -gt 0 -and (Test-RooProcessPolicyAnyWildcard $processName $excludeNamePatterns)) { return $false }

    $excludePathPatterns = Get-RooPropertyArray $Match 'excludePathPatterns'
    if ($excludePathPatterns.Count -gt 0 -and (Test-RooProcessPolicyAnyWildcard $processPath $excludePathPatterns)) { return $false }

    $excludeCommandLinePatterns = Get-RooPropertyArray $Match 'excludeCommandLinePatterns'
    if ($excludeCommandLinePatterns.Count -gt 0 -and (Test-RooProcessPolicyAnyWildcard $commandLine $excludeCommandLinePatterns)) { return $false }

    $excludeCategories = Get-RooPropertyArray $Match 'excludeProcessCategories'
    foreach ($candidate in $excludeCategories) {
        if ($category -eq [string]$candidate) { return $false }
    }
    return $true
}

function Get-RooProcessPolicyRules {
    param([object]$Profile)
    $policy = Get-RooProcessPolicyProfileRoot $Profile
    $rules = @(Get-RooPropertyArray $policy 'rules')
    if ($rules.Count -eq 0) { $rules = @(Get-RooPropertyArray $Profile 'rules') }
    return @($rules)
}

function Get-RooProcessPolicyRuleMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    foreach ($rule in @(Get-RooProcessPolicyRules $Profile)) {
        $enabled = [bool](Get-RooPropertyValue $rule 'enabled' $true)
        if (-not $enabled) { continue }
        $match = Get-RooPropertyValue $rule 'match' $rule
        if (Test-RooProcessPolicyRuleMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; rule = $rule }
        }
    }
    return [pscustomobject]@{ matched = $false; rule = $null }
}

function Get-RooProcessPolicyRuleById {
    param(
        [object]$Profile,
        [string]$RuleId
    )
    foreach ($rule in @(Get-RooProcessPolicyRules $Profile)) {
        if ([string](Get-RooPropertyValue $rule 'ruleId' '') -eq $RuleId) { return $rule }
    }
    return $null
}

function Get-RooProcessPolicyProfileProtectedMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    $policy = Get-RooProcessPolicyProfileRoot $Profile
    $protectedItems = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-RooPropertyArray $policy 'protectedProcesses')) { $protectedItems.Add($item) | Out-Null }
    foreach ($item in @(Get-RooPropertyArray $Profile 'protectedProcesses')) { $protectedItems.Add($item) | Out-Null }
    foreach ($item in @(Get-RooPropertyArray $Profile 'protectedCompanions')) { $protectedItems.Add($item) | Out-Null }
    foreach ($item in @($protectedItems.ToArray())) {
        $match = Get-RooPropertyValue $item 'match' $null
        if ($null -eq $match) {
            $names = New-Object System.Collections.Generic.List[string]
            foreach ($name in @(Get-RooPropertyArray $item 'names')) { $names.Add([string]$name) | Out-Null }
            foreach ($name in @(Get-RooPropertyArray $item 'processNames')) { $names.Add([string]$name) | Out-Null }
            $singleName = [string](Get-RooPropertyValue $item 'name' '')
            if (-not [string]::IsNullOrWhiteSpace($singleName)) { $names.Add($singleName) | Out-Null }
            $match = [pscustomobject]@{
                processNames = @($names.ToArray())
                namePatterns = @(Get-RooPropertyArray $item 'namePatterns')
                pathPatterns = @(Get-RooPropertyArray $item 'pathPatterns')
                processCategories = @(Get-RooPropertyArray $item 'processCategories')
                commandLinePatterns = @(Get-RooPropertyArray $item 'commandLinePatterns')
            }
        }
        if (Test-RooProcessPolicyRuleMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; item = $item }
        }
    }
    return [pscustomobject]@{ matched = $false; item = $null }
}

function Add-RooProcessPolicyReason {
    param(
        [System.Collections.Generic.List[string]]$Reasons,
        [object]$Values
    )
    foreach ($value in @(Get-RooArray $Values)) {
        if ($null -eq $value) { continue }
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text) -and -not $Reasons.Contains($text)) {
            $Reasons.Add($text) | Out-Null
        }
    }
}

function Get-RooProcessPolicyProtection {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $messages = New-Object System.Collections.Generic.List[string]
    $processId = [int](Get-RooPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooPropertyValue $Process 'name' '')
    $category = [string](Get-RooPropertyValue $Process 'category' '')
    $profileProtected = Get-RooProcessPolicyProfileProtectedMatch $Process $Profile
    $catalogProtected = Get-RooProtectedCatalogMatch $Process $ProtectedCatalog

    if ($processId -le 4) {
        Add-RooProcessPolicyReason $reasons @('SYSTEM_PROCESS_EXCLUDED')
        $messages.Add('System process IDs are excluded from persistent policy control.') | Out-Null
    }
    if ($category -in $script:RooProcessPolicyProtectedCategories) {
        Add-RooProcessPolicyReason $reasons @('PROTECTED_CATEGORY')
        $messages.Add("Process category '$category' is protected from persistent policy control.") | Out-Null
    }
    if ((Get-RooNormalizedProcessName $processName) -in $script:RooProcessPolicyProtectedNames) {
        Add-RooProcessPolicyReason $reasons @('PROTECTED_PROCESS_NAME')
        $messages.Add('Process name is in the hard protected process list.') | Out-Null
    }
    if ($catalogProtected.matched) {
        Add-RooProcessPolicyReason $reasons (Get-RooPropertyArray $catalogProtected.item 'reasonCodes')
        Add-RooProcessPolicyReason $reasons @('PROTECTED_CATALOG_MATCH')
        $messages.Add([string](Get-RooPropertyValue $catalogProtected.item 'reason' 'Protected process catalog match.')) | Out-Null
    }
    if ($profileProtected.matched) {
        Add-RooProcessPolicyReason $reasons (Get-RooPropertyArray $profileProtected.item 'reasonCodes')
        Add-RooProcessPolicyReason $reasons @('PROFILE_PROTECTED_PROCESS')
        $messages.Add([string](Get-RooPropertyValue $profileProtected.item 'reason' 'Profile protected process match.')) | Out-Null
    }

    return [pscustomobject]@{
        blocked = ($reasons.Count -gt 0)
        profileProtected = [bool]$profileProtected.matched
        catalogProtected = [bool]$catalogProtected.matched
        reasonCodes = @($reasons.ToArray())
        reason = ($messages.ToArray() -join ' ')
    }
}

function Get-RooProcessPolicyControls {
    param([object]$Rule)
    $controls = Get-RooPropertyValue $Rule 'controls' $null
    if ($null -eq $controls) { $controls = Get-RooPropertyValue $Rule 'action' $null }
    if ($null -eq $controls) { $controls = $Rule }
    return [pscustomobject]@{
        priorityClass = Get-RooPropertyValue $controls 'priorityClass' $null
        affinityMask = Get-RooPropertyValue $controls 'affinityMask' $null
        ioPriority = Get-RooPropertyValue $controls 'ioPriority' $null
        gpuPriority = Get-RooPropertyValue $controls 'gpuPriority' $null
    }
}

function New-RooProcessPolicyControlChanges {
    param(
        [object]$Controls,
        [object]$CurrentState
    )
    $changes = New-Object System.Collections.Generic.List[object]
    $blocked = $false
    $blockedReason = $null
    $priority = Get-RooPropertyValue $Controls 'priorityClass' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$priority) -and [string](Get-RooPropertyValue $CurrentState 'priorityClass' $null) -ne [string]$priority) {
        if (Test-RooPriorityAllowed ([string]$priority)) {
            $changes.Add((New-RooControlChange 'priorityClass' (Get-RooPropertyValue $CurrentState 'priorityClass' $null) ([string]$priority) 'setPriority' 'Apply saved process policy priority class.')) | Out-Null
        } else {
            $blocked = $true
            $blockedReason = "Priority class '$priority' is outside the allow-list."
        }
    }

    $affinity = Get-RooPropertyValue $Controls 'affinityMask' $null
    if ($null -ne $affinity) {
        if (-not (Test-RooAffinityMaskAllowed $affinity)) {
            $blocked = $true
            $blockedReason = "Affinity mask '$affinity' is invalid."
        } elseif ($null -eq (Get-RooPropertyValue $CurrentState 'affinityMask' $null) -or [int64](Get-RooPropertyValue $CurrentState 'affinityMask' 0) -ne [int64]$affinity) {
            $changes.Add((New-RooControlChange 'affinityMask' (Get-RooPropertyValue $CurrentState 'affinityMask' $null) ([int64]$affinity) 'setAffinity' 'Apply saved process policy CPU affinity.')) | Out-Null
        }
    }

    $ioPriority = Get-RooPropertyValue $Controls 'ioPriority' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$ioPriority) -and [string](Get-RooPropertyValue $CurrentState 'ioPriority' $null) -ne [string]$ioPriority) {
        if (Test-RooIoPriorityAllowed ([string]$ioPriority)) {
            $changes.Add((New-RooControlChange 'ioPriority' (Get-RooPropertyValue $CurrentState 'ioPriority' $null) ([string]$ioPriority) 'setIoPriority' 'Apply saved process policy I/O priority.')) | Out-Null
        } else {
            $blocked = $true
            $blockedReason = "I/O priority '$ioPriority' is outside the allow-list."
        }
    }

    $gpuPriority = Get-RooPropertyValue $Controls 'gpuPriority' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$gpuPriority) -and [string](Get-RooPropertyValue $CurrentState 'gpuPriority' $null) -ne [string]$gpuPriority) {
        if (Test-RooGpuPriorityAllowed ([string]$gpuPriority)) {
            $changes.Add((New-RooControlChange 'gpuPriority' (Get-RooPropertyValue $CurrentState 'gpuPriority' $null) ([string]$gpuPriority) 'setGpuPriority' 'Apply saved process policy GPU scheduling priority.')) | Out-Null
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

function New-RooProcessPolicyPreviewEntry {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog
    )
    $ruleMatch = Get-RooProcessPolicyRuleMatch $Process $Profile
    $protection = Get-RooProcessPolicyProtection $Process $Profile $ProtectedCatalog
    if (-not $ruleMatch.matched -and -not $protection.profileProtected) { return $null }

    $processId = [int](Get-RooPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooPropertyValue $Process 'name' '')
    $rule = $ruleMatch.rule
    $ruleId = if ($ruleMatch.matched) { [string](Get-RooPropertyValue $rule 'ruleId' 'process-policy-rule') } else { 'process-policy-protected-skip' }
    $controls = if ($ruleMatch.matched) { Get-RooProcessPolicyControls $rule } else { [pscustomobject]@{} }
    $currentControls = Get-RooProcessControlState $processId (Get-RooPropertyValue $Process 'priorityClass' $null)
    $controlState = [pscustomobject]@{
        priorityClass = $currentControls.priorityClass
        affinityMask = $currentControls.affinityMask
        ioPriority = $currentControls.ioPriority
        gpuPriority = $currentControls.gpuPriority
    }
    $changeResult = if ($ruleMatch.matched -and -not $protection.blocked) {
        New-RooProcessPolicyControlChanges $controls $controlState
    } else {
        [pscustomobject]@{ changes = @(); blocked = $false; blockedReason = $null }
    }

    $blocked = [bool]$protection.blocked
    $blockedReason = if ($blocked) { [string]$protection.reason } else { $null }
    if (-not $blocked -and [bool]$changeResult.blocked) {
        $blocked = $true
        $blockedReason = [string]$changeResult.blockedReason
    }
    $changes = if ($blocked) { @() } else { @(Get-RooPropertyArray $changeResult 'changes') }
    $changes = @($changes)
    $changeCount = @($changes).Count
    $reasonCodes = New-Object System.Collections.Generic.List[string]
    Add-RooProcessPolicyReason $reasonCodes (Get-RooPropertyArray $rule 'reasonCodes')
    Add-RooProcessPolicyReason $reasonCodes $protection.reasonCodes
    if ($reasonCodes.Count -eq 0) {
        Add-RooProcessPolicyReason $reasonCodes @(if ($ruleMatch.matched) { 'PROCESS_POLICY_RULE_MATCH' } else { 'PROCESS_POLICY_PROTECTED_SKIP' })
    }

    $reason = if ($blocked) {
        $blockedReason
    } elseif ($changeCount -eq 0) {
        'Process already matches the saved policy controls.'
    } else {
        [string](Get-RooPropertyValue $rule 'reason' 'Saved process policy controls would apply.')
    }
    $proposedAction = if ($blocked -or $changeCount -eq 0) {
        'noChange'
    } elseif ($changeCount -eq 1) {
        switch ([string](Get-RooPropertyValue $changes[0] 'control' '')) {
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
    $tags += Get-RooPropertyArray $rule 'tags'
    $tags += Get-RooPropertyArray $rule 'scenarioTags'

    return [pscustomobject]@{
        previewId = (($ruleId, $processName, $processId) -join '-').ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
        type = 'persistentProcessPolicy'
        target = "$processName`:$processId"
        displayName = $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooPropertyValue $Process 'executablePath' $null
        currentPriorityClass = $currentControls.priorityClass
        proposedPriorityClass = if ($blocked -or $null -eq (Get-RooPropertyValue $controls 'priorityClass' $null)) { $currentControls.priorityClass } else { Get-RooPropertyValue $controls 'priorityClass' $currentControls.priorityClass }
        currentAffinityMask = $currentControls.affinityMask
        proposedAffinityMask = if ($blocked -or $null -eq (Get-RooPropertyValue $controls 'affinityMask' $null)) { $currentControls.affinityMask } else { [int64](Get-RooPropertyValue $controls 'affinityMask' $currentControls.affinityMask) }
        currentIoPriority = $currentControls.ioPriority
        proposedIoPriority = if ($blocked -or $null -eq (Get-RooPropertyValue $controls 'ioPriority' $null)) { $currentControls.ioPriority } else { Get-RooPropertyValue $controls 'ioPriority' $currentControls.ioPriority }
        currentGpuPriority = $currentControls.gpuPriority
        proposedGpuPriority = if ($blocked -or $null -eq (Get-RooPropertyValue $controls 'gpuPriority' $null)) { $currentControls.gpuPriority } else { Get-RooPropertyValue $controls 'gpuPriority' $currentControls.gpuPriority }
        proposedAction = $proposedAction
        controlChanges = @($changes)
        ruleId = $ruleId
        reason = $reason
        reasonCodes = @($reasonCodes.ToArray())
        classification = if ($blocked) { 'protected' } elseif ($ruleMatch.matched) { 'safeCandidate' } else { 'unknown' }
        blocked = $blocked
        blockedReason = if ($blocked) { $blockedReason } else { $null }
        risk = if ($blocked) { 'protected' } else { [string](Get-RooPropertyValue $rule 'risk' 'low') }
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
            category = Get-RooPropertyValue $Process 'category' 'unknown'
            startTimeUtc = Get-RooPropertyValue $Process 'startTimeUtc' $null
            commandLinePresent = -not [string]::IsNullOrWhiteSpace([string](Get-RooPropertyValue $Process 'commandLine' ''))
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = if ($blocked -or $null -eq (Get-RooPropertyValue $controls 'priorityClass' $null)) { $currentControls.priorityClass } else { Get-RooPropertyValue $controls 'priorityClass' $currentControls.priorityClass }
            affinityMask = if ($blocked -or $null -eq (Get-RooPropertyValue $controls 'affinityMask' $null)) { $currentControls.affinityMask } else { [int64](Get-RooPropertyValue $controls 'affinityMask' $currentControls.affinityMask) }
            ioPriority = if ($blocked -or $null -eq (Get-RooPropertyValue $controls 'ioPriority' $null)) { $currentControls.ioPriority } else { Get-RooPropertyValue $controls 'ioPriority' $currentControls.ioPriority }
            gpuPriority = if ($blocked -or $null -eq (Get-RooPropertyValue $controls 'gpuPriority' $null)) { $currentControls.gpuPriority } else { Get-RooPropertyValue $controls 'gpuPriority' $currentControls.gpuPriority }
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

function Get-RooProcessPolicyPreview {
    param(
        [object]$Profile,
        [string]$ProfilePath,
        [object]$ProtectedCatalog,
        [switch]$IncludeCommandLine
    )
    $processes = @(Get-RooProcessPolicySnapshot -IncludeCommandLine:$IncludeCommandLine)
    $preview = New-Object System.Collections.Generic.List[object]
    foreach ($proc in $processes) {
        $entry = New-RooProcessPolicyPreviewEntry $proc $Profile $ProtectedCatalog
        if ($null -ne $entry) { $preview.Add($entry) | Out-Null }
    }
    return [pscustomobject]@{
        profileId = [string](Get-RooPropertyValue $Profile 'profileId' '')
        profilePath = $ProfilePath
        capturedAtUtc = Get-RooUtcStamp
        processCount = $processes.Count
        preview = @($preview.ToArray())
    }
}

function Get-RooProcessPolicyEntryKey {
    param([object]$Entry)
    return "$([int](Get-RooPropertyValue $Entry 'processId' 0))|$([string](Get-RooPropertyValue $Entry 'processName' ''))|$([string](Get-RooPropertyValue $Entry 'executablePath' ''))|$([string](Get-RooPropertyValue (Get-RooPropertyValue $Entry 'currentState' $null) 'startTimeUtc' ''))"
}

function Test-RooProcessPolicyPathUnderRoot {
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

function Test-RooProcessPolicyConfirmedAllowed {
    param(
        [object]$Entry,
        [object]$Rule,
        [object]$Profile
    )
    if ([bool](Get-RooPropertyValue $Entry 'blocked' $false) -or -not [bool](Get-RooPropertyValue $Entry 'requiresConfirmation' $false)) {
        return [pscustomobject]@{ allowed = $false; reason = 'Policy entry is blocked or has no process control change.' }
    }
    $policy = Get-RooProcessPolicyProfileRoot $Profile
    $safety = Get-RooPropertyValue $policy 'safety' (Get-RooPropertyValue $Profile 'safety' $null)
    $requireRuleAllow = [bool](Get-RooPropertyValue $safety 'confirmedApplyRequiresRuleAllow' $true)
    $ruleAllowsApply = [bool](Get-RooPropertyValue $Rule 'allowConfirmedApply' $false)
    $ruleSafety = Get-RooPropertyValue $Rule 'safety' $null
    if (-not $ruleAllowsApply -and $null -ne $ruleSafety) {
        $ruleAllowsApply = [bool](Get-RooPropertyValue $ruleSafety 'confirmedApplyAllowed' $false)
    }
    if ($requireRuleAllow -and -not $ruleAllowsApply) {
        return [pscustomobject]@{ allowed = $false; reason = 'Rule is not explicitly allowed for confirmed policy application.' }
    }
    $pathRoots = @(Get-RooPropertyArray $safety 'confirmedApplyPathRoots')
    $requirePathRoot = [bool](Get-RooPropertyValue $safety 'confirmedApplyRequiresPathRoot' $true)
    if ($requirePathRoot) {
        if ($pathRoots.Count -eq 0) {
            return [pscustomobject]@{ allowed = $false; reason = 'Confirmed policy application requires an allowed process path root.' }
        }
        $pathAllowed = $false
        $entryPath = [string](Get-RooPropertyValue $Entry 'executablePath' '')
        foreach ($root in $pathRoots) {
            if (Test-RooProcessPolicyPathUnderRoot $entryPath ([string]$root)) { $pathAllowed = $true }
        }
        if (-not $pathAllowed) {
            return [pscustomobject]@{ allowed = $false; reason = 'Process executable path is outside the confirmed policy apply roots.' }
        }
    }
    return [pscustomobject]@{ allowed = $true; reason = $null }
}

function Get-RooProcessPolicyLiveIdentity {
    param([object]$Entry)
    $processId = [int](Get-RooPropertyValue $Entry 'processId' 0)
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
    $expectedName = [string](Get-RooPropertyValue $Entry 'processName' '')
    $nameMatches = Test-RooProcessNameEquals $live.ProcessName $expectedName
    $currentPath = $null
    try { $currentPath = $live.Path } catch { $currentPath = $null }
    $expectedPath = Get-RooPropertyValue $Entry 'executablePath' $null
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

function New-RooProcessPolicyChangedItem {
    param(
        [object]$Entry,
        [object]$OriginalState,
        [object]$AppliedState,
        [object[]]$AppliedControls,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = [int](Get-RooPropertyValue $Entry 'processId' 0)
        processName = [string](Get-RooPropertyValue $Entry 'processName' '')
        executablePath = Get-RooPropertyValue $Entry 'executablePath' $null
        originalPriorityClass = Get-RooPropertyValue $OriginalState 'priorityClass' $null
        appliedPriorityClass = Get-RooPropertyValue $AppliedState 'priorityClass' $null
        originalAffinityMask = Get-RooPropertyValue $OriginalState 'affinityMask' $null
        appliedAffinityMask = Get-RooPropertyValue $AppliedState 'affinityMask' $null
        originalIoPriority = Get-RooPropertyValue $OriginalState 'ioPriority' $null
        appliedIoPriority = Get-RooPropertyValue $AppliedState 'ioPriority' $null
        originalGpuPriority = Get-RooPropertyValue $OriginalState 'gpuPriority' $null
        appliedGpuPriority = Get-RooPropertyValue $AppliedState 'gpuPriority' $null
        appliedControls = @(Get-RooArray $AppliedControls)
        ruleId = [string](Get-RooPropertyValue $Entry 'ruleId' '')
        reason = [string](Get-RooPropertyValue $Entry 'reason' '')
        pollIndex = $PollIndex
        changedAtUtc = Get-RooUtcStamp
    }
}

function New-RooProcessPolicySkippedItem {
    param(
        [object]$Entry,
        [string]$Reason,
        [int]$PollIndex
    )
    return [pscustomobject]@{
        processId = Get-RooPropertyValue $Entry 'processId' $null
        processName = Get-RooPropertyValue $Entry 'processName' $null
        executablePath = Get-RooPropertyValue $Entry 'executablePath' $null
        ruleId = Get-RooPropertyValue $Entry 'ruleId' $null
        reason = $Reason
        reasonCodes = @(Get-RooPropertyArray $Entry 'reasonCodes')
        pollIndex = $PollIndex
        skippedAtUtc = Get-RooUtcStamp
    }
}

function New-RooProcessPolicyBackupMetadata {
    param(
        [object]$BackupManifest,
        [string]$BackupPath
    )
    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($snap in @(Get-RooPropertyArray $BackupManifest 'snapshots')) {
        $snapshots.Add([pscustomobject]@{
            type = 'persistentProcessPolicy'
            target = "$([string](Get-RooPropertyValue $snap 'processName' ''))`:$([int](Get-RooPropertyValue $snap 'processId' 0))"
            originalState = [pscustomobject]@{
                priorityClass = Get-RooPropertyValue $snap 'originalPriorityClass' $null
                affinityMask = Get-RooPropertyValue $snap 'originalAffinityMask' $null
                ioPriority = Get-RooPropertyValue $snap 'originalIoPriority' $null
                gpuPriority = Get-RooPropertyValue $snap 'originalGpuPriority' $null
                executablePath = Get-RooPropertyValue $snap 'executablePath' $null
                startTimeUtc = Get-RooPropertyValue $snap 'startTimeUtc' $null
            }
        }) | Out-Null
    }
    return [pscustomobject]@{
        backupId = [string](Get-RooPropertyValue $BackupManifest 'backupId' '')
        scope = 'persistent-process-policy-controls'
        createdAtUtc = [string](Get-RooPropertyValue $BackupManifest 'createdAtUtc' '')
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

function Get-RooProcessPolicyRestoreChanges {
    param(
        [object]$Snapshot,
        [object]$CurrentState
    )
    $changes = New-Object System.Collections.Generic.List[object]
    $originalPriority = Get-RooPropertyValue $Snapshot 'originalPriorityClass' $null
    $originalAffinity = Get-RooPropertyValue $Snapshot 'originalAffinityMask' $null
    $originalIo = Get-RooPropertyValue $Snapshot 'originalIoPriority' $null
    $originalGpu = Get-RooPropertyValue $Snapshot 'originalGpuPriority' $null
    if (-not [string]::IsNullOrWhiteSpace([string]$originalPriority) -and (Test-RooPriorityAllowed ([string]$originalPriority)) -and [string](Get-RooPropertyValue $CurrentState 'priorityClass' $null) -ne [string]$originalPriority) {
        $changes.Add((New-RooControlChange 'priorityClass' (Get-RooPropertyValue $CurrentState 'priorityClass' $null) $originalPriority 'restorePriority' 'Restore original process priority after policy session.')) | Out-Null
    }
    if ($null -ne $originalAffinity -and (Test-RooAffinityMaskAllowed $originalAffinity) -and [int64](Get-RooPropertyValue $CurrentState 'affinityMask' 0) -ne [int64]$originalAffinity) {
        $changes.Add((New-RooControlChange 'affinityMask' (Get-RooPropertyValue $CurrentState 'affinityMask' $null) ([int64]$originalAffinity) 'restoreAffinity' 'Restore original CPU affinity after policy session.')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$originalIo) -and (Test-RooIoPriorityAllowed ([string]$originalIo)) -and [string](Get-RooPropertyValue $CurrentState 'ioPriority' $null) -ne [string]$originalIo) {
        $changes.Add((New-RooControlChange 'ioPriority' (Get-RooPropertyValue $CurrentState 'ioPriority' $null) $originalIo 'restoreIoPriority' 'Restore original I/O priority after policy session.')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$originalGpu) -and (Test-RooGpuPriorityAllowed ([string]$originalGpu)) -and [string](Get-RooPropertyValue $CurrentState 'gpuPriority' $null) -ne [string]$originalGpu) {
        $changes.Add((New-RooControlChange 'gpuPriority' (Get-RooPropertyValue $CurrentState 'gpuPriority' $null) $originalGpu 'restoreGpuPriority' 'Restore original GPU scheduling priority after policy session.')) | Out-Null
    }
    return @($changes.ToArray())
}
