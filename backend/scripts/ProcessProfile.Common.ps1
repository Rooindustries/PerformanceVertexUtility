. (Join-Path $PSScriptRoot 'GovernorOwnership.Common.ps1')
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
$script:RooIndustriesProcessProductName = 'Roo Industries Optimization Suite'
$script:RooIndustriesAllowedPriorityClasses = @('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High')
$script:RooIndustriesAllowedIoPriorities = @('VeryLow', 'Low', 'Normal')
$script:RooIndustriesAllowedMemoryPriorities = @(1, 2, 3, 4, 5)
$script:RooIndustriesAllowedGpuPriorities = @('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High', 'Realtime')

function ConvertTo-RooIndustriesWindowsArgument {
    param([string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Join-RooIndustriesWindowsArguments {
    param([string[]]$Arguments)
    return (@($Arguments | ForEach-Object { ConvertTo-RooIndustriesWindowsArgument $_ }) -join ' ')
}

function Get-RooIndustriesUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-RooIndustriesFileStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
}

function Resolve-RooIndustriesPath {
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

function Read-RooIndustriesJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Ensure-RooIndustriesDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-RooIndustriesJsonOutput {
    param(
        [object]$Value,
        [string]$OutputPath
    )
    $json = $Value | ConvertTo-Json -Depth 24
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolved = Resolve-RooIndustriesPath $OutputPath (Join-Path (Get-Location) $OutputPath)
        Ensure-RooIndustriesDirectory (Split-Path $resolved -Parent)
        $json | Set-Content -LiteralPath $resolved -Encoding UTF8
    }
    return $json
}

function Get-RooIndustriesArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-RooIndustriesPropertyArray {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return @() }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return @() }
    return @(Get-RooIndustriesArray $prop.Value)
}

function Get-RooIndustriesPropertyValue {
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

function Get-RooIndustriesNormalizedProcessName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.Trim().ToLowerInvariant()
    if ($n.EndsWith('.exe')) {
        return $n.Substring(0, $n.Length - 4)
    }
    return $n
}

function Test-RooIndustriesProcessNameEquals {
    param(
        [string]$Left,
        [string]$Right
    )
    return (Get-RooIndustriesNormalizedProcessName $Left) -eq (Get-RooIndustriesNormalizedProcessName $Right)
}

function Test-RooIndustriesAnyNameMatch {
    param(
        [string]$ProcessName,
        [object[]]$Names
    )
    foreach ($name in @(Get-RooIndustriesArray $Names)) {
        if (Test-RooIndustriesProcessNameEquals $ProcessName ([string]$name)) { return $true }
    }
    return $false
}

function Test-RooIndustriesAnyWildcardMatch {
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

function Test-RooIndustriesProcessMatch {
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
    $names += Get-RooIndustriesPropertyArray $Match 'names'
    $names += Get-RooIndustriesPropertyArray $Match 'processNames'
    if ($names.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooIndustriesAnyNameMatch $processName $names) { $matched = $true }
    }

    $namePatterns = Get-RooIndustriesPropertyArray $Match 'namePatterns'
    if ($namePatterns.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooIndustriesAnyWildcardMatch $processName $namePatterns) { $matched = $true }
    }

    $pathPatterns = Get-RooIndustriesPropertyArray $Match 'pathPatterns'
    if ($pathPatterns.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooIndustriesAnyWildcardMatch $processPath $pathPatterns) { $matched = $true }
    }

    $commandLinePatterns = Get-RooIndustriesPropertyArray $Match 'commandLinePatterns'
    if ($commandLinePatterns.Count -gt 0) {
        $hasPositiveSelector = $true
        if (Test-RooIndustriesAnyWildcardMatch $commandLine $commandLinePatterns) { $matched = $true }
    }

    $categories = Get-RooIndustriesPropertyArray $Match 'processCategories'
    if ($categories.Count -gt 0) {
        $hasPositiveSelector = $true
        foreach ($candidate in $categories) {
            if ($category -eq [string]$candidate) { $matched = $true }
        }
    }

    if (-not $hasPositiveSelector -or -not $matched) { return $false }

    $excludeNames = Get-RooIndustriesPropertyArray $Match 'excludeProcessNames'
    if ($excludeNames.Count -gt 0 -and (Test-RooIndustriesAnyNameMatch $processName $excludeNames)) { return $false }

    $excludeNamePatterns = Get-RooIndustriesPropertyArray $Match 'excludeNamePatterns'
    if ($excludeNamePatterns.Count -gt 0 -and (Test-RooIndustriesAnyWildcardMatch $processName $excludeNamePatterns)) { return $false }

    $excludeCategories = Get-RooIndustriesPropertyArray $Match 'excludeProcessCategories'
    foreach ($candidate in $excludeCategories) {
        if ($category -eq [string]$candidate) { return $false }
    }

    return $true
}

