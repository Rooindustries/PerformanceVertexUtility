$script:RooProcessProductName = 'Roo Industries Optimization Suite'
$script:RooAllowedPriorityClasses = @('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High')
$script:RooAllowedIoPriorities = @('VeryLow', 'Low', 'Normal')
$script:RooAllowedGpuPriorities = @('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High', 'Realtime')

function Get-RooUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-RooFileStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
}

function Resolve-RooPath {
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

function Read-RooJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Ensure-RooDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-RooJsonOutput {
    param(
        [object]$Value,
        [string]$OutputPath
    )
    $json = $Value | ConvertTo-Json -Depth 24
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolved = Resolve-RooPath $OutputPath (Join-Path (Get-Location) $OutputPath)
        Ensure-RooDirectory (Split-Path $resolved -Parent)
        $json | Set-Content -LiteralPath $resolved -Encoding UTF8
    }
    return $json
}

function Get-RooArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-RooPropertyArray {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return @() }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return @() }
    return @(Get-RooArray $prop.Value)
}

function Get-RooPropertyValue {
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

function Get-RooNormalizedProcessName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.Trim().ToLowerInvariant()
    if ($n.EndsWith('.exe')) {
        return $n.Substring(0, $n.Length - 4)
    }
    return $n
}

function Test-RooProcessNameEquals {
    param(
        [string]$Left,
        [string]$Right
    )
    return (Get-RooNormalizedProcessName $Left) -eq (Get-RooNormalizedProcessName $Right)
}

function Test-RooAnyNameMatch {
    param(
        [string]$ProcessName,
        [object[]]$Names
    )
    foreach ($name in @(Get-RooArray $Names)) {
        if (Test-RooProcessNameEquals $ProcessName ([string]$name)) { return $true }
    }
    return $false
}

function Test-RooAnyWildcardMatch {
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

function Test-RooProcessMatch {
    param(
        [object]$Process,
        [object]$Match
    )
    if ($null -eq $Process -or $null -eq $Match) { return $false }

    $matched = $false
    $hasPositiveSelector = $false
    $processName = [string]$Process.name
    $processPath = [string]$Process.executablePath
    $commandLine = [string]$Process.commandLine
    $category = [string]$Process.category

    $names = @()
    $names += Get-RooPropertyArray $Match 'names'
    $names += Get-RooPropertyArray $Match 'processNames'
    if ($names.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooAnyNameMatch $processName $names) { $matched = $true }
    }

    $namePatterns = Get-RooPropertyArray $Match 'namePatterns'
    if ($namePatterns.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooAnyWildcardMatch $processName $namePatterns) { $matched = $true }
    }

    $pathPatterns = Get-RooPropertyArray $Match 'pathPatterns'
    if ($pathPatterns.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooAnyWildcardMatch $processPath $pathPatterns) { $matched = $true }
    }

    $commandLinePatterns = Get-RooPropertyArray $Match 'commandLinePatterns'
    if ($commandLinePatterns.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooAnyWildcardMatch $commandLine $commandLinePatterns) { $matched = $true }
    }

    $categories = Get-RooPropertyArray $Match 'processCategories'
    if ($categories.Count -gt 0) {
        $hasPositiveSelector = $true
        foreach ($candidate in $categories) {
            if ($category -eq [string]$candidate) { $matched = $true }
        }
    }

    if (-not $hasPositiveSelector -or -not $matched) { return $false }

    $excludeNames = Get-RooPropertyArray $Match 'excludeProcessNames'
    if ($excludeNames.Count -gt 0 -and (Test-RooAnyNameMatch $processName $excludeNames)) { return $false }

    $excludeNamePatterns = Get-RooPropertyArray $Match 'excludeNamePatterns'
    if ($excludeNamePatterns.Count -gt 0 -and (Test-RooAnyWildcardMatch $processName $excludeNamePatterns)) { return $false }

    $excludeCategories = Get-RooPropertyArray $Match 'excludeProcessCategories'
    foreach ($candidate in $excludeCategories) {
        if ($category -eq [string]$candidate) { return $false }
    }

    return $true
}

