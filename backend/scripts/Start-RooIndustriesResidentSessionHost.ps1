param(
    [int]$MaxDurationSeconds = 5,
    [int]$PollIntervalMilliseconds = 1000,
    [string]$BudgetProfilePath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ResidentSessionHost.Common.ps1')
$floor = $null

try {
    if ($MaxDurationSeconds -lt 1) { $MaxDurationSeconds = 1 }
    if ($MaxDurationSeconds -gt 300) { $MaxDurationSeconds = 300 }
    if ($PollIntervalMilliseconds -lt 500) { $PollIntervalMilliseconds = 500 }
    if ($PollIntervalMilliseconds -gt 60000) { $PollIntervalMilliseconds = 60000 }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $budget = Get-RooIndustriesBackendBudgetProfile $BudgetProfilePath
    $floor = Start-RooIndustriesPowerShellFloor
    $sessionId = "resident-host-$(Get-RooIndustriesFileStamp)"
    $startedAtUtc = Get-RooIndustriesUtcStamp
    $process = Get-Process -Id $PID
    $processCountBefore = Get-RooIndustriesBackendProcessCount
    $before = Get-RooIndustriesBackendScriptProcessMeasurement $process
    $samples = New-Object System.Collections.Generic.List[object]
    $peakWorkingSetBytes = [int64]$before.workingSetBytes
    $peakPrivateBytes = [int64]$before.privateBytes
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollIndex = 0

    while ($watch.Elapsed.TotalSeconds -lt $MaxDurationSeconds) {
        $remainingMs = [int](([double]$MaxDurationSeconds - $watch.Elapsed.TotalSeconds) * 1000)
        if ($remainingMs -le 0) { break }
        $sleepMs = [math]::Min($PollIntervalMilliseconds, $remainingMs)
        if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        $pollIndex++
        $sample = Get-RooIndustriesBackendScriptProcessMeasurement $process
        if ([int64]$sample.workingSetBytes -gt $peakWorkingSetBytes) { $peakWorkingSetBytes = [int64]$sample.workingSetBytes }
        if ([int64]$sample.privateBytes -gt $peakPrivateBytes) { $peakPrivateBytes = [int64]$sample.privateBytes }
        $samples.Add([pscustomobject]@{
            pollIndex = $pollIndex
            capturedAtUtc = Get-RooIndustriesUtcStamp
            elapsedRuntimeSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
            workingSetBytes = $sample.workingSetBytes
            privateBytes = $sample.privateBytes
            cpuSeconds = $sample.cpuSeconds
            handleCount = $sample.handleCount
            handleCountAvailable = $sample.handleCountAvailable
        }) | Out-Null
    }

    $watch.Stop()
    $after = Get-RooIndustriesBackendScriptProcessMeasurement $process
    $floorMeasurement = Get-RooIndustriesPowerShellFloorMeasurement $floor
    Stop-RooIndustriesPowerShellFloor $floor
    $floor = $null
    $processCountAfter = Get-RooIndustriesBackendProcessCount
    if ([int64]$after.workingSetBytes -gt $peakWorkingSetBytes) { $peakWorkingSetBytes = [int64]$after.workingSetBytes }
    if ([int64]$after.privateBytes -gt $peakPrivateBytes) { $peakPrivateBytes = [int64]$after.privateBytes }
    $delta = Get-RooIndustriesBackendFootprintDelta $before $after $watch.Elapsed.TotalSeconds
    $stateEntryCount = Get-RooIndustriesBackendStateEntryCount $repoRoot.Path
    $budgetEvaluation = if ($budget.profile) {
        New-RooIndustriesBackendBudgetEvaluation `
            -BudgetProfile $budget.profile `
            -AverageCpuPercent $delta.averageCpuPercent `
            -PrivateBytes $after.privateBytes `
            -FloorPrivateBytes $floorMeasurement.privateBytes `
            -StateEntryCount $stateEntryCount `
            -PersistentUiProcessRequired:$false
    } else {
        $null
    }
    $footprint = [pscustomobject]@{
        elapsedRuntimeSeconds = $delta.elapsedRuntimeSeconds
        cpuTimeDeltaSeconds = $delta.cpuTimeDeltaSeconds
        averageCpuPercent = $delta.averageCpuPercent
        processorCount = $delta.processorCount
        workingSetBytes = $after.workingSetBytes
        privateBytes = $after.privateBytes
        powerShellFloor = $floorMeasurement
        privateBytesOverPowerShellFloor = ($after.privateBytes - $floorMeasurement.privateBytes)
        peakWorkingSetBytes = $peakWorkingSetBytes
        peakPrivateBytes = $peakPrivateBytes
        handleCount = $after.handleCount
        handleCountAvailable = $after.handleCountAvailable
        processCount = [pscustomobject]@{
            before = $processCountBefore
            after = $processCountAfter
            delta = ($processCountAfter - $processCountBefore)
        }
        budgetProfilePath = $budget.path
        budgetEvaluation = $budgetEvaluation
    }
    $bounds = [pscustomobject]@{
        maxDurationSeconds = $MaxDurationSeconds
        pollIntervalMilliseconds = $PollIntervalMilliseconds
        boundedForegroundSession = $true
        unboundedLoop = $false
    }
    $state = [pscustomobject]@{
        stateRoot = Join-Path $repoRoot.Path 'backend\state'
        wroteState = $false
        boundedStateEntryCount = $stateEntryCount
        unboundedStateGrowthAllowed = $false
    }
    $dependencyProof = [pscustomobject]@{
        frontendProcessRequired = $false
        persistentUiProcessRequired = $false
        externalProcessGovernorDependencyRequired = $false
        processLassoProcessStartedByHost = $false
    }
    $status = Get-RooIndustriesResidentHostStatusModel `
        -ProcessId $PID `
        -Status 'completed' `
        -SessionId $sessionId `
        -Footprint $footprint `
        -Bounds $bounds `
        -State $state `
        -DependencyProof $dependencyProof `
        -Samples @($samples.ToArray()) `
        -StartedAtUtc $startedAtUtc `
        -CompletedAtUtc (Get-RooIndustriesUtcStamp) `
        -PollCount $pollIndex `
        -Logs @((New-RooIndustriesLog 'Resident host bounded foreground session completed without service installation or state writes.'))
    $status.actionId = 'backend.residentHost.start'
    Write-RooIndustriesJsonOutput $status $OutputPath
} catch {
    $errorStatus = Get-RooIndustriesResidentHostStatusModel `
        -ProcessId $PID `
        -Status 'failed' `
        -Errors @((New-RooIndustriesIssue 'RESIDENT_HOST_SESSION_FAILED' $_.Exception.Message 'error' 'backend.residentHost' $PSCommandPath $true 'Review host bounds and retry.' $null)) `
        -Logs @((New-RooIndustriesLog 'Resident host bounded foreground session failed.' 'error'))
    $errorStatus.actionId = 'backend.residentHost.start'
    Write-RooIndustriesJsonOutput $errorStatus $OutputPath
    exit 1
} finally {
    Stop-RooIndustriesPowerShellFloor $floor
}