function Get-RooIndustriesProtectedCatalogMatch {
    param(
        [object]$Process,
        [object]$ProtectedCatalog
    )
    foreach ($item in @(Get-RooIndustriesPropertyArray $ProtectedCatalog 'protectedProcesses')) {
        $match = [pscustomobject]@{
            names = @(Get-RooIndustriesPropertyArray $item 'names')
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

function Get-RooIndustriesProtectedCompanionMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    foreach ($item in @(Get-RooIndustriesPropertyArray $Profile 'protectedCompanions')) {
        $match = [pscustomobject]@{
            names = @(Get-RooIndustriesPropertyArray $item 'names')
            processNames = @([string](Get-RooIndustriesPropertyValue $item 'name' ''))
        }
        if (Test-RooIndustriesProcessMatch $Process $match) {
            return [pscustomobject]@{ matched = $true; item = $item }
        }
    }
    return [pscustomobject]@{ matched = $false; item = $null }
}

function Get-RooIndustriesTargetGameMatch {
    param(
        [object]$Process,
        [object]$Profile,
        [string]$TargetGameProcessName
    )
    if (-not [string]::IsNullOrWhiteSpace($TargetGameProcessName)) {
        if (Test-RooIndustriesProcessNameEquals ([string]$Process.name) $TargetGameProcessName) {
            return [pscustomobject]@{
                matched = $true
                ruleId = (Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Profile 'foregroundGame' $null) 'ruleId' 'boost-foreground-game')
                reasonCodes = @('TARGET_GAME_PARAMETER')
            }
        }
    }

    $foregroundGame = Get-RooIndustriesPropertyValue $Profile 'foregroundGame' $null
    if ($foregroundGame) {
        $match = [pscustomobject]@{ processNames = @(Get-RooIndustriesPropertyArray $foregroundGame 'processNames') }
        if (Test-RooIndustriesProcessMatch $Process $match) {
            return [pscustomobject]@{
                matched = $true
                ruleId = (Get-RooIndustriesPropertyValue $foregroundGame 'ruleId' 'boost-foreground-game')
                reasonCodes = @(Get-RooIndustriesPropertyArray $foregroundGame 'reasonCodes')
            }
        }
    }

    foreach ($game in @(Get-RooIndustriesPropertyArray $Profile 'targetGames')) {
        $match = [pscustomobject]@{ processNames = @(Get-RooIndustriesPropertyArray $game 'processNames') }
        if (Test-RooIndustriesProcessMatch $Process $match) {
            return [pscustomobject]@{
                matched = $true
                ruleId = (Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $Profile 'foregroundGame' $null) 'ruleId' 'boost-foreground-game')
                reasonCodes = @(Get-RooIndustriesPropertyArray $game 'reasonCodes')
            }
        }
    }

    return [pscustomobject]@{ matched = $false; ruleId = $null; reasonCodes = @() }
}

function Get-RooIndustriesRuleMatch {
    param(
        [object]$Process,
        [object]$Profile,
        [string[]]$ActionTypes
    )
    foreach ($rule in @(Get-RooIndustriesPropertyArray $Profile 'rules')) {
        $enabled = [bool](Get-RooIndustriesPropertyValue $rule 'enabled' $true)
        if (-not $enabled) { continue }
        $action = Get-RooIndustriesPropertyValue $rule 'action' $null
        $actionType = [string](Get-RooIndustriesPropertyValue $action 'actionType' '')
        if ($ActionTypes.Count -gt 0 -and $actionType -notin $ActionTypes) { continue }
        if (Test-RooIndustriesProcessMatch $Process (Get-RooIndustriesPropertyValue $rule 'match' $null)) {
            return [pscustomobject]@{ matched = $true; rule = $rule }
        }
    }
    return [pscustomobject]@{ matched = $false; rule = $null }
}

function Get-RooIndustriesSafeCandidateMatch {
    param(
        [object]$Process,
        [object]$Profile
    )
    foreach ($rule in @(Get-RooIndustriesPropertyArray $Profile 'safeCandidates')) {
        if (Test-RooIndustriesProcessMatch $Process (Get-RooIndustriesPropertyValue $rule 'match' $null)) {
            return [pscustomobject]@{ matched = $true; rule = $rule }
        }
    }
    return [pscustomobject]@{ matched = $false; rule = $null }
}

function Test-RooIndustriesProtectedPreviewName {
    param(
        [object]$Process,
        [object]$Profile
    )
    return Test-RooIndustriesAnyNameMatch ([string]$Process.name) @(Get-RooIndustriesPropertyArray $Profile 'protectedPreviewProcessNames')
}

function Add-RooIndustriesReasonCode {
    param(
        [System.Collections.Generic.List[string]]$ReasonCodes,
        [object]$Values
    )
    foreach ($value in @(Get-RooIndustriesArray $Values)) {
        if ($null -eq $value) { continue }
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text) -and -not $ReasonCodes.Contains($text)) {
            $ReasonCodes.Add($text) | Out-Null
        }
    }
}