function Get-RooProtectedCatalogMatch {
    param(
        [object]$Process,
        [object]$ProtectedCatalog
    )
    foreach ($item in @(Get-RooPropertyArray $ProtectedCatalog 'protectedProcesses')) {
        $match = [pscustomobject]@{
            names = @(Get-RooPropertyArray $item 'names')
            namePatterns = @(Get-RooPropertyArray $item 'namePatterns')
            pathPatterns = @(Get-RooPropertyArray $item 'pathPatterns')
            processCategories = @(Get-RooPropertyArray $item 'processCategories')
        }
        if (Test-RooProcessMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; item = $item }
        }
    }
    return [pscustomobject]@{ matched = $false; item = $null }
}

function Get-RooProtectedCompanionMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    foreach ($item in @(Get-RooPropertyArray $Profile 'protectedCompanions')) {
        $match = [pscustomobject]@{
            names = @(Get-RooPropertyArray $item 'names')
            processNames = @([string](Get-RooPropertyValue $item 'name' ''))
        }
        if (Test-RooProcessMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; item = $item }
        }
    }
    return [pscustomobject]@{ matched = $false; item = $null }
}

function Get-RooTargetGameMatch {
    param(
        [object]$Process,
        [object]$Profile,
        [string]$TargetGameProcessName
    )
    if (-not [string]::IsNullOrWhiteSpace($TargetGameProcessName)) {
        if (Test-RooProcessNameEquals ([string]$Process.name) $TargetGameProcessName) {
            return [pscustomobject]@{
                matched = $true
                ruleId = (Get-RooPropertyValue (Get-RooPropertyValue $Profile 'foregroundGame' $null) 'ruleId' 'boost-foreground-game')
                reasonCodes = @('TARGET_GAME_PARAMETER')
            }
        }
    }

    $foregroundGame = Get-RooPropertyValue $Profile 'foregroundGame' $null
    if ($foregroundGame) {
        $match = [pscustomobject]@{ processNames = @(Get-RooPropertyArray $foregroundGame 'processNames') }
        if (Test-RooProcessMatch $Process $match) {
            return [pscustomobject]@{
                matched = $true
                ruleId = (Get-RooPropertyValue $foregroundGame 'ruleId' 'boost-foreground-game')
                reasonCodes = @(Get-RooPropertyArray $foregroundGame 'reasonCodes')
            }
        }
    }

    foreach ($game in @(Get-RooPropertyArray $Profile 'targetGames')) {
        $match = [pscustomobject]@{ processNames = @(Get-RooPropertyArray $game 'processNames') }
        if (Test-RooProcessMatch $Process $match) {
            return [pscustomobject]@{
                matched = $true
                ruleId = (Get-RooPropertyValue (Get-RooPropertyValue $Profile 'foregroundGame' $null) 'ruleId' 'boost-foreground-game')
                reasonCodes = @(Get-RooPropertyArray $game 'reasonCodes')
            }
        }
    }

    return [pscustomobject]@{ matched = $false; ruleId = $null; reasonCodes = @() }
}

function Get-RooRuleMatch {
    param(
        [object]$Process,
        [object]$Profile,
        [string[]]$ActionTypes
    )
    foreach ($rule in @(Get-RooPropertyArray $Profile 'rules')) {
        $enabled = [bool](Get-RooPropertyValue $rule 'enabled' $true)
        if (-not $enabled) { continue }
        $action = Get-RooPropertyValue $rule 'action' $null
        $actionType = [string](Get-RooPropertyValue $action 'actionType' '')
        if ($ActionTypes.Count -gt 0 -and $actionType -notin $ActionTypes) { continue }
        if (Test-RooProcessMatch $Process (Get-RooPropertyValue $rule 'match' $null)) {
            return [pscustomobject]@{ matched = $true; rule = $rule }
        }
    }
    return [pscustomobject]@{ matched = $false; rule = $null }
}

function Get-RooSafeCandidateMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    foreach ($rule in @(Get-RooPropertyArray $Profile 'safeCandidates')) {
        if (Test-RooProcessMatch $Process (Get-RooPropertyValue $rule 'match' $null)) {
            return [pscustomobject]@{ matched = $true; rule = $rule }
        }
    }
    return [pscustomobject]@{ matched = $false; rule = $null }
}

function Test-RooProtectedPreviewName {
    param(
        [object]$Process,
        [object]$Profile
    )
    return Test-RooAnyNameMatch ([string]$Process.name) @(Get-RooPropertyArray $Profile 'protectedPreviewProcessNames')
}

