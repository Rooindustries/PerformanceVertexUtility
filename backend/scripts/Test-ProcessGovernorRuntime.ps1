$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $PSScriptRoot 'ProcessGovernor.Common.ps1')
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
        if ([string]$proc.ProcessName -like 'Roo.OptimizationSuite*' -or [string]$proc.ProcessName -like 'RooOptimizationSuite*') {
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
    foreach ($id in @(Get-RooArray $Before)) { $beforeSet[[int]$id] = $true }
    return @(@(Get-RooArray $After) | Where-Object { -not $beforeSet.ContainsKey([int]$_) })
}

function Write-GovernorValidationProfile {
    param(
        [string]$Path,
        [string[]]$CandidateNames,
        [string]$ProtectedName,
        [int]$MaxDurationSeconds
    )
    $singleCoreCpuPercent = 100.0 / [math]::Max(1, [Environment]::ProcessorCount)
    $perProcessCpuThresholdPercent = [math]::Max(0.1, [math]::Round($singleCoreCpuPercent * 0.45, 3))
    $restoreCpuThresholdPercent = [math]::Max(0.05, [math]::Round($singleCoreCpuPercent * 0.2, 3))
    $profile = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        profileId = 'live-governor-validation'
        name = 'Live Governor Validation'
        profileKind = 'process-governor'
        risk = 'low'
        targetScenario = 'Disposable process governor validation.'
        protectedCatalogPath = (Join-Path $repoRoot 'backend\profiles\protected-processes.json')
        governor = [pscustomobject]@{
            thresholds = [pscustomobject]@{
                totalCpuPressureThresholdPercent = 0.1
                perProcessCpuThresholdPercent = $perProcessCpuThresholdPercent
                timeOverThresholdSeconds = 0.3
                minimumRestraintSeconds = 1
                restoreCpuThresholdPercent = $restoreCpuThresholdPercent
                cooldownAfterRestoreSeconds = 0
                maxSessionDurationSeconds = $MaxDurationSeconds
                pollIntervalSeconds = 1
            }
            restraint = [pscustomobject]@{
                priorityClass = 'BelowNormal'
                ioPriority = $null
            }
            excludeForegroundProcess = $true
            protectedProcesses = @(
                [pscustomobject]@{
                    itemId = 'protect-live-validation-probe'
                    type = 'process'
                    names = @($ProtectedName)
                    reason = 'Disposable protected validation probe is excluded from governor restraint.'
                    reasonCodes = @('LIVE_VALIDATION_PROTECTED_PROBE')
                    defaultAction = 'block'
                }
            )
            candidateSelectors = @(
                [pscustomobject]@{
                    ruleId = 'live-validation-probes'
                    enabled = $true
                    match = [pscustomobject]@{
                        processNames = @($CandidateNames)
                    }
                    reason = 'Disposable validation probe exceeded governor CPU thresholds.'
                    reasonCodes = @('LIVE_VALIDATION_GOVERNOR_CANDIDATE')
                    risk = 'low'
                }
            )
        }
        telemetryTargets = @('background-cpu-pressure','restraint-count','restore-count')
        rollbackPolicy = [pscustomobject]@{
            supported = $true
            scope = 'process-governor-process-controls'
            stateRoot = 'temp-validation-state'
            restoreOriginalPriorityClass = $true
        }
        safety = [pscustomobject]@{
            confirmedApplyChanges = @('PriorityClass')
            continuousEnforcement = $true
            runtimeService = $false
            foregroundExclusion = $true
        }
    }
    ($profile | ConvertTo-Json -Depth 18) | Set-Content -LiteralPath $Path -Encoding UTF8
}

$requiredFiles = @(
    'backend\profiles\probalance-governor.profile.json',
    'backend\scripts\ProcessGovernor.Common.ps1',
    'backend\scripts\Preview-ProcessGovernor.ps1',
    'backend\scripts\Start-ProcessGovernorSession.ps1',
    'backend\scripts\Stop-ProcessGovernorSession.ps1',
    'backend\scripts\Get-ProcessGovernorSessionStatus.ps1',
    'backend\samples\process-governor-preview.sample.json',
    'backend\samples\process-governor-session-confirmed.sample.json',
    'backend\samples\process-governor-session-status.sample.json',
    'backend\samples\process-governor-stop-preview.sample.json',
    'backend\samples\process-governor-stop-result.sample.json'
)
foreach ($relative in $requiredFiles) {
    Test-RequiredFile $relative
}

