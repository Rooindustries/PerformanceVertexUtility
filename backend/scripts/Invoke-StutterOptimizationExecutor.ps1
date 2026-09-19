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
    foreach ($target in @(Get-RooIndustriesArray $Allowlist)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) { continue }
        $allowed[[System.IO.Path]::GetFullPath([string]$target).ToLowerInvariant()] = $true
    }
    foreach ($target in @(Get-RooIndustriesArray $Targets)) {
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
    return Invoke-RooIndustriesBackendPowerShellShim -ShimPath $ShimPath -Arguments $Arguments -TimeoutSeconds $Timeout
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
    $completed = ((-not [bool](Get-RooIndustriesPropertyValue $result 'timedOut' $false)) -and [int](Get-RooIndustriesPropertyValue $result 'exitCode' -1) -eq 0)
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
    $mockRunnerPresent = (-not [string]::IsNullOrWhiteSpace($MockRunnerPath) -and (Test-Path -LiteralPath (Resolve-RooIndustriesPath $MockRunnerPath $MockRunnerPath)))
    $shaderItems = if ($OptimizationId -eq 'shader-cache-cleanup' -and -not [string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { @(Get-RooIndustriesStutterShaderCacheItems $ShaderCacheRoot) } else { @() }
    $shaderTargets = @($shaderItems | ForEach-Object { [string](Get-RooIndustriesPropertyValue $_ 'path' '') })
    $pathTargets = switch ($OptimizationId) {
        'shader-cache-cleanup' { $shaderTargets }
        'power-plan' { if ([string]::IsNullOrWhiteSpace($PowerPlanPath)) { @() } else { @($PowerPlanPath) } }
        default { @() }
    }
    $exactTargetsApproved = if ($pathTargets.Count -gt 0) { Test-StutterExactAllowlist $pathTargets $ExactTargetAllowlist } else { $true }
    $fixtureRootIsTemp = if ([string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { $false } else { Test-RooIndustriesStutterPathInsideTemp $ShaderCacheRoot }

    $gates = @(
        (New-RooIndustriesBackendExecutorGate 'confirm-apply' 'Confirmed execution requested' $true ([bool]$ConfirmApply) 'Executor remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooIndustriesBackendExecutorGate 'executor-mode-selected' 'Executor mode selected' $true $executeRequested 'ExecutorMode must be Mock, Fixture, or Real to run.' ([pscustomobject]@{ executorMode = $ExecutorMode })),
        (New-RooIndustriesBackendExecutorGate 'explicit-user-approval' 'Explicit user approval evidence captured' $true ([bool]$UserApproved) 'Execution requires user approval evidence for the exact optimization and targets.' $null),
        (New-RooIndustriesBackendExecutorGate 'backup-completed' 'Backup or restore metadata completed' $true ([bool]$BackupCompleted) 'System-changing optimizations require backup or restore metadata before execution.' $null),
        (New-RooIndustriesBackendExecutorGate 'mock-runner-present' 'Mock runner present' $mockMode ((-not $mockMode) -or $mockRunnerPresent) 'Mock validation requires a runner shim path.' ([pscustomobject]@{ mockRunnerPath = $MockRunnerPath })),
        (New-RooIndustriesBackendExecutorGate 'exact-target-allowlist' 'Exact target allowlist covers path targets' ($pathTargets.Count -gt 0) $exactTargetsApproved 'Path-based optimizations require exact target allowlist coverage.' ([pscustomobject]@{ targetCount = $pathTargets.Count; allowlistCount = @(Get-RooIndustriesArray $ExactTargetAllowlist).Count })),
        (New-RooIndustriesBackendExecutorGate 'fixture-mode-shader-only' 'Fixture mode limited to shader cache' $fixtureMode ((-not $fixtureMode) -or $OptimizationId -eq 'shader-cache-cleanup') 'Disposable fixture execution is only implemented for shader cache cleanup.' $null),
        (New-RooIndustriesBackendExecutorGate 'fixture-root-temp' 'Fixture root is inside temp' $fixtureMode ((-not $fixtureMode) -or $fixtureRootIsTemp) 'Shader cache fixture root must be under the OS temp path.' ([pscustomobject]@{ shaderCacheRoot = $ShaderCacheRoot })),
        (New-RooIndustriesBackendExecutorGate 'fixture-explicit-flag' 'Disposable fixture flag supplied' $fixtureMode ((-not $fixtureMode) -or [bool]$AllowDisposableFixtureApply) 'Fixture execution requires -AllowDisposableFixtureApply beyond confirmation.' $null),
        (New-RooIndustriesBackendExecutorGate 'real-system-explicit-flag' 'Real-system explicit flag supplied' $realMode ((-not $realMode) -or [bool]$AllowRealSystemExecution) 'Real system-changing execution requires -AllowRealSystemExecution beyond confirmation.' $null),
        (New-RooIndustriesBackendExecutorGate 'real-system-runner-implemented' 'Real-system runner implemented' $realMode $true 'Per-action real, reversible, read-only, or helper-contract executors are implemented in Invoke-StutterOptimizationRealExecutor.ps1.' $null)
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
                foreach ($svc in @(Get-RooIndustriesArray $ServiceName)) {
                    $stepOk = Add-StutterMockStep $sequence $order 'service-pause' @('service-pause', [string]$svc) $MockRunnerPath $TimeoutSeconds
                    if (-not $stepOk) { $ok = $false }
                    $order++
                }
                foreach ($svc in @(Get-RooIndustriesArray $ServiceName)) {
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
        $status = [string](Get-RooIndustriesPropertyValue $fixtureResult 'status' 'failed')
        $sequence.Add([pscustomobject]@{
            order = 1
            step = 'shader-cache-fixture-apply'
            result = $fixtureResult
            completed = ($status -eq 'success')
        }) | Out-Null
    } elseif ($canExecute -and $realMode) {
        $realParams = @{
            OptimizationId = $OptimizationId
            UserApproved = $true
        }
        if ($ConfirmApply) { $realParams['ConfirmApply'] = $true }
        if ($AllowRealSystemExecution) { $realParams['AllowRealSystemExecution'] = $true }
        if (-not [string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { $realParams['ShaderCacheRoot'] = $ShaderCacheRoot }
        if (@(Get-RooIndustriesArray $ServiceName).Count -gt 0) { $realParams['ServiceName'] = @(Get-RooIndustriesArray $ServiceName) }
        $realOutput = & (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') @realParams
        $realResult = ($realOutput -join [Environment]::NewLine) | ConvertFrom-Json
        $status = [string](Get-RooIndustriesPropertyValue $realResult 'status' 'failed')
        $sequence.Add([pscustomobject]@{
            order = 1
            step = 'stutter-real-controlled-executor'
            result = $realResult
            completed = ($status -in @('success','requires-elevation','cli-unsupported','probe-incomplete','approval-or-input-required') -or $status -notin @('failed','blocked'))
        }) | Out-Null
    }

    $runs = @($sequence.ToArray())
    $rollbackManifest = [pscustomobject]@{
        manifestId = New-RooIndustriesStutterRollbackManifestId $OptimizationId
        schemaVersion = 1
        productName = $script:RooIndustriesStutterProductName
        actionId = 'performance.stutterOptimization.rollback'
        optimizationId = $OptimizationId
        createdAtUtc = Get-RooIndustriesUtcStamp
        realSystemRollback = $false
        exactTargetAllowlist = @(Get-RooIndustriesArray $ExactTargetAllowlist)
        backupCompleted = [bool]$BackupCompleted
        runnerResults = $runs
        fixtureRollback = if ($fixtureResult) { Get-RooIndustriesPropertyValue $fixtureResult 'rollback' $null } else { $null }
    }
    $resolvedRollbackManifestPath = $null
    if ($canExecute -and -not [string]::IsNullOrWhiteSpace($RollbackManifestPath)) {
        $resolvedRollbackManifestPath = Resolve-RooIndustriesPath $RollbackManifestPath $RollbackManifestPath
        Ensure-RooIndustriesDirectory (Split-Path $resolvedRollbackManifestPath -Parent)
        ($rollbackManifest | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $resolvedRollbackManifestPath -Encoding UTF8
    }

    $result = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.executor'
        schemaVersion = 1
        productName = $script:RooIndustriesStutterProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
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
            realSystemRunnerImplemented = $true
            standbyMemoryRunnerAbstracted = $true
            timerResolutionLifecycleAbstracted = $true
            powerPlanRunnerAbstracted = $true
            shaderCacheRunnerAbstracted = $true
            servicePauseRestoreAbstracted = $true
        }
        summary = [pscustomobject]@{
            willRunMockRunner = ($canExecute -and $mockMode)
            willRunFixtureApply = ($canExecute -and $fixtureMode)
            willRunRealSystemAction = ($canExecute -and $realMode)
            willLaunchUtilities = $false
            executionStepCount = $runs.Count
            completedStepCount = @($runs | Where-Object { $_.completed -eq $true }).Count
            timeoutCount = @($runs | Where-Object { $_.result.timedOut -eq $true }).Count
            nonZeroExitCount = @($runs | Where-Object { $null -ne $_.result.exitCode -and [int]$_.result.exitCode -ne 0 }).Count
            focusStealPrevented = (@($runs | Where-Object { $_.result.invocation.focusStealPrevented -eq $false }).Count -eq 0)
            blockingGateCount = $blockingGates.Count
        }
        warnings = @((New-RooIndustriesStutterIssue 'STUTTER_EXECUTOR_CONTROLLED' 'Stutter optimization executor abstraction evaluated with mock, fixture, or real controlled per-action runner gates.' 'info' $OptimizationId $false 'Use real mode only with exact approval, helper, backup, and restore evidence.' $null))
        errors = @()
        logs = @((New-RooIndustriesLog 'Stutter optimization executor abstraction completed.'))
    }
    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.executor'
        schemaVersion = 1
        productName = $script:RooIndustriesStutterProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        optimizationId = $OptimizationId
        dryRun = $true
        status = 'failed'
        executionMode = $ExecutorMode.ToLowerInvariant()
        executionSequence = @()
        summary = [pscustomobject]@{ willRunMockRunner = $false; willRunFixtureApply = $false; willRunRealSystemAction = $false }
        warnings = @()
        errors = @((New-RooIndustriesStutterIssue 'STUTTER_EXECUTOR_FAILED' $_.Exception.Message 'error' $OptimizationId $true 'Check executor mode, mock shim, target allowlist, and backup gates.' $null))
        logs = @((New-RooIndustriesLog 'Stutter optimization executor abstraction failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