function Add-RooReasonCode {
    param(
        [System.Collections.Generic.List[string]]$ReasonCodes,
        [object]$Values
    )
    foreach ($value in @(Get-RooArray $Values)) {
        if ($null -eq $value) { continue }
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text) -and -not $ReasonCodes.Contains($text)) {
            $ReasonCodes.Add($text) | Out-Null
        }
    }
}

function Get-RooProcessClassificationInfo {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog,
        [string]$TargetGameProcessName
    )
    $reasonCodes = New-Object System.Collections.Generic.List[string]
    $classification = 'unknown'
    $matchedRuleId = $null
    $matchedProtectedItemId = $null
    $matchedProfileItemId = $null
    $profileMatched = $false
    $sessionProfileMatched = $false
    $blocked = $false
    $protected = $false
    $risk = [string](Get-RooPropertyValue $Process 'risk' 'low')

    $companionMatch = Get-RooProtectedCompanionMatch $Process $Profile
    if ($companionMatch.matched) {
        $classification = 'protectedCompanion'
        $matchedProfileItemId = [string](Get-RooPropertyValue $companionMatch.item 'itemId' '')
        $profileMatched = $true
        $sessionProfileMatched = $true
        $blocked = $true
        $protected = $true
        $risk = 'protected'
        Add-RooReasonCode $reasonCodes (Get-RooPropertyArray $companionMatch.item 'reasonCodes')
    } else {
        $protectedMatch = Get-RooProtectedCatalogMatch $Process $ProtectedCatalog
        if ($protectedMatch.matched) {
            $catalogClassification = [string](Get-RooPropertyValue $protectedMatch.item 'classification' 'protected')
            if ($catalogClassification -eq 'protectedCompanion') {
                $classification = 'protectedCompanion'
            } else {
                $classification = 'protected'
            }
            $matchedProtectedItemId = [string](Get-RooPropertyValue $protectedMatch.item 'itemId' '')
            $sessionProfileMatched = Test-RooProtectedPreviewName $Process $Profile
            $blocked = $true
            $protected = $true
            $risk = 'protected'
            Add-RooReasonCode $reasonCodes (Get-RooPropertyArray $protectedMatch.item 'reasonCodes')
        } else {
            $targetMatch = Get-RooTargetGameMatch $Process $Profile $TargetGameProcessName
            if ($targetMatch.matched) {
                $classification = 'gameTarget'
                $matchedRuleId = [string]$targetMatch.ruleId
                $profileMatched = $true
                $sessionProfileMatched = $true
                $risk = 'medium'
                Add-RooReasonCode $reasonCodes $targetMatch.reasonCodes
                Add-RooReasonCode $reasonCodes @('GAME_TARGET')
            } else {
                $demotionMatch = Get-RooRuleMatch $Process $Profile @('setPriority')
                if ($demotionMatch.matched) {
                    $rulePriority = [string](Get-RooPropertyValue (Get-RooPropertyValue $demotionMatch.rule 'action' $null) 'priorityClass' '')
                    if ($rulePriority -eq 'BelowNormal' -or $rulePriority -eq 'Idle') {
                        $classification = 'demotionCandidate'
                        $matchedRuleId = [string](Get-RooPropertyValue $demotionMatch.rule 'ruleId' '')
                        $profileMatched = $true
                        $sessionProfileMatched = $true
                        $risk = [string](Get-RooPropertyValue $demotionMatch.rule 'risk' 'low')
                        Add-RooReasonCode $reasonCodes @('BACKGROUND_DEMOTION_CANDIDATE')
                    }
                }

                if ($classification -eq 'unknown') {
                    $safeMatch = Get-RooSafeCandidateMatch $Process $Profile
                    if ($safeMatch.matched) {
                        $classification = 'safeCandidate'
                        $matchedRuleId = [string](Get-RooPropertyValue $safeMatch.rule 'ruleId' '')
                        $profileMatched = $true
                        $sessionProfileMatched = $true
                        $risk = [string](Get-RooPropertyValue $safeMatch.rule 'risk' 'low')
                        Add-RooReasonCode $reasonCodes (Get-RooPropertyArray $safeMatch.rule 'reasonCodes')
                    }
                }

                if ($classification -eq 'unknown' -and [string](Get-RooPropertyValue $Process 'protection' '') -eq 'protected') {
                    $classification = 'protected'
                    $blocked = $true
                    $protected = $true
                    $risk = 'protected'
                    Add-RooReasonCode $reasonCodes @('INVENTORY_PROTECTED')
                }
            }
        }
    }

    if ($reasonCodes.Count -eq 0) {
        Add-RooReasonCode $reasonCodes @('NO_PROFILE_MATCH')
    }

    $canChangePriority = [bool](Get-RooPropertyValue $Process 'canChangePriority' $false)
    if ($protected -or $blocked) { $canChangePriority = $false }

    return [pscustomobject]@{
        classification = $classification
        reasonCodes = @($reasonCodes.ToArray())
        matchedRuleId = $matchedRuleId
        matchedProtectedItemId = $matchedProtectedItemId
        matchedProfileItemId = $matchedProfileItemId
        profileMatched = $profileMatched
        sessionProfileMatched = $sessionProfileMatched
        blocked = $blocked
        protected = $protected
        risk = $risk
        canChangePriority = $canChangePriority
    }
}

