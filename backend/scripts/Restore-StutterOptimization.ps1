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
    $manifestPath = Resolve-RooPath $RollbackManifestPath $RollbackManifestPath
    $manifest = Read-RooJsonFile $manifestPath
    $fixtureRoot = [string](Get-RooPropertyValue $manifest 'fixtureRoot' '')
    $rootIsTemp = ((-not [string]::IsNullOrWhiteSpace($fixtureRoot)) -and (Test-RooStutterPathInsideTemp $fixtureRoot))
    $gates = @(
        (New-RooStutterGate 'confirm-restore' 'Confirmed restore requested' $true ([bool]$ConfirmApply) 'Restore remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooStutterGate 'disposable-fixture-flag' 'Disposable fixture restore allowed' $true ([bool]$AllowDisposableFixtureApply) 'Restore is allowed only for disposable temp fixtures.' $null),
        (New-RooStutterGate 'fixture-root-temp' 'Fixture root is inside temp' $true $rootIsTemp 'Fixture restore root must be under the OS temp path.' ([pscustomobject]@{ fixtureRoot = $fixtureRoot }))
    )
    $blockingGateCount = @($gates | Where-Object { $_.blocking }).Count
    $canRestore = ($blockingGateCount -eq 0)
    $restored = New-Object System.Collections.Generic.List[object]
    if ($canRestore) {
        foreach ($backup in @(Get-RooPropertyArray $manifest 'fileBackups')) {
            $source = [string](Get-RooPropertyValue $backup 'backupPath' '')
            $target = [string](Get-RooPropertyValue $backup 'source' '')
            if (-not (Test-RooStutterPathInsideRoot $target $fixtureRoot)) { throw "Restore target escaped fixture root: $target" }
            Ensure-RooDirectory (Split-Path $target -Parent)
            Copy-Item -LiteralPath $source -Destination $target -Force
            $restored.Add([pscustomobject]@{
                itemId = [string](Get-RooPropertyValue $backup 'itemId' '')
                source = $source
                target = $target
                restored = $true
            }) | Out-Null
        }
    }
    $result = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.restore'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
        optimizationId = Get-RooPropertyValue $manifest 'optimizationId' 'shader-cache-cleanup'
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
        warnings = @((New-RooStutterIssue 'STUTTER_RESTORE_FIXTURE_ONLY' 'Shader cache restore is limited to disposable temp fixtures.' 'warning' 'shader-cache-cleanup' $true 'Use this only for validation rollback proof.' $null))
        errors = @()
        logs = @((New-RooLog 'Shader cache fixture restore evaluated without utility launches.'))
    }
    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.restore'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
        dryRun = $true
        status = 'failed'
        executionMode = 'blocked'
        restoredItems = @()
        summary = [pscustomobject]@{ willChangeSystem = $false; willLaunchUtilities = $false; restoredCount = 0 }
        warnings = @()
        errors = @((New-RooStutterIssue 'STUTTER_RESTORE_FAILED' $_.Exception.Message 'error' 'shader-cache-cleanup' $true 'Check rollback manifest and fixture root.' $null))
        logs = @((New-RooLog 'Shader cache fixture restore failed.' 'error'))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}

