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

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Get-ReliabilityProbeProcesses {
    return @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.ProcessName -like 'RooGovernorReliabilityProbe*' }
    )
}

function Stop-ReliabilityProbe {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) { return }

    try { $Process.Refresh() } catch { }
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $Process.Id -Timeout 5 -ErrorAction SilentlyContinue
    }

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if ($null -eq (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 250
    }
}

function Remove-ReliabilityTempRoot {
    param([string]$Path)

    $fullTempRoot = [System.IO.Path]::GetFullPath($Path)
    $systemTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $fullTempRoot.StartsWith($systemTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove non-temp reliability root: $fullTempRoot"
    }

    if (-not (Test-Path -LiteralPath $fullTempRoot)) { return $true }

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            Remove-Item -LiteralPath $fullTempRoot -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            if ($attempt -eq 10) { return $false }
            Start-Sleep -Milliseconds 300
        }
    }

    return $false
}

function Write-ReliabilityGovernorProfile {
    param(
        [string]$Path,
        [string]$CandidateName
    )
    $singleCoreCpuPercent = 100.0 / [math]::Max(1, [Environment]::ProcessorCount)
    $perProcessCpuThresholdPercent = [math]::Max(0.1, [math]::Round($singleCoreCpuPercent * 0.45, 3))
    $restoreCpuThresholdPercent = [math]::Max(0.05, [math]::Round($singleCoreCpuPercent * 0.2, 3))
    $profile = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        profileId = 'governor-reliability-validation'
        name = 'Governor Reliability Validation'
        profileKind = 'process-governor'
        risk = 'low'
        targetScenario = 'Repeated disposable process governor reliability validation.'
        protectedCatalogPath = (Join-Path $repoRoot 'backend\profiles\protected-processes.json')
        governor = [pscustomobject]@{
            thresholds = [pscustomobject]@{
                totalCpuPressureThresholdPercent = 0.1
                perProcessCpuThresholdPercent = $perProcessCpuThresholdPercent
                timeOverThresholdSeconds = 0.3
                minimumRestraintSeconds = 1
                restoreCpuThresholdPercent = $restoreCpuThresholdPercent
                cooldownAfterRestoreSeconds = 0
                maxSessionDurationSeconds = 16
                pollIntervalSeconds = 1
            }
            restraint = [pscustomobject]@{
                priorityClass = 'BelowNormal'
                ioPriority = $null
            }
            excludeForegroundProcess = $false
            candidateSelectors = @(
                [pscustomobject]@{
                    ruleId = 'reliability-calm-probe'
                    enabled = $true
                    match = [pscustomobject]@{
                        processNames = @($CandidateName)
                    }
                    reason = 'Disposable reliability probe exceeded governor CPU thresholds.'
                    reasonCodes = @('RELIABILITY_GOVERNOR_CANDIDATE')
                    risk = 'low'
                }
            )
        }
        telemetryTargets = @('background-cpu-pressure','restraint-count','restore-count')
        rollbackPolicy = [pscustomobject]@{
            supported = $true
            scope = 'process-governor-process-controls'
            stateRoot = 'temp-reliability-state'
            restoreOriginalPriorityClass = $true
        }
        safety = [pscustomobject]@{
            confirmedApplyChanges = @('PriorityClass')
            continuousEnforcement = $true
            runtimeService = $false
            foregroundExclusion = $false
        }
    }
    ($profile | ConvertTo-Json -Depth 18) | Set-Content -LiteralPath $Path -Encoding UTF8
}

$initialStateCount = Get-StateEntryCount
if ($initialStateCount -eq 0) {
    Add-Pass 'backend/state is empty before repeated governor reliability validation'
} else {
    Add-Failure "backend/state is not empty before repeated governor reliability validation: count=$initialStateCount"
}

$initialProbes = @(Get-ReliabilityProbeProcesses)
if ($initialProbes.Count -eq 0) {
    Add-Pass 'No governor reliability probes were running before validation'
} else {
    Add-Failure "Governor reliability probe process(es) already running: $(@($initialProbes | ForEach-Object { $_.Id }) -join ', ')"
}

$runResults = New-Object System.Collections.Generic.List[object]

