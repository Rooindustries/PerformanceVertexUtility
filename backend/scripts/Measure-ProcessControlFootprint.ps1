param(
    [int]$SampleDurationSeconds = 4,
    [int]$PollIntervalMilliseconds = 500,
    [string]$BaselinePath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Remove-ProcessControlMeasureRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $full = [System.IO.Path]::GetFullPath($Path)
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $full.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove non-temp process-control measurement root: $full"
    }
    if (-not (Test-Path -LiteralPath $full)) { return $true }
    Remove-Item -LiteralPath $full -Recurse -Force
    return (-not (Test-Path -LiteralPath $full))
}

function Get-ProcessControlMeasurementSample {
    param([System.Diagnostics.Process]$Process)

    $live = Get-Process -Id $Process.Id -ErrorAction Stop
    $workingSet = [uint64]0
    $peakWorkingSet = [uint64]0
    $cpu = [double]0
    try { $workingSet = [uint64]$live.WorkingSet64 } catch { }
    try { $peakWorkingSet = [uint64]$live.PeakWorkingSet64 } catch { $peakWorkingSet = $workingSet }
    try { $cpu = [double]$live.CPU } catch { }
    if ($peakWorkingSet -lt $workingSet) { $peakWorkingSet = $workingSet }

    return [pscustomobject]@{
        workingSetBytes = $workingSet
        peakWorkingSetBytes = $peakWorkingSet
        cpuSeconds = $cpu
    }
}

function Measure-ProcessControlProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Tool,
        [int]$SampleDurationSeconds,
        [int]$PollIntervalMilliseconds
    )

    $initial = Get-ProcessControlMeasurementSample -Process $Process
    $latest = $initial
    $peak = [uint64]$initial.peakWorkingSetBytes
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $SampleDurationSeconds) {
        $remainingMs = [int](([double]$SampleDurationSeconds - $watch.Elapsed.TotalSeconds) * 1000)
        if ($remainingMs -le 0) { break }
        $sleepMs = [math]::Min($PollIntervalMilliseconds, $remainingMs)
        if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        try {
            $latest = Get-ProcessControlMeasurementSample -Process $Process
            if ([uint64]$latest.peakWorkingSetBytes -gt $peak) { $peak = [uint64]$latest.peakWorkingSetBytes }
        } catch {
            break
        }
    }
    $watch.Stop()

    try {
        $latest = Get-ProcessControlMeasurementSample -Process $Process
        if ([uint64]$latest.peakWorkingSetBytes -gt $peak) { $peak = [uint64]$latest.peakWorkingSetBytes }
    } catch { }

    $cpuDelta = [math]::Max(0.0, [double]$latest.cpuSeconds - [double]$initial.cpuSeconds)
    return [pscustomobject]@{
        tool = $Tool
        processId = [int]$Process.Id
        processName = [string]$Process.ProcessName
        workingSetBytes = [uint64]$latest.workingSetBytes
        peakWorkingSetBytes = [uint64]$peak
        cpuSeconds = [math]::Round($cpuDelta, 6)
        totalCpuSeconds = [math]::Round([double]$latest.cpuSeconds, 6)
        elapsedSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        sampledAtUtc = Get-RooIndustriesUtcStamp
    }
}

