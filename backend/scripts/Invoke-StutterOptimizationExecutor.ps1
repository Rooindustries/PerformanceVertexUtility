param(
    [ValidateSet('standby-memory','timer-resolution','power-plan','shader-cache-cleanup','service-pause-preview')]
    [string]$OptimizationId,
    [ValidateSet('Preview','Mock','Fixture','Real')]
    [string]$ExecutorMode = 'Preview',
    [string]$MockRunnerPath = '',
    [string[]]$ExactTargetAllowlist = @(),
    [string]$ShaderCacheRoot = '',
    [string]$BackupRoot = '',
    [string]$RollbackManifestPath = '',
    [string[]]$ServiceName = @(),
    [string]$PowerPlanPath = '',
    [string]$PowerSchemeGuid = '',
    [int]$TimeoutSeconds = 30,
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$UserApproved,
    [switch]$BackupCompleted,
    [switch]$AllowDisposableFixtureApply,
    [switch]$AllowRealSystemExecution
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StutterOptimization.Common.ps1')
. (Join-Path $PSScriptRoot 'BackendExecutor.Common.ps1')

function Test-StutterExactAllowlist {
    param(
        [string[]]$Targets,
        [string[]]$Allowlist
    )
    if (@($Targets).Count -eq 0) { return $false }
    $allowed = @{}
    foreach ($target in @(Get-RooArray $Allowlist)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) { continue }
        $allowed[[System.IO.Path]::GetFullPath([string]$target).ToLowerInvariant()] = $true
    }
    foreach ($target in @(Get-RooArray $Targets)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) { return $false }
        $full = [System.IO.Path]::GetFullPath([string]$target).ToLowerInvariant()
        if (-not $allowed.ContainsKey($full)) { return $false }
    }
    return $true
}
function Invoke-StutterMockRunner {
    param(
        [string]$ShimPath,
        [string[]]$Arguments,
        [int]$Timeout
    )
    return Invoke-RooBackendPowerShellShim -ShimPath $ShimPath -Arguments $Arguments -TimeoutSeconds $Timeout
}

function Add-StutterMockStep {
    param(
        [System.Collections.Generic.List[object]]$Sequence,
        [int]$Order,
        [string]$Step,
        [string[]]$Arguments,
        [string]$ShimPath,
        [int]$Timeout
    )
    $result = Invoke-StutterMockRunner -ShimPath $ShimPath -Arguments $Arguments -Timeout $Timeout
    $completed = ((-not [bool](Get-RooPropertyValue $result 'timedOut' $false)) -and [int](Get-RooPropertyValue $result 'exitCode' -1) -eq 0)
    $Sequence.Add([pscustomobject]@{
        order = $Order
        step = $Step
        arguments = @($Arguments)
        result = $result
        completed = $completed
    }) | Out-Null
    return $completed
}

