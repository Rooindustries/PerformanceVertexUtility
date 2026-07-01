param(
    [int]$MaxDurationSeconds = 5,
    [int]$PollIntervalMilliseconds = 1000,
    [string]$BudgetProfilePath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ResidentSessionHost.Common.ps1')

try {
    if ($MaxDurationSeconds -lt 1) { $MaxDurationSeconds = 1 }
    if ($MaxDurationSeconds -gt 300) { $MaxDurationSeconds = 300 }
    if ($PollIntervalMilliseconds -lt 500) { $PollIntervalMilliseconds = 500 }
    if ($PollIntervalMilliseconds -gt 60000) { $PollIntervalMilliseconds = 60000 }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $budget = Get-RooBackendBudgetProfile $BudgetProfilePath
    $sessionId = "resident-host-$(Get-RooFileStamp)"
    $startedAtUtc = Get-RooUtcStamp
    $process = Get-Process -Id $PID
    $processCountBefore = Get-RooBackendProcessCount
    $before = Get-RooBackendScriptProcessMeasurement $process
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
        $sample = Get-RooBackendScriptProcessMeasurement $process
        if ([int64]$sample.workingSetBytes -gt $peakWorkingSetBytes) { $peakWorkingSetBytes = [int64]$sample.workingSetBytes }
        if ([int64]$sample.privateBytes -gt $peakPrivateBytes) { $peakPrivateBytes = [int64]$sample.privateBytes }
        $samples.Add([pscustomobject]@{
            pollIndex = $pollIndex
            capturedAtUtc = Get-RooUtcStamp
            elapsedRuntimeSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
            workingSetBytes = $sample.workingSetBytes
            privateBytes = $sample.privateBytes
            cpuSeconds = $sample.cpuSeconds
            handleCount = $sample.handleCount
            handleCountAvailable = $sample.handleCountAvailable
        }) | Out-Null
    }

    $watch.Stop()
    $after = Get-RooBackendScriptProcessMeasurement $process
    $processCountAfter = Get-RooBackendProcessCount
    if ([int64]$after.workingSetBytes -gt $peakWorkingSetBytes) { $peakWorkingSetBytes = [int64]$after.workingSetBytes }
    if ([int64]$after.privateBytes -gt $peakPrivateBytes) { $peakPrivateBytes = [int64]$after.privateBytes }
    $delta = Get-RooBackendFootprintDelta $before $after $watch.Elapsed.TotalSeconds
    $stateEntryCount = Get-RooBackendStateEntryCount $repoRoot.Path
    $budgetEvaluation = if ($budget.profile) {
        New-RooBackendBudgetEvaluation `
            -BudgetProfile $budget.profile `
            -AverageCpuPercent $delta.averageCpuPercent `
            -PrivateBytes $after.privateBytes `
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
    $status = Get-RooResidentHostStatusModel `
        -ProcessId $PID `
        -Status 'completed' `
        -SessionId $sessionId `
        -Footprint $footprint `
        -Bounds $bounds `
        -State $state `
        -DependencyProof $dependencyProof `
        -Samples @($samples.ToArray()) `
        -StartedAtUtc $startedAtUtc `
        -CompletedAtUtc (Get-RooUtcStamp) `
        -PollCount $pollIndex `
        -Logs @((New-RooLog 'Resident host bounded foreground session completed without service installation or state writes.'))
    $status.actionId = 'backend.residentHost.start'
    Write-RooJsonOutput $status $OutputPath
} catch {
    $errorStatus = Get-RooResidentHostStatusModel `
        -ProcessId $PID `
        -Status 'failed' `
        -Errors @((New-RooIssue 'RESIDENT_HOST_SESSION_FAILED' $_.Exception.Message 'error' 'backend.residentHost' $PSCommandPath $true 'Review host bounds and retry.' $null)) `
        -Logs @((New-RooLog 'Resident host bounded foreground session failed.' 'error'))
    $errorStatus.actionId = 'backend.residentHost.start'
    Write-RooJsonOutput $errorStatus $OutputPath
    exit 1
}