function Write-ProcessControlMeasureGovernorProfile {
    param(
        [string]$Path,
        [int]$MaxDurationSeconds
    )

    $profile = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        profileId = 'process-control-footprint-measurement'
        name = 'Process Control Footprint Measurement'
        profileKind = 'process-governor'
        risk = 'low'
        targetScenario = 'Bounded no-match process governor footprint measurement.'
        protectedCatalogPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'backend\profiles\protected-processes.json')
        governor = [pscustomobject]@{
            thresholds = [pscustomobject]@{
                totalCpuPressureThresholdPercent = 100
                perProcessCpuThresholdPercent = 100
                timeOverThresholdSeconds = 1
                minimumRestraintSeconds = 1
                restoreCpuThresholdPercent = 0
                cooldownAfterRestoreSeconds = 0
                maxSessionDurationSeconds = $MaxDurationSeconds
                pollIntervalSeconds = 1
            }
            restraint = [pscustomobject]@{
                priorityClass = 'BelowNormal'
                ioPriority = $null
            }
            excludeForegroundProcess = $true
            candidateSelectors = @(
                [pscustomobject]@{
                    ruleId = 'process-control-footprint-no-match'
                    enabled = $true
                    match = [pscustomobject]@{
                        processNames = @('NoSuchProcessControlFootprintProbe.exe')
                    }
                    reason = 'No-match footprint measurement selector.'
                    reasonCodes = @('PROCESS_CONTROL_FOOTPRINT_MEASURE')
                    risk = 'low'
                }
            )
        }
        telemetryTargets = @('process-control-footprint')
        rollbackPolicy = [pscustomobject]@{
            supported = $true
            scope = 'process-governor-process-controls'
            stateRoot = 'temp-measurement-state'
            restoreOriginalPriorityClass = $true
        }
        safety = [pscustomobject]@{
            confirmedApplyChanges = @('PriorityClass')
            continuousEnforcement = $false
            runtimeService = $false
            foregroundExclusion = $true
        }
    }
    ($profile | ConvertTo-Json -Depth 18) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-ProcessControlMeasureNativePolicy {
    param(
        [string]$Path,
        [string]$StateRoot,
        [int]$MaxDurationSeconds,
        [int]$PollIntervalMilliseconds
    )

    $policy = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        policyId = 'process-control-footprint-measurement'
        confirmApply = $false
        session = [pscustomobject]@{
            maxDurationSeconds = $MaxDurationSeconds
            pollIntervalMilliseconds = $PollIntervalMilliseconds
            stateRoot = $StateRoot
            restoreOnExit = $true
        }
        safety = [pscustomobject]@{
            allowLiveApply = $false
            requireDisposableTargets = $true
            protectForegroundProcess = $true
            protectGameObsDiscord = $true
            disposableNamePatterns = @('NoSuchProcessControlFootprintProbe.exe')
        }
        restraint = [pscustomobject]@{
            priorityClass = 'BelowNormal'
            affinityMask = $null
            ioPriority = $null
            gpuPriority = $null
        }
        protectedProcesses = @()
        candidateSelectors = @(
            [pscustomobject]@{
                ruleId = 'process-control-footprint-no-match'
                enabled = $true
                match = [pscustomobject]@{
                    processNames = @('NoSuchProcessControlFootprintProbe.exe')
                }
                reason = 'No-match native footprint measurement selector.'
                reasonCodes = @('PROCESS_CONTROL_FOOTPRINT_MEASURE')
            }
        )
    }
    ($policy | ConvertTo-Json -Depth 18) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Resolve-ProcessControlBaselinePath {
    param(
        [string]$RequestedPath,
        [string]$RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolved = Resolve-RooIndustriesPath $RequestedPath $RepoRoot
        if (Test-Path -LiteralPath $resolved) { return $resolved }
        return $null
    }

    $roots = @(
        (Join-Path $RepoRoot 'backend\samples'),
        (Join-Path $RepoRoot 'backend\state')
    )
    $patterns = @(
        'process-control-footprint',
        'process-controls-footprint',
        'process-governor-footprint',
        'native-process-governor-footprint'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $candidates = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $name = $_.BaseName.ToLowerInvariant()
                @($patterns | Where-Object { $name -like "*$_*" }).Count -gt 0
            } |
            Sort-Object LastWriteTimeUtc -Descending)
        if ($candidates.Count -gt 0) { return $candidates[0].FullName }
    }
    return $null
}