foreach ($root in @(
    (Join-Path $repoRoot 'backend\contracts'),
    (Join-Path $repoRoot 'backend\samples'),
    (Join-Path $repoRoot 'backend\profiles'),
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
    $dryRunStateRoot = Join-Path (Join-Path $repoRoot 'backend\state') "process-governor-dry-run-validation-$([guid]::NewGuid().ToString('N'))"
    $dryRun = & (Join-Path $PSScriptRoot 'Start-ProcessGovernorSession.ps1') `
        -ProfilePath (Join-Path $repoRoot 'backend\profiles\probalance-governor.profile.json') `
        -SampleIntervalMilliseconds 200 `
        -MaxDurationSeconds 1 `
        -StateRoot $dryRunStateRoot | ConvertFrom-Json
    if ($dryRun.actionId -eq 'performance.governor.startSession' -and $dryRun.dryRun -eq $true -and $dryRun.status -eq 'completed') {
        Add-Pass 'Dry-run process governor session returned a completed preview envelope'
    } else {
        Add-Failure 'Dry-run process governor session returned an unexpected envelope'
    }
    if ($null -eq $dryRun.sessionPath -and $null -eq $dryRun.backupManifestPath -and $dryRun.restorable -eq $false) {
        Add-Pass 'Dry-run process governor session wrote no session or backup state'
    } else {
        Add-Failure 'Dry-run process governor session reported session or backup state'
    }
    if ($dryRun.runtimeEvidence.productionRuntimeCapable -eq $true -and $dryRun.runtimeEvidence.externalProcessGovernorDependencyRequired -eq $false -and $dryRun.runtimeEvidence.frontendProcessRequired -eq $false -and $dryRun.runtimeEvidence.dryRunWritesState -eq $false) {
        Add-Pass 'Dry-run process governor envelope reports native production runtime evidence without frontend or Process Lasso dependency'
    } else {
        Add-Failure 'Dry-run process governor runtime evidence was missing or unsafe'
    }
    if (-not (Test-Path -LiteralPath $dryRunStateRoot)) {
        Add-Pass 'Dry-run process governor session left no backend state root behind'
    } else {
        Add-Failure "Dry-run process governor session created state root: $dryRunStateRoot"
    }
} catch {
    Add-Failure "Dry-run process governor session failed: $($_.Exception.Message)"
}

try {
    $status = & (Join-Path $PSScriptRoot 'Get-ProcessGovernorSessionStatus.ps1') `
        -StateRoot (Join-Path $repoRoot 'backend\state\missing-process-governor-validation') | ConvertFrom-Json
    if ($status.actionId -eq 'performance.governor.sessionStatus' -and $status.status -eq 'notFound') {
        Add-Pass 'Process governor status reports notFound cleanly when no session exists'
    } else {
        Add-Failure 'Process governor status missing-session result had an unexpected shape'
    }
    if ($status.runtimeEvidence.productionRuntimeCapable -eq $true -and $status.runtimeEvidence.processLassoRequired -eq $false -and $status.runtimeEvidence.frontendProcessRequired -eq $false) {
        Add-Pass 'Process governor status contract exposes runtime capability evidence even when no session exists'
    } else {
        Add-Failure 'Process governor status missing-session runtime evidence was incomplete'
    }
} catch {
    Add-Failure "Process governor status notFound check failed: $($_.Exception.Message)"
}

$stateBefore = Get-StateEntryCount
$frontendBefore = @(Get-FrontendProcessIds)
$backendHostBefore = @(Get-BackendScriptHostProcesses)
$externalGovernorBefore = @(Get-ExternalGovernorProcessIds)
$liveRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-process-governor-live-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
$busyProbe = $null
$protectedProbe = $null
$calmProbe = $null
try {
    New-Item -ItemType Directory -Path $liveRoot -Force | Out-Null
    $busyExe = Join-Path $liveRoot 'RooGovernorBusyProbe.exe'
    $protectedExe = Join-Path $liveRoot 'RooGovernorProtectedProbe.exe'
    $calmExe = Join-Path $liveRoot 'RooGovernorCalmProbe.exe'
    Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $busyExe -Force
    Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $protectedExe -Force
    Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $calmExe -Force
    $profilePath = Join-Path $liveRoot 'governor-profile.json'
    $stateRoot = Join-Path $liveRoot 'state'
    Write-GovernorValidationProfile `
        -Path $profilePath `
        -CandidateNames @('RooGovernorBusyProbe.exe','RooGovernorProtectedProbe.exe','RooGovernorCalmProbe.exe') `
        -ProtectedName 'RooGovernorProtectedProbe.exe' `
        -MaxDurationSeconds 7

    $busyProbe = Start-Process -FilePath $busyExe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','while ($true) { [Math]::Sqrt(144) | Out-Null }' -WindowStyle Hidden -PassThru
    $protectedProbe = Start-Process -FilePath $protectedExe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800
    $beforeBusy = Get-RooProcessControlState $busyProbe.Id $null
    $beforeProtected = Get-RooProcessControlState $protectedProbe.Id $null

    $preview = & (Join-Path $PSScriptRoot 'Preview-ProcessGovernor.ps1') `
        -ProfilePath $profilePath `
        -SampleIntervalMilliseconds 400 `
        -ForegroundProcessId $protectedProbe.Id | ConvertFrom-Json
    $afterPreviewBusy = Get-RooProcessControlState $busyProbe.Id $null
    $previewBusy = @($preview.preview | Where-Object { $_.processId -eq $busyProbe.Id }) | Select-Object -First 1
    $previewProtected = @($preview.preview | Where-Object { $_.processId -eq $protectedProbe.Id }) | Select-Object -First 1

    if ($preview.dryRun -eq $true -and $previewBusy.requiresConfirmation -eq $true -and $afterPreviewBusy.priorityClass -eq $beforeBusy.priorityClass) {
        Add-Pass "Preview proposed disposable busy-probe restraint without changing priority: before=$($beforeBusy.priorityClass) afterPreview=$($afterPreviewBusy.priorityClass)"
    } else {
        Add-Failure 'Preview did not propose busy-probe restraint or changed priority unexpectedly'
    }
    if ($previewProtected.blocked -eq $true -and ($previewProtected.reasonCodes -contains 'LIVE_VALIDATION_PROTECTED_PROBE') -and ($previewProtected.reasonCodes -contains 'FOREGROUND_PROCESS_EXCLUDED')) {
        Add-Pass "Manual-review foreground-style probe skipped with reason codes: $($previewProtected.reasonCodes -join ',')"
    } else {
        Add-Failure 'Manual-review foreground-style probe was not skipped with review and foreground proof'
    }
    if ($beforeProtected.priorityClass -eq (Get-RooProcessControlState $protectedProbe.Id $null).priorityClass) {
        Add-Pass "Manual-review probe priority stayed unchanged during preview: $($beforeProtected.priorityClass)"
    } else {
        Add-Failure 'Protected probe priority changed during preview'
    }

    $session = & (Join-Path $PSScriptRoot 'Start-ProcessGovernorSession.ps1') `
        -ProfilePath $profilePath `
        -SampleIntervalMilliseconds 400 `
        -MaxDurationSeconds 3 `
        -ForegroundProcessId $protectedProbe.Id `
        -StateRoot $stateRoot `
        -ConfirmApply | ConvertFrom-Json
    $afterApplyBusy = Get-RooProcessControlState $busyProbe.Id $null
    $changedBusy = @($session.changedItems | Where-Object { $_.processId -eq $busyProbe.Id }) | Select-Object -First 1
    if ($session.dryRun -eq $false -and $changedBusy -and $afterApplyBusy.priorityClass -eq 'BelowNormal') {
        Add-Pass "Live governor restrained busy probe: before=$($beforeBusy.priorityClass) applied=$($afterApplyBusy.priorityClass)"
    } else {
        Add-Failure "Live governor did not restrain busy probe: current=$($afterApplyBusy.priorityClass)"
    }
    $statusAfterStart = & (Join-Path $PSScriptRoot 'Get-ProcessGovernorSessionStatus.ps1') -SessionPath $session.sessionPath | ConvertFrom-Json
    if ($statusAfterStart.status -eq 'restorable' -and $statusAfterStart.summary.activeRestraintCount -ge 1) {
        Add-Pass 'Process governor status is restorable with an active restraint after confirmed apply'
    } else {
        Add-Failure 'Process governor status did not report active restorable restraint'
    }
    if ($statusAfterStart.runtimeEvidence.stateBacked -eq $true -and $statusAfterStart.runtimeEvidence.restoreContractAvailable -eq $true -and $statusAfterStart.runtimeEvidence.externalProcessGovernorDependencyRequired -eq $false -and $statusAfterStart.runtimeEvidence.frontendProcessRequired -eq $false) {
        Add-Pass 'Confirmed process governor status reports state-backed restore-ready native runtime evidence'
    } else {
        Add-Failure 'Confirmed process governor status runtime evidence was incomplete'
    }
    $restorePreview = & (Join-Path $PSScriptRoot 'Stop-ProcessGovernorSession.ps1') -SessionPath $session.sessionPath | ConvertFrom-Json
    $afterRestorePreview = Get-RooProcessControlState $busyProbe.Id $null
    if ($restorePreview.dryRun -eq $true -and $afterRestorePreview.priorityClass -eq 'BelowNormal') {
        Add-Pass 'Process governor stop preview did not restore or change the busy probe'
    } else {
        Add-Failure 'Process governor stop preview changed the busy probe unexpectedly'
    }
    $restore = & (Join-Path $PSScriptRoot 'Stop-ProcessGovernorSession.ps1') -SessionPath $session.sessionPath -ConfirmApply | ConvertFrom-Json
    $afterRestoreBusy = Get-RooProcessControlState $busyProbe.Id $null
    if ($restore.dryRun -eq $false -and @($restore.restoredItems).Count -ge 1 -and $afterRestoreBusy.priorityClass -eq $beforeBusy.priorityClass) {
        Add-Pass "Confirmed process governor stop restored busy probe: applied=$($afterApplyBusy.priorityClass) restored=$($afterRestoreBusy.priorityClass)"
    } else {
        Add-Failure "Confirmed process governor stop did not restore busy probe: restored=$($afterRestoreBusy.priorityClass) expected=$($beforeBusy.priorityClass)"
    }

    if ($busyProbe -and -not $busyProbe.HasExited) {
        Stop-Process -Id $busyProbe.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $busyProbe.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
    $busyProbe = $null

    $calmProbe = Start-Process -FilePath $calmExe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','$end=(Get-Date).AddSeconds(6); while ((Get-Date) -lt $end) { [Math]::Sqrt(144) | Out-Null }; Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800
    $beforeCalm = Get-RooProcessControlState $calmProbe.Id $null
    $calmSession = & (Join-Path $PSScriptRoot 'Start-ProcessGovernorSession.ps1') `
        -ProfilePath $profilePath `
        -SampleIntervalMilliseconds 400 `
        -MaxDurationSeconds 16 `
        -ForegroundProcessId $protectedProbe.Id `
        -StateRoot $stateRoot `
        -ConfirmApply | ConvertFrom-Json
    $afterCalmSession = Get-RooProcessControlState $calmProbe.Id $null
    $calmChanged = @($calmSession.changedItems | Where-Object { $_.processId -eq $calmProbe.Id }) | Select-Object -First 1
    $calmRestored = @($calmSession.restoredItems | Where-Object { $_.processId -eq $calmProbe.Id }) | Select-Object -First 1
    if ($calmChanged -and $calmRestored -and $afterCalmSession.priorityClass -eq $beforeCalm.priorityClass) {
        Add-Pass "Governor auto-restored calm probe after CPU dropped: applied=$($calmChanged.appliedPriorityClass) restored=$($afterCalmSession.priorityClass)"
    } else {
        Add-Failure "Governor did not auto-restore calm probe after CPU dropped: changed=$([bool]$calmChanged), restored=$([bool]$calmRestored), current=$($afterCalmSession.priorityClass), expected=$($beforeCalm.priorityClass)"
        if ($calmSession.restorable -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$calmSession.sessionPath)) {
            & (Join-Path $PSScriptRoot 'Stop-ProcessGovernorSession.ps1') -SessionPath $calmSession.sessionPath -ConfirmApply | Out-Null
        }
    }

    $fullStateRoot = [System.IO.Path]::GetFullPath($stateRoot)
    $fullLiveRoot = [System.IO.Path]::GetFullPath($liveRoot)
    if ($session.sessionPath -like "$fullStateRoot*" -and $calmSession.sessionPath -like "$fullStateRoot*") {
        Add-Pass 'Confirmed process governor state was isolated under the temp validation root'
    } else {
        Add-Failure 'Confirmed process governor state was not isolated under the temp validation root'
    }

    if ($protectedProbe -and -not $protectedProbe.HasExited) {
        Stop-Process -Id $protectedProbe.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $protectedProbe.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
    if ($calmProbe -and -not $calmProbe.HasExited) {
        Stop-Process -Id $calmProbe.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $calmProbe.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
    $protectedProbe = $null
    $calmProbe = $null
    $tempRoot = [System.IO.Path]::GetTempPath()
    if ($fullLiveRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullLiveRoot)) {
        Remove-Item -LiteralPath $fullLiveRoot -Recurse -Force
    }
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $fullLiveRoot)) {
        Add-Pass 'Disposable governor probe processes and temp state root were cleaned up'
    } else {
        Add-Failure 'Disposable governor temp state root remained after cleanup'
    }
} catch {
    Add-Failure "Live process governor validation failed: $($_.Exception.Message)"
} finally {
    foreach ($probe in @($busyProbe, $protectedProbe, $calmProbe)) {
        if ($probe -and -not $probe.HasExited) {
            Stop-Process -Id $probe.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $probe.Id -Timeout 5 -ErrorAction SilentlyContinue
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

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after process governor runtime validation'
} else {
    Add-Failure "backend/state is not empty or changed during process governor validation: before=$stateBefore after=$stateAfter"
}

$frontendAfter = @(Get-FrontendProcessIds)
$newFrontendIds = @(Get-NewIds $frontendBefore $frontendAfter)
if ($newFrontendIds.Count -eq 0) {
    Add-Pass 'Process governor validation launched no frontend process'
} else {
    Add-Failure "Process governor validation launched frontend process id(s): $($newFrontendIds -join ', ')"
}

$backendHostAfter = @(Get-BackendScriptHostProcesses)
$backendHostBeforeIds = @($backendHostBefore | ForEach-Object { [int]$_.processId })
$backendHostAfterIds = @($backendHostAfter | ForEach-Object { [int]$_.processId })
$newBackendHostIds = @(Get-NewIds $backendHostBeforeIds $backendHostAfterIds)
if ($newBackendHostIds.Count -eq 0) {
    Add-Pass 'Process governor validation left no backend script host process behind'
} else {
    Add-Failure "Process governor validation left backend script host process id(s): $($newBackendHostIds -join ', ')"
}

$externalGovernorAfter = @(Get-ExternalGovernorProcessIds)
$newExternalGovernorIds = @(Get-NewIds $externalGovernorBefore $externalGovernorAfter)
if ($newExternalGovernorIds.Count -eq 0) {
    Add-Pass 'Process governor validation launched no external process governor utility'
} else {
    Add-Failure "Process governor validation launched external process governor process id(s): $($newExternalGovernorIds -join ', ')"
}

$runtimeScriptFiles = @(
    (Join-Path $PSScriptRoot 'ProcessGovernor.Common.ps1'),
    (Join-Path $PSScriptRoot 'Preview-ProcessGovernor.ps1'),
    (Join-Path $PSScriptRoot 'Start-ProcessGovernorSession.ps1'),
    (Join-Path $PSScriptRoot 'Stop-ProcessGovernorSession.ps1'),
    (Join-Path $PSScriptRoot 'Get-ProcessGovernorSessionStatus.ps1')
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
    Add-Pass 'Process governor runtime scripts do not call registry, service, driver, uninstall, process-kill, or cleanup actions'
} else {
    Add-Failure "Forbidden action pattern found in process governor runtime scripts: $($matches -join ', ')"
}

Add-Pass 'Validation invokes -ConfirmApply only against disposable local probe processes'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Process governor runtime validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Process governor runtime validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