function Get-RooIndustriesProcessClassificationInfo {
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
    $risk = [string](Get-RooIndustriesPropertyValue $Process 'risk' 'low')

    $companionMatch = Get-RooIndustriesProtectedCompanionMatch $Process $Profile
    if ($companionMatch.matched) {
        $classification = 'protectedCompanion'
        $matchedProfileItemId = [string](Get-RooIndustriesPropertyValue $companionMatch.item 'itemId' '')
        $profileMatched = $true
        $sessionProfileMatched = $true
        $blocked = $true
        $protected = $true
        $risk = 'protected'
        Add-RooIndustriesReasonCode $reasonCodes (Get-RooIndustriesPropertyArray $companionMatch.item 'reasonCodes')
    } else {
        $protectedMatch = Get-RooIndustriesProtectedCatalogMatch $Process $ProtectedCatalog
        if ($protectedMatch.matched) {
            $catalogClassification = [string](Get-RooIndustriesPropertyValue $protectedMatch.item 'classification' 'protected')
            if ($catalogClassification -eq 'protectedCompanion') {
                $classification = 'protectedCompanion'
            } else {
                $classification = 'protected'
            }
            $matchedProtectedItemId = [string](Get-RooIndustriesPropertyValue $protectedMatch.item 'itemId' '')
            $sessionProfileMatched = Test-RooIndustriesProtectedPreviewName $Process $Profile
            $blocked = $true
            $protected = $true
            $risk = 'protected'
            Add-RooIndustriesReasonCode $reasonCodes (Get-RooIndustriesPropertyArray $protectedMatch.item 'reasonCodes')
        } else {
            $targetMatch = Get-RooIndustriesTargetGameMatch $Process $Profile $TargetGameProcessName
            if ($targetMatch.matched) {
                $classification = 'gameTarget'
                $matchedRuleId = [string]$targetMatch.ruleId
                $profileMatched = $true
                $sessionProfileMatched = $true
                $risk = 'medium'
                Add-RooIndustriesReasonCode $reasonCodes $targetMatch.reasonCodes
                Add-RooIndustriesReasonCode $reasonCodes @('GAME_TARGET')
            } else {
                $demotionMatch = Get-RooIndustriesRuleMatch $Process $Profile @('setPriority')
                if ($demotionMatch.matched) {
                    $rulePriority = [string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $demotionMatch.rule 'action' $null) 'priorityClass' '')
                    if ($rulePriority -eq 'BelowNormal' -or $rulePriority -eq 'Idle') {
                        $classification = 'demotionCandidate'
                        $matchedRuleId = [string](Get-RooIndustriesPropertyValue $demotionMatch.rule 'ruleId' '')
                        $profileMatched = $true
                        $sessionProfileMatched = $true
                        $risk = [string](Get-RooIndustriesPropertyValue $demotionMatch.rule 'risk' 'low')
                        Add-RooIndustriesReasonCode $reasonCodes @('BACKGROUND_DEMOTION_CANDIDATE')
                    }
                }

                if ($classification -eq 'unknown') {
                    $safeMatch = Get-RooIndustriesSafeCandidateMatch $Process $Profile
                    if ($safeMatch.matched) {
                        $classification = 'safeCandidate'
                        $matchedRuleId = [string](Get-RooIndustriesPropertyValue $safeMatch.rule 'ruleId' '')
                        $profileMatched = $true
                        $sessionProfileMatched = $true
                        $risk = [string](Get-RooIndustriesPropertyValue $safeMatch.rule 'risk' 'low')
                        Add-RooIndustriesReasonCode $reasonCodes (Get-RooIndustriesPropertyArray $safeMatch.rule 'reasonCodes')
                    }
                }

                if ($classification -eq 'unknown' -and [string](Get-RooIndustriesPropertyValue $Process 'protection' '') -eq 'protected') {
                    $classification = 'protected'
                    $blocked = $true
                    $protected = $true
                    $risk = 'protected'
                    Add-RooIndustriesReasonCode $reasonCodes @('INVENTORY_PROTECTED')
                }
            }
        }
    }

    if ($reasonCodes.Count -eq 0) {
        Add-RooIndustriesReasonCode $reasonCodes @('NO_PROFILE_MATCH')
    }

    $canChangePriority = [bool](Get-RooIndustriesPropertyValue $Process 'canChangePriority' $false)
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

function Get-RooIndustriesRuleById {
    param(
        [object]$Profile,
        [string]$RuleId
    )
    foreach ($rule in @(Get-RooIndustriesPropertyArray $Profile 'rules')) {
        if ([string](Get-RooIndustriesPropertyValue $rule 'ruleId' '') -eq $RuleId) { return $rule }
    }
    return $null
}

