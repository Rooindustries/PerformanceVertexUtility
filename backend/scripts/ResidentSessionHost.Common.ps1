. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Get-RooBackendProcessCount {
    return @(Get-Process -ErrorAction SilentlyContinue).Count
}

function Get-RooBackendScriptProcessMeasurement {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) {
        $Process = Get-Process -Id $PID
    }
    $Process.Refresh()
    $handleCount = $null
    $handleCountAvailable = $false
    try {
        $handleCount = [int]$Process.HandleCount
        $handleCountAvailable = $true
    } catch {
        $handleCount = $null
        $handleCountAvailable = $false
    }
    $cpuSeconds = 0.0
    try { $cpuSeconds = [double]$Process.TotalProcessorTime.TotalSeconds } catch { $cpuSeconds = 0.0 }
    $workingSetBytes = 0
    $privateBytes = 0
    try { $workingSetBytes = [int64]$Process.WorkingSet64 } catch { $workingSetBytes = 0 }
    try { $privateBytes = [int64]$Process.PrivateMemorySize64 } catch { $privateBytes = 0 }
    return [pscustomobject]@{
        processId = [int]$Process.Id
        processName = [string]$Process.ProcessName
        workingSetBytes = $workingSetBytes
        privateBytes = $privateBytes
        cpuSeconds = [math]::Round($cpuSeconds, 6)
        handleCount = $handleCount
        handleCountAvailable = $handleCountAvailable
    }
}

function Get-RooBackendFootprintDelta {
    param(
        [object]$Before,
        [object]$After,
        [double]$ElapsedSeconds
    )
    $processorCount = [Environment]::ProcessorCount
    if ($processorCount -lt 1) { $processorCount = 1 }
    if ($ElapsedSeconds -le 0) { $ElapsedSeconds = 0.001 }
    $cpuDelta = [double](Get-RooPropertyValue $After 'cpuSeconds' 0) - [double](Get-RooPropertyValue $Before 'cpuSeconds' 0)
    if ($cpuDelta -lt 0) { $cpuDelta = 0 }
    $averageCpuPercent = (($cpuDelta / $ElapsedSeconds) / $processorCount) * 100
    return [pscustomobject]@{
        elapsedRuntimeSeconds = [math]::Round($ElapsedSeconds, 3)
        cpuTimeDeltaSeconds = [math]::Round($cpuDelta, 6)
        averageCpuPercent = [math]::Round($averageCpuPercent, 4)
        processorCount = $processorCount
    }
}

function Resolve-RooBackendBudgetProfilePath {
    param([string]$BudgetProfilePath)
    $defaultPath = Join-Path $PSScriptRoot '..\profiles\lightweight-governor-budget.profile.json'
    return Resolve-RooPath $BudgetProfilePath $defaultPath
}

function Get-RooBackendBudgetProfile {
    param([string]$BudgetProfilePath)
    $resolved = Resolve-RooBackendBudgetProfilePath $BudgetProfilePath
    if (Test-Path -LiteralPath $resolved) {
        return [pscustomobject]@{
            path = $resolved
            profile = (Read-RooJsonFile $resolved)
        }
    }
    return [pscustomobject]@{
        path = $resolved
        profile = $null
    }
}

function New-RooBackendBudgetEvaluation {
    param(
        [object]$BudgetProfile,
        [double]$AverageCpuPercent,
        [int64]$PrivateBytes,
        [int64]$StateEntryCount,
        [bool]$PersistentUiProcessRequired
    )
    if ($null -eq $BudgetProfile) { return $null }
    $budgets = Get-RooPropertyValue $BudgetProfile 'budgets' $null
    $cpuMax = [double](Get-RooPropertyValue $budgets 'idleBackendCpuAveragePercentMax' 0.5)
    $privateMax = [int64](Get-RooPropertyValue $budgets 'backendPowerShellPrivateBytesMax' 78643200)
    $stateMax = [int64](Get-RooPropertyValue $budgets 'backendStateEntryCountMaxAfterValidation' 0)
    $idleWithinBudget = ($AverageCpuPercent -le $cpuMax)
    $privateWithinBudget = ($PrivateBytes -le $privateMax)
    $stateWithinBudget = ($StateEntryCount -le $stateMax)
    $uiWithinBudget = (-not $PersistentUiProcessRequired)
    return [pscustomobject]@{
        profileId = [string](Get-RooPropertyValue $BudgetProfile 'profileId' 'lightweight-governor-budget')
        idleBackendCpuAveragePercentMax = $cpuMax
        backendPowerShellPrivateBytesMax = $privateMax
        backendStateEntryCountMaxAfterValidation = $stateMax
        persistentUiProcessRequired = $PersistentUiProcessRequired
        withinBudget = ($idleWithinBudget -and $privateWithinBudget -and $stateWithinBudget -and $uiWithinBudget)
        idleCpuWithinBudget = $idleWithinBudget
        privateBytesWithinBudget = $privateWithinBudget
        stateEntryCountWithinBudget = $stateWithinBudget
        persistentUiRequirementWithinBudget = $uiWithinBudget
    }
}

function Get-RooBackendStateEntryCount {
    param([string]$RepositoryRoot)
    $stateRoot = Join-Path $RepositoryRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Get-RooResidentHostStatusModel {
    param(
        [int]$ProcessId,
        [string]$Status,
        [string]$SessionId = $null,
        [object]$Footprint = $null,
        [object]$Bounds = $null,
        [object]$State = $null,
        [object]$DependencyProof = $null,
        [object[]]$Samples = @(),
        [string]$StartedAtUtc = $null,
        [string]$CompletedAtUtc = $null,
        [int]$PollCount = 0,
        [object[]]$Warnings = @(),
        [object[]]$Errors = @(),
        [object[]]$Logs = @()
    )
    $measurement = $null
    $live = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($live) { $measurement = Get-RooBackendScriptProcessMeasurement $live }
    return [pscustomobject]@{
        actionId = 'backend.residentHost.status'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        capturedAtUtc = Get-RooUtcStamp
        startedAtUtc = $StartedAtUtc
        completedAtUtc = $CompletedAtUtc
        status = $Status
        sessionId = $SessionId
        pollCount = $PollCount
        host = [pscustomobject]@{
            processId = $ProcessId
            processName = if ($measurement) { $measurement.processName } else { $null }
            executionMode = 'foregroundCli'
            serviceReady = $true
            serviceInstalled = $false
            serviceInstallActionPerformed = $false
            persistentUiProcessRequired = $false
        }
        footprint = $Footprint
        currentMeasurement = $measurement
        bounds = $Bounds
        state = $State
        dependencyProof = $DependencyProof
        samples = @(Get-RooArray $Samples)
        warnings = @(Get-RooArray $Warnings)
        errors = @(Get-RooArray $Errors)
        logs = @(Get-RooArray $Logs)
    }
}
