$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
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

function ConvertFrom-ScriptJson {
    param([object[]]$Output)
    return ($Output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

$requiredFiles = @(
    'backend\scripts\Invoke-TimerResolutionSession.ps1',
    'backend\scripts\Invoke-StutterOptimizationRealExecutor.ps1'
)
foreach ($relative in $requiredFiles) {
    $path = Join-Path $repoRoot $relative
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $relative"
    } else {
        Add-Failure "Required file missing: $relative"
    }
}

$stateBefore = Get-StateEntryCount
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-stutter-real-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $timer = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') -OptimizationId timer-resolution -ConfirmApply -AllowRealSystemExecution -UserApproved -TimerDurationMilliseconds 50 -TimeoutSeconds 10)
    $timerStep = @($timer.executionSequence | Where-Object { $_.step -eq 'timer-resolution-bounded-session' }) | Select-Object -First 1
    if ($timer.status -in @('success','capability-limited') -and $timer.summary.willPersist -eq $false -and $timer.summary.willLaunchForbiddenUtility -eq $false -and $timerStep.result.invocation.focusStealPrevented -eq $true -and $timer.capabilities.timerRestoreProved -eq $true) {
        Add-Pass 'Timer resolution real executor ran bounded helper and proved restore-on-exit'
    } else {
        Add-Failure 'Timer resolution real executor did not prove bounded restore behavior'
    }

    $power = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') -OptimizationId power-plan -ConfirmApply -AllowRealSystemExecution -UserApproved -TimeoutSeconds 15)
    if ($power.status -in @('success','capability-limited') -and $power.capabilities.exportImportPathUsed -eq $true -and $power.summary.willPersist -eq $false -and $power.summary.willLaunchForbiddenUtility -eq $false -and $power.summary.nextEngineeringStep -and ($power.capabilities.restoreAttempted -eq $true -or $power.status -eq 'capability-limited') -and -not (Test-Path -LiteralPath ([string]$power.capabilities.temporaryPowFilePath))) {
        Add-Pass 'Power plan real executor attempted export/import/select/restore/delete flow or reported exact capability limitation'
    } else {
        Add-Failure 'Power plan real executor did not prove export/import reversible flow or exact limitation'
    }

    $standby = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') -OptimizationId standby-memory -UserApproved)
    if ($standby.status -eq 'helper-required' -and $standby.capabilities.readOnlyCountersImplemented -eq $true -and $standby.capabilities.oneShotClearRunnerScaffolded -eq $true -and $standby.capabilities.helperSourceExists -eq $true -and $standby.summary.nextEngineeringStep) {
        Add-Pass 'Standby memory executor reports read-only counters and exact native helper source path'
    } else {
        Add-Failure 'Standby memory executor did not report expected helper contract'
    }

    $shaderRoot = Join-Path $tempRoot 'shader-real-readiness'
    $shaderCacheRoot = Join-Path $shaderRoot 'NVIDIA\DXCache'
    New-Item -ItemType Directory -Path $shaderCacheRoot -Force | Out-Null
    $shaderFile = Join-Path $shaderCacheRoot 'a.bin'
    Set-Content -LiteralPath $shaderFile -Value 'shader cache' -Encoding UTF8
    $shader = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') -OptimizationId shader-cache-cleanup -ShaderCacheRoot $shaderRoot -UserApproved)
    if ($shader.status -eq 'success' -and $shader.capabilities.realPathPlannerImplemented -eq $true -and $shader.capabilities.sameBackupDeleteRestorePlanner -eq $true -and $shader.capabilities.realDeletionAttempted -eq $false -and (Test-Path -LiteralPath $shaderFile)) {
        Add-Pass 'Shader cache real-path readiness uses backup/delete/restore planner without deleting real-path files'
    } else {
        Add-Failure 'Shader cache real-path readiness did not preserve files or expose planner proof'
    }
    $shaderDelete = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') -OptimizationId shader-cache-cleanup -ShaderCacheRoot $shaderCacheRoot -ConfirmApply -AllowRealSystemExecution -UserApproved)
    $rollbackPath = [string]$shaderDelete.capabilities.rollbackManifestPath
    if ($shaderDelete.status -eq 'success' -and $shaderDelete.capabilities.approvalGatedDeletePathExecuted -eq $true -and (Test-Path -LiteralPath $rollbackPath) -and -not (Test-Path -LiteralPath $shaderFile)) {
        Add-Pass 'Shader cache real executor validates approval-gated delete path on temp cache root'
    } else {
        Add-Failure 'Shader cache real executor did not validate approval-gated delete path'
    }
    $shaderRestore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-StutterOptimization.ps1') -RollbackManifestPath $rollbackPath -ConfirmApply -AllowDisposableFixtureApply)
    if ($shaderRestore.status -eq 'success' -and (Test-Path -LiteralPath $shaderFile)) {
        Add-Pass 'Shader cache approval-gated delete path restores through rollback manifest'
    } else {
        Add-Failure 'Shader cache approval-gated delete path did not restore'
    }

    $serviceName = (Get-Service | Select-Object -First 1).Name
    $service = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') -OptimizationId service-pause-preview -ServiceName $serviceName -UserApproved)
    $serviceRecord = @($service.executionSequence[0].services) | Select-Object -First 1
    if ($service.status -eq 'success' -and $service.capabilities.serviceAnalyzerImplemented -eq $true -and $service.capabilities.realPauseRunnerLayerReady -eq $true -and $service.capabilities.realPauseAttempted -eq $false -and $serviceRecord.exists -eq $true) {
        Add-Pass 'Service pause real executor analyzes service status and dependencies without pausing real service'
    } else {
        Add-Failure 'Service pause real executor did not expose analyzer proof'
    }
    $serviceShim = Join-Path $tempRoot 'service-shim.ps1'
    $serviceLog = Join-Path $tempRoot 'service-shim.log'
    @"
param([Parameter(ValueFromRemainingArguments = `$true)][string[]]`$Rest)
(`$Rest -join '|') | Add-Content -LiteralPath '$($serviceLog.Replace("'", "''"))'
exit 0
"@ | Set-Content -LiteralPath $serviceShim -Encoding UTF8
    $serviceShimRun = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') -OptimizationId service-pause-preview -ServiceName 'FixtureService' -ServiceShimPath $serviceShim -ConfirmApply -AllowRealSystemExecution -UserApproved)
    $shimLog = if (Test-Path -LiteralPath $serviceLog) { @(Get-Content -LiteralPath $serviceLog) } else { @() }
    if ($serviceShimRun.status -eq 'success' -and $serviceShimRun.capabilities.serviceShimRunnerExecuted -eq $true -and $shimLog.Count -eq 3 -and $shimLog[0] -match 'service-backup' -and $shimLog[1] -match 'service-pause' -and $shimLog[2] -match 'service-restore') {
        Add-Pass 'Service pause real executor validates backup/pause/restore runner through harmless shim'
    } else {
        Add-Failure 'Service pause real executor did not validate shim runner'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'Stutter real executor disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Stutter real executor disposable fixtures remain'
    }
} catch {
    Add-Failure "Stutter real executor validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after stutter real executor validation'
} else {
    Add-Failure "backend/state is not empty or changed during stutter real executor validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Stutter real executor validation did not launch {source}, WinUtil, cleanup, registry, service edit, driver, or forbidden tweak utilities'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Stutter real executor validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Stutter real executor validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