function New-RooIndustriesIssue {
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

function New-RooIndustriesLog {
    param(
        [string]$Message,
        [string]$Level = 'info'
    )
    return [pscustomobject]@{
        timestampUtc = Get-RooIndustriesUtcStamp
        level = $Level
        message = $Message
    }
}

function New-RooIndustriesActionResult {
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
        completedAtUtc = Get-RooIndustriesUtcStamp
        summary = $Summary
        changedItems = @(Get-RooIndustriesArray $ChangedItems)
        skippedItems = @(Get-RooIndustriesArray $SkippedItems)
        metricsBefore = $null
        metricsAfter = $null
        artifacts = @(Get-RooIndustriesArray $Artifacts)
    }
}

function New-RooIndustriesActionEnvelope {
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
        productName = $script:RooIndustriesProcessProductName
        correlationId = $CorrelationId
        dryRun = $DryRun
        risk = $Risk
        requiresElevation = $RequiresElevation
        status = $Status
        preview = @(Get-RooIndustriesArray $Preview)
        backup = $Backup
        result = $Result
        warnings = @(Get-RooIndustriesArray $Warnings)
        errors = @(Get-RooIndustriesArray $Errors)
        logs = @(Get-RooIndustriesArray $Logs)
    }
}

function Test-RooIndustriesPriorityAllowed {
    param([string]$PriorityClass,[switch]$Restoring)
    return $script:RooIndustriesAllowedPriorityClasses -contains $PriorityClass -or ($Restoring -and $PriorityClass -eq 'RealTime')
}

