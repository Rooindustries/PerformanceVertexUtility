$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.Common.ps1')

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $PSScriptRoot 'ResidentSessionHost.Common.ps1')
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

function Get-FrontendProcessIds {
    $names = @('Roo.OptimizationSuite.App','RooOptimizationSuite.App','Roo.OptimizationSuite','RooOptimizationSuite')
    $items = New-Object System.Collections.Generic.List[int]
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($names -contains [string]$proc.ProcessName -or [string]$proc.ProcessName -like 'Roo.OptimizationSuite*') {
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
                commandLine = $commandLine
            }) | Out-Null
        }
    }
    return @($items.ToArray())
}

function Test-BudgetEvaluation {
    param(
        [object]$Evaluation,
        [string]$Label
    )
    if ($null -eq $Evaluation) {
        Add-Failure "$Label did not include budget evaluation"
        return
    }
    if ($Evaluation.withinBudget -eq $true -and $Evaluation.idleCpuWithinBudget -eq $true -and $Evaluation.privateBytesWithinBudget -eq $true -and $Evaluation.stateEntryCountWithinBudget -eq $true -and $Evaluation.persistentUiRequirementWithinBudget -eq $true) {
        Add-Pass "$Label stayed within overall, idle CPU, memory, state, and no-UI budgets"
    } else {
        Add-Failure "$Label exceeded budget: overall=$($Evaluation.withinBudget), idleCpu=$($Evaluation.idleCpuWithinBudget), memory=$($Evaluation.privateBytesWithinBudget), state=$($Evaluation.stateEntryCountWithinBudget), noUi=$($Evaluation.persistentUiRequirementWithinBudget)"
    }
}

$requiredFiles = @(
    'backend\profiles\lightweight-governor-budget.profile.json',
    'backend\scripts\ResidentSessionHost.Common.ps1',
    'backend\scripts\Measure-RooBackendFootprint.ps1',
    'backend\scripts\Start-RooResidentSessionHost.ps1',
    'backend\scripts\Get-RooResidentHostStatus.ps1',
    'backend\samples\backend-footprint-result.sample.json',
    'backend\samples\lightweight-governor-budget.sample.json',
    'backend\samples\resident-host-status.sample.json',
    'backend\samples\all-control-policy-validation-result.sample.json'
)
foreach ($relative in $requiredFiles) {
    Test-RequiredFile $relative
}

try {
    $utilitiesManifest = Read-RooJsonFile (Join-Path $repoRoot 'modules\utilities_manifest.json')
    $externalGovernor = @($utilitiesManifest.tools | Where-Object { $_.id -eq 'process-lasso' }) | Select-Object -First 1
    if ($externalGovernor -and $externalGovernor.autoRunAllowed -eq $false -and [string]$externalGovernor.appRole -eq 'optional-manual-reference') {
        Add-Pass 'Utility manifest marks Process Lasso as optional and not autorun-required for backend operation'
    } else {
        Add-Failure 'Utility manifest does not prove Process Lasso is optional for backend operation'
    }
} catch {
    Add-Failure "Utility manifest dependency check failed: $($_.Exception.Message)"
}

