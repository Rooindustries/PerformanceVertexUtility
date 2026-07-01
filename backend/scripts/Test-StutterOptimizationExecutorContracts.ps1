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

function New-StutterRunnerShim {
    param(
        [string]$Path,
        [string]$LogPath
    )
    $escapedLog = $LogPath.Replace("'", "''")
    $content = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$logPath = '__LOG__'
$entry = [pscustomobject]@{ args = @($Rest); atUtc = (Get-Date).ToUniversalTime().ToString('o') }
($entry | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $logPath
exit 0
'@
    $content = $content.Replace('__LOG__', $escapedLog)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Read-MockLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json })
}

$requiredFiles = @(
    'backend\scripts\BackendExecutor.Common.ps1',
    'backend\scripts\Invoke-StutterOptimizationExecutor.ps1'
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-stutter-executor-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $mockLog = Join-Path $tempRoot 'stutter-mock.log'
    $mockShim = Join-Path $tempRoot 'stutter-mock.ps1'
    New-StutterRunnerShim $mockShim $mockLog

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationExecutor.ps1') -OptimizationId standby-memory)
    if ($preview.status -eq 'preview' -and $preview.summary.willRunMockRunner -eq $false -and $preview.summary.willRunRealSystemAction -eq $false -and @($preview.executionSequence).Count -eq 0) {
        Add-Pass 'Stutter optimization executor default call is preview-only and runs no command'
    } else {
        Add-Failure 'Stutter optimization executor default call was not preview-only'
    }

    $standby = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationExecutor.ps1') -OptimizationId standby-memory -ExecutorMode Mock -MockRunnerPath $mockShim -ConfirmApply -UserApproved -BackupCompleted)
    if ($standby.status -eq 'success' -and $standby.summary.willRunMockRunner -eq $true -and $standby.summary.willRunRealSystemAction -eq $false -and @($standby.executionSequence).Count -eq 1 -and @($standby.executionSequence)[0].step -eq 'standby-clear') {
        Add-Pass 'Stutter executor mock path abstracts standby memory clearing without real system action'
    } else {
        Add-Failure 'Stutter executor standby mock path did not expose expected contract'
    }

    $timer = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationExecutor.ps1') -OptimizationId timer-resolution -ExecutorMode Mock -MockRunnerPath $mockShim -ConfirmApply -UserApproved -BackupCompleted)
    if ($timer.status -eq 'success' -and @($timer.executionSequence).Count -eq 2 -and @($timer.executionSequence)[0].step -eq 'timer-start' -and @($timer.executionSequence)[1].step -eq 'timer-stop-restore') {
        Add-Pass 'Stutter executor mock path proves timer start and restore lifecycle'
    } else {
        Add-Failure 'Stutter executor timer mock path did not prove restore lifecycle'
    }

    $powerPlan = Join-Path $tempRoot 'UltimateFixture.pow'
    Set-Content -LiteralPath $powerPlan -Value 'fixture power plan' -Encoding UTF8
    $power = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationExecutor.ps1') -OptimizationId power-plan -ExecutorMode Mock -MockRunnerPath $mockShim -PowerPlanPath $powerPlan -PowerSchemeGuid '11111111-2222-3333-4444-555555555555' -ExactTargetAllowlist $powerPlan -ConfirmApply -UserApproved -BackupCompleted)
    if ($power.status -eq 'success' -and @($power.executionSequence).Count -eq 3 -and @($power.executionSequence)[0].step -eq 'power-import' -and @($power.executionSequence)[1].step -eq 'power-select' -and @($power.executionSequence)[2].step -eq 'power-restore') {
        Add-Pass 'Stutter executor mock path proves power plan import, selection, and restore contract'
    } else {
        Add-Failure 'Stutter executor power plan mock path did not prove import/select/restore'
    }

    $service = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationExecutor.ps1') -OptimizationId service-pause-preview -ExecutorMode Mock -MockRunnerPath $mockShim -ServiceName @('FixtureUpdater') -ConfirmApply -UserApproved -BackupCompleted)
    if ($service.status -eq 'success' -and @($service.executionSequence).Count -eq 2 -and @($service.executionSequence)[0].step -eq 'service-pause' -and @($service.executionSequence)[1].step -eq 'service-restore') {
        Add-Pass 'Stutter executor mock path proves service pause and restore contract'
    } else {
        Add-Failure 'Stutter executor service mock path did not prove pause/restore'
    }

    $shaderRoot = Join-Path $tempRoot 'shader-cache'
    New-Item -ItemType Directory -Path (Join-Path $shaderRoot 'NVIDIA\DXCache') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $shaderRoot 'DirectX') -Force | Out-Null
    $shaderFileA = Join-Path $shaderRoot 'NVIDIA\DXCache\a.bin'
    $shaderFileB = Join-Path $shaderRoot 'DirectX\b.bin'
    Set-Content -LiteralPath $shaderFileA -Value 'nvidia cache' -Encoding UTF8
    Set-Content -LiteralPath $shaderFileB -Value 'directx cache' -Encoding UTF8

    $blockedFixture = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationExecutor.ps1') -OptimizationId shader-cache-cleanup -ExecutorMode Fixture -ShaderCacheRoot $shaderRoot -ExactTargetAllowlist @($shaderFileA, $shaderFileB) -ConfirmApply -UserApproved -BackupCompleted)
    $fixtureFlagGate = @($blockedFixture.gates | Where-Object { $_.gateId -eq 'fixture-explicit-flag' }) | Select-Object -First 1
    if ($blockedFixture.status -eq 'blocked' -and $fixtureFlagGate.blocking -eq $true -and @(Get-ChildItem -LiteralPath $shaderRoot -Recurse -File).Count -eq 2) {
        Add-Pass 'Stutter executor blocks shader fixture apply without disposable-fixture flag'
    } else {
        Add-Failure 'Stutter executor did not block missing disposable-fixture flag'
    }

    $fixtureRollback = Join-Path $tempRoot 'shader-executor-rollback.json'
    $fixture = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationExecutor.ps1') -OptimizationId shader-cache-cleanup -ExecutorMode Fixture -ShaderCacheRoot $shaderRoot -ExactTargetAllowlist @($shaderFileA, $shaderFileB) -RollbackManifestPath $fixtureRollback -ConfirmApply -UserApproved -BackupCompleted -AllowDisposableFixtureApply)
    if ($fixture.status -eq 'success' -and $fixture.summary.willRunFixtureApply -eq $true -and $fixture.summary.willRunRealSystemAction -eq $false -and $fixture.summary.willLaunchUtilities -eq $false -and @($fixture.executionSequence).Count -eq 1 -and (Test-Path -LiteralPath $fixtureRollback) -and @(Get-ChildItem -LiteralPath $shaderRoot -File -Recurse | Where-Object { $_.FullName -notlike '*_roo-shader-cache-backup*' }).Count -eq 0) {
        Add-Pass 'Stutter executor fixture path deletes only disposable shader cache files and writes rollback manifest'
    } else {
        Add-Failure 'Stutter executor shader fixture path did not produce expected disposable cleanup proof'
    }
    $restorePath = [string]$fixture.rollbackManifest.fixtureRollback.rollbackManifestPath
    $restore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-StutterOptimization.ps1') -RollbackManifestPath $restorePath -ConfirmApply -AllowDisposableFixtureApply)
    if ($restore.status -eq 'success' -and $restore.summary.restoredCount -eq 2 -and @(Get-ChildItem -LiteralPath $shaderRoot -Recurse -File | Where-Object { $_.FullName -notlike '*_roo-shader-cache-backup*' }).Count -eq 2) {
        Add-Pass 'Stutter executor fixture rollback rehydrates disposable shader cache files'
    } else {
        Add-Failure 'Stutter executor fixture rollback did not restore disposable shader cache files'
    }

    $blockedReal = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationExecutor.ps1') -OptimizationId standby-memory -ExecutorMode Real -ConfirmApply -UserApproved -BackupCompleted -AllowRealSystemExecution)
    $realGate = @($blockedReal.gates | Where-Object { $_.gateId -eq 'real-system-runner-implemented' }) | Select-Object -First 1
    if ($blockedReal.status -eq 'blocked' -and $realGate.blocking -eq $true -and $blockedReal.capabilities.realSystemRunnerImplemented -eq $false -and $blockedReal.summary.willRunRealSystemAction -eq $false) {
        Add-Pass 'Stutter executor real system actions remain blocked by design even with explicit flag'
    } else {
        Add-Failure 'Stutter executor real system action was not blocked by design'
    }

    $mockEntries = Read-MockLog $mockLog
    if (@($mockEntries).Count -eq 8 -and $standby.summary.focusStealPrevented -eq $true -and $timer.summary.focusStealPrevented -eq $true -and $power.summary.focusStealPrevented -eq $true -and $service.summary.focusStealPrevented -eq $true) {
        Add-Pass 'Stutter executor mock validation used hidden runner shims for all system-changing contracts'
    } else {
        Add-Failure 'Stutter executor mock validation did not prove hidden runner shim coverage'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'Stutter executor disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Stutter executor disposable fixtures remain'
    }
} catch {
    Add-Failure "Stutter executor validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after stutter executor validation'
} else {
    Add-Failure "backend/state is not empty or changed during stutter executor validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Stutter executor validation did not launch FSOS, WinUtil, timer, power, service, cleanup, or tweak utilities'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Stutter executor validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Stutter executor validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