function Get-RooRuleById {
    param(
        [object]$Profile,
        [string]$RuleId
    )
    foreach ($rule in @(Get-RooPropertyArray $Profile 'rules')) {
        if ([string](Get-RooPropertyValue $rule 'ruleId' '') -eq $RuleId) { return $rule }
    }
    return $null
}

function New-RooIssue {
    param(
        [string]$Code,
        [string]$Message,
        [string]$Severity = 'warning',
        [string]$Source = 'performance.profile',
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

function New-RooLog {
    param(
        [string]$Message,
        [string]$Level = 'info'
    )
    return [pscustomobject]@{
        timestampUtc = Get-RooUtcStamp
        level = $Level
        message = $Message
    }
}

function New-RooActionResult {
    param(
        [string]$ResultId,
        [string]$Status,
        [string]$Summary,
        [object[]]$ChangedItems = @(),
        [object[]]$SkippedItems = @(),
        [object[]]$Artifacts = @()
    )
    return [pscustomobject]@{
        resultId = $ResultId
        status = $Status
        startedAtUtc = $null
        completedAtUtc = Get-RooUtcStamp
        summary = $Summary
        changedItems = @(Get-RooArray $ChangedItems)
        skippedItems = @(Get-RooArray $SkippedItems)
        metricsBefore = $null
        metricsAfter = $null
        artifacts = @(Get-RooArray $Artifacts)
    }
}

function New-RooActionEnvelope {
    param(
        [string]$ActionId,
        [bool]$DryRun,
        [string]$Risk = 'medium',
        [bool]$RequiresElevation = $false,
        [string]$Status = 'preview',
        [object[]]$Preview = @(),
        [object]$Backup = $null,
        [object]$Result = $null,
        [object[]]$Warnings = @(),
        [object[]]$Errors = @(),
        [object[]]$Logs = @(),
        [string]$CorrelationId = $null
    )
    return [pscustomobject]@{
        actionId = $ActionId
        schemaVersion = 1
        productName = $script:RooProcessProductName
        correlationId = $CorrelationId
        dryRun = $DryRun
        risk = $Risk
        requiresElevation = $RequiresElevation
        status = $Status
        preview = @(Get-RooArray $Preview)
        backup = $Backup
        result = $Result
        warnings = @(Get-RooArray $Warnings)
        errors = @(Get-RooArray $Errors)
        logs = @(Get-RooArray $Logs)
    }
}

function Test-RooPriorityAllowed {
    param([string]$PriorityClass)
    return $script:RooAllowedPriorityClasses -contains $PriorityClass
}

function Ensure-RooNativeProcessControl {
    if ('RooNativeProcessControl' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RooNativeProcessControl {
    [DllImport("gdi32.dll")]
    public static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int priorityClass);
    [DllImport("gdi32.dll")]
    public static extern int D3DKMTSetProcessSchedulingPriorityClass(IntPtr process, int priorityClass);
    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationProcess(IntPtr process, int informationClass, ref int information, int informationLength, IntPtr returnLength);
    [DllImport("ntdll.dll")]
    public static extern int NtSetInformationProcess(IntPtr process, int informationClass, ref int information, int informationLength);
}
"@
}

function Convert-RooIoPriorityToValue {
    param([string]$Priority)
    switch ($Priority) {
        'VeryLow' { return 0 }
        'Idle' { return 0 }
        'Low' { return 1 }
        'Normal' { return 2 }
        default { return $null }
    }
}

function Convert-RooIoPriorityFromValue {
    param([int]$Value)
    switch ($Value) {
        0 { return 'VeryLow' }
        1 { return 'Low' }
        2 { return 'Normal' }
        default { return "Unknown($Value)" }
    }
}

function Convert-RooGpuPriorityToValue {
    param([string]$Priority)
    switch ($Priority) {
        'Idle' { return 0 }
        'BelowNormal' { return 1 }
        'Normal' { return 2 }
        'AboveNormal' { return 3 }
        'High' { return 4 }
        'Realtime' { return 5 }
        'RealTime' { return 5 }
        default { return $null }
    }
}

function Convert-RooGpuPriorityFromValue {
    param([int]$Value)
    switch ($Value) {
        0 { return 'Idle' }
        1 { return 'BelowNormal' }
        2 { return 'Normal' }
        3 { return 'AboveNormal' }
        4 { return 'High' }
        5 { return 'Realtime' }
        default { return "Unknown($Value)" }
    }
}

function Test-RooIoPriorityAllowed {
    param([string]$Priority)
    return $null -ne (Convert-RooIoPriorityToValue $Priority)
}

function Test-RooGpuPriorityAllowed {
    param([string]$Priority)
    return $null -ne (Convert-RooGpuPriorityToValue $Priority)
}

function Test-RooAffinityMaskAllowed {
    param([object]$AffinityMask)
    if ($null -eq $AffinityMask) { return $false }
    try {
        $mask = [int64]$AffinityMask
        return $mask -gt 0
    } catch {
        return $false
    }
}

function Get-RooProcessIoPriority {
    param([System.Diagnostics.Process]$Process)
    Ensure-RooNativeProcessControl
    $value = 0
    $status = [RooNativeProcessControl]::NtQueryInformationProcess($Process.Handle, 33, [ref]$value, 4, [IntPtr]::Zero)
    if ($status -ne 0) {
        return [pscustomobject]@{ available = $false; value = $null; name = $null; status = $status }
    }
    return [pscustomobject]@{ available = $true; value = $value; name = Convert-RooIoPriorityFromValue $value; status = $status }
}

function Set-RooProcessIoPriority {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Priority
    )
    Ensure-RooNativeProcessControl
    $value = Convert-RooIoPriorityToValue $Priority
    if ($null -eq $value) { throw "I/O priority '$Priority' is outside the allow-list." }
    $status = [RooNativeProcessControl]::NtSetInformationProcess($Process.Handle, 33, [ref]$value, 4)
    if ($status -ne 0) { throw "Failed to set I/O priority '$Priority' (NTSTATUS $status)." }
}

function Get-RooProcessGpuPriority {
    param([System.Diagnostics.Process]$Process)
    Ensure-RooNativeProcessControl
    $value = 0
    $status = [RooNativeProcessControl]::D3DKMTGetProcessSchedulingPriorityClass($Process.Handle, [ref]$value)
    if ($status -ne 0) {
        return [pscustomobject]@{ available = $false; value = $null; name = $null; status = $status }
    }
    return [pscustomobject]@{ available = $true; value = $value; name = Convert-RooGpuPriorityFromValue $value; status = $status }
}

function Set-RooProcessGpuPriority {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Priority
    )
    Ensure-RooNativeProcessControl
    $value = Convert-RooGpuPriorityToValue $Priority
    if ($null -eq $value) { throw "GPU priority '$Priority' is outside the allow-list." }
    $status = [RooNativeProcessControl]::D3DKMTSetProcessSchedulingPriorityClass($Process.Handle, $value)
    if ($status -ne 0) { throw "Failed to set GPU priority '$Priority' (status $status)." }
}

