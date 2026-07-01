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
        backendStatus = 'preview-only'
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
            blockedReason = 'Real standby-list clearing is system-changing and remains blocked until a dedicated executor and before/after validation are approved.'
            disposableFixtureSupported = $false
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $false
            reason = 'Standby memory clear is transient and cannot be restored; only before/after evidence can be captured.'
        }
        warnings = @((New-RooStutterIssue 'STANDBY_MEMORY_APPLY_BLOCKED' 'Standby memory clear is preview-only in this backend contract.' 'warning' 'standby-memory' $true 'Use the memory evidence to decide whether a future one-shot executor is justified.' $null))
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
        backendStatus = 'preview-only'
        dryRun = $true
        evidence = [pscustomobject]@{ timerResolution = $timer }
        proposedAction = [pscustomobject]@{
            action = 'timer-resolution-session'
            applyAllowedNow = $false
            blockedReason = 'Timer resolution changes require an owned lifecycle process and cleanup guarantees; no timer helper is launched by validation.'
            disposableFixtureSupported = $false
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $true
            restoreAction = 'stop-owned-timer-session'
            implementedNow = $false
        }
        warnings = @((New-RooStutterIssue 'TIMER_RESOLUTION_APPLY_BLOCKED' 'Timer resolution apply is blocked; only the status contract is exposed.' 'warning' 'timer-resolution' $true 'Add a dedicated owned lifecycle before enabling apply.' $null))
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
        backendStatus = 'preview-only'
        dryRun = $true
        evidence = [pscustomobject]@{ activePowerPlan = $power }
        proposedAction = [pscustomobject]@{
            action = 'power-plan-import-or-select'
            applyAllowedNow = $false
            blockedReason = 'Power scheme import/selection is system-changing; this contract captures restore requirements only.'
            disposableFixtureSupported = $false
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $true
            restoreActiveSchemeGuid = Get-RooPropertyValue $power 'activeSchemeGuid' $null
            restoreRequiredBeforeApply = $true
            implementedNow = $false
        }
        warnings = @((New-RooStutterIssue 'POWER_PLAN_APPLY_BLOCKED' 'Power plan import/selection remains preview-only.' 'warning' 'power-plan' $true 'Review active scheme and laptop/thermal gates before any future apply.' $null))
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
        backendStatus = 'fixture-apply-ready'
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
            blockedReason = 'Real shader-cache deletion remains blocked; fixture apply is available only under a temp root with confirmation.'
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $true
            rollbackActionId = 'performance.stutterOptimization.restoreShaderCacheFixture'
            backupRequiredBeforeDelete = $true
        }
        warnings = @((New-RooStutterIssue 'SHADER_CACHE_REAL_APPLY_BLOCKED' 'Shader cache cleanup can be applied only to disposable temp fixtures in this backend validation.' 'warning' 'shader-cache-cleanup' $true 'Use Invoke-StutterOptimization.ps1 with -AllowDisposableFixtureApply for fixture proof only.' $null))
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
        backendStatus = 'preview-only'
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
            blockedReason = 'Service pause is preview-only until dependency graph, state backup, and restore failure validation exist.'
            disposableFixtureSupported = $false
        }
        rollback = [pscustomobject]@{
            rollbackSupported = $true
            stateBackupRequired = $true
            implementedNow = $false
        }
        warnings = @((New-RooStutterIssue 'SERVICE_PAUSE_APPLY_BLOCKED' 'Service pause is preview-only; no service control command is called.' 'warning' 'service-pause-preview' $true 'Keep this as candidate explanation until restore tests cover dependency failures.' $null))
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

