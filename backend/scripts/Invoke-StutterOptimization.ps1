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
        if (@(Get-RooArray $ServiceName).Count -gt 0) { $realParams['ServiceName'] = @(Get-RooArray $ServiceName) }
        if (-not [string]::IsNullOrWhiteSpace($ServiceShimPath)) { $realParams['ServiceShimPath'] = $ServiceShimPath }
        if ($ConfirmApply) { $realParams['ConfirmApply'] = $true }
        if ($AllowRealSystemExecution) { $realParams['AllowRealSystemExecution'] = $true }
        if ($UserApproved) { $realParams['UserApproved'] = $true }
        & (Join-Path $PSScriptRoot 'Invoke-StutterOptimizationRealExecutor.ps1') @realParams
        return
    }

    $resolvedRoot = if ([string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { $null } else { [System.IO.Path]::GetFullPath($ShaderCacheRoot) }
    $resolvedBackupRoot = if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        if ([string]::IsNullOrWhiteSpace($resolvedRoot)) { $null } else { Join-Path $resolvedRoot '_roo-shader-cache-backup' }
    } else {
        [System.IO.Path]::GetFullPath($BackupRoot)
    }
    $rootIsTemp = ((-not [string]::IsNullOrWhiteSpace($resolvedRoot)) -and (Test-RooStutterPathInsideTemp $resolvedRoot))
    $items = @(Get-RooStutterShaderCacheItems $resolvedRoot)
    $gates = @(
        (New-RooStutterGate 'confirm-apply' 'Confirmed apply requested' $true ([bool]$ConfirmApply) 'Shader cache fixture deletion remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooStutterGate 'disposable-fixture-flag' 'Disposable fixture apply allowed' $true ([bool]$AllowDisposableFixtureApply) 'Shader cache deletion is allowed only for disposable temp fixtures.' $null),
        (New-RooStutterGate 'fixture-root-temp' 'Shader cache root is inside temp' $true $rootIsTemp 'Fixture shader cache root must be under the OS temp path.' ([pscustomobject]@{ shaderCacheRoot = $resolvedRoot })),
        (New-RooStutterGate 'fixture-items-present' 'Shader cache fixture items present' $true ($items.Count -gt 0) 'Fixture apply needs at least one file target.' ([pscustomobject]@{ itemCount = $items.Count }))
    )
    $blockingGateCount = @($gates | Where-Object { $_.blocking }).Count
    $canApply = ($blockingGateCount -eq 0)
    $backupRecords = New-Object System.Collections.Generic.List[object]
    $deletedRecords = New-Object System.Collections.Generic.List[object]
    $rollbackManifestPath = $null

    if ($canApply) {
        Ensure-RooDirectory $resolvedBackupRoot
        foreach ($item in $items) {
            $source = [System.IO.Path]::GetFullPath([string](Get-RooPropertyValue $item 'path' ''))
            if (-not (Test-RooStutterPathInsideRoot $source $resolvedRoot)) { throw "Shader cache target escaped fixture root: $source" }
            $relative = [string](Get-RooPropertyValue $item 'relativePath' '')
            $destination = Join-Path $resolvedBackupRoot $relative
            Ensure-RooDirectory (Split-Path $destination -Parent)
            Copy-Item -LiteralPath $source -Destination $destination -Force
            Remove-Item -LiteralPath $source -Force
            $backupRecords.Add([pscustomobject]@{
                itemId = [string](Get-RooPropertyValue $item 'itemId' '')
                source = $source
                relativePath = $relative
                backupPath = $destination
                bytes = [uint64](Get-RooPropertyValue $item 'bytes' 0)
            }) | Out-Null
            $deletedRecords.Add([pscustomobject]@{
                itemId = [string](Get-RooPropertyValue $item 'itemId' '')
                path = $source
                deleted = $true
            }) | Out-Null
        }
        foreach ($dir in @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
            if ($dir.FullName -eq $resolvedBackupRoot -or $dir.FullName.StartsWith($resolvedBackupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (@(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $dir.FullName -Force
            }
        }
        $rollbackManifestPath = Join-Path $resolvedBackupRoot 'shader-cache-rollback-manifest.json'
        $rollbackManifest = [pscustomobject]@{
            manifestId = New-RooStutterRollbackManifestId 'shader-cache-cleanup'
            schemaVersion = 1
            productName = $script:RooStutterProductName
            actionId = 'performance.stutterOptimization.restoreShaderCacheFixture'
            optimizationId = 'shader-cache-cleanup'
            fixtureRoot = $resolvedRoot
            backupRoot = $resolvedBackupRoot
            createdAtUtc = Get-RooUtcStamp
            realSystemRollback = $false
            restoreSupported = $true
            fileBackups = @($backupRecords.ToArray())
        }
        ($rollbackManifest | ConvertTo-Json -Depth 24) | Set-Content -LiteralPath $rollbackManifestPath -Encoding UTF8
    }

    $result = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.apply'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
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
        warnings = @((New-RooStutterIssue 'SHADER_CACHE_FIXTURE_ONLY' 'Shader cache apply is limited to disposable temp fixtures and does not touch real cache paths.' 'warning' 'shader-cache-cleanup' $true 'Use this only for backend validation proof.' $null))
        errors = @()
        logs = @((New-RooLog 'Shader cache fixture apply evaluated without utility launches.'))
    }
    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.apply'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
        optimizationId = $OptimizationId
        dryRun = $true
        status = 'failed'
        executionMode = 'blocked'
        changedItems = @()
        rollback = $null
        summary = [pscustomobject]@{ willChangeSystem = $false; willLaunchUtilities = $false; deletedCount = 0; backupCount = 0 }
        warnings = @()
        errors = @((New-RooStutterIssue 'STUTTER_APPLY_FAILED' $_.Exception.Message 'error' $OptimizationId $true 'Check fixture paths and retry.' $null))
        logs = @((New-RooLog 'Stutter optimization apply failed.' 'error'))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