function Get-RooProcessStartTimeUtc {
    param([System.Diagnostics.Process]$Process)
    try {
        return $Process.StartTime.ToUniversalTime().ToString('o')
    } catch {
        return $null
    }
}

function Get-RooProcessControlState {
    param(
        [int]$ProcessId,
        [string]$FallbackPriorityClass = $null
    )
    $live = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $live) {
        return [pscustomobject]@{
            exists = $false
            process = $null
            priorityClass = $FallbackPriorityClass
            affinityMask = $null
            ioPriority = $null
            gpuPriority = $null
            startTimeUtc = $null
        }
    }

    $priority = $FallbackPriorityClass
    try { $priority = [string]$live.PriorityClass } catch { }
    $affinity = $null
    try { $affinity = [int64]$live.ProcessorAffinity } catch { }
    $io = [pscustomobject]@{ available = $false; value = $null; name = $null; status = $null }
    try { $io = Get-RooProcessIoPriority $live } catch { }
    $gpu = [pscustomobject]@{ available = $false; value = $null; name = $null; status = $null }
    try { $gpu = Get-RooProcessGpuPriority $live } catch { }

    return [pscustomobject]@{
        exists = $true
        process = $live
        priorityClass = $priority
        affinityMask = $affinity
        ioPriority = if ($io.available) { $io.name } else { $null }
        gpuPriority = if ($gpu.available) { $gpu.name } else { $null }
        startTimeUtc = Get-RooProcessStartTimeUtc $live
        ioPriorityAvailable = [bool]$io.available
        gpuPriorityAvailable = [bool]$gpu.available
        ioPriorityStatus = $io.status
        gpuPriorityStatus = $gpu.status
    }
}