for ($runIndex = 1; $runIndex -le 3; $runIndex++) {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-governor-reliability-$([guid]::NewGuid().ToString('N'))"
    $probe = $null
    $cleanupDone = $false
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $probeName = "RooGovernorReliabilityProbe$runIndex.exe"
        $probeExe = Join-Path $tempRoot $probeName
        Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $probeExe -Force
        $profilePath = Join-Path $tempRoot 'governor-profile.json'
        $stateRoot = Join-Path $tempRoot 'state'
        Write-ReliabilityGovernorProfile -Path $profilePath -CandidateName $probeName

        $probe = Start-Process -FilePath $probeExe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','$end=(Get-Date).AddSeconds(6); while ((Get-Date) -lt $end) { [Math]::Sqrt(144) | Out-Null }; Start-Sleep -Seconds 90' -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 800
        $before = Get-RooProcessControlState $probe.Id $null
        $session = & (Join-Path $PSScriptRoot 'Start-ProcessGovernorSession.ps1') `
            -ProfilePath $profilePath `
            -SampleIntervalMilliseconds 400 `
            -MaxDurationSeconds 16 `
            -StateRoot $stateRoot `
            -ConfirmApply | ConvertFrom-Json
        $after = Get-RooProcessControlState $probe.Id $null
        $changed = @($session.changedItems | Where-Object { $_.processId -eq $probe.Id }) | Select-Object -First 1
        $restored = @($session.restoredItems | Where-Object { $_.processId -eq $probe.Id }) | Select-Object -First 1
        $activeCount = @($session.activeRestraints).Count

        if ($changed -and $restored -and $after.priorityClass -eq $before.priorityClass -and $activeCount -eq 0 -and $session.restorable -eq $false) {
            Add-Pass "Reliability run $runIndex restrained and restored disposable probe: applied=$($changed.appliedPriorityClass) restored=$($after.priorityClass)"
        } else {
            Add-Failure "Reliability run $runIndex failed restore proof: changed=$([bool]$changed), restored=$([bool]$restored), current=$($after.priorityClass), expected=$($before.priorityClass), active=$activeCount, restorable=$($session.restorable)"
            if ($session.restorable -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$session.sessionPath)) {
                & (Join-Path $PSScriptRoot 'Stop-ProcessGovernorSession.ps1') -SessionPath $session.sessionPath -ConfirmApply | Out-Null
            }
        }

        Stop-ReliabilityProbe -Process $probe
        $probe = $null

        $fullTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
        $removedTempRoot = Remove-ReliabilityTempRoot -Path $tempRoot
        $cleanupDone = $true

        $leftoverProbes = @(Get-ReliabilityProbeProcesses)
        if ($leftoverProbes.Count -eq 0) {
            Add-Pass "Reliability run $runIndex left no disposable probe process behind"
        } else {
            Add-Failure "Reliability run $runIndex left disposable probe process(es): $(@($leftoverProbes | ForEach-Object { $_.Id }) -join ', ')"
        }

        $stateAfterRun = Get-StateEntryCount
        if ($stateAfterRun -eq 0) {
            Add-Pass "backend/state is empty after reliability run $runIndex"
        } else {
            Add-Failure "backend/state is not empty after reliability run ${runIndex}: count=$stateAfterRun"
        }

        if ($removedTempRoot -and -not (Test-Path -LiteralPath $fullTempRoot)) {
            Add-Pass "Reliability run $runIndex temp state root was cleaned up"
        } else {
            Add-Failure "Reliability run $runIndex temp state root remained: $fullTempRoot"
        }

        $runResults.Add([pscustomobject]@{
            runIndex = $runIndex
            changed = [bool]$changed
            restored = [bool]$restored
            finalPriorityClass = $after.priorityClass
            expectedPriorityClass = $before.priorityClass
            activeRestraintCount = $activeCount
            pollCount = $session.pollCount
        }) | Out-Null
    } catch {
        Add-Failure "Reliability run $runIndex failed: $($_.Exception.Message)"
    } finally {
        Stop-ReliabilityProbe -Process $probe
        if (-not $cleanupDone) {
            Remove-ReliabilityTempRoot -Path $tempRoot | Out-Null
        }
    }
}

if ($runResults.Count -eq 3 -and @($runResults | Where-Object { $_.changed -and $_.restored -and $_.activeRestraintCount -eq 0 }).Count -eq 3) {
    Add-Pass 'Repeated governor reliability completed 3 consecutive live disposable apply/restore runs'
} else {
    Add-Failure "Repeated governor reliability did not complete 3 successful runs: successes=$(@($runResults | Where-Object { $_.changed -and $_.restored -and $_.activeRestraintCount -eq 0 }).Count)"
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Process governor reliability validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Process governor reliability validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
