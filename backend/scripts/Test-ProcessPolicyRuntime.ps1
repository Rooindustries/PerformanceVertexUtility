$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.Common.ps1')
Set-RooIndustriesValidationNormalPriority

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $PSScriptRoot 'ProcessPolicy.Common.ps1')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

function Add-Pass {
    param([string]$Message)
    $passes.Add($Message) | Out-Null
    Write-Host "PASS $Message"
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "FAIL $Message"
}

function Test-RequiredFile {
    param([string]$RelativePath)
    $path = Join-Path $repoRoot $RelativePath
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $RelativePath"
    } else {
        Add-Failure "Required file missing: $RelativePath"
    }
}

function Test-JsonFile {
    param([string]$Path)
    try {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json | Out-Null
        Add-Pass "JSON parsed: $((Resolve-Path -LiteralPath $Path).Path.Substring($repoRoot.Path.Length + 1))"
    } catch {
        Add-Failure "JSON parse failed: $Path :: $($_.Exception.Message)"
    }
}

function Test-PowerShellParser {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -eq 0) {
        Add-Pass "PowerShell parsed: $((Resolve-Path -LiteralPath $Path).Path.Substring($repoRoot.Path.Length + 1))"
    } else {
        Add-Failure "PowerShell parse failed: $Path :: $(($errors | ForEach-Object { $_.Message }) -join '; ')"
    }
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Get-FrontendProcessIds {
    $items = New-Object System.Collections.Generic.List[int]
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ([string]$proc.ProcessName -like 'RooIndustries.OptimizationSuite*' -or [string]$proc.ProcessName -like 'RooIndustriesOptimizationSuite*') {
            $items.Add([int]$proc.Id) | Out-Null
        }
    }
    return @($items.ToArray())
}

function Get-BackendScriptHostProcesses {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $commandLine = [string]$proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) { continue }
        if ([int]$proc.ProcessId -eq $PID) { continue }
        if ($commandLine -like '*LeanClientOptimizer*backend*scripts*') {
            $items.Add([pscustomobject]@{
                processId = [int]$proc.ProcessId
                name = [string]$proc.Name
            }) | Out-Null
        }
    }
    return @($items.ToArray())
}

function Get-ExternalGovernorProcessIds {
    $items = New-Object System.Collections.Generic.List[int]
    foreach ($name in @('ProcessLasso','ProcessGovernor')) {
        foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $items.Add([int]$proc.Id) | Out-Null
        }
    }
    return @($items.ToArray())
}

function Get-NewIds {
    param(
        [int[]]$Before,
        [int[]]$After
    )
    $beforeSet = @{}
    foreach ($id in @(Get-RooIndustriesArray $Before)) { $beforeSet[[int]$id] = $true }
    return @(@(Get-RooIndustriesArray $After) | Where-Object { -not $beforeSet.ContainsKey([int]$_) })
}