function ConvertTo-ProcessControlBaselineMeasurement {
    param(
        [object]$Baseline,
        [string]$Tool
    )

    $candidate = $Baseline
    if ($Baseline.PSObject.Properties.Name -contains 'target') {
        $candidate = $Baseline.target
    }
    if ($Baseline.PSObject.Properties.Name -contains 'measurements') {
        $matching = @($Baseline.measurements | Where-Object { [string]$_.tool -eq $Tool }) | Select-Object -First 1
        if ($matching) {
            $candidate = $matching
        } elseif (@($Baseline.measurements).Count -gt 0) {
            $candidate = @($Baseline.measurements)[0]
        }
    }

    if (-not ($candidate.PSObject.Properties.Name -contains 'workingSetBytes')) { return $null }
    return [pscustomobject]@{
        tool = Get-RooIndustriesPropertyValue $candidate 'tool' $null
        workingSetBytes = [uint64](Get-RooIndustriesPropertyValue $candidate 'workingSetBytes' 0)
        peakWorkingSetBytes = [uint64](Get-RooIndustriesPropertyValue $candidate 'peakWorkingSetBytes' 0)
        cpuSeconds = [double](Get-RooIndustriesPropertyValue $candidate 'cpuSeconds' 0)
        sampledAtUtc = Get-RooIndustriesPropertyValue $candidate 'sampledAtUtc' $null
    }
}

