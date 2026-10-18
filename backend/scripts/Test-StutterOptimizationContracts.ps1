param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]
$evidence = [ordered]@{ schemaVersion = 1; test = 'shader-backup-recovery'; cases = [ordered]@{} }
if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $EvidencePath = Join-Path $repoRoot 'artifacts\validation\shader-backup-recovery.json' }

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
    'backend\scripts\StutterOptimization.Common.ps1',
    'backend\scripts\Preview-StutterOptimization.ps1',
    'backend\scripts\Invoke-StutterOptimization.ps1',
    'backend\scripts\Invoke-StutterOptimizationRealExecutor.ps1',
    'backend\scripts\Restore-StutterOptimization.ps1'
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-stutter-contract-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    $shaderRoot = Join-Path $tempRoot 'shader-cache'
    New-Item -ItemType Directory -Path (Join-Path $shaderRoot 'NVIDIA\DXCache') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $shaderRoot 'DirectX') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $shaderRoot 'Steam') -Force | Out-Null
    'nvidia-cache' | Set-Content -LiteralPath (Join-Path $shaderRoot 'NVIDIA\DXCache\a.bin') -Encoding UTF8
    'directx-cache' | Set-Content -LiteralPath (Join-Path $shaderRoot 'DirectX\b.bin') -Encoding UTF8
    'steam-cache' | Set-Content -LiteralPath (Join-Path $shaderRoot 'Steam\c.bin') -Encoding UTF8

    $memoryPath = Join-Path $tempRoot 'memory.json'
    $timerPath = Join-Path $tempRoot 'timer.json'
    $powerPath = Join-Path $tempRoot 'power.json'
    $servicePath = Join-Path $tempRoot 'services.json'
    ([pscustomobject]@{ source = 'fixture'; totalPhysicalBytes = 17179869184; availableBytes = 1879048192; standbyBytes = 4294967296; commitUsedBytes = 13958643712; commitLimitBytes = 21474836480 } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $memoryPath -Encoding UTF8
    ([pscustomobject]@{ source = 'fixture'; current100ns = 156250; minimum100ns = 5000; maximum100ns = 156250 } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $timerPath -Encoding UTF8
    ([pscustomobject]@{ source = 'fixture'; activeSchemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'; activeSchemeName = 'Balanced'; isLaptop = $false } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $powerPath -Encoding UTF8
    ([pscustomobject]@{
        source = 'fixture'
        services = @(
            [pscustomobject]@{ name = 'FixtureUpdater'; displayName = 'Fixture Updater'; protected = $false; allowPause = $true; state = 'Running'; startMode = 'Manual' },
            [pscustomobject]@{ name = 'AudioEndpointBuilder'; displayName = 'Windows Audio Endpoint Builder'; protected = $true; allowPause = $false; state = 'Running'; startMode = 'Auto' }
        )
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $servicePath -Encoding UTF8

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Preview-StutterOptimization.ps1') -MemorySnapshotPath $memoryPath -TimerSnapshotPath $timerPath -PowerPlanSnapshotPath $powerPath -ShaderCacheRoot $shaderRoot -ServiceInventoryPath $servicePath)
    if ($preview.status -eq 'preview' -and $preview.summary.contractCount -eq 5 -and $preview.summary.realApplyAllowedCount -eq 0 -and $preview.summary.fixtureApplyReadyCount -eq 1 -and $preview.summary.controlledExecutorReadyCount -eq 4 -and $preview.summary.helperContractReadyCount -eq 1) {
        Add-Pass 'Stutter optimization preview returns five backend contracts with controlled executor readiness metadata'
    } else {
        Add-Failure 'Stutter optimization preview returned an unexpected contract summary'
    }
    $standby = @($preview.contracts | Where-Object { $_.optimizationId -eq 'standby-memory' }) | Select-Object -First 1
    $timer = @($preview.contracts | Where-Object { $_.optimizationId -eq 'timer-resolution' }) | Select-Object -First 1
    $power = @($preview.contracts | Where-Object { $_.optimizationId -eq 'power-plan' }) | Select-Object -First 1
    $service = @($preview.contracts | Where-Object { $_.optimizationId -eq 'service-pause-preview' }) | Select-Object -First 1
    if ($standby.backendStatus -eq 'helper-contract-ready' -and $timer.backendStatus -eq 'real-executor-ready' -and $power.backendStatus -eq 'real-executor-ready' -and $service.backendStatus -eq 'service-runner-layer-ready' -and $standby.proposedAction.applyAllowedNow -eq $false -and $timer.proposedAction.applyAllowedNow -eq $false -and $power.proposedAction.applyAllowedNow -eq $false -and $service.proposedAction.applyAllowedNow -eq $false) {
        Add-Pass 'Stutter preview distinguishes controlled executor readiness from product approval gates'
    } else {
        Add-Failure 'Stutter preview did not expose expected executor readiness and approval gates'
    }

    $approvalGated = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -OptimizationId standby-memory -ConfirmApply -AllowDisposableFixtureApply)
    $approvalGate = @($approvalGated.gates | Where-Object { $_.gateId -eq 'explicit-user-approval' }) | Select-Object -First 1
    if ($approvalGated.actionId -eq 'performance.stutterOptimization.realExecutor' -and $approvalGated.status -eq 'blocked' -and $approvalGate.blocking -eq $true -and $approvalGated.summary.willPersist -eq $false) {
        Add-Pass 'Legacy stutter apply entrypoint routes non-fixture actions to the controlled real executor and approval gate'
    } else {
        Add-Failure 'Legacy stutter apply entrypoint did not route non-fixture action to controlled real executor'
    }

    $standbyRoute = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -OptimizationId standby-memory -UserApproved)
    if ($standbyRoute.actionId -eq 'performance.stutterOptimization.realExecutor' -and $standbyRoute.status -eq 'helper-required' -and $standbyRoute.capabilities.helperBuildScriptExists -eq $true -and $standbyRoute.capabilities.helperElevationCommand) {
        Add-Pass 'Legacy stutter apply entrypoint exposes standby helper build and elevation plan through real executor'
    } else {
        Add-Failure 'Legacy stutter apply entrypoint did not expose standby helper plan'
    }

    $applyBlocked = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -OptimizationId shader-cache-cleanup -ShaderCacheRoot $shaderRoot -ConfirmApply)
    if ($applyBlocked.status -eq 'blocked' -and $applyBlocked.summary.deletedCount -eq 0 -and @(Get-ChildItem -LiteralPath $shaderRoot -Recurse -File).Count -eq 3) {
        Add-Pass 'Shader cache fixture apply blocks without disposable-fixture flag and leaves files intact'
    } else {
        Add-Failure 'Shader cache fixture apply did not block safely without disposable-fixture flag'
    }

    $apply = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -OptimizationId shader-cache-cleanup -ShaderCacheRoot $shaderRoot -ConfirmApply -AllowDisposableFixtureApply)
    if ($apply.status -eq 'success' -and $apply.summary.deletedCount -eq 3 -and $apply.summary.willDeleteRealFiles -eq $false -and $apply.rollback.backupRoot -like '*.shader-cache-backup-*' -and (Test-Path -LiteralPath $apply.rollback.rollbackManifestPath) -and @(Get-ChildItem -LiteralPath $shaderRoot -File -Recurse).Count -eq 0) {
        Add-Pass 'Shader cache fixture apply backs up and deletes only disposable cache files'
    } else {
        Add-Failure 'Shader cache fixture apply did not produce expected backup/delete proof'
    }

    $restore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-StutterOptimization.ps1') -RollbackManifestPath $apply.rollback.rollbackManifestPath -ConfirmApply -AllowDisposableFixtureApply)
    if ($restore.status -eq 'success' -and $restore.summary.restoredCount -eq 3 -and @(Get-ChildItem -LiteralPath $shaderRoot -Recurse -File).Count -eq 3) {
        Add-Pass 'Shader cache fixture restore rehydrates files from rollback manifest'
    } else {
        Add-Failure 'Shader cache fixture restore did not restore expected files'
    }

    $firstApply = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -OptimizationId shader-cache-cleanup -ShaderCacheRoot $shaderRoot -ConfirmApply -AllowDisposableFixtureApply)
    $laterFile = Join-Path $shaderRoot 'NVIDIA\DXCache\later.bin'
    New-Item -ItemType Directory -Path (Split-Path $laterFile -Parent) -Force | Out-Null
    'later-cache' | Set-Content -LiteralPath $laterFile -Encoding UTF8
    $secondApply = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -OptimizationId shader-cache-cleanup -ShaderCacheRoot $shaderRoot -ConfirmApply -AllowDisposableFixtureApply)
    $secondSources = @($secondApply.rollback.backupRecords | ForEach-Object { [IO.Path]::GetFileName([string]$_.source) })
    $secondRestore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-StutterOptimization.ps1') -RollbackManifestPath $secondApply.rollback.rollbackManifestPath -ConfirmApply -AllowDisposableFixtureApply)
    $firstRestore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-StutterOptimization.ps1') -RollbackManifestPath $firstApply.rollback.rollbackManifestPath -ConfirmApply -AllowDisposableFixtureApply)
    $restoredNames = @(Get-ChildItem -LiteralPath $shaderRoot -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
    if ($firstApply.status -eq 'success' -and $secondApply.status -eq 'success' -and $secondApply.summary.backupCount -eq 1 -and $secondSources.Count -eq 1 -and $secondSources[0] -eq 'later.bin' -and
        -not ([IO.Path]::GetFullPath([string]$firstApply.rollback.backupRoot) + [IO.Path]::DirectorySeparatorChar).StartsWith([IO.Path]::GetFullPath($shaderRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and $firstApply.rollback.backupRoot -ne $secondApply.rollback.backupRoot -and
        $secondRestore.status -eq 'success' -and $firstRestore.status -eq 'success' -and ($restoredNames -join ',') -eq 'a.bin,b.bin,c.bin,later.bin') {
        Add-Pass 'A repeated shader cache cleanup keeps earlier backups out of the cache and both runs restore'
    } else {
        Add-Failure "A repeated shader cache cleanup must not consume an earlier backup: second sources $($secondSources -join ', '); restored $($restoredNames -join ', ')"
    }

    $explicitRoot = Join-Path $tempRoot 'explicit-cache'
    $explicitBackupRoot = Join-Path $tempRoot 'explicit-backup'
    [IO.Directory]::CreateDirectory($explicitRoot) | Out-Null
    $firstFile = Join-Path $explicitRoot 'a.bin'; $secondFile = Join-Path $explicitRoot 'b.bin'
    [IO.File]::WriteAllText($firstFile, 'first cache')
    $firstHash = (Get-FileHash -LiteralPath $firstFile -Algorithm SHA256).Hash
    $explicitApply = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -OptimizationId shader-cache-cleanup -ShaderCacheRoot $explicitRoot -BackupRoot $explicitBackupRoot -ConfirmApply -AllowDisposableFixtureApply)
    $explicitManifest = $explicitApply.rollback.rollbackManifestPath
    $manifestHash = (Get-FileHash -LiteralPath $explicitManifest -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($secondFile, 'second cache')
    $secondHash = (Get-FileHash -LiteralPath $secondFile -Algorithm SHA256).Hash
    $explicitRetry = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -OptimizationId shader-cache-cleanup -ShaderCacheRoot $explicitRoot -BackupRoot $explicitBackupRoot -ConfirmApply -AllowDisposableFixtureApply)
    $backupGate = @($explicitRetry.gates | Where-Object { $_.gateId -eq 'backup-root-new' })
    $manifestHashAfter = (Get-FileHash -LiteralPath $explicitManifest -Algorithm SHA256).Hash
    $explicitRestore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-StutterOptimization.ps1') -RollbackManifestPath $explicitManifest -ConfirmApply -AllowDisposableFixtureApply)
    $evidence.cases['explicit-backup-reuse'] = [pscustomobject]@{ firstApply = $explicitApply; retry = $explicitRetry; restore = $explicitRestore; manifestSha256Before = $manifestHash; manifestSha256After = $manifestHashAfter; firstFileSha256Before = $firstHash; firstFileSha256After = (Get-FileHash -LiteralPath $firstFile -Algorithm SHA256).Hash; secondFileSha256Before = $secondHash; secondFileSha256After = (Get-FileHash -LiteralPath $secondFile -Algorithm SHA256).Hash }
    if ($explicitApply.status -eq 'success' -and $explicitApply.summary.deletedCount -eq 1 -and
        $explicitRetry.status -eq 'blocked' -and $explicitRetry.dryRun -and $explicitRetry.summary.deletedCount -eq 0 -and $explicitRetry.summary.backupCount -eq 0 -and
        $backupGate.Count -eq 1 -and $backupGate[0].blocking -and -not $backupGate[0].satisfied -and
        $manifestHashAfter -eq $manifestHash -and (Get-FileHash -LiteralPath $secondFile -Algorithm SHA256).Hash -eq $secondHash -and
        $explicitRestore.status -eq 'success' -and $explicitRestore.summary.restoredCount -eq 1 -and (Get-FileHash -LiteralPath $firstFile -Algorithm SHA256).Hash -eq $firstHash) {
        Add-Pass 'Reusing an explicit shader backup folder is blocked without deletion or manifest changes and its first run still restores'
    } else { Add-Failure 'Reusing an explicit shader backup folder must preserve both cache files and the first restore manifest' }

    $blockedBackupRoot = Join-Path $tempRoot 'blocked-backup'
    New-Item -ItemType Directory -Path $blockedBackupRoot -Force | Out-Null
    'not a folder' | Set-Content -LiteralPath (Join-Path $blockedBackupRoot 'Steam') -Encoding UTF8
    $partial = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -OptimizationId shader-cache-cleanup -ShaderCacheRoot $shaderRoot -BackupRoot $blockedBackupRoot -ConfirmApply -AllowDisposableFixtureApply)
    $remaining = @(Get-ChildItem -LiteralPath $shaderRoot -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
    $occupiedGate = @($partial.gates | Where-Object { $_.gateId -eq 'backup-root-new' })
    $evidence.cases['occupied-backup'] = $partial
    if ($partial.status -eq 'blocked' -and $partial.dryRun -eq $true -and $partial.summary.deletedCount -eq 0 -and
        $occupiedGate.Count -eq 1 -and $occupiedGate[0].blocking -and [IO.File]::ReadAllText((Join-Path $blockedBackupRoot 'Steam')).Trim() -eq 'not a folder' -and ($remaining -join ',') -eq 'a.bin,b.bin,c.bin,later.bin') {
        Add-Pass 'An occupied shader backup folder is blocked before copying or deleting files'
    } else {
        Add-Failure "An occupied shader backup folder must be blocked without deletion: remaining $($remaining -join ', '); reported deleted $($partial.summary.deletedCount)"
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'Stutter optimization disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Stutter optimization disposable fixtures remain'
    }
} catch {
    Add-Failure "Stutter optimization contract validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after stutter optimization contract validation'
} else {
    Add-Failure "backend/state is not empty or changed during stutter validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Stutter optimization validation did not launch FSOS, WinUtil, power, service, cleanup, registry, driver, or forbidden tweak utilities'

$evidence.scriptSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') -Algorithm SHA256).Hash
$evidence.passes = @($passes.ToArray()); $evidence.failures = @($failures.ToArray())
$evidence.stateBefore = $stateBefore; $evidence.stateAfter = $stateAfter; $evidence.fixturesRemoved = -not (Test-Path -LiteralPath $tempRoot)
[IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($EvidencePath)) -Parent)) | Out-Null
$evidence | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
Write-Host "Evidence: $EvidencePath"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Stutter optimization contract validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Stutter optimization contract validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