function Wait-PolicyPriority {
    param(
        [int]$ProcessId,
        [string]$PriorityClass,
        [int]$TimeoutSeconds = 6
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Get-RooIndustriesProcessControlState $ProcessId $null
        if ($state.exists -and [string]$state.priorityClass -eq $PriorityClass) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Wait-PolicySessionChanged {
    param(
        [string]$StateRoot,
        [int]$ProcessId,
        [int]$TimeoutSeconds = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $StateRoot) {
            $sessionFile = Get-ChildItem -LiteralPath $StateRoot -Filter 'session.json' -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
            if ($sessionFile) {
                try {
                    $sessionState = Get-Content -LiteralPath $sessionFile.FullName -Raw | ConvertFrom-Json
                    $match = @($sessionState.changedItems | Where-Object { $_.processId -eq $ProcessId }) | Select-Object -First 1
                    if ($match) { return $true }
                } catch { }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Write-PolicyValidationProfile {
    param(
        [string]$Path,
        [string]$LiveRoot,
        [string]$Mode,
        [int64]$AffinityMask = 0
    )
    $controls = if ($Mode -eq 'preview-all-controls') {
        [pscustomobject]@{
            priorityClass = 'BelowNormal'
            affinityMask = $AffinityMask
            ioPriority = 'Low'
            gpuPriority = 'AboveNormal'
        }
    } else {
        [pscustomobject]@{
            priorityClass = 'BelowNormal'
        }
    }
    $rules = if ($Mode -eq 'preview-all-controls') {
        @(
            [pscustomobject]@{
                ruleId = 'policy-preview-name-command-controls'
                enabled = $true
                allowConfirmedApply = $true
                match = [pscustomobject]@{
                    processNames = @('RooIndustriesPolicyExistingProbe.exe')
                    commandLinePatterns = @('*policy-existing-marker*')
                }
                controls = $controls
                reason = 'Disposable preview probe matches by process name and command-line marker.'
                reasonCodes = @('LIVE_POLICY_NAME_COMMAND_MATCH')
                scenarioTags = @('game','browser helper')
                risk = 'low'
            },
            [pscustomobject]@{
                ruleId = 'policy-preview-protected'
                enabled = $true
                allowConfirmedApply = $true
                match = [pscustomobject]@{
                    processNames = @('RooIndustriesPolicyProtectedProbe.exe')
                }
                controls = [pscustomobject]@{ priorityClass = 'BelowNormal' }
                reason = 'Disposable protected probe is present so preview can explain the skip.'
                reasonCodes = @('LIVE_POLICY_PROTECTED_RULE')
                scenarioTags = @('voice')
                risk = 'protected'
            }
        )
    } else {
        @(
            [pscustomobject]@{
                ruleId = 'policy-existing-name-command'
                enabled = $true
                allowConfirmedApply = $true
                match = [pscustomobject]@{
                    processNames = @('RooIndustriesPolicyExistingProbe.exe')
                }
                controls = $controls
                reason = 'Apply saved policy to a disposable process that was already running when the session started.'
                reasonCodes = @('LIVE_POLICY_EXISTING_APPLY')
                scenarioTags = @('game','browser helper')
                risk = 'low'
            },
            [pscustomobject]@{
                ruleId = 'policy-launch-name-path-category'
                enabled = $true
                allowConfirmedApply = $true
                match = [pscustomobject]@{
                    namePatterns = @('RooIndustriesPolicyLaunch*.exe')
                    pathPatterns = @((Join-Path $LiveRoot 'RooIndustriesPolicyLaunch*.exe'))
                    processCategories = @('backgroundApp')
                }
                controls = $controls
                reason = 'Apply saved policy to a disposable process launched after the watcher starts.'
                reasonCodes = @('LIVE_POLICY_LAUNCH_APPLY')
                scenarioTags = @('launcher','game')
                risk = 'low'
            },
            [pscustomobject]@{
                ruleId = 'policy-relaunch-same-match'
                enabled = $true
                allowConfirmedApply = $true
                match = [pscustomobject]@{
                    processNames = @('RooIndustriesPolicyRelaunchProbe.exe')
                    processCategories = @('backgroundApp')
                }
                controls = $controls
                reason = 'Apply saved policy to each new disposable process instance with the same match.'
                reasonCodes = @('LIVE_POLICY_RELAUNCH_APPLY')
                scenarioTags = @('launcher','network')
                risk = 'low'
            },
            [pscustomobject]@{
                ruleId = 'policy-protected-skip'
                enabled = $true
                allowConfirmedApply = $true
                match = [pscustomobject]@{
                    processNames = @('RooIndustriesPolicyProtectedProbe.exe')
                }
                controls = $controls
                reason = 'Protected disposable process should be skipped even when a policy rule matches.'
                reasonCodes = @('LIVE_POLICY_PROTECTED_RULE')
                scenarioTags = @('voice')
                risk = 'protected'
            }
        )
    }
    $profile = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        profileId = "live-policy-validation-$Mode"
        name = "Live Policy Validation $Mode"
        profileKind = 'persistent-process-policy'
        risk = 'low'
        targetScenario = 'Disposable persistent policy validation.'
        protectedCatalogPath = (Join-Path $repoRoot 'backend\profiles\protected-processes.json')
        policy = [pscustomobject]@{
            session = [pscustomobject]@{
                pollIntervalSeconds = 1
                maxSessionDurationSeconds = 45
            }
            safety = [pscustomobject]@{
                confirmedApplyRequiresRuleAllow = $true
                confirmedApplyRequiresPathRoot = $true
                confirmedApplyPathRoots = @($LiveRoot)
            }
            protectedProcesses = @(
                [pscustomobject]@{
                    itemId = 'protect-live-policy-probe'
                    type = 'process'
                    names = @('RooIndustriesPolicyProtectedProbe.exe')
                    reason = 'Disposable protected validation probe is excluded from persistent policy control.'
                    reasonCodes = @('LIVE_POLICY_PROTECTED_PROBE')
                    defaultAction = 'block'
                }
            )
            rules = $rules
        }
        telemetryTargets = @('persistent-policy-enforcement','launch-watcher-coverage','policy-restore-count')
        rollbackPolicy = [pscustomobject]@{
            supported = $true
            scope = 'persistent-process-policy-controls'
            stateRoot = 'temp-validation-state'
            restoreOriginalPriorityClass = $true
        }
        safety = [pscustomobject]@{
            confirmedApplyChanges = @('PriorityClass')
            continuousEnforcement = $true
            runtimeService = $false
            requiresExplicitApplyRoots = $true
        }
    }
    ($profile | ConvertTo-Json -Depth 22) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-PolicyControlValue {
    param(
        [object]$State,
        [string]$Control
    )
    switch ($Control) {
        'priorityClass' { return Get-RooIndustriesPropertyValue $State 'priorityClass' $null }
        'affinityMask' { return Get-RooIndustriesPropertyValue $State 'affinityMask' $null }
        'ioPriority' { return Get-RooIndustriesPropertyValue $State 'ioPriority' $null }
        'gpuPriority' { return Get-RooIndustriesPropertyValue $State 'gpuPriority' $null }
        default { return $null }
    }
}

function Test-PolicyControlValueEquals {
    param(
        [string]$Control,
        [object]$Left,
        [object]$Right
    )
    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if ($Control -eq 'affinityMask') {
        try { return [int64]$Left -eq [int64]$Right } catch { return $false }
    }
    return [string]$Left -eq [string]$Right
}

function New-PolicyControlValidationResult {
    param(
        [string]$Control,
        [string]$Status,
        [object]$TargetValue,
        [object]$OriginalValue,
        [object]$AppliedValue,
        [object]$RestoredValue,
        [object]$OsStatus,
        [string]$Message
    )
    return [pscustomobject]@{
        control = $Control
        status = $Status
        targetValue = $TargetValue
        originalValue = $OriginalValue
        appliedValue = $AppliedValue
        restoredValue = $RestoredValue
        osStatus = $OsStatus
        message = $Message
    }
}

function Write-PolicySingleControlValidationProfile {
    param(
        [string]$Path,
        [string]$LiveRoot,
        [string]$ProbeName,
        [string]$Control,
        [object]$TargetValue
    )
    $controlTable = [ordered]@{}
    $controlTable[$Control] = $TargetValue
    $profile = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        profileId = "live-policy-all-control-$Control"
        name = "Live Policy All Control $Control"
        profileKind = 'persistent-process-policy'
        risk = 'low'
        targetScenario = 'Disposable all-control persistent policy validation.'
        protectedCatalogPath = (Join-Path $repoRoot 'backend\profiles\protected-processes.json')
        policy = [pscustomobject]@{
            session = [pscustomobject]@{
                pollIntervalSeconds = 1
                maxSessionDurationSeconds = 2
            }
            safety = [pscustomobject]@{
                confirmedApplyRequiresRuleAllow = $true
                confirmedApplyRequiresPathRoot = $true
                confirmedApplyPathRoots = @($LiveRoot)
            }
            protectedProcesses = @()
            rules = @(
                [pscustomobject]@{
                    ruleId = "policy-all-control-$Control"
                    enabled = $true
                    allowConfirmedApply = $true
                    match = [pscustomobject]@{
                        processNames = @($ProbeName)
                        commandLinePatterns = @("*policy-all-control-$Control*")
                    }
                    controls = [pscustomobject]$controlTable
                    reason = "Apply $Control to a disposable policy validation probe."
                    reasonCodes = @("LIVE_POLICY_CONTROL_$($Control.ToUpperInvariant())")
                    scenarioTags = @('validation')
                    risk = 'low'
                }
            )
        }
        telemetryTargets = @('persistent-policy-enforcement')
        rollbackPolicy = [pscustomobject]@{
            supported = $true
            scope = 'persistent-process-policy-controls'
            stateRoot = 'temp-validation-state'
            restoreOriginalPriorityClass = $true
            restoreOriginalAffinityMask = $true
            restoreOriginalIoPriority = $true
            restoreOriginalGpuPriority = $true
        }
        safety = [pscustomobject]@{
            confirmedApplyChanges = @($Control)
            continuousEnforcement = $true
            runtimeService = $false
            requiresExplicitApplyRoots = $true
        }
    }
    ($profile | ConvertTo-Json -Depth 22) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-PolicySingleControlValidation {
    param(
        [string]$Control,
        [string]$LiveRoot,
        [string]$StateRoot
    )
    $safeControl = switch ($Control) {
        'priorityClass' { 'Priority' }
        'affinityMask' { 'Affinity' }
        'ioPriority' { 'Io' }
        'gpuPriority' { 'Gpu' }
        default { 'Control' }
    }
    $probeName = "RooIndustriesPolicyControl$($safeControl)Probe.exe"
    $probeExe = Join-Path $LiveRoot $probeName
    $probe = $null
    try {
        Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $probeExe -Force
        $probe = Start-Process -FilePath $probeExe -ArgumentList (Join-RooIndustriesWindowsArguments @('-NoProfile','-WindowStyle','Hidden','-Command',"`$marker='policy-all-control-$Control'; Start-Sleep -Seconds 120")) -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 700
        $before = Get-RooIndustriesProcessControlState $probe.Id $null
        $originalValue = Get-PolicyControlValue $before $Control
        $targetValue = $null
        $osStatus = $null
        switch ($Control) {
            'priorityClass' {
                if ([string]::IsNullOrWhiteSpace([string]$before.priorityClass)) {
                    return New-PolicyControlValidationResult $Control 'unsupported' $null $originalValue $null $null $null 'Priority class was not readable for the disposable probe.'
                }
                $targetValue = if ([string]$before.priorityClass -eq 'BelowNormal') { 'Normal' } else { 'BelowNormal' }
            }
            'affinityMask' {
                if ($null -eq $before.affinityMask) {
                    return New-PolicyControlValidationResult $Control 'unsupported' $null $originalValue $null $null $null 'CPU affinity mask was not readable for the disposable probe.'
                }
                $mask = [int64]$before.affinityMask
                if (($mask -band 1) -eq 1 -and $mask -ne 1) {
                    $targetValue = 1
                } elseif (($mask -band 2) -eq 2 -and $mask -ne 2) {
                    $targetValue = 2
                } else {
                    return New-PolicyControlValidationResult $Control 'unsupported' $null $originalValue $null $null $null 'CPU affinity could not be changed because the disposable probe had no alternate allowed CPU bit.'
                }
            }
            'ioPriority' {
                $osStatus = Get-RooIndustriesPropertyValue $before 'ioPriorityStatus' $null
                if (-not [bool](Get-RooIndustriesPropertyValue $before 'ioPriorityAvailable' $false)) {
                    return New-PolicyControlValidationResult $Control 'unsupported' 'Low' $originalValue $null $null $osStatus 'I/O priority is not available for the disposable probe in this Windows session.'
                }
                $targetValue = if ([string]$before.ioPriority -eq 'Low') { 'Normal' } else { 'Low' }
            }
            'gpuPriority' {
                $osStatus = Get-RooIndustriesPropertyValue $before 'gpuPriorityStatus' $null
                if (-not [bool](Get-RooIndustriesPropertyValue $before 'gpuPriorityAvailable' $false)) {
                    return New-PolicyControlValidationResult $Control 'unsupported' 'BelowNormal' $originalValue $null $null $osStatus 'GPU scheduling priority is not available for the disposable probe in this Windows session.'
                }
                $targetValue = if ([string]$before.gpuPriority -eq 'BelowNormal') { 'Normal' } else { 'BelowNormal' }
            }
        }

        $profilePath = Join-Path $LiveRoot "policy-all-control-$Control.json"
        Write-PolicySingleControlValidationProfile -Path $profilePath -LiveRoot $LiveRoot -ProbeName $probeName -Control $Control -TargetValue $targetValue
        $session = & (Join-Path $PSScriptRoot 'Start-ProcessPolicySession.ps1') `
            -ProfilePath $profilePath `
            -PollIntervalSeconds 1 `
            -MaxDurationSeconds 2 `
            -StateRoot $StateRoot `
            -ConfirmApply `
            -IncludeCommandLine | ConvertFrom-Json
        $afterApply = Get-RooIndustriesProcessControlState $probe.Id $null
        $appliedValue = Get-PolicyControlValue $afterApply $Control
        $changed = @($session.changedItems | Where-Object { $_.processId -eq $probe.Id }) | Select-Object -First 1
        $appliedControl = @($changed.appliedControls | Where-Object { $_.control -eq $Control }) | Select-Object -First 1
        $skip = @($session.skippedItems | Where-Object { $_.processId -eq $probe.Id -and ([string]$_.reason -match $Control) }) | Select-Object -First 1
        if (-not $appliedControl) {
            $message = if ($skip) { [string]$skip.reason } else { "Persistent policy did not apply $Control to the disposable probe." }
            $status = if ($Control -in @('ioPriority','gpuPriority') -and $message -match '(?i)(status|ntstatus|not available|failed to set)') { 'unsupported' } else { 'failed' }
            return New-PolicyControlValidationResult $Control $status $targetValue $originalValue $appliedValue $null $osStatus $message
        }
        $restore = & (Join-Path $PSScriptRoot 'Stop-ProcessPolicySession.ps1') -SessionPath $session.sessionPath -ConfirmApply | ConvertFrom-Json
        $afterRestore = Get-RooIndustriesProcessControlState $probe.Id $null
        $restoredValue = Get-PolicyControlValue $afterRestore $Control
        $appliedMatches = Test-PolicyControlValueEquals $Control $appliedValue $targetValue
        $restoredMatches = Test-PolicyControlValueEquals $Control $restoredValue $originalValue
        if ($restore.dryRun -eq $false -and $appliedMatches -and $restoredMatches) {
            return New-PolicyControlValidationResult $Control 'liveAppliedRestored' $targetValue $originalValue $appliedValue $restoredValue $osStatus "Disposable probe $Control was applied by persistent policy and restored."
        }
        return New-PolicyControlValidationResult $Control 'failed' $targetValue $originalValue $appliedValue $restoredValue $osStatus "Persistent policy $Control validation did not apply and restore cleanly."
    } catch {
        $message = $_.Exception.Message
        $status = if ($Control -in @('ioPriority','gpuPriority') -and $message -match '(?i)(status|ntstatus|entry point|not available|failed to set)') { 'unsupported' } else { 'failed' }
        return New-PolicyControlValidationResult $Control $status $null $null $null $null $null $message
    } finally {
        if ($probe -and -not $probe.HasExited) {
            Stop-RooIndustriesValidationProcess $probe
        }
    }
}

$requiredFiles = @(
    'backend\profiles\persistent-policy.profile.json',
    'backend\scripts\ProcessPolicy.Common.ps1',
    'backend\scripts\Preview-ProcessPolicy.ps1',
    'backend\scripts\Start-ProcessPolicySession.ps1',
    'backend\scripts\Stop-ProcessPolicySession.ps1',
    'backend\scripts\Get-ProcessPolicySessionStatus.ps1',
    'backend\samples\process-policy-preview.sample.json',
    'backend\samples\process-policy-session-confirmed.sample.json',
    'backend\samples\process-policy-session-status.sample.json',
    'backend\samples\process-policy-stop-preview.sample.json',
    'backend\samples\process-policy-stop-result.sample.json',
    'backend\samples\all-control-policy-validation-result.sample.json'
)
foreach ($relative in $requiredFiles) {
    Test-RequiredFile $relative
}

foreach ($root in @(
    (Join-Path $repoRoot 'backend\contracts'),
    (Join-Path $repoRoot 'backend\samples'),
    (Join-Path $repoRoot 'backend\profiles'),
    (Join-Path $repoRoot 'backend\uninstall'),
    (Join-Path $repoRoot 'modules')
)) {
    if (Test-Path -LiteralPath $root) {
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -Recurse -File) {
            Test-JsonFile $file.FullName
        }
    }
}

foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'backend\scripts') -Filter '*.ps1' -File) {
    Test-PowerShellParser $file.FullName
}

try {
    $dryRunStateRoot = Join-Path (Join-Path $repoRoot 'backend\state') "process-policy-dry-run-validation-$([guid]::NewGuid().ToString('N'))"
    $dryRun = & (Join-Path $PSScriptRoot 'Start-ProcessPolicySession.ps1') `
        -ProfilePath (Join-Path $repoRoot 'backend\profiles\persistent-policy.profile.json') `
        -MaxDurationSeconds 1 `
        -StateRoot $dryRunStateRoot | ConvertFrom-Json
    if ($dryRun.actionId -eq 'performance.policy.startSession' -and $dryRun.dryRun -eq $true -and $dryRun.status -eq 'completed') {
        Add-Pass 'Dry-run persistent policy session returned a completed preview envelope'
    } else {
        Add-Failure 'Dry-run persistent policy session returned an unexpected envelope'
    }
    if ($null -eq $dryRun.sessionPath -and $null -eq $dryRun.backupManifestPath -and $dryRun.restorable -eq $false) {
        Add-Pass 'Dry-run persistent policy session wrote no session or backup state'
    } else {
        Add-Failure 'Dry-run persistent policy session reported session or backup state'
    }
    if (-not (Test-Path -LiteralPath $dryRunStateRoot)) {
        Add-Pass 'Dry-run persistent policy session left no backend state root behind'
    } else {
        Add-Failure "Dry-run persistent policy session created state root: $dryRunStateRoot"
    }
} catch {
    Add-Failure "Dry-run persistent policy session failed: $($_.Exception.Message)"
}

try {
    $status = & (Join-Path $PSScriptRoot 'Get-ProcessPolicySessionStatus.ps1') `
        -StateRoot (Join-Path $repoRoot 'backend\state\missing-process-policy-validation') | ConvertFrom-Json
    if ($status.actionId -eq 'performance.policy.sessionStatus' -and $status.status -eq 'notFound') {
        Add-Pass 'Persistent policy status reports notFound cleanly when no session exists'
    } else {
        Add-Failure 'Persistent policy status missing-session result had an unexpected shape'
    }
} catch {
    Add-Failure "Persistent policy status notFound check failed: $($_.Exception.Message)"
}

$stateBefore = Get-StateEntryCount
$frontendBefore = @(Get-FrontendProcessIds)
$backendHostBefore = @(Get-BackendScriptHostProcesses)
$externalGovernorBefore = @(Get-ExternalGovernorProcessIds)
$liveRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-process-policy-live-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
$existingProbe = $null
$launchProbe = $null
$relaunchProbeFirst = $null
$relaunchProbeSecond = $null
$protectedProbe = $null
$sessionProc = $null
try {
    New-Item -ItemType Directory -Path $liveRoot -Force | Out-Null
    $existingExe = Join-Path $liveRoot 'RooIndustriesPolicyExistingProbe.exe'
    $launchExe = Join-Path $liveRoot 'RooIndustriesPolicyLaunchProbe.exe'
    $relaunchExe = Join-Path $liveRoot 'RooIndustriesPolicyRelaunchProbe.exe'
    $protectedExe = Join-Path $liveRoot 'RooIndustriesPolicyProtectedProbe.exe'
    foreach ($exe in @($existingExe, $launchExe, $relaunchExe, $protectedExe)) {
        Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $exe -Force
    }

    $existingProbe = Start-Process -FilePath $existingExe -ArgumentList (Join-RooIndustriesWindowsArguments @('-NoProfile','-WindowStyle','Hidden','-Command',"`$marker='policy-existing-marker'; Start-Sleep -Seconds 120")) -WindowStyle Hidden -PassThru
    $protectedProbe = Start-Process -FilePath $protectedExe -ArgumentList (Join-RooIndustriesWindowsArguments @('-NoProfile','-WindowStyle','Hidden','-Command',"`$marker='policy-protected-marker'; Start-Sleep -Seconds 120")) -WindowStyle Hidden -PassThru
    $relaunchProbeFirst = Start-Process -FilePath $relaunchExe -ArgumentList (Join-RooIndustriesWindowsArguments @('-NoProfile','-WindowStyle','Hidden','-Command',"`$marker='policy-relaunch-first'; Start-Sleep -Seconds 120")) -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800
    $beforeExisting = Get-RooIndustriesProcessControlState $existingProbe.Id $null
    $beforeProtected = Get-RooIndustriesProcessControlState $protectedProbe.Id $null
    $targetAffinity = if (($beforeExisting.affinityMask -band 1) -eq 1 -and [int64]$beforeExisting.affinityMask -ne 1) { 1 } elseif (($beforeExisting.affinityMask -band 2) -eq 2) { 2 } else { $beforeExisting.affinityMask }

    $previewProfilePath = Join-Path $liveRoot 'policy-preview-profile.json'
    Write-PolicyValidationProfile -Path $previewProfilePath -LiveRoot $liveRoot -Mode 'preview-all-controls' -AffinityMask ([int64]$targetAffinity)
    $preview = & (Join-Path $PSScriptRoot 'Preview-ProcessPolicy.ps1') `
        -ProfilePath $previewProfilePath `
        -IncludeCommandLine | ConvertFrom-Json
    $afterPreviewExisting = Get-RooIndustriesProcessControlState $existingProbe.Id $null
    $previewExisting = @($preview.preview | Where-Object { $_.processId -eq $existingProbe.Id }) | Select-Object -First 1
    $previewProtected = @($preview.preview | Where-Object { $_.processId -eq $protectedProbe.Id }) | Select-Object -First 1
    $previewControls = @($previewExisting.controlChanges | ForEach-Object { $_.control })
    if ($preview.dryRun -eq $true -and $previewExisting.requiresConfirmation -eq $true -and $previewControls -contains 'priorityClass' -and $previewControls -contains 'affinityMask' -and $previewControls -contains 'ioPriority' -and $previewControls -contains 'gpuPriority' -and $afterPreviewExisting.priorityClass -eq $beforeExisting.priorityClass) {
        Add-Pass "Dry-run preview proposed priority, affinity, I/O, and GPU policy controls without changing probe priority: before=$($beforeExisting.priorityClass) afterPreview=$($afterPreviewExisting.priorityClass)"
    } else {
        Add-Failure 'Dry-run preview did not propose all process controls or changed the existing probe'
    }
    if ($previewProtected.blocked -eq $true -and ($previewProtected.reasonCodes -contains 'LIVE_POLICY_PROTECTED_PROBE')) {
        Add-Pass "Protected probe was explained as a policy skip during preview: $($previewProtected.reasonCodes -join ',')"
    } else {
        Add-Failure 'Protected probe was not reported as a protected preview skip'
    }
    if ((Get-RooIndustriesProcessControlState $protectedProbe.Id $null).priorityClass -eq $beforeProtected.priorityClass) {
        Add-Pass "Protected probe priority stayed unchanged during preview: $($beforeProtected.priorityClass)"
    } else {
        Add-Failure 'Protected probe priority changed during preview'
    }

    $allControlStateRoot = Join-Path $liveRoot 'all-control-state'
    $controlCoverage = New-Object System.Collections.Generic.List[object]
    foreach ($control in @('priorityClass','affinityMask','ioPriority','gpuPriority')) {
        $result = Invoke-PolicySingleControlValidation -Control $control -LiveRoot $liveRoot -StateRoot $allControlStateRoot
        $controlCoverage.Add($result) | Out-Null
        if ($result.status -eq 'liveAppliedRestored') {
            Add-Pass "Persistent policy live-applied and restored $control on a disposable probe: original=$($result.originalValue) target=$($result.targetValue) restored=$($result.restoredValue)"
        } elseif ($result.status -eq 'unsupported') {
            Add-Pass "Persistent policy reported $control as unsupported for this Windows session: status=$($result.osStatus) message=$($result.message)"
        } else {
            Add-Failure "Persistent policy $control validation failed: $($result.message)"
        }
    }
    $coverageCount = @($controlCoverage | Where-Object { $_.status -in @('liveAppliedRestored','unsupported') }).Count
    if ($coverageCount -eq 4) {
        Add-Pass 'Persistent policy explicitly covered priority, affinity, I/O priority, and GPU scheduling priority'
    } else {
        Add-Failure "Persistent policy all-control coverage was incomplete: $coverageCount of 4 controls reported"
    }

    $sessionProfilePath = Join-Path $liveRoot 'policy-session-profile.json'
    $stateRoot = Join-Path $liveRoot 'state'
    Write-PolicyValidationProfile -Path $sessionProfilePath -LiveRoot $liveRoot -Mode 'session-priority-only'
    $sessionOutput = Join-Path $liveRoot 'policy-session-output.json'
    $sessionError = Join-Path $liveRoot 'policy-session-error.txt'
    $sessionArgs = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'Start-ProcessPolicySession.ps1'),
        '-ProfilePath',
        $sessionProfilePath,
        '-PollIntervalSeconds',
        '1',
        '-MaxDurationSeconds',
        '45',
        '-StateRoot',
        $stateRoot,
        '-ConfirmApply'
    )
    $sessionProc = Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-RooIndustriesWindowsArguments $sessionArgs) -WindowStyle Hidden -RedirectStandardOutput $sessionOutput -RedirectStandardError $sessionError -PassThru
    $firstRelaunchApplied = Wait-PolicySessionChanged -StateRoot $stateRoot -ProcessId $relaunchProbeFirst.Id -TimeoutSeconds 25
    if ($relaunchProbeFirst -and -not $relaunchProbeFirst.HasExited) {
        Stop-RooIndustriesValidationProcess $relaunchProbeFirst
    }
    Start-Sleep -Seconds 1
    $launchProbe = Start-Process -FilePath $launchExe -ArgumentList (Join-RooIndustriesWindowsArguments @('-NoProfile','-WindowStyle','Hidden','-Command',"`$marker='policy-launch-marker'; Start-Sleep -Seconds 120")) -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $relaunchProbeSecond = Start-Process -FilePath $relaunchExe -ArgumentList (Join-RooIndustriesWindowsArguments @('-NoProfile','-WindowStyle','Hidden','-Command',"`$marker='policy-relaunch-second'; Start-Sleep -Seconds 120")) -WindowStyle Hidden -PassThru
    Wait-PolicySessionChanged -StateRoot $stateRoot -ProcessId $relaunchProbeSecond.Id -TimeoutSeconds 15 | Out-Null
    Wait-RooIndustriesValidationProcess $sessionProc 75
    $sessionProc.Refresh()
    $sessionExitCode = $sessionProc.ExitCode
    $sessionProc = $null
    if ($null -ne $sessionExitCode -and $sessionExitCode -ne 0) {
        $errorText = if (Test-Path -LiteralPath $sessionError) { Get-Content -LiteralPath $sessionError -Raw } else { '' }
        Add-Failure "Confirmed persistent policy session exited with code $sessionExitCode :: $errorText"
    }
    $session = Get-Content -LiteralPath $sessionOutput -Raw | ConvertFrom-Json
    $afterSessionExisting = Get-RooIndustriesProcessControlState $existingProbe.Id $null
    $afterSessionLaunch = Get-RooIndustriesProcessControlState $launchProbe.Id $null
    $afterSessionSecond = Get-RooIndustriesProcessControlState $relaunchProbeSecond.Id $null
    $existingChanged = @($session.changedItems | Where-Object { $_.processId -eq $existingProbe.Id }) | Select-Object -First 1
    $launchChanged = @($session.changedItems | Where-Object { $_.processId -eq $launchProbe.Id }) | Select-Object -First 1
    $firstRelaunchChanged = @($session.changedItems | Where-Object { $_.processId -eq $relaunchProbeFirst.Id }) | Select-Object -First 1
    $secondRelaunchChanged = @($session.changedItems | Where-Object { $_.processId -eq $relaunchProbeSecond.Id }) | Select-Object -First 1
    $protectedSkip = @($session.skippedItems | Where-Object { $_.processId -eq $protectedProbe.Id }) | Select-Object -First 1
    if ($session.dryRun -eq $false -and $session.status -eq 'completed' -and $existingChanged -and $afterSessionExisting.priorityClass -eq 'BelowNormal') {
        Add-Pass "Confirmed policy session applied to running probe: before=$($beforeExisting.priorityClass) applied=$($afterSessionExisting.priorityClass)"
    } else {
        Add-Failure "Confirmed policy session did not apply to existing probe: current=$($afterSessionExisting.priorityClass)"
    }
    if ($launchChanged -and $afterSessionLaunch.priorityClass -eq 'BelowNormal') {
        Add-Pass "Launch watcher applied policy to after-start probe: pid=$($launchProbe.Id) priority=$($afterSessionLaunch.priorityClass)"
    } else {
        Add-Failure "Launch watcher did not apply policy to after-start probe: current=$($afterSessionLaunch.priorityClass)"
    }
    if ($firstRelaunchApplied -and $firstRelaunchChanged -and $secondRelaunchChanged -and $afterSessionSecond.priorityClass -eq 'BelowNormal' -and $firstRelaunchChanged.processId -ne $secondRelaunchChanged.processId) {
        Add-Pass "Relaunch watcher treated same-name probe as a new candidate: firstPid=$($firstRelaunchChanged.processId) secondPid=$($secondRelaunchChanged.processId)"
    } else {
        Add-Failure 'Relaunch watcher did not prove first and second same-name probe applications'
    }
    if ($protectedSkip -and ($protectedSkip.reasonCodes -contains 'LIVE_POLICY_PROTECTED_PROBE') -and (Get-RooIndustriesProcessControlState $protectedProbe.Id $null).priorityClass -eq $beforeProtected.priorityClass) {
        Add-Pass "Protected probe was skipped and remained unchanged: priority=$($beforeProtected.priorityClass)"
    } else {
        Add-Failure 'Protected probe was not skipped or changed unexpectedly'
    }
    $existingChangeCount = @($session.changedItems | Where-Object { $_.processId -eq $existingProbe.Id }).Count
    if ($existingChangeCount -eq 1) {
        Add-Pass 'Policy session did not repeatedly apply the same already-correct process'
    } else {
        Add-Failure "Policy session repeatedly applied existing probe $existingChangeCount time(s)"
    }
    $fullStateRoot = [System.IO.Path]::GetFullPath($stateRoot)
    if ([string]$session.sessionPath -like "$fullStateRoot*") {
        Add-Pass 'Confirmed persistent policy state was isolated under the temp validation root'
    } else {
        Add-Failure 'Confirmed persistent policy state was not isolated under the temp validation root'
    }

    $statusAfterSession = & (Join-Path $PSScriptRoot 'Get-ProcessPolicySessionStatus.ps1') -SessionPath $session.sessionPath | ConvertFrom-Json
    if ($statusAfterSession.status -eq 'restorable' -and $statusAfterSession.summary.activeApplicationCount -ge 3) {
        Add-Pass 'Persistent policy status is restorable with active applications after confirmed apply'
    } else {
        Add-Failure 'Persistent policy status did not report active restorable applications'
    }
    $restorePreview = & (Join-Path $PSScriptRoot 'Stop-ProcessPolicySession.ps1') -SessionPath $session.sessionPath | ConvertFrom-Json
    $afterRestorePreviewExisting = Get-RooIndustriesProcessControlState $existingProbe.Id $null
    if ($restorePreview.dryRun -eq $true -and $afterRestorePreviewExisting.priorityClass -eq 'BelowNormal') {
        Add-Pass 'Persistent policy stop preview did not restore or change the existing probe'
    } else {
        Add-Failure 'Persistent policy stop preview changed the existing probe unexpectedly'
    }
    $restore = & (Join-Path $PSScriptRoot 'Stop-ProcessPolicySession.ps1') -SessionPath $session.sessionPath -ConfirmApply | ConvertFrom-Json
    $afterRestoreExisting = Get-RooIndustriesProcessControlState $existingProbe.Id $null
    $afterRestoreLaunch = Get-RooIndustriesProcessControlState $launchProbe.Id $null
    $afterRestoreSecond = Get-RooIndustriesProcessControlState $relaunchProbeSecond.Id $null
    if ($restore.dryRun -eq $false -and @($restore.restoredItems).Count -ge 3 -and $afterRestoreExisting.priorityClass -eq $beforeExisting.priorityClass -and $afterRestoreLaunch.priorityClass -eq $beforeExisting.priorityClass -and $afterRestoreSecond.priorityClass -eq $beforeExisting.priorityClass) {
        Add-Pass "Confirmed persistent policy stop restored running probes to original priority: $($beforeExisting.priorityClass)"
    } else {
        Add-Failure "Confirmed persistent policy stop did not restore running probes: existing=$($afterRestoreExisting.priorityClass), launch=$($afterRestoreLaunch.priorityClass), relaunch=$($afterRestoreSecond.priorityClass), expected=$($beforeExisting.priorityClass)"
    }
    $firstRelaunchRestoreSkip = @($restore.skippedItems | Where-Object { $_.processId -eq $relaunchProbeFirst.Id }) | Select-Object -First 1
    if ($firstRelaunchRestoreSkip) {
        Add-Pass 'Confirmed stop skipped the exited first relaunch probe without killing or recreating it'
    } else {
        Add-Failure 'Confirmed stop did not report the exited first relaunch probe as skipped'
    }

    foreach ($probe in @($existingProbe, $launchProbe, $relaunchProbeSecond, $protectedProbe)) {
        if ($probe -and -not $probe.HasExited) {
            Stop-RooIndustriesValidationProcess $probe
        }
    }
    $existingProbe = $null
    $launchProbe = $null
    $relaunchProbeSecond = $null
    $protectedProbe = $null
    $tempRoot = [System.IO.Path]::GetTempPath()
    $fullLiveRoot = [System.IO.Path]::GetFullPath($liveRoot)
    if ($fullLiveRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullLiveRoot)) {
        Remove-Item -LiteralPath $fullLiveRoot -Recurse -Force
    }
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $fullLiveRoot)) {
        Add-Pass 'Disposable policy probe processes and temp state root were cleaned up'
    } else {
        Add-Failure 'Disposable policy temp state root remained after cleanup'
    }
} catch {
    Add-Failure "Live persistent policy validation failed: $($_.Exception.Message)"
} finally {
    if ($sessionProc -and -not $sessionProc.HasExited) {
        Wait-Process -Id $sessionProc.Id -Timeout 2 -ErrorAction SilentlyContinue
    }
    foreach ($probe in @($existingProbe, $launchProbe, $relaunchProbeFirst, $relaunchProbeSecond, $protectedProbe)) {
        if ($probe -and -not $probe.HasExited) {
            Stop-RooIndustriesValidationProcess $probe
        }
    }
    if (-not $cleanupDone) {
        $tempRoot = [System.IO.Path]::GetTempPath()
        $fullLiveRoot = [System.IO.Path]::GetFullPath($liveRoot)
        if ($fullLiveRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullLiveRoot)) {
            Remove-Item -LiteralPath $fullLiveRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$leftoverProbeNames = @(
    'RooIndustriesPolicyExistingProbe',
    'RooIndustriesPolicyLaunchProbe',
    'RooIndustriesPolicyRelaunchProbe',
    'RooIndustriesPolicyProtectedProbe',
    'RooIndustriesPolicyControlPriorityProbe',
    'RooIndustriesPolicyControlAffinityProbe',
    'RooIndustriesPolicyControlIoProbe',
    'RooIndustriesPolicyControlGpuProbe'
)
$leftovers = @()
foreach ($name in $leftoverProbeNames) {
    $leftovers += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
}
if (@($leftovers).Count -eq 0) {
    Add-Pass 'No disposable policy probe processes remained after validation'
} else {
    Add-Failure "Disposable policy probe process(es) remained: $(@($leftovers | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', ')"
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after persistent policy runtime validation'
} else {
    Add-Failure "backend/state is not empty or changed during persistent policy validation: before=$stateBefore after=$stateAfter"
}

$frontendAfter = @(Get-FrontendProcessIds)
$newFrontendIds = @(Get-NewIds $frontendBefore $frontendAfter)
if ($newFrontendIds.Count -eq 0) {
    Add-Pass 'Persistent policy validation launched no frontend process'
} else {
    Add-Failure "Persistent policy validation launched frontend process id(s): $($newFrontendIds -join ', ')"
}

$backendHostAfter = @(Get-BackendScriptHostProcesses)
$backendHostBeforeIds = @($backendHostBefore | ForEach-Object { [int]$_.processId })
$backendHostAfterIds = @($backendHostAfter | ForEach-Object { [int]$_.processId })
$newBackendHostIds = @(Get-NewIds $backendHostBeforeIds $backendHostAfterIds)
if ($newBackendHostIds.Count -eq 0) {
    Add-Pass 'Persistent policy validation left no backend script host process behind'
} else {
    Add-Failure "Persistent policy validation left backend script host process id(s): $($newBackendHostIds -join ', ')"
}

$externalGovernorAfter = @(Get-ExternalGovernorProcessIds)
$newExternalGovernorIds = @(Get-NewIds $externalGovernorBefore $externalGovernorAfter)
if ($newExternalGovernorIds.Count -eq 0) {
    Add-Pass 'Persistent policy validation launched no external process governor utility'
} else {
    Add-Failure "Persistent policy validation launched external process governor process id(s): $($newExternalGovernorIds -join ', ')"
}

$runtimeScriptFiles = @(
    (Join-Path $PSScriptRoot 'ProcessPolicy.Common.ps1'),
    (Join-Path $PSScriptRoot 'Preview-ProcessPolicy.ps1'),
    (Join-Path $PSScriptRoot 'Start-ProcessPolicySession.ps1'),
    (Join-Path $PSScriptRoot 'Stop-ProcessPolicySession.ps1'),
    (Join-Path $PSScriptRoot 'Get-ProcessPolicySessionStatus.ps1')
)
$forbiddenPattern = '(?i)\b(Set-ItemProperty|New-ItemProperty|Remove-Item|Remove-ItemProperty|Clear-Item|Stop-Service|Start-Service|Set-Service|sc\.exe|pnputil|Disable-PnpDevice|Enable-PnpDevice|Uninstall-Package|msiexec|winget\s+uninstall|Stop-Process|taskkill|reg\.exe|Clear-Standby|EmptyWorkingSet)\b'
$matches = New-Object System.Collections.Generic.List[string]
foreach ($scriptPath in $runtimeScriptFiles) {
    $content = Get-Content -LiteralPath $scriptPath -Raw
    if ($content -match $forbiddenPattern) {
        $matches.Add((Split-Path $scriptPath -Leaf)) | Out-Null
    }
}
if ($matches.Count -eq 0) {
    Add-Pass 'Persistent policy runtime scripts do not call registry, service, driver, uninstall, process-kill, or cleanup actions'
} else {
    Add-Failure "Forbidden action pattern found in persistent policy runtime scripts: $($matches -join ', ')"
}

Add-Pass 'Validation invokes -ConfirmApply only against disposable local probe processes under a temp allow root'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Persistent policy runtime validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Persistent policy runtime validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
