param(
    [int]$SampleDurationSeconds = 3,
    [int]$PollIntervalMilliseconds = 1000,
    [string]$BudgetProfilePath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ResidentSessionHost.Common.ps1')
$floor = $null

try {
    if ($SampleDurationSeconds -lt 1) { $SampleDurationSeconds = 1 }
    if ($SampleDurationSeconds -gt 300) { $SampleDurationSeconds = 300 }
    if ($PollIntervalMilliseconds -lt 250) { $PollIntervalMilliseconds = 250 }
    if ($PollIntervalMilliseconds -gt 60000) { $PollIntervalMilliseconds = 60000 }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $budget = Get-RooIndustriesBackendBudgetProfile $BudgetProfilePath
    $floor = Start-RooIndustriesPowerShellFloor
    $process = Get-Process -Id $PID
    $startedAtUtc = Get-RooIndustriesUtcStamp
    $processCountBefore = Get-RooIndustriesBackendProcessCount
    $before = Get-RooIndustriesBackendScriptProcessMeasurement $process
    $samples = New-Object System.Collections.Generic.List[object]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($watch.Elapsed.TotalSeconds -lt $SampleDurationSeconds) {
        $remainingMs = [int](([double]$SampleDurationSeconds - $watch.Elapsed.TotalSeconds) * 1000)
        if ($remainingMs -le 0) { break }
        $sleepMs = [math]::Min($PollIntervalMilliseconds, $remainingMs)
        if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        $sampleProcess = Get-RooIndustriesBackendScriptProcessMeasurement $process
        $samples.Add([pscustomobject]@{
            capturedAtUtc = Get-RooIndustriesUtcStamp
            elapsedRuntimeSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
            workingSetBytes = $sampleProcess.workingSetBytes
            privateBytes = $sampleProcess.privateBytes
            cpuSeconds = $sampleProcess.cpuSeconds
            handleCount = $sampleProcess.handleCount
            handleCountAvailable = $sampleProcess.handleCountAvailable
        }) | Out-Null
    }

    $watch.Stop()
    $after = Get-RooIndustriesBackendScriptProcessMeasurement $process
    $floorMeasurement = Get-RooIndustriesPowerShellFloorMeasurement $floor
    Stop-RooIndustriesPowerShellFloor $floor
    $floor = $null
    $delta = Get-RooIndustriesBackendFootprintDelta $before $after $watch.Elapsed.TotalSeconds
    $processCountAfter = Get-RooIndustriesBackendProcessCount
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

    $result = [pscustomobject]@{
        actionId = 'backend.measureFootprint'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-RooIndustriesUtcStamp
        dryRun = $true
        status = 'completed'
        sampleDurationSeconds = $SampleDurationSeconds
        pollIntervalMilliseconds = $PollIntervalMilliseconds
        elapsedRuntimeSeconds = $delta.elapsedRuntimeSeconds
        currentProcessCount = $processCountAfter
        processCount = [pscustomobject]@{
            before = $processCountBefore
            after = $processCountAfter
            delta = ($processCountAfter - $processCountBefore)
        }
        backendScriptProcess = [pscustomobject]@{
            processId = $after.processId
            processName = $after.processName
            scriptPath = $PSCommandPath
            workingSetBytes = $after.workingSetBytes
            privateBytes = $after.privateBytes
            powerShellFloor = $floorMeasurement
            privateBytesOverPowerShellFloor = ($after.privateBytes - $floorMeasurement.privateBytes)
            cpuTimeSecondsBefore = $before.cpuSeconds
            cpuTimeSecondsAfter = $after.cpuSeconds
            cpuTimeDeltaSeconds = $delta.cpuTimeDeltaSeconds
            averageCpuPercent = $delta.averageCpuPercent
            processorCount = $delta.processorCount
            handleCount = $after.handleCount
            handleCountAvailable = $after.handleCountAvailable
        }
        budgetProfilePath = $budget.path
        budgetEvaluation = $budgetEvaluation
        state = [pscustomobject]@{
            backendStateEntryCount = $stateEntryCount
            wroteState = $false
        }
        samples = @($samples.ToArray())
        warnings = @()
        errors = @()
        logs = @((New-RooIndustriesLog 'Backend footprint measurement completed without system changes.'))
    }

    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'backend.measureFootprint'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        dryRun = $true
        status = 'failed'
        sampleDurationSeconds = $SampleDurationSeconds
        pollIntervalMilliseconds = $PollIntervalMilliseconds
        currentProcessCount = $null
        backendScriptProcess = $null
        budgetProfilePath = $BudgetProfilePath
        budgetEvaluation = $null
        state = $null
        samples = @()
        warnings = @()
        errors = @((New-RooIndustriesIssue 'BACKEND_FOOTPRINT_MEASURE_FAILED' $_.Exception.Message 'error' 'backend.footprint' $PSCommandPath $true 'Review script permissions and retry.' $null))
        logs = @((New-RooIndustriesLog 'Backend footprint measurement failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
} finally {
    Stop-RooIndustriesPowerShellFloor $floor
}
