param(
    [ValidateSet('standby-memory','timer-resolution','power-plan','shader-cache-cleanup','service-pause-preview')]
    [string]$OptimizationId = 'shader-cache-cleanup',
    [string]$ShaderCacheRoot = '',
    [string]$BackupRoot = '',
    [string[]]$ServiceName = @(),
    [string]$ServiceShimPath = '',
    [uint32]$TimerPeriodMilliseconds = 1,
    [int]$TimerDurationMilliseconds = 250,
    [int]$TimeoutSeconds = 15,
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowDisposableFixtureApply,
    [switch]$AllowRealSystemExecution,
    [switch]$UserApproved
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StutterOptimization.Common.ps1')
$backupRecords = New-Object System.Collections.Generic.List[object]
$deletedRecords = New-Object System.Collections.Generic.List[object]
$rollbackManifestPath = $null
$resolvedBackupRoot = $null

try {
    if ($OptimizationId -ne 'shader-cache-cleanup' -or [bool]$AllowRealSystemExecution) {
        $realParams = @{
            OptimizationId = $OptimizationId
            TimerPeriodMilliseconds = $TimerPeriodMilliseconds
            TimerDurationMilliseconds = $TimerDurationMilliseconds
            TimeoutSeconds = $TimeoutSeconds
        }
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { $realParams['OutputPath'] = $OutputPath }
        if (-not [string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { $realParams['ShaderCacheRoot'] = $ShaderCacheRoot }
        if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) { $realParams['BackupRoot'] = $BackupRoot }
        if (@(Get-RooIndustriesArray $ServiceName).Count -gt 0) { $realParams['ServiceName'] = @(Get-RooIndustriesArray $ServiceName) }
        if (-not [string]::IsNullOrWhiteSpace($ServiceShimPath)) { $realParams['ServiceShimPath'] = $ServiceShimPath }
        if ($ConfirmApply) { $realParams['ConfirmApply'] = $true }
        if ($AllowRealSystemExecution) { $realParams['AllowRealSystemExecution'] = $true }
        if ($UserApproved) { $realParams['UserApproved'] = $true }
        & (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') @realParams
        return
    }

    $resolvedRoot = if ([string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { $null } else { [System.IO.Path]::GetFullPath($ShaderCacheRoot) }
    $resolvedBackupRoot = if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        if ([string]::IsNullOrWhiteSpace($resolvedRoot)) { $null } else {
            $cacheFolder = $resolvedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            Join-Path (Split-Path $cacheFolder -Parent) ((Split-Path $cacheFolder -Leaf) + '.roo-industries-shader-backup-' + [guid]::NewGuid().ToString('N'))
        }
    } else {
        [System.IO.Path]::GetFullPath($BackupRoot)
    }
    $rootIsTemp = ((-not [string]::IsNullOrWhiteSpace($resolvedRoot)) -and (Test-RooIndustriesStutterPathInsideTemp $resolvedRoot))
    $items = @(Get-RooIndustriesStutterShaderCacheItems $resolvedRoot)
    $gates = @(
        (New-RooIndustriesStutterGate 'confirm-apply' 'Confirmed apply requested' $true ([bool]$ConfirmApply) 'Shader cache fixture deletion remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooIndustriesStutterGate 'disposable-fixture-flag' 'Disposable fixture apply allowed' $true ([bool]$AllowDisposableFixtureApply) 'Shader cache deletion is allowed only for disposable temp fixtures.' $null),
        (New-RooIndustriesStutterGate 'fixture-root-temp' 'Shader cache root is inside temp' $true $rootIsTemp 'Fixture shader cache root must be under the OS temp path.' ([pscustomobject]@{ shaderCacheRoot = $resolvedRoot })),
        (New-RooIndustriesStutterGate 'fixture-items-present' 'Shader cache fixture items present' $true ($items.Count -gt 0) 'Fixture apply needs at least one file target.' ([pscustomobject]@{ itemCount = $items.Count })),
        (New-RooIndustriesStutterGate 'backup-root-outside-cache' 'Backup folder is outside the shader cache' $true (-not (Test-RooIndustriesStutterPathInsideRoot $resolvedBackupRoot $resolvedRoot)) 'Backups must be stored outside the shader cache folder so a later cleanup cannot pick them up.' ([pscustomobject]@{ backupRoot = $resolvedBackupRoot }))
    )
    $blockingGateCount = @($gates | Where-Object { $_.blocking }).Count
    $canApply = ($blockingGateCount -eq 0)

    if ($canApply) {
        Ensure-RooIndustriesDirectory $resolvedBackupRoot
        foreach ($item in $items) {
            $source = [System.IO.Path]::GetFullPath([string](Get-RooIndustriesPropertyValue $item 'path' ''))
            if (-not (Test-RooIndustriesStutterPathInsideRoot $source $resolvedRoot)) { throw "Shader cache target escaped fixture root: $source" }
            $relative = [string](Get-RooIndustriesPropertyValue $item 'relativePath' '')
            $destination = Join-Path $resolvedBackupRoot $relative
            Ensure-RooIndustriesDirectory (Split-Path $destination -Parent)
            [System.IO.File]::Copy($source, $destination, $false)
            $backupRecords.Add([pscustomobject]@{
                itemId = [string](Get-RooIndustriesPropertyValue $item 'itemId' '')
                source = $source
                relativePath = $relative
                backupPath = $destination
                bytes = [uint64](Get-RooIndustriesPropertyValue $item 'bytes' 0)
            }) | Out-Null
        }
        $manifestPath = Join-Path $resolvedBackupRoot 'shader-cache-rollback-manifest.json'
        $rollbackManifest = [pscustomobject]@{
            manifestId = New-RooIndustriesStutterRollbackManifestId 'shader-cache-cleanup'
            schemaVersion = 1
            productName = $script:RooIndustriesStutterProductName
            actionId = 'performance.stutterOptimization.restoreShaderCacheFixture'
            optimizationId = 'shader-cache-cleanup'
            fixtureRoot = $resolvedRoot
            backupRoot = $resolvedBackupRoot
            createdAtUtc = Get-RooIndustriesUtcStamp
            realSystemRollback = $false
            restoreSupported = $true
            fileBackups = @($backupRecords.ToArray())
        }
        ($rollbackManifest | ConvertTo-Json -Depth 24) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $rollbackManifestPath = $manifestPath
        foreach ($record in @($backupRecords.ToArray())) {
            Remove-Item -LiteralPath $record.source -Force
            $deletedRecords.Add([pscustomobject]@{
                itemId = $record.itemId
                path = $record.source
                deleted = $true
            }) | Out-Null
        }
        foreach ($dir in @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
            if ($dir.FullName -eq $resolvedBackupRoot -or $dir.FullName.StartsWith($resolvedBackupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (@(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $dir.FullName -Force
            }
        }
    }

    $result = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.apply'
        schemaVersion = 1
        productName = $script:RooIndustriesStutterProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        optimizationId = 'shader-cache-cleanup'
        dryRun = (-not $canApply)
        status = if ($canApply) { 'success' } elseif ($ConfirmApply) { 'blocked' } else { 'preview' }
        executionMode = if ($canApply) { 'disposable-fixture-apply' } else { 'preview-or-blocked' }
        shaderCacheRoot = $resolvedRoot
        gates = @($gates)
        changedItems = @($deletedRecords.ToArray())
        rollback = [pscustomobject]@{
            rollbackManifestPath = $rollbackManifestPath
            backupRoot = $resolvedBackupRoot
            backupRecords = @($backupRecords.ToArray())
            restoreSupported = $true
        }
        summary = [pscustomobject]@{
            itemCount = $items.Count
            backupCount = $backupRecords.Count
            deletedCount = @($deletedRecords.ToArray() | Where-Object { $_.deleted }).Count
            blockingGateCount = $blockingGateCount
            willChangeSystem = $false
            willDeleteFixtureFiles = $canApply
            willDeleteRealFiles = $false
            willLaunchUtilities = $false
            willWriteState = $false
        }
        warnings = @((New-RooIndustriesStutterIssue 'SHADER_CACHE_FIXTURE_ONLY' 'Shader cache apply is limited to disposable temp fixtures and does not touch real cache paths.' 'warning' 'shader-cache-cleanup' $true 'Use this only for backend validation proof.' $null))
        errors = @()
        logs = @((New-RooIndustriesLog 'Shader cache fixture apply evaluated without utility launches.'))
    }
    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.apply'
        schemaVersion = 1
        productName = $script:RooIndustriesStutterProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        optimizationId = $OptimizationId
        dryRun = ($deletedRecords.Count -eq 0)
        status = 'failed'
        executionMode = 'blocked'
        changedItems = @($deletedRecords.ToArray())
        rollback = if ($rollbackManifestPath -and (Test-Path -LiteralPath $rollbackManifestPath -PathType Leaf)) { [pscustomobject]@{ rollbackManifestPath = $rollbackManifestPath; backupRoot = $resolvedBackupRoot; backupRecords = @($backupRecords.ToArray()); restoreSupported = $true } } else { $null }
        summary = [pscustomobject]@{ willChangeSystem = $false; willLaunchUtilities = $false; deletedCount = $deletedRecords.Count; backupCount = $backupRecords.Count }
        warnings = @()
        errors = @((New-RooIndustriesStutterIssue 'STUTTER_APPLY_FAILED' $_.Exception.Message 'error' $OptimizationId $true 'Check fixture paths and retry.' $null))
        logs = @((New-RooIndustriesLog 'Stutter optimization apply failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
