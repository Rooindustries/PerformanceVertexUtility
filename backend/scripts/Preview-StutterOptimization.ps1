param(
    [string]$OptimizationId = 'all',
    [string]$MemorySnapshotPath = '',
    [string]$TimerSnapshotPath = '',
    [string]$PowerPlanSnapshotPath = '',
    [string]$ShaderCacheRoot = '',
    [string]$ServiceInventoryPath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StutterOptimization.Common.ps1')

function New-StandbyMemoryContract {
    $memory = Get-RooStutterMemorySnapshot $MemorySnapshotPath
    $total = Get-RooPropertyValue $memory 'totalPhysicalBytes' $null
    $available = Get-RooPropertyValue $memory 'availableBytes' $null
    $standby = Get-RooPropertyValue $memory 'standbyBytes' $null
    $availableRatio = if ($null -ne $total -and [double]$total -gt 0 -and $null -ne $available) { [math]::Round(([double]$available / [double]$total), 4) } else { $null }
    $pressure = ($null -ne $availableRatio -and $availableRatio -lt 0.18)
    return [pscustomobject]@{
        optimizationId = 'standby-memory'
        title = 'Measure memory pressure and safely clear standby memory'
        sourceRefs = @('dash-clear-standby-memory')
        backendStatus = 'helper-contract-ready'
        dryRun = $true
        evidence = [pscustomobject]@{
            memory = $memory
            availableRatio = $availableRatio
            standbyBytes = $standby
            pressureLikely = $pressure
        }
        proposedAction = [pscustomobject]@{
            action = 'standby-list-clear'
            applyAllowedNow = $false
            approvalGate = 'Build and elevate the owned standby-memory helper, then run through Invoke-StutterOptimizationRealExecutor.ps1 with before/after counters.'
            disposableFixtureSupported = $false
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $false
            reason = 'Standby memory clear is transient and cannot be restored; only before/after evidence can be captured.'
        }
        warnings = @((New-RooStutterIssue 'STANDBY_MEMORY_HELPER_APPROVAL_GATED' 'Standby memory clear has an owned helper source contract and remains product approval-gated because the purge is transient.' 'warning' 'standby-memory' $true 'Build the helper and run it only through the controlled real executor with before/after evidence.' $null))
    }
}

function New-TimerResolutionContract {
    $timer = Get-RooStutterJsonInput $TimerSnapshotPath
    if ($null -eq $timer) {
        $timer = [pscustomobject]@{ source = 'not-probed'; current100ns = $null; minimum100ns = $null; maximum100ns = $null }
    }
    return [pscustomobject]@{
        optimizationId = 'timer-resolution'
        title = 'Backend-owned timer-resolution session lifecycle'
        sourceRefs = @('playbook-timer-resolution-scheduled-task','dash-timer-resolution-toggle')
        backendStatus = 'real-executor-ready'
        dryRun = $true
        evidence = [pscustomobject]@{ timerResolution = $timer }
        proposedAction = [pscustomobject]@{
            action = 'timer-resolution-session'
            applyAllowedNow = $false
            approvalGate = 'Invoke-StutterOptimizationRealExecutor.ps1 runs a bounded timer helper only with confirmation, user approval, and -AllowRealSystemExecution.'
            disposableFixtureSupported = $false
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $true
            restoreAction = 'stop-owned-timer-session'
            implementedNow = $true
        }
        warnings = @((New-RooStutterIssue 'TIMER_RESOLUTION_APPROVAL_GATED' 'Timer resolution apply is available through the controlled bounded executor and remains approval-gated from preview.' 'warning' 'timer-resolution' $true 'Use Invoke-StutterOptimizationRealExecutor.ps1 for the bounded session path.' $null))
    }
}

function New-PowerPlanContract {
    $power = Get-RooStutterJsonInput $PowerPlanSnapshotPath
    if ($null -eq $power) {
        $power = [pscustomobject]@{ source = 'not-probed'; activeSchemeGuid = $null; activeSchemeName = $null; isLaptop = $null }
    }
    return [pscustomobject]@{
        optimizationId = 'power-plan'
        title = 'Power plan import and selection with restore'
        sourceRefs = @('playbook-power-plan-import-and-selection','dash-power-plan-and-power-state-controls','winutil-config-tweaks-performance-plans')
        backendStatus = 'real-executor-ready'
        dryRun = $true
        evidence = [pscustomobject]@{ activePowerPlan = $power }
        proposedAction = [pscustomobject]@{
            action = 'power-plan-import-or-select'
            applyAllowedNow = $false
            approvalGate = 'Invoke-StutterOptimizationRealExecutor.ps1 validates temporary export/import/select/restore/delete only with confirmation, user approval, and -AllowRealSystemExecution.'
            disposableFixtureSupported = $false
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $true
            restoreActiveSchemeGuid = Get-RooPropertyValue $power 'activeSchemeGuid' $null
            restoreRequiredBeforeApply = $true
            implementedNow = $true
        }
        warnings = @((New-RooStutterIssue 'POWER_PLAN_APPROVAL_GATED' 'Power plan import/selection is available through the controlled temporary scheme executor and remains approval-gated from preview.' 'warning' 'power-plan' $true 'Review active scheme and laptop/thermal gates before invoking the reversible executor.' $null))
    }
}

function New-ShaderCacheContract {
    $items = @(Get-RooStutterShaderCacheItems $ShaderCacheRoot)
    $bytes = [uint64]0
    foreach ($item in $items) { $bytes += [uint64](Get-RooPropertyValue $item 'bytes' 0) }
    return [pscustomobject]@{
        optimizationId = 'shader-cache-cleanup'
        title = 'Game-aware shader cache cleanup'
        sourceRefs = @('dash-shader-cache-cleanup')
        backendStatus = 'real-planner-and-fixture-ready'
        dryRun = $true
        evidence = [pscustomobject]@{
            shaderCacheRoot = if ([string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { $null } else { [System.IO.Path]::GetFullPath($ShaderCacheRoot) }
            itemCount = $items.Count
            totalBytes = $bytes
            items = @($items)
        }
        proposedAction = [pscustomobject]@{
            action = 'shader-cache-backup-and-delete'
            applyAllowedNow = $false
            disposableFixtureSupported = $true
            approvalGate = 'Real-path planning exists; deletion uses the same backup/delete/restore engine only after exact target approval. Disposable fixture apply remains available under temp roots.'
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $true
            rollbackActionId = 'performance.stutterOptimization.restoreShaderCacheFixture'
            backupRequiredBeforeDelete = $true
        }
        warnings = @((New-RooStutterIssue 'SHADER_CACHE_APPROVAL_GATED' 'Shader cache cleanup has real-path planning and disposable-fixture apply; real user cache deletion remains approval-gated.' 'warning' 'shader-cache-cleanup' $true 'Use the controlled real executor only with exact target approval and rollback evidence.' $null))
    }
}

function New-ServicePauseContract {
    $inventory = Get-RooStutterJsonInput $ServiceInventoryPath
    $services = @(Get-RooPropertyArray $inventory 'services')
    $candidates = @($services | Where-Object { [bool](Get-RooPropertyValue $_ 'allowPause' $false) -and -not [bool](Get-RooPropertyValue $_ 'protected' $true) })
    return [pscustomobject]@{
        optimizationId = 'service-pause-preview'
        title = 'Time-boxed service pause preview with strict allowlist'
        sourceRefs = @('dash-pause-non-essential-services')
        backendStatus = 'service-runner-layer-ready'
        dryRun = $true
        evidence = [pscustomobject]@{
            serviceInventoryPath = if ([string]::IsNullOrWhiteSpace($ServiceInventoryPath)) { $null } else { Resolve-RooPath $ServiceInventoryPath $ServiceInventoryPath }
            serviceCount = $services.Count
            candidateCount = $candidates.Count
            candidates = @($candidates)
        }
        proposedAction = [pscustomobject]@{
            action = 'service-pause-session'
            applyAllowedNow = $false
            approvalGate = 'Invoke-StutterOptimizationRealExecutor.ps1 provides service analysis and shim-validated backup/pause/restore sequencing; real services require exact service allowlist approval.'
            disposableFixtureSupported = $false
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $true
            stateBackupRequired = $true
            implementedNow = $true
        }
        warnings = @((New-RooStutterIssue 'SERVICE_PAUSE_APPROVAL_GATED' 'Service pause has a controlled runner layer and remains approval-gated for real services.' 'warning' 'service-pause-preview' $true 'Require exact service allowlist, dependency review, backup, and restore evidence before pausing real services.' $null))
    }
}

try {
    $ids = if ($OptimizationId -eq 'all') { @($script:RooStutterOptimizationIds) } else { @($OptimizationId) }
    $contracts = New-Object System.Collections.Generic.List[object]
    foreach ($id in $ids) {
        switch ($id) {
            'standby-memory' { $contracts.Add((New-StandbyMemoryContract)) | Out-Null }
            'timer-resolution' { $contracts.Add((New-TimerResolutionContract)) | Out-Null }
            'power-plan' { $contracts.Add((New-PowerPlanContract)) | Out-Null }
            'shader-cache-cleanup' { $contracts.Add((New-ShaderCacheContract)) | Out-Null }
            'service-pause-preview' { $contracts.Add((New-ServicePauseContract)) | Out-Null }
            default { throw "Unknown stutter optimization id: $id" }
        }
    }
    $contractArray = @($contracts.ToArray())
    $result = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.preview'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
        dryRun = $true
        status = 'preview'
        executionMode = 'preview-only'
        optimizationId = $OptimizationId
        contracts = $contractArray
        summary = [pscustomobject]@{
            contractCount = $contractArray.Count
            realApplyAllowedCount = @($contractArray | Where-Object { $_.proposedAction.applyAllowedNow -eq $true }).Count
            fixtureApplyReadyCount = @($contractArray | Where-Object { $_.proposedAction.disposableFixtureSupported -eq $true }).Count
            controlledExecutorReadyCount = @($contractArray | Where-Object { [string]$_.backendStatus -in @('real-executor-ready','real-planner-and-fixture-ready','service-runner-layer-ready') }).Count
            helperContractReadyCount = @($contractArray | Where-Object { [string]$_.backendStatus -eq 'helper-contract-ready' }).Count
            willChangeSystem = $false
            willLaunchUtilities = $false
            willWriteState = $false
        }
        warnings = @((New-RooStutterIssue 'STUTTER_OPTIMIZATION_PREVIEW_ONLY' 'Stutter optimization contracts were generated without system changes or utility launches.' 'info' $OptimizationId $false 'Use fixture apply only for shader-cache validation.' $null))
        errors = @()
        logs = @((New-RooLog 'Stutter optimization preview completed without system changes.'))
    }
    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.preview'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
        dryRun = $true
        status = 'failed'
        executionMode = 'preview-only'
        optimizationId = $OptimizationId
        contracts = @()
        summary = [pscustomobject]@{ willChangeSystem = $false; willLaunchUtilities = $false; willWriteState = $false }
        warnings = @()
        errors = @((New-RooStutterIssue 'STUTTER_OPTIMIZATION_PREVIEW_FAILED' $_.Exception.Message 'error' $OptimizationId $true 'Check fixture paths and optimization id.' $null))
        logs = @((New-RooLog 'Stutter optimization preview failed.' 'error'))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