function New-RooControlChange {
    param(
        [string]$Control,
        [object]$CurrentValue,
        [object]$ProposedValue,
        [string]$Action,
        [string]$Reason,
        [bool]$Blocked = $false,
        [string]$BlockedReason = $null
    )
    return [pscustomobject]@{
        control = $Control
        currentValue = $CurrentValue
        proposedValue = $ProposedValue
        action = $Action
        reason = $Reason
        blocked = $Blocked
        blockedReason = $BlockedReason
    }
}

function Get-RooPreviewControlChanges {
    param([object]$PreviewEntry)
    $changes = @(Get-RooPropertyArray $PreviewEntry 'controlChanges')
    if ($changes.Count -gt 0) { return $changes }
    if ([string](Get-RooPropertyValue $PreviewEntry 'proposedAction' '') -eq 'setPriority') {
        return @((New-RooControlChange `
            -Control 'priorityClass' `
            -CurrentValue (Get-RooPropertyValue $PreviewEntry 'currentPriorityClass' $null) `
            -ProposedValue (Get-RooPropertyValue $PreviewEntry 'proposedPriorityClass' $null) `
            -Action 'setPriority' `
            -Reason (Get-RooPropertyValue $PreviewEntry 'reason' 'Set process priority.')))
    }
    return @()
}

function Get-RooControlStateValue {
    param(
        [object]$State,
        [string]$Control
    )
    switch ($Control) {
        'priorityClass' { return Get-RooPropertyValue $State 'priorityClass' $null }
        'affinityMask' { return Get-RooPropertyValue $State 'affinityMask' $null }
        'ioPriority' { return Get-RooPropertyValue $State 'ioPriority' $null }
        'gpuPriority' { return Get-RooPropertyValue $State 'gpuPriority' $null }
        default { return $null }
    }
}

function Test-RooControlValueEqual {
    param(
        [string]$Control,
        [object]$Left,
        [object]$Right
    )
    if ($Control -eq 'affinityMask') {
        if ($null -eq $Left -or $null -eq $Right) { return $false }
        try { return [int64]$Left -eq [int64]$Right } catch { return $false }
    }
    return [string]$Left -eq [string]$Right
}

function Get-RooControlChangeValidationReason {
    param(
        [object]$Change,
        [object]$CurrentState
    )
    $control = [string](Get-RooPropertyValue $Change 'control' '')
    $value = Get-RooPropertyValue $Change 'proposedValue' $null
    switch ($control) {
        'priorityClass' {
            if (-not (Test-RooPriorityAllowed ([string]$value))) { return "Priority class '$value' is outside the allow-list." }
            if ([string]::IsNullOrWhiteSpace([string](Get-RooControlStateValue $CurrentState $control))) { return 'Current priority class could not be read, so no priority change is proposed.' }
        }
        'affinityMask' {
            if (-not (Test-RooAffinityMaskAllowed $value)) { return "Affinity mask '$value' is invalid." }
            if ($null -eq (Get-RooControlStateValue $CurrentState $control)) { return 'Current CPU affinity could not be read, so no affinity change is proposed.' }
        }
        'ioPriority' {
            if (-not (Test-RooIoPriorityAllowed ([string]$value))) { return "I/O priority '$value' is outside the allow-list." }
            if ([string]::IsNullOrWhiteSpace([string](Get-RooControlStateValue $CurrentState $control))) { return 'Current I/O priority could not be read, so no I/O priority change is proposed.' }
        }
        'gpuPriority' {
            if (-not (Test-RooGpuPriorityAllowed ([string]$value))) { return "GPU priority '$value' is outside the allow-list." }
            if (-not [bool](Get-RooPropertyValue $CurrentState 'gpuPriorityAvailable' $false)) { return 'GPU scheduling priority is unavailable for this process.' }
        }
        default {
            return "Unsupported process control '$control'."
        }
    }
    return $null
}

function Get-RooApplicableProcessControlChanges {
    param(
        [object[]]$ControlChanges,
        [object]$CurrentState
    )
    $applicable = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    foreach ($change in @(Get-RooArray $ControlChanges)) {
        $control = [string](Get-RooPropertyValue $change 'control' '')
        if ([bool](Get-RooPropertyValue $change 'blocked' $false)) {
            $reason = [string](Get-RooPropertyValue $change 'blockedReason' (Get-RooPropertyValue $change 'reason' 'Requested process control is blocked.'))
            $skipped.Add([pscustomobject]@{ control = $control; reason = $reason; currentValue = Get-RooPropertyValue $change 'currentValue' $null; proposedValue = Get-RooPropertyValue $change 'proposedValue' $null; category = 'blocked' }) | Out-Null
            continue
        }

        $validationReason = Get-RooControlChangeValidationReason $change $CurrentState
        if (-not [string]::IsNullOrWhiteSpace($validationReason)) {
            $skipped.Add([pscustomobject]@{ control = $control; reason = $validationReason; currentValue = Get-RooControlStateValue $CurrentState $control; proposedValue = Get-RooPropertyValue $change 'proposedValue' $null; category = 'unavailable' }) | Out-Null
            continue
        }

        $currentValue = Get-RooControlStateValue $CurrentState $control
        $proposedValue = Get-RooPropertyValue $change 'proposedValue' $null
        if (Test-RooControlValueEqual $control $currentValue $proposedValue) {
            $skipped.Add([pscustomobject]@{ control = $control; reason = "Process already has requested $control value."; currentValue = $currentValue; proposedValue = $proposedValue; category = 'no-change' }) | Out-Null
            continue
        }

        $applicable.Add($change) | Out-Null
    }
    return [pscustomobject]@{
        changes = @($applicable.ToArray())
        skippedControls = @($skipped.ToArray())
    }
}

function Invoke-RooProcessControlChange {
    param(
        [System.Diagnostics.Process]$Process,
        [object]$Change
    )
    $control = [string](Get-RooPropertyValue $Change 'control' '')
    $value = Get-RooPropertyValue $Change 'proposedValue' $null
    switch ($control) {
        'priorityClass' {
            $priority = [string]$value
            if (-not (Test-RooPriorityAllowed $priority)) { throw "Priority class '$priority' is outside the allow-list." }
            $Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$priority
        }
        'affinityMask' {
            if (-not (Test-RooAffinityMaskAllowed $value)) { throw "Affinity mask '$value' is invalid." }
            $Process.ProcessorAffinity = [IntPtr]([int64]$value)
        }
        'ioPriority' {
            $priority = [string]$value
            if (-not (Test-RooIoPriorityAllowed $priority)) { throw "I/O priority '$priority' is outside the allow-list." }
            Set-RooProcessIoPriority $Process $priority
        }
        'gpuPriority' {
            $priority = [string]$value
            if (-not (Test-RooGpuPriorityAllowed $priority)) { throw "GPU priority '$priority' is outside the allow-list." }
            Set-RooProcessGpuPriority $Process $priority
        }
        default {
            throw "Unsupported process control '$control'."
        }
    }
}