try {
    if ($SampleDurationSeconds -lt 1) { $SampleDurationSeconds = 1 }
    if ($SampleDurationSeconds -gt 60) { $SampleDurationSeconds = 60 }
    if ($PollIntervalMilliseconds -lt 100) { $PollIntervalMilliseconds = 100 }
    if ($PollIntervalMilliseconds -gt 5000) { $PollIntervalMilliseconds = 5000 }

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-process-control-footprint-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $process = $null
    $measurement = $null
    $usedNativeWorker = $false
    $cleanupDone = $false
    try {
        $nativeWorker = Join-Path $repoRoot 'backend\bin\RooIndustriesProcessGovernor.exe'
        if (Test-Path -LiteralPath $nativeWorker) {
            $policyPath = Join-Path $tempRoot 'native-footprint-policy.json'
            $nativeOutput = Join-Path $tempRoot 'native-footprint-output.json'
            Write-ProcessControlMeasureNativePolicy -Path $policyPath -StateRoot (Join-Path $tempRoot 'native-state') -MaxDurationSeconds $SampleDurationSeconds -PollIntervalMilliseconds $PollIntervalMilliseconds
            $process = Start-Process -FilePath $nativeWorker -ArgumentList @('--policy', $policyPath, '--output', $nativeOutput) -WindowStyle Hidden -PassThru
            $measurement = Measure-ProcessControlProcess -Process $process -Tool 'native-process-governor-worker' -SampleDurationSeconds $SampleDurationSeconds -PollIntervalMilliseconds $PollIntervalMilliseconds
            $usedNativeWorker = $true
        } else {
            $profilePath = Join-Path $tempRoot 'governor-footprint-profile.json'
            $sessionOutput = Join-Path $tempRoot 'governor-footprint-output.json'
            $sessionError = Join-Path $tempRoot 'governor-footprint-error.txt'
            $stateRoot = Join-Path $tempRoot 'governor-state'
            Write-ProcessControlMeasureGovernorProfile -Path $profilePath -MaxDurationSeconds $SampleDurationSeconds
            $sessionArgs = @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                (Join-Path $PSScriptRoot 'Start-ProcessGovernorSession.ps1'),
                '-ProfilePath',
                $profilePath,
                '-SampleIntervalMilliseconds',
                ([string]$PollIntervalMilliseconds),
                '-MaxDurationSeconds',
                ([string]$SampleDurationSeconds),
                '-StateRoot',
                $stateRoot,
                '-ConfirmApply'
            )
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $sessionArgs -WindowStyle Hidden -RedirectStandardOutput $sessionOutput -RedirectStandardError $sessionError -PassThru
            $measurement = Measure-ProcessControlProcess -Process $process -Tool 'powershell-process-governor-session' -SampleDurationSeconds $SampleDurationSeconds -PollIntervalMilliseconds $PollIntervalMilliseconds
        }

        Wait-Process -Id $process.Id -Timeout ([math]::Max(10, $SampleDurationSeconds + 10)) -ErrorAction SilentlyContinue
        $process.Refresh()
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $process.Id -Timeout 5 -ErrorAction SilentlyContinue
            throw "Measured process did not exit within the bounded footprint window: pid=$($process.Id)"
        }
        if ($null -ne $process.ExitCode -and $process.ExitCode -ne 0) {
            throw "Measured process exited with code $($process.ExitCode)."
        }

        $baselinePathResolved = Resolve-ProcessControlBaselinePath -RequestedPath $BaselinePath -RepoRoot $repoRoot
        $baselineMeasurement = $null
        if ($baselinePathResolved) {
            $baselineMeasurement = ConvertTo-ProcessControlBaselineMeasurement -Baseline (Get-Content -LiteralPath $baselinePathResolved -Raw | ConvertFrom-Json) -Tool $measurement.tool
        }
        $comparison = if ($baselineMeasurement) {
            [pscustomobject]@{
                baselineFound = $true
                baselinePath = $baselinePathResolved
                workingSetDeltaBytes = ([int64]$measurement.workingSetBytes - [int64]$baselineMeasurement.workingSetBytes)
                peakWorkingSetDeltaBytes = ([int64]$measurement.peakWorkingSetBytes - [int64]$baselineMeasurement.peakWorkingSetBytes)
                cpuDeltaSeconds = [math]::Round(([double]$measurement.cpuSeconds - [double]$baselineMeasurement.cpuSeconds), 6)
                status = 'compared'
            }
        } else {
            [pscustomobject]@{
                baselineFound = $false
                baselinePath = $baselinePathResolved
                workingSetDeltaBytes = $null
                peakWorkingSetDeltaBytes = $null
                cpuDeltaSeconds = $null
                status = 'record-current-numbers-as-baseline-in-report'
            }
        }

        $cleanupDone = Remove-ProcessControlMeasureRoot -Path $tempRoot
        $result = [pscustomobject]@{
            actionId = 'performance.processControls.measureFootprint'
            schemaVersion = 1
            productName = $script:RooIndustriesProcessProductName
            status = 'completed'
            dryRun = $true
            tool = $measurement.tool
            workingSetBytes = $measurement.workingSetBytes
            peakWorkingSetBytes = $measurement.peakWorkingSetBytes
            cpuSeconds = $measurement.cpuSeconds
            sampledAtUtc = $measurement.sampledAtUtc
            target = $measurement
            usedNativeWorker = $usedNativeWorker
            baseline = $baselineMeasurement
            comparison = $comparison
            tempStateCleaned = $cleanupDone
            warnings = @()
            errors = @()
            logs = @((New-RooIndustriesLog 'Process-control footprint measurement completed without live process-control changes.'))
        }
        Write-RooIndustriesJsonOutput $result $OutputPath
    } finally {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $process.Id -Timeout 5 -ErrorAction SilentlyContinue
        }
        if (-not $cleanupDone) {
            Remove-ProcessControlMeasureRoot -Path $tempRoot | Out-Null
        }
    }
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.processControls.measureFootprint'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        status = 'failed'
        dryRun = $true
        tool = $null
        workingSetBytes = $null
        peakWorkingSetBytes = $null
        cpuSeconds = $null
        sampledAtUtc = Get-RooIndustriesUtcStamp
        target = $null
        usedNativeWorker = $false
        baseline = $null
        comparison = $null
        tempStateCleaned = $null
        warnings = @()
        errors = @((New-RooIndustriesIssue 'PROCESS_CONTROL_FOOTPRINT_MEASURE_FAILED' $_.Exception.Message 'error' 'performance.processControls' $PSCommandPath $true 'Review worker/session launch conditions and retry.' $null))
        logs = @((New-RooIndustriesLog 'Process-control footprint measurement failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