$frontendBefore = @(Get-FrontendProcessIds)
$backendBefore = @(Get-BackendScriptHostProcesses)
$stateBefore = Get-RooBackendStateEntryCount $repoRoot.Path
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-resident-backend-runtime-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $footprintOut = Join-Path $tempRoot 'footprint-output.json'
    $footprintErr = Join-Path $tempRoot 'footprint-error.txt'
    $footprintArgs = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'Measure-RooBackendFootprint.ps1'),
        '-SampleDurationSeconds',
        '3',
        '-PollIntervalMilliseconds',
        '1000',
        '-BudgetProfilePath',
        (Join-Path $repoRoot 'backend\profiles\lightweight-governor-budget.profile.json')
    )
    $footprintProc = Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-RooWindowsArguments $footprintArgs) -WindowStyle Hidden -RedirectStandardOutput $footprintOut -RedirectStandardError $footprintErr -Wait -PassThru
    if ($null -ne $footprintProc.ExitCode -and $footprintProc.ExitCode -ne 0) {
        $footprintErrorText = if (Test-Path -LiteralPath $footprintErr) { Get-Content -LiteralPath $footprintErr -Raw } else { '' }
        Add-Failure "Footprint measurement host exited with code $($footprintProc.ExitCode): $footprintErrorText"
    }
    $footprint = Get-Content -LiteralPath $footprintOut -Raw | ConvertFrom-Json
    if ($footprint.actionId -eq 'backend.measureFootprint' -and $footprint.status -eq 'completed' -and $footprint.currentProcessCount -gt 0 -and $footprint.backendScriptProcess.cpuTimeDeltaSeconds -ge 0 -and $footprint.elapsedRuntimeSeconds -gt 0) {
        Add-Pass "Footprint measurement returned process count $($footprint.currentProcessCount), private bytes $($footprint.backendScriptProcess.privateBytes), CPU delta $($footprint.backendScriptProcess.cpuTimeDeltaSeconds)s"
    } else {
        Add-Failure 'Footprint measurement returned an unexpected contract shape'
    }
    if ($footprint.backendScriptProcess.handleCountAvailable -eq $true -and $footprint.backendScriptProcess.handleCount -ge 0) {
        Add-Pass "Footprint measurement reported handle count $($footprint.backendScriptProcess.handleCount)"
    } else {
        Add-Pass 'Footprint measurement reported handle count as unavailable without failing'
    }
    Test-BudgetEvaluation $footprint.budgetEvaluation 'Footprint measurement'

    $residentOut = Join-Path $tempRoot 'resident-output.json'
    $residentErr = Join-Path $tempRoot 'resident-error.txt'
    $residentArgs = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'Start-RooResidentSessionHost.ps1'),
        '-MaxDurationSeconds',
        '4',
        '-PollIntervalMilliseconds',
        '1000',
        '-BudgetProfilePath',
        (Join-Path $repoRoot 'backend\profiles\lightweight-governor-budget.profile.json')
    )
    $residentProc = Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-RooWindowsArguments $residentArgs) -WindowStyle Hidden -RedirectStandardOutput $residentOut -RedirectStandardError $residentErr -Wait -PassThru
    if ($null -eq $residentProc.ExitCode -or $residentProc.ExitCode -eq 0) {
        Add-Pass "Bounded resident host process exited cleanly: pid=$($residentProc.Id)"
    } else {
        $errText = if (Test-Path -LiteralPath $residentErr) { Get-Content -LiteralPath $residentErr -Raw } else { '' }
        Add-Failure "Bounded resident host exited with code $($residentProc.ExitCode): $errText"
    }
    $resident = Get-Content -LiteralPath $residentOut -Raw | ConvertFrom-Json
    if ($resident.actionId -eq 'backend.residentHost.start' -and $resident.status -eq 'completed' -and $resident.bounds.boundedForegroundSession -eq $true -and $resident.bounds.unboundedLoop -eq $false -and $resident.pollCount -gt 0) {
        Add-Pass "Resident host completed bounded foreground session with $($resident.pollCount) poll(s)"
    } else {
        Add-Failure 'Resident host output did not prove bounded foreground execution'
    }
    if ($resident.host.serviceReady -eq $true -and $resident.host.serviceInstalled -eq $false -and $resident.host.serviceInstallActionPerformed -eq $false) {
        Add-Pass 'Resident host is service-ready without installing or changing a service'
    } else {
        Add-Failure 'Resident host service boundary was not explicit'
    }
    if ($resident.state.wroteState -eq $false -and $resident.state.unboundedStateGrowthAllowed -eq $false) {
        Add-Pass 'Resident host wrote no state and reports bounded state policy'
    } else {
        Add-Failure 'Resident host wrote state or allowed unbounded state growth'
    }
    if ($resident.dependencyProof.frontendProcessRequired -eq $false -and $resident.dependencyProof.persistentUiProcessRequired -eq $false -and $resident.dependencyProof.externalProcessGovernorDependencyRequired -eq $false -and $resident.dependencyProof.processLassoProcessStartedByHost -eq $false) {
        Add-Pass 'Resident host requires no frontend, persistent UI process, or external process governor dependency'
    } else {
        Add-Failure 'Resident host dependency proof was not clean'
    }
    Test-BudgetEvaluation $resident.footprint.budgetEvaluation 'Resident host idle monitor'

    $status = & (Join-Path $PSScriptRoot 'Get-RooResidentHostStatus.ps1') -ProcessId $PID | ConvertFrom-Json
    if ($status.actionId -eq 'backend.residentHost.status' -and $status.status -eq 'active' -and $status.host.executionMode -eq 'foregroundCli') {
        Add-Pass 'Resident host status contract reports a live foreground CLI host'
    } else {
        Add-Failure 'Resident host status contract returned an unexpected shape'
    }

    $backendAfter = @(Get-BackendScriptHostProcesses)
    $beforeIds = @{}
    foreach ($item in $backendBefore) { $beforeIds[[int]$item.processId] = $true }
    $newBackendHosts = @($backendAfter | Where-Object { -not $beforeIds.ContainsKey([int]$_.processId) })
    if ($newBackendHosts.Count -eq 0) {
        Add-Pass 'No leftover backend script host processes remained after resident validation'
    } else {
        Add-Failure "Leftover backend script host process(es) remained: $(@($newBackendHosts | ForEach-Object { "$($_.name):$($_.processId)" }) -join ', ')"
    }

    $frontendAfter = @(Get-FrontendProcessIds)
    $frontendBeforeIds = @{}
    foreach ($id in $frontendBefore) { $frontendBeforeIds[[int]$id] = $true }
    $newFrontend = @($frontendAfter | Where-Object { -not $frontendBeforeIds.ContainsKey([int]$_) })
    if ($newFrontend.Count -eq 0) {
        Add-Pass 'No frontend process was launched during resident validation'
    } else {
        Add-Failure "Frontend process id(s) appeared during resident validation: $($newFrontend -join ', ')"
    }

    $stateAfter = Get-RooBackendStateEntryCount $repoRoot.Path
    if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
        Add-Pass 'backend/state remains empty after resident backend validation'
    } else {
        Add-Failure "backend/state is not empty or changed during resident validation: before=$stateBefore after=$stateAfter"
    }

    $fullTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $systemTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($fullTempRoot.StartsWith($systemTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullTempRoot)) {
        Remove-Item -LiteralPath $fullTempRoot -Recurse -Force
    }
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $fullTempRoot)) {
        Add-Pass 'Resident validation temp output was cleaned up'
    } else {
        Add-Failure 'Resident validation temp output remained after cleanup'
    }
} catch {
    Add-Failure "Resident backend runtime validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone) {
        $fullTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
        $systemTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($fullTempRoot.StartsWith($systemTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullTempRoot)) {
            Remove-Item -LiteralPath $fullTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Resident backend runtime validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Resident backend runtime validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