try {
    $mockMode = ($ExecutorMode -eq 'Mock')
    $fixtureMode = ($ExecutorMode -eq 'Fixture')
    $realMode = ($ExecutorMode -eq 'Real')
    $executeRequested = ($ExecutorMode -ne 'Preview')
    $mockRunnerPresent = (-not [string]::IsNullOrWhiteSpace($MockRunnerPath) -and (Test-Path -LiteralPath (Resolve-RooPath $MockRunnerPath $MockRunnerPath)))
    $shaderItems = if ($OptimizationId -eq 'shader-cache-cleanup' -and -not [string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { @(Get-RooStutterShaderCacheItems $ShaderCacheRoot) } else { @() }
    $shaderTargets = @($shaderItems | ForEach-Object { [string](Get-RooPropertyValue $_ 'path' '') })
    $pathTargets = switch ($OptimizationId) {
        'shader-cache-cleanup' { $shaderTargets }
        'power-plan' { if ([string]::IsNullOrWhiteSpace($PowerPlanPath)) { @() } else { @($PowerPlanPath) } }
        default { @() }
    }
    $exactTargetsApproved = if ($pathTargets.Count -gt 0) { Test-StutterExactAllowlist $pathTargets $ExactTargetAllowlist } else { $true }
    $fixtureRootIsTemp = if ([string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { $false } else { Test-RooStutterPathInsideTemp $ShaderCacheRoot }

    $gates = @(
        (New-RooBackendExecutorGate 'confirm-apply' 'Confirmed execution requested' $true ([bool]$ConfirmApply) 'Executor remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooBackendExecutorGate 'executor-mode-selected' 'Executor mode selected' $true $executeRequested 'ExecutorMode must be Mock, Fixture, or Real to run.' ([pscustomobject]@{ executorMode = $ExecutorMode })),
        (New-RooBackendExecutorGate 'explicit-user-approval' 'Explicit user approval evidence captured' $true ([bool]$UserApproved) 'Execution requires user approval evidence for the exact optimization and targets.' $null),
        (New-RooBackendExecutorGate 'backup-completed' 'Backup or restore metadata completed' $true ([bool]$BackupCompleted) 'System-changing optimizations require backup or restore metadata before execution.' $null),
        (New-RooBackendExecutorGate 'mock-runner-present' 'Mock runner present' $mockMode ((-not $mockMode) -or $mockRunnerPresent) 'Mock validation requires a runner shim path.' ([pscustomobject]@{ mockRunnerPath = $MockRunnerPath })),
        (New-RooBackendExecutorGate 'exact-target-allowlist' 'Exact target allowlist covers path targets' ($pathTargets.Count -gt 0) $exactTargetsApproved 'Path-based optimizations require exact target allowlist coverage.' ([pscustomobject]@{ targetCount = $pathTargets.Count; allowlistCount = @(Get-RooArray $ExactTargetAllowlist).Count })),
        (New-RooBackendExecutorGate 'fixture-mode-shader-only' 'Fixture mode limited to shader cache' $fixtureMode ((-not $fixtureMode) -or $OptimizationId -eq 'shader-cache-cleanup') 'Disposable fixture execution is only implemented for shader cache cleanup.' $null),
        (New-RooBackendExecutorGate 'fixture-root-temp' 'Fixture root is inside temp' $fixtureMode ((-not $fixtureMode) -or $fixtureRootIsTemp) 'Shader cache fixture root must be under the OS temp path.' ([pscustomobject]@{ shaderCacheRoot = $ShaderCacheRoot })),
        (New-RooBackendExecutorGate 'fixture-explicit-flag' 'Disposable fixture flag supplied' $fixtureMode ((-not $fixtureMode) -or [bool]$AllowDisposableFixtureApply) 'Fixture execution requires -AllowDisposableFixtureApply beyond confirmation.' $null),
        (New-RooBackendExecutorGate 'real-system-explicit-flag' 'Real-system explicit flag supplied' $realMode ((-not $realMode) -or [bool]$AllowRealSystemExecution) 'Real system-changing execution requires -AllowRealSystemExecution beyond confirmation.' $null),
        (New-RooBackendExecutorGate 'real-system-runner-implemented' 'Real-system runner implemented' $realMode $false 'Real standby, timer, power, shader, and service runners are intentionally not implemented in this validation build.' $null)
    )
    $blockingGates = @($gates | Where-Object { $_.blocking })
    $canExecute = ($blockingGates.Count -eq 0)
    $sequence = New-Object System.Collections.Generic.List[object]
    $status = if ($canExecute) { 'success' } elseif ($ConfirmApply -or $executeRequested) { 'blocked' } else { 'preview' }
    $fixtureResult = $null

    if ($canExecute -and $mockMode) {
        $ok = $true
        switch ($OptimizationId) {
            'standby-memory' {
                $ok = Add-StutterMockStep $sequence 1 'standby-clear' @('standby-clear') $MockRunnerPath $TimeoutSeconds
            }
            'timer-resolution' {
                $ok = (Add-StutterMockStep $sequence 1 'timer-start' @('timer-start','5000') $MockRunnerPath $TimeoutSeconds)
                if ($ok) { $ok = (Add-StutterMockStep $sequence 2 'timer-stop-restore' @('timer-stop-restore') $MockRunnerPath $TimeoutSeconds) }
            }
            'power-plan' {
                $ok = (Add-StutterMockStep $sequence 1 'power-import' @('power-import', $PowerPlanPath) $MockRunnerPath $TimeoutSeconds)
                if ($ok) { $ok = (Add-StutterMockStep $sequence 2 'power-select' @('power-select', $PowerSchemeGuid) $MockRunnerPath $TimeoutSeconds) }
                if ($ok) { $ok = (Add-StutterMockStep $sequence 3 'power-restore' @('power-restore') $MockRunnerPath $TimeoutSeconds) }
            }
            'shader-cache-cleanup' {
                $order = 1
                foreach ($target in $pathTargets) {
                    $stepOk = Add-StutterMockStep $sequence $order 'shader-cache-delete' @('shader-cache-delete', $target) $MockRunnerPath $TimeoutSeconds
                    if (-not $stepOk) { $ok = $false }
                    $order++
                }
            }
            'service-pause-preview' {
                $order = 1
                foreach ($svc in @(Get-RooArray $ServiceName)) {
                    $stepOk = Add-StutterMockStep $sequence $order 'service-pause' @('service-pause', [string]$svc) $MockRunnerPath $TimeoutSeconds
                    if (-not $stepOk) { $ok = $false }
                    $order++
                }
                foreach ($svc in @(Get-RooArray $ServiceName)) {
                    $stepOk = Add-StutterMockStep $sequence $order 'service-restore' @('service-restore', [string]$svc) $MockRunnerPath $TimeoutSeconds
                    if (-not $stepOk) { $ok = $false }
                    $order++
                }
            }
        }
        if (-not $ok) { $status = 'failed' }
    } elseif ($canExecute -and $fixtureMode -and $OptimizationId -eq 'shader-cache-cleanup') {
        $fixtureOutput = & (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') `
            -OptimizationId shader-cache-cleanup `
            -ShaderCacheRoot $ShaderCacheRoot `
            -BackupRoot $BackupRoot `
            -ConfirmApply `
            -AllowDisposableFixtureApply
        $fixtureResult = ($fixtureOutput -join [Environment]::NewLine) | ConvertFrom-Json
        $status = [string](Get-RooPropertyValue $fixtureResult 'status' 'failed')
        $sequence.Add([pscustomobject]@{
            order = 1
            step = 'shader-cache-fixture-apply'
            result = $fixtureResult
            completed = ($status -eq 'success')
        }) | Out-Null
    }

    $runs = @($sequence.ToArray())
    $rollbackManifest = [pscustomobject]@{
        manifestId = New-RooStutterRollbackManifestId $OptimizationId
        schemaVersion = 1
        productName = $script:RooStutterProductName
        actionId = 'performance.stutterOptimization.rollback'
        optimizationId = $OptimizationId
        createdAtUtc = Get-RooUtcStamp
        realSystemRollback = $false
        exactTargetAllowlist = @(Get-RooArray $ExactTargetAllowlist)
        backupCompleted = [bool]$BackupCompleted
        runnerResults = $runs
        fixtureRollback = if ($fixtureResult) { Get-RooPropertyValue $fixtureResult 'rollback' $null } else { $null }
    }
    $resolvedRollbackManifestPath = $null
    if ($canExecute -and -not [string]::IsNullOrWhiteSpace($RollbackManifestPath)) {
        $resolvedRollbackManifestPath = Resolve-RooPath $RollbackManifestPath $RollbackManifestPath
        Ensure-RooDirectory (Split-Path $resolvedRollbackManifestPath -Parent)
        ($rollbackManifest | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $resolvedRollbackManifestPath -Encoding UTF8
    }

    $result = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.executor'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
        optimizationId = $OptimizationId
        dryRun = (-not $canExecute)
        status = $status
        executionMode = $ExecutorMode.ToLowerInvariant()
        gates = @($gates)
        executionSequence = $runs
        rollbackManifest = $rollbackManifest
        rollbackManifestPath = $resolvedRollbackManifestPath
        capabilities = [pscustomobject]@{
            mockRunnerImplemented = $true
            shaderCacheFixtureRunnerImplemented = $true
            realSystemRunnerImplemented = $false
            standbyMemoryRunnerAbstracted = $true
            timerResolutionLifecycleAbstracted = $true
            powerPlanRunnerAbstracted = $true
            shaderCacheRunnerAbstracted = $true
            servicePauseRestoreAbstracted = $true
        }
        summary = [pscustomobject]@{
            willRunMockRunner = ($canExecute -and $mockMode)
            willRunFixtureApply = ($canExecute -and $fixtureMode)
            willRunRealSystemAction = $false
            willLaunchUtilities = $false
            executionStepCount = $runs.Count
            completedStepCount = @($runs | Where-Object { $_.completed -eq $true }).Count
            timeoutCount = @($runs | Where-Object { $_.result.timedOut -eq $true }).Count
            nonZeroExitCount = @($runs | Where-Object { $null -ne $_.result.exitCode -and [int]$_.result.exitCode -ne 0 }).Count
            focusStealPrevented = (@($runs | Where-Object { $_.result.invocation.focusStealPrevented -eq $false }).Count -eq 0)
            blockingGateCount = $blockingGates.Count
        }
        warnings = @((New-RooStutterIssue 'STUTTER_EXECUTOR_CONTROLLED' 'Stutter optimization executor abstraction evaluated with mock, fixture, or blocked real-system gates.' 'info' $OptimizationId $false 'Use mock mode for system-changing flows and fixture mode only for shader-cache disposable validation.' $null))
        errors = @()
        logs = @((New-RooLog 'Stutter optimization executor abstraction completed.'))
    }
    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.executor'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
        optimizationId = $OptimizationId
        dryRun = $true
        status = 'failed'
        executionMode = $ExecutorMode.ToLowerInvariant()
        executionSequence = @()
        summary = [pscustomobject]@{ willRunMockRunner = $false; willRunFixtureApply = $false; willRunRealSystemAction = $false }
        warnings = @()
        errors = @((New-RooStutterIssue 'STUTTER_EXECUTOR_FAILED' $_.Exception.Message 'error' $OptimizationId $true 'Check executor mode, mock shim, target allowlist, and backup gates.' $null))
        logs = @((New-RooLog 'Stutter optimization executor abstraction failed.' 'error'))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
