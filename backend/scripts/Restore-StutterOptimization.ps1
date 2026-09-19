param(
    [string]$RollbackManifestPath,
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowDisposableFixtureApply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StutterOptimization.Common.ps1')

try {
    if ([string]::IsNullOrWhiteSpace($RollbackManifestPath)) { throw 'RollbackManifestPath is required.' }
    $manifestPath = Resolve-RooIndustriesPath $RollbackManifestPath $RollbackManifestPath
    $manifest = Read-RooIndustriesJsonFile $manifestPath
    $fixtureRoot = [string](Get-RooIndustriesPropertyValue $manifest 'fixtureRoot' '')
    $rootIsTemp = ((-not [string]::IsNullOrWhiteSpace($fixtureRoot)) -and (Test-RooIndustriesStutterPathInsideTemp $fixtureRoot))
    $gates = @(
        (New-RooIndustriesStutterGate 'confirm-restore' 'Confirmed restore requested' $true ([bool]$ConfirmApply) 'Restore remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooIndustriesStutterGate 'disposable-fixture-flag' 'Disposable fixture restore allowed' $true ([bool]$AllowDisposableFixtureApply) 'Restore is allowed only for disposable temp fixtures.' $null),
        (New-RooIndustriesStutterGate 'fixture-root-temp' 'Fixture root is inside temp' $true $rootIsTemp 'Fixture restore root must be under the OS temp path.' ([pscustomobject]@{ fixtureRoot = $fixtureRoot }))
    )
    $blockingGateCount = @($gates | Where-Object { $_.blocking }).Count
    $canRestore = ($blockingGateCount -eq 0)
    $restored = New-Object System.Collections.Generic.List[object]
    if ($canRestore) {
        foreach ($backup in @(Get-RooIndustriesPropertyArray $manifest 'fileBackups')) {
            $source = [string](Get-RooIndustriesPropertyValue $backup 'backupPath' '')
            $target = [string](Get-RooIndustriesPropertyValue $backup 'source' '')
            if (-not (Test-RooIndustriesStutterPathInsideRoot $target $fixtureRoot)) { throw "Restore target escaped fixture root: $target" }
            Ensure-RooIndustriesDirectory (Split-Path $target -Parent)
            Copy-Item -LiteralPath $source -Destination $target -Force
            $restored.Add([pscustomobject]@{
                itemId = [string](Get-RooIndustriesPropertyValue $backup 'itemId' '')
                source = $source
                target = $target
                restored = $true
            }) | Out-Null
        }
    }
    $result = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.restore'
        schemaVersion = 1
        productName = $script:RooIndustriesStutterProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        optimizationId = Get-RooIndustriesPropertyValue $manifest 'optimizationId' 'shader-cache-cleanup'
        dryRun = (-not $canRestore)
        status = if ($canRestore) { 'success' } elseif ($ConfirmApply) { 'blocked' } else { 'preview' }
        executionMode = if ($canRestore) { 'disposable-fixture-restore' } else { 'preview-or-blocked' }
        rollbackManifestPath = $manifestPath
        gates = @($gates)
        restoredItems = @($restored.ToArray())
        summary = [pscustomobject]@{
            restoredCount = $restored.Count
            blockingGateCount = $blockingGateCount
            willChangeSystem = $false
            willRestoreFixtureFiles = $canRestore
            willLaunchUtilities = $false
            willWriteState = $false
        }
        warnings = @((New-RooIndustriesStutterIssue 'STUTTER_RESTORE_FIXTURE_ONLY' 'Shader cache restore is limited to disposable temp fixtures.' 'warning' 'shader-cache-cleanup' $true 'Use this only for validation rollback proof.' $null))
        errors = @()
        logs = @((New-RooIndustriesLog 'Shader cache fixture restore evaluated without utility launches.'))
    }
    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.restore'
        schemaVersion = 1
        productName = $script:RooIndustriesStutterProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        dryRun = $true
        status = 'failed'
        executionMode = 'blocked'
        restoredItems = @()
        summary = [pscustomobject]@{ willChangeSystem = $false; willLaunchUtilities = $false; restoredCount = 0 }
        warnings = @()
        errors = @((New-RooIndustriesStutterIssue 'STUTTER_RESTORE_FAILED' $_.Exception.Message 'error' 'shader-cache-cleanup' $true 'Check rollback manifest and fixture root.' $null))
        logs = @((New-RooIndustriesLog 'Shader cache fixture restore failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}