function Ensure-RooIndustriesNativeProcessControl {
    if ('RooIndustriesNativeProcessControl' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesNativeProcessControl {
    [DllImport("gdi32.dll")]
    public static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int priorityClass);
    [DllImport("gdi32.dll")]
    public static extern int D3DKMTSetProcessSchedulingPriorityClass(IntPtr process, int priorityClass);
    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationProcess(IntPtr process, int informationClass, ref int information, int informationLength, IntPtr returnLength);
    [DllImport("ntdll.dll")]
    public static extern int NtSetInformationProcess(IntPtr process, int informationClass, ref int information, int informationLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessInformation(IntPtr process, int informationClass, out uint information, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetProcessInformation(IntPtr process, int informationClass, ref uint information, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessAffinityMask(IntPtr process, out IntPtr processMask, out IntPtr systemMask);
    [DllImport("kernel32.dll")]
    public static extern ushort GetActiveProcessorGroupCount();
}
public sealed class RooIndustriesIoPriorityPrivilege : IDisposable {
    private Microsoft.Win32.SafeHandles.SafeFileHandle token;
    private TokenPrivileges previous;
    public RooIndustriesIoPriorityPrivilege() {
        try {
            if (!OpenProcessToken(new IntPtr(-1), 0x28, out token)) throw new System.ComponentModel.Win32Exception();
            Luid luid;
            if (!LookupPrivilegeValue(null, "SeIncreaseBasePriorityPrivilege", out luid)) throw new System.ComponentModel.Win32Exception();
            var request = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
            int needed;
            if (!AdjustTokenPrivileges(token, false, ref request, Marshal.SizeOf(typeof(TokenPrivileges)), out previous, out needed)) throw new System.ComponentModel.Win32Exception();
            int error = Marshal.GetLastWin32Error();
            if (error != 0) throw new System.ComponentModel.Win32Exception(error);
        } catch { Dispose(); throw; }
    }
    public void Dispose() {
        if (token == null || token.IsClosed) return;
        try {
            if (previous.Count != 0) {
                bool restored = RestoreTokenPrivileges(token, false, ref previous, 0, IntPtr.Zero, IntPtr.Zero);
                if ((!restored || Marshal.GetLastWin32Error() != 0) &&
                    (!RestoreTokenPrivileges(token, false, ref previous, 0, IntPtr.Zero, IntPtr.Zero) || Marshal.GetLastWin32Error() != 0))
                    Environment.FailFast("The I/O priority privilege could not be returned to its original state.");
            }
        } finally { token.Dispose(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] private struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out Microsoft.Win32.SafeHandles.SafeFileHandle token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool AdjustTokenPrivileges(Microsoft.Win32.SafeHandles.SafeFileHandle token, bool disableAll, ref TokenPrivileges request, int size, out TokenPrivileges previous, out int needed);
    [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)] private static extern bool RestoreTokenPrivileges(Microsoft.Win32.SafeHandles.SafeFileHandle token, bool disableAll, ref TokenPrivileges request, int size, IntPtr previous, IntPtr needed);
}
"@
}

function Convert-RooIndustriesIoPriorityToValue {
    param([string]$Priority,[switch]$Restoring)
    switch ($Priority) {
        'VeryLow' { return 0 }
        'Idle' { return 0 }
        'Low' { return 1 }
        'Normal' { return 2 }
        'High' { if($Restoring){return 3};return $null }
        default { return $null }
    }
}

function Convert-RooIndustriesIoPriorityFromValue {
    param([int]$Value)
    switch ($Value) {
        0 { return 'VeryLow' }
        1 { return 'Low' }
        2 { return 'Normal' }
        3 { return 'High' }
        default { return "Unknown($Value)" }
    }
}

function Convert-RooIndustriesGpuPriorityToValue {
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

function Convert-RooIndustriesGpuPriorityFromValue {
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

function Test-RooIndustriesIoPriorityAllowed {
    param([string]$Priority,[switch]$Restoring)
    return $null -ne (Convert-RooIndustriesIoPriorityToValue $Priority -Restoring:$Restoring)
}

function Test-RooIndustriesGpuPriorityAllowed {
    param([string]$Priority)
    return $null -ne (Convert-RooIndustriesGpuPriorityToValue $Priority)
}

function Test-RooIndustriesAffinityMaskAllowed {
    param([object]$AffinityMask)
    if ($null -eq $AffinityMask) { return $false }
    try {
        $mask = [int64]$AffinityMask
        return $mask -ne 0
    } catch {
        return $false
    }
}

function Convert-RooIndustriesMemoryPriorityName {
    param([int]$Priority)
    switch($Priority) {
        1 { return 'VeryLow' }
        2 { return 'Low' }
        3 { return 'Medium' }
        4 { return 'BelowNormal' }
        5 { return 'Normal' }
        default { return "Unknown($Priority)" }
    }
}

function Test-RooIndustriesMemoryPriorityAllowed {
    param([object]$Priority)
    return $null -ne $Priority -and [string]$Priority -match '^[1-5]$' -and $script:RooIndustriesAllowedMemoryPriorities -contains [int]$Priority
}

function Get-RooIndustriesProcessMemoryPriority {
    param([System.Diagnostics.Process]$Process)
    Ensure-RooIndustriesNativeProcessControl
    [uint32]$value=0
    $available=[RooIndustriesNativeProcessControl]::GetProcessInformation($Process.Handle,0,[ref]$value,4)
    $status=if($available){0}else{[Runtime.InteropServices.Marshal]::GetLastWin32Error()}
    return [pscustomobject]@{available=$available;value=if($available){[int]$value}else{$null};name=if($available){Convert-RooIndustriesMemoryPriorityName $value}else{$null};status=$status}
}

function Set-RooIndustriesProcessMemoryPriority {
    param([System.Diagnostics.Process]$Process,[object]$Priority)
    if(-not(Test-RooIndustriesMemoryPriorityAllowed $Priority)){throw "Memory priority '$Priority' is outside the allow-list."}
    Ensure-RooIndustriesNativeProcessControl
    [uint32]$value=$Priority
    if(-not[RooIndustriesNativeProcessControl]::SetProcessInformation($Process.Handle,0,[ref]$value,4)) {
        throw "Failed to set memory priority '$Priority' (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
}

function Get-RooIndustriesProcessIoPriority {
    param([System.Diagnostics.Process]$Process)
    Ensure-RooIndustriesNativeProcessControl
    $value = 0
    $status = [RooIndustriesNativeProcessControl]::NtQueryInformationProcess($Process.Handle, 33, [ref]$value, 4, [IntPtr]::Zero)
    if ($status -ne 0) {
        return [pscustomobject]@{ available = $false; value = $null; name = $null; status = $status }
    }
    return [pscustomobject]@{ available = $true; value = $value; name = Convert-RooIndustriesIoPriorityFromValue $value; status = $status }
}

function Set-RooIndustriesProcessIoPriority {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Priority,
        [switch]$Restoring
    )
    Ensure-RooIndustriesNativeProcessControl
    $value = Convert-RooIndustriesIoPriorityToValue $Priority -Restoring:$Restoring
    if ($null -eq $value) { throw "I/O priority '$Priority' is outside the allow-list." }
    $privilege=$null
    try {
        if($value -eq 3){$privilege=[RooIndustriesIoPriorityPrivilege]::new()}
        $status = [RooIndustriesNativeProcessControl]::NtSetInformationProcess($Process.Handle, 33, [ref]$value, 4)
    } finally {if($privilege){$privilege.Dispose()}}
    if ($status -ne 0) { throw "Failed to set I/O priority '$Priority' (NTSTATUS $status)." }
}

function Get-RooIndustriesProcessGpuPriority {
    param([System.Diagnostics.Process]$Process)
    Ensure-RooIndustriesNativeProcessControl
    $value = 0
    $status = [RooIndustriesNativeProcessControl]::D3DKMTGetProcessSchedulingPriorityClass($Process.Handle, [ref]$value)
    if ($status -ne 0) {
        return [pscustomobject]@{ available = $false; value = $null; name = $null; status = $status }
    }
    return [pscustomobject]@{ available = $true; value = $value; name = Convert-RooIndustriesGpuPriorityFromValue $value; status = $status }
}

function Set-RooIndustriesProcessGpuPriority {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Priority
    )
    Ensure-RooIndustriesNativeProcessControl
    $value = Convert-RooIndustriesGpuPriorityToValue $Priority
    if ($null -eq $value) { throw "GPU priority '$Priority' is outside the allow-list." }
    $status = [RooIndustriesNativeProcessControl]::D3DKMTSetProcessSchedulingPriorityClass($Process.Handle, $value)
    if ($status -ne 0) { throw "Failed to set GPU priority '$Priority' (status $status)." }
}

function Get-RooIndustriesProcessStartTimeUtc {
    param([System.Diagnostics.Process]$Process)
    try {
        return $Process.StartTime.ToUniversalTime().ToString('o')
    } catch {
        return $null
    }
}

function Get-RooIndustriesProcessControlState {
    param(
        [int]$ProcessId,
        [string]$FallbackPriorityClass = $null,
        [System.Diagnostics.Process]$Process = $null
    )
    $live = if ($null -ne $Process) { $Process } else { Get-Process -Id $ProcessId -ErrorAction SilentlyContinue }
    if ($null -eq $live) {
        return [pscustomobject]@{
            exists = $false
            process = $null
            priorityClass = $FallbackPriorityClass
            affinityMask = $null
            ioPriority = $null
            memoryPriority = $null
            gpuPriority = $null
            startTimeUtc = $null
        }
    }

    $live.Refresh()
    $priority = $FallbackPriorityClass
    try { $priority = [string]$live.PriorityClass } catch { }
    $affinity = $null
    try { $affinity = [int64]$live.ProcessorAffinity } catch { }
    $io = [pscustomobject]@{ available = $false; value = $null; name = $null; status = $null }
    try { $io = Get-RooIndustriesProcessIoPriority $live } catch { }
    $gpu = [pscustomobject]@{ available = $false; value = $null; name = $null; status = $null }
    try { $gpu = Get-RooIndustriesProcessGpuPriority $live } catch { }
    $memory = [pscustomobject]@{ available = $false; value = $null; name = $null; status = $null }
    try { $memory = Get-RooIndustriesProcessMemoryPriority $live } catch { $memory.status = $_.Exception.Message }
    $systemAffinity=$null
    try {
        Ensure-RooIndustriesNativeProcessControl
        $processMask=[IntPtr]::Zero;$systemMask=[IntPtr]::Zero
        if([RooIndustriesNativeProcessControl]::GetProcessAffinityMask($live.Handle,[ref]$processMask,[ref]$systemMask)){$systemAffinity=$systemMask.ToInt64()}
    } catch { }

    return [pscustomobject]@{
        exists = $true
        process = $live
        priorityClass = $priority
        affinityMask = $affinity
        ioPriority = if ($io.available) { $io.name } else { $null }
        memoryPriority = if ($memory.available) { $memory.value } else { $null }
        memoryPriorityName = $memory.name
        memoryPriorityAvailable = [bool]$memory.available
        memoryPriorityStatus = $memory.status
        systemAffinityMask = $systemAffinity
        gpuPriority = if ($gpu.available) { $gpu.name } else { $null }
        startTimeUtc = Get-RooIndustriesProcessStartTimeUtc $live
        ioPriorityAvailable = [bool]$io.available
        gpuPriorityAvailable = [bool]$gpu.available
        ioPriorityStatus = $io.status
        gpuPriorityStatus = $gpu.status
    }
}

function New-RooIndustriesControlChange {
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
        outcome = 'pending'
    }
}

function Get-RooIndustriesPreviewControlChanges {
    param([object]$PreviewEntry)
    $changes = @(Get-RooIndustriesPropertyArray $PreviewEntry 'controlChanges')
    if ($changes.Count -gt 0) { return $changes }
    if ([string](Get-RooIndustriesPropertyValue $PreviewEntry 'proposedAction' '') -eq 'setPriority') {
        return @((New-RooIndustriesControlChange `
            -Control 'priorityClass' `
            -CurrentValue (Get-RooIndustriesPropertyValue $PreviewEntry 'currentPriorityClass' $null) `
            -ProposedValue (Get-RooIndustriesPropertyValue $PreviewEntry 'proposedPriorityClass' $null) `
            -Action 'setPriority' `
            -Reason (Get-RooIndustriesPropertyValue $PreviewEntry 'reason' 'Set process priority.')))
    }
    return @()
}

function Test-RooIndustriesProcessStartTime {
    param([object]$SavedStartTimeUtc, [object]$CurrentStartTimeUtc)
    if ([string]::IsNullOrWhiteSpace([string]$SavedStartTimeUtc) -or [string]::IsNullOrWhiteSpace([string]$CurrentStartTimeUtc)) { return $false }
    try {
        return [datetime]::Parse([string]$SavedStartTimeUtc).ToUniversalTime().Ticks -eq [datetime]::Parse([string]$CurrentStartTimeUtc).ToUniversalTime().Ticks
    } catch { return $false }
}

function Get-RooIndustriesControlStateValue {
    param(
        [object]$State,
        [string]$Control
    )
    switch ($Control) {
        'priorityClass' { return Get-RooIndustriesPropertyValue $State 'priorityClass' $null }
        'affinityMask' { return Get-RooIndustriesPropertyValue $State 'affinityMask' $null }
        'ioPriority' { return Get-RooIndustriesPropertyValue $State 'ioPriority' $null }
        'memoryPriority' { return Get-RooIndustriesPropertyValue $State 'memoryPriority' $null }
        'gpuPriority' { return Get-RooIndustriesPropertyValue $State 'gpuPriority' $null }
        default { return $null }
    }
}

function Test-RooIndustriesControlValueEqual {
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

function Get-RooIndustriesControlChangeValidationReason {
    param(
        [object]$Change,
        [object]$CurrentState
    )
    $control = [string](Get-RooIndustriesPropertyValue $Change 'control' '')
    $value = Get-RooIndustriesPropertyValue $Change 'proposedValue' $null
    $action = [string](Get-RooIndustriesPropertyValue $Change 'action' '')
    switch ($control) {
        'priorityClass' {
            if (-not (Test-RooIndustriesPriorityAllowed ([string]$value) -Restoring:($action -eq 'restorePriority'))) { return "Priority class '$value' is outside the allow-list." }
            if ([string]::IsNullOrWhiteSpace([string](Get-RooIndustriesControlStateValue $CurrentState $control))) { return 'Current priority class could not be read, so no priority change is proposed.' }
        }
        'affinityMask' {
            if (-not (Test-RooIndustriesAffinityMaskAllowed $value)) { return "Affinity mask '$value' is invalid." }
            if ($null -eq (Get-RooIndustriesControlStateValue $CurrentState $control)) { return 'Current CPU affinity could not be read, so no affinity change is proposed.' }
        }
        'ioPriority' {
            if (-not (Test-RooIndustriesIoPriorityAllowed ([string]$value) -Restoring:($action -eq 'restoreIoPriority'))) { return "I/O priority '$value' is outside the allow-list." }
            if ([string]::IsNullOrWhiteSpace([string](Get-RooIndustriesControlStateValue $CurrentState $control))) { return 'Current I/O priority could not be read, so no I/O priority change is proposed.' }
        }
        'gpuPriority' {
            if (-not (Test-RooIndustriesGpuPriorityAllowed ([string]$value))) { return "GPU priority '$value' is outside the allow-list." }
            if (-not [bool](Get-RooIndustriesPropertyValue $CurrentState 'gpuPriorityAvailable' $false)) { return 'GPU scheduling priority is unavailable for this process.' }
        }
        'memoryPriority' {
            if(-not(Test-RooIndustriesMemoryPriorityAllowed $value)){return "Memory priority '$value' is outside the allow-list."}
            if(-not[bool](Get-RooIndustriesPropertyValue $CurrentState 'memoryPriorityAvailable' $false)){return 'Current memory priority could not be read, so no memory change is proposed.'}
        }
        default {
            return "Unsupported process control '$control'."
        }
    }
    return $null
}

function Get-RooIndustriesApplicableProcessControlChanges {
    param(
        [object[]]$ControlChanges,
        [object]$CurrentState
    )
    $applicable = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $process = Get-RooIndustriesPropertyValue $CurrentState 'process' $null
    foreach ($change in @(Get-RooIndustriesArray $ControlChanges)) {
        $control = [string](Get-RooIndustriesPropertyValue $change 'control' '')
        if ([bool](Get-RooIndustriesPropertyValue $change 'blocked' $false)) {
            $reason = [string](Get-RooIndustriesPropertyValue $change 'blockedReason' (Get-RooIndustriesPropertyValue $change 'reason' 'Requested process control is blocked.'))
            $skipped.Add([pscustomobject]@{ control = $control; reason = $reason; currentValue = Get-RooIndustriesPropertyValue $change 'currentValue' $null; proposedValue = Get-RooIndustriesPropertyValue $change 'proposedValue' $null; category = 'blocked' }) | Out-Null
            continue
        }
        if ($process -is [System.Diagnostics.Process] -and (Test-RooIndustriesGovernorOwnsControl $process $control)) {
            $skipped.Add([pscustomobject]@{ control = $control; reason = $script:RooIndustriesGovernorManaged; currentValue = Get-RooIndustriesControlStateValue $CurrentState $control; proposedValue = Get-RooIndustriesPropertyValue $change 'proposedValue' $null; category = 'managed' }) | Out-Null
            continue
        }

        $validationReason = Get-RooIndustriesControlChangeValidationReason $change $CurrentState
        if (-not [string]::IsNullOrWhiteSpace($validationReason)) {
            $skipped.Add([pscustomobject]@{ control = $control; reason = $validationReason; currentValue = Get-RooIndustriesControlStateValue $CurrentState $control; proposedValue = Get-RooIndustriesPropertyValue $change 'proposedValue' $null; category = 'unavailable' }) | Out-Null
            continue
        }

        $currentValue = Get-RooIndustriesControlStateValue $CurrentState $control
        $proposedValue = Get-RooIndustriesPropertyValue $change 'proposedValue' $null
        if (Test-RooIndustriesControlValueEqual $control $currentValue $proposedValue) {
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

function Get-RooIndustriesProcessControlReadback {
    param([System.Diagnostics.Process]$Process, [string]$Control)
    $Process.Refresh()
    switch ($Control) {
        'priorityClass' { return [string]$Process.PriorityClass }
        'affinityMask' { return [int64]$Process.ProcessorAffinity }
        'ioPriority' { $read = Get-RooIndustriesProcessIoPriority $Process; if (-not $read.available) { throw 'Windows could not read back I/O priority.' }; return $read.name }
        'memoryPriority' { $read = Get-RooIndustriesProcessMemoryPriority $Process; if (-not $read.available) { throw 'Windows could not read back memory priority.' }; return $read.value }
        'gpuPriority' { $read = Get-RooIndustriesProcessGpuPriority $Process; if (-not $read.available) { throw 'Windows could not read back GPU priority.' }; return $read.name }
        default { throw "Unsupported process control '$Control'." }
    }
}

function Get-RooIndustriesRestorableProcessControls {
    param($Snapshot, $CurrentState)
    foreach ($change in @(Get-RooIndustriesPropertyArray $Snapshot 'controlChanges')) {
        $outcome = [string](Get-RooIndustriesPropertyValue $change 'outcome' '')
        if ($outcome -eq 'failed') { continue }
        $control = [string](Get-RooIndustriesPropertyValue $change 'control' '')
        if ($outcome -eq 'pending' -and -not (Test-RooIndustriesControlValueEqual $control (Get-RooIndustriesControlStateValue $CurrentState $control) (Get-RooIndustriesPropertyValue $change 'proposedValue' $null))) { continue }
        $change
    }
}

function Invoke-RooIndustriesProcessControlChange {
    param(
        [System.Diagnostics.Process]$Process,
        [object]$Change
    )
    $control = [string](Get-RooIndustriesPropertyValue $Change 'control' '')
    $value = Get-RooIndustriesPropertyValue $Change 'proposedValue' $null
    $action = [string](Get-RooIndustriesPropertyValue $Change 'action' '')
    $Change | Add-Member -NotePropertyName outcome -NotePropertyValue 'pending' -Force
    try {
        if (Test-RooIndustriesGovernorOwnsControl $Process $control) { throw $script:RooIndustriesGovernorManaged }
        if ($action -like 'restore*' -and -not (Test-RooIndustriesControlValueEqual $control (Get-RooIndustriesProcessControlReadback $Process $control) (Get-RooIndustriesPropertyValue $Change 'currentValue' $null))) { throw 'The control changed externally; its current value was preserved.' }
        switch ($control) {
            'priorityClass' {
                $priority = [string]$value
                if (-not (Test-RooIndustriesPriorityAllowed $priority -Restoring:($action -eq 'restorePriority'))) { throw "Priority class '$priority' is outside the allow-list." }
                $Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$priority
            }
            'affinityMask' {
                if (-not (Test-RooIndustriesAffinityMaskAllowed $value)) { throw "Affinity mask '$value' is invalid." }
                $Process.ProcessorAffinity = [IntPtr]([int64]$value)
            }
            'ioPriority' {
                $priority = [string]$value
                if (-not (Test-RooIndustriesIoPriorityAllowed $priority -Restoring:($action -eq 'restoreIoPriority'))) { throw "I/O priority '$priority' is outside the allow-list." }
                Set-RooIndustriesProcessIoPriority $Process $priority -Restoring:($action -eq 'restoreIoPriority')
            }
            'gpuPriority' {
                $priority = [string]$value
                if (-not (Test-RooIndustriesGpuPriorityAllowed $priority)) { throw "GPU priority '$priority' is outside the allow-list." }
                Set-RooIndustriesProcessGpuPriority $Process $priority
            }
            'memoryPriority' {
                Set-RooIndustriesProcessMemoryPriority $Process $value
            }
            default {
                throw "Unsupported process control '$control'."
            }
        }
        $actual = Get-RooIndustriesProcessControlReadback $Process $control
        if (-not (Test-RooIndustriesControlValueEqual $control $actual $value)) { throw "Windows kept a different value for $control (requested $value, read back $actual)." }
        $Change.outcome = 'applied'
    } catch {
        $Change.outcome = 'failed'
        throw
    }
}
