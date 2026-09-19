$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.Common.ps1')

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
            Where-Object {
                [string]$_.ProcessName -like 'RooIndustriesGovernorReliabilityProbe*' -or
                [string]$_.ProcessName -like 'RooIndustriesGovernorRelaunchProbe*'
            }
    )
}

function Stop-ReliabilityProbe {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) { return }

    try { $Process.Refresh() } catch { }
    if (-not $Process.HasExited) {
        Stop-RooIndustriesValidationProcess $Process
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

function Wait-ReliabilitySessionChanged {
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
                    $session = Get-Content -LiteralPath $sessionFile.FullName -Raw | ConvertFrom-Json
                    $changed = @($session.changedItems | Where-Object { [int]$_.processId -eq $ProcessId }) | Select-Object -First 1
                    if ($changed) {
                        return [pscustomobject]@{
                            found = $true
                            sessionPath = $sessionFile.FullName
                            session = $session
                            changedItem = $changed
                        }
                    }
                } catch { }
            }
        }
        Start-Sleep -Milliseconds 300
    }

    return [pscustomobject]@{
        found = $false
        sessionPath = $null
        session = $null
        changedItem = $null
    }
}

function Get-ReliabilityBackupFileCount {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -Filter 'backup.json' -Recurse -File -ErrorAction SilentlyContinue).Count
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
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-governor-reliability-$([guid]::NewGuid().ToString('N'))"
    $probe = $null
    $cleanupDone = $false
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $probeName = "RooIndustriesGovernorReliabilityProbe$runIndex.exe"
        $probeExe = Join-Path $tempRoot $probeName
        Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $probeExe -Force
        $profilePath = Join-Path $tempRoot 'governor-profile.json'
        $stateRoot = Join-Path $tempRoot 'state'
        Write-ReliabilityGovernorProfile -Path $profilePath -CandidateName $probeName

        $probe = Start-Process -FilePath $probeExe -ArgumentList (Join-RooIndustriesWindowsArguments @('-NoProfile','-WindowStyle','Hidden','-Command','$end=(Get-Date).AddSeconds(6); while ((Get-Date) -lt $end) { [Math]::Sqrt(144) | Out-Null }; Start-Sleep -Seconds 90')) -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 800
        $before = Get-RooIndustriesProcessControlState $probe.Id $null
        $session = & (Join-Path $PSScriptRoot 'Start-ProcessGovernorSession.ps1') `
            -ProfilePath $profilePath `
            -SampleIntervalMilliseconds 400 `
            -MaxDurationSeconds 16 `
            -StateRoot $stateRoot `
            -ConfirmApply | ConvertFrom-Json
        $after = Get-RooIndustriesProcessControlState $probe.Id $null
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

$relaunchRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-governor-relaunch-$([guid]::NewGuid().ToString('N'))"
$relaunchFirst = $null
$relaunchSecond = $null
$relaunchSessionProc = $null
$relaunchCleanupDone = $false
try {
    New-Item -ItemType Directory -Path $relaunchRoot -Force | Out-Null
    $probeName = 'RooIndustriesGovernorRelaunchProbe.exe'
    $probeExe = Join-Path $relaunchRoot $probeName
    Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $probeExe -Force
    $profilePath = Join-Path $relaunchRoot 'governor-relaunch-profile.json'
    $stateRoot = Join-Path $relaunchRoot 'state'
    Write-ReliabilityGovernorProfile -Path $profilePath -CandidateName $probeName

    $relaunchFirst = Start-Process -FilePath $probeExe -ArgumentList (Join-RooIndustriesWindowsArguments @('-NoProfile','-WindowStyle','Hidden','-Command','while ($true) { [Math]::Sqrt(144) | Out-Null }')) -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800
    $beforeFirst = Get-RooIndustriesProcessControlState $relaunchFirst.Id $null
    $sessionOutput = Join-Path $relaunchRoot 'governor-relaunch-session-output.json'
    $sessionError = Join-Path $relaunchRoot 'governor-relaunch-session-error.txt'
    $sessionArgs = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'Start-ProcessGovernorSession.ps1'),
        '-ProfilePath',
        $profilePath,
        '-SampleIntervalMilliseconds',
        '400',
        '-MaxDurationSeconds',
        '18',
        '-StateRoot',
        $stateRoot,
        '-ConfirmApply'
    )
    $relaunchSessionProc = Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-RooIndustriesWindowsArguments $sessionArgs) -WindowStyle Hidden -RedirectStandardOutput $sessionOutput -RedirectStandardError $sessionError -PassThru

    $firstChange = Wait-ReliabilitySessionChanged -StateRoot $stateRoot -ProcessId $relaunchFirst.Id -TimeoutSeconds 20
    $afterFirstApply = Get-RooIndustriesProcessControlState $relaunchFirst.Id $null
    if ($firstChange.found -and $afterFirstApply.priorityClass -eq 'BelowNormal') {
        Add-Pass "Relaunch scenario restrained first same-name probe before exit: pid=$($relaunchFirst.Id) original=$($beforeFirst.priorityClass) applied=$($afterFirstApply.priorityClass)"
    } else {
        Add-Failure "Relaunch scenario did not restrain first same-name probe before timeout: pid=$($relaunchFirst.Id) current=$($afterFirstApply.priorityClass)"
    }

    Stop-ReliabilityProbe -Process $relaunchFirst
    $relaunchFirst = $null
    Start-Sleep -Milliseconds 700

    $relaunchSecond = Start-Process -FilePath $probeExe -ArgumentList (Join-RooIndustriesWindowsArguments @('-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120')) -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800
    $beforeSecond = Get-RooIndustriesProcessControlState $relaunchSecond.Id $null

    Wait-RooIndustriesValidationProcess $relaunchSessionProc 35
    $relaunchSessionProc.Refresh()
    $sessionExitCode = $relaunchSessionProc.ExitCode
    $relaunchSessionProc = $null
    if ($null -ne $sessionExitCode -and $sessionExitCode -ne 0) {
        $errorText = if (Test-Path -LiteralPath $sessionError) { Get-Content -LiteralPath $sessionError -Raw } else { '' }
        Add-Failure "Relaunch governor session exited with code $sessionExitCode :: $errorText"
    }

    $session = Get-Content -LiteralPath $sessionOutput -Raw | ConvertFrom-Json
    $firstExitSkip = @($session.skippedItems | Where-Object { [int]$_.processId -eq [int]$firstChange.changedItem.processId -and [string]$_.reason -like '*exited*' }) | Select-Object -First 1
    $secondChanged = @($session.changedItems | Where-Object { [int]$_.processId -eq $relaunchSecond.Id }) | Select-Object -First 1
    $backupBeforeRestoreCount = Get-ReliabilityBackupFileCount -Path $relaunchRoot
    if ($firstExitSkip -and -not $secondChanged -and $backupBeforeRestoreCount -eq 1) {
        Add-Pass "Relaunch session tracked exited first PID without applying to same-name replacement: firstPid=$($firstChange.changedItem.processId) secondPid=$($relaunchSecond.Id) backups=$backupBeforeRestoreCount"
    } else {
        Add-Failure "Relaunch session did not prove exited-PID isolation: firstSkip=$([bool]$firstExitSkip), secondChanged=$([bool]$secondChanged), backups=$backupBeforeRestoreCount"
    }

    $restore = & (Join-Path $PSScriptRoot 'Stop-ProcessGovernorSession.ps1') -BackupPath $session.backupManifestPath -ConfirmApply | ConvertFrom-Json
    $afterRestoreSecond = Get-RooIndustriesProcessControlState $relaunchSecond.Id $null
    $secondRestored = @($restore.restoredItems | Where-Object { [int]$_.processId -eq $relaunchSecond.Id }) | Select-Object -First 1
    $firstRestoreSkip = @($restore.skippedItems | Where-Object { [int]$_.processId -eq [int]$firstChange.changedItem.processId }) | Select-Object -First 1
    if (-not $secondRestored -and $firstRestoreSkip -and $afterRestoreSecond.priorityClass -eq $beforeSecond.priorityClass) {
        Add-Pass "Relaunch restore skipped exited PID and did not restore onto same-name replacement: secondPid=$($relaunchSecond.Id) priority=$($afterRestoreSecond.priorityClass)"
    } else {
        Add-Failure "Relaunch restore touched the wrong process or missed the exited-PID skip: secondRestored=$([bool]$secondRestored), firstSkip=$([bool]$firstRestoreSkip), secondPriority=$($afterRestoreSecond.priorityClass), expected=$($beforeSecond.priorityClass)"
    }

    Stop-ReliabilityProbe -Process $relaunchSecond
    $relaunchSecond = $null
    $fullRelaunchRoot = [System.IO.Path]::GetFullPath($relaunchRoot)
    $removedRelaunchRoot = Remove-ReliabilityTempRoot -Path $relaunchRoot
    $relaunchCleanupDone = $true
    if ($removedRelaunchRoot -and -not (Test-Path -LiteralPath $fullRelaunchRoot)) {
        Add-Pass 'Relaunch scenario temp state root and backup were cleaned up'
    } else {
        Add-Failure "Relaunch scenario temp root remained: $fullRelaunchRoot"
    }

    $leftoverRelaunchProbes = @(Get-ReliabilityProbeProcesses)
    if ($leftoverRelaunchProbes.Count -eq 0) {
        Add-Pass 'Relaunch scenario left no disposable probe process behind'
    } else {
        Add-Failure "Relaunch scenario left disposable probe process(es): $(@($leftoverRelaunchProbes | ForEach-Object { $_.Id }) -join ', ')"
    }

    $stateAfterRelaunch = Get-StateEntryCount
    if ($stateAfterRelaunch -eq 0) {
        Add-Pass 'backend/state is empty after relaunch reliability validation'
    } else {
        Add-Failure "backend/state is not empty after relaunch reliability validation: count=$stateAfterRelaunch"
    }
} catch {
    Add-Failure "Relaunch reliability validation failed: $($_.Exception.Message)"
} finally {
    if ($relaunchSessionProc -and -not $relaunchSessionProc.HasExited) {
        Stop-RooIndustriesValidationProcess $relaunchSessionProc
    }
    Stop-ReliabilityProbe -Process $relaunchFirst
    Stop-ReliabilityProbe -Process $relaunchSecond
    if (-not $relaunchCleanupDone) {
        Remove-ReliabilityTempRoot -Path $relaunchRoot | Out-Null
    }
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Process governor reliability validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Process governor reliability validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
