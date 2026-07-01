param(
    [string]$RollbackManifestPath,
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowDisposableFixtureApply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')

function Test-CleanupRestorePathInsideRoot {
    param(
        [string]$Path,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootWithSlash = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    return ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-CleanupRestorePathInsideTemp {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Path).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function New-CleanupRestoreGate {
    param(
        [string]$GateId,
        [string]$Name,
        [bool]$Required,
        [bool]$Satisfied,
        [string]$Reason,
        [object]$Evidence = $null
    )
    return [pscustomobject]@{
        gateId = $GateId
        name = $Name
        required = $Required
        satisfied = $Satisfied
        blocking = ($Required -and -not $Satisfied)
        reason = $Reason
        evidence = $Evidence
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($RollbackManifestPath)) { throw 'RollbackManifestPath is required.' }
    $manifestPath = Resolve-RooUninstallPath $RollbackManifestPath $RollbackManifestPath
    $manifest = Read-RooUninstallJsonFile $manifestPath
    $fixtureRoot = [string](Get-RooUninstallPropertyValue $manifest 'fixtureRoot' '')
    $fixtureRootInTemp = Test-CleanupRestorePathInsideTemp $fixtureRoot
    $backups = @(Get-RooUninstallPropertyArray $manifest 'fileBackups')
    $escapedTargets = @($backups | Where-Object { -not (Test-CleanupRestorePathInsideRoot ([string](Get-RooUninstallPropertyValue $_ 'source' '')) $fixtureRoot) })
    $gates = @(
        (New-CleanupRestoreGate 'confirm-restore' 'Confirmed restore requested' $true ([bool]$ConfirmApply) 'Restore remains preview-only until -ConfirmApply is supplied.' $null),
        (New-CleanupRestoreGate 'disposable-fixture-flag' 'Disposable fixture restore allowed' $true ([bool]$AllowDisposableFixtureApply) 'Cleanup restore is allowed only for disposable temp fixtures.' $null),
        (New-CleanupRestoreGate 'fixture-root-temp' 'Fixture root is inside temp' $true $fixtureRootInTemp 'Fixture restore root must be under the OS temp path.' ([pscustomobject]@{ fixtureRoot = $fixtureRoot })),
        (New-CleanupRestoreGate 'restore-targets-inside-fixture' 'Restore targets stay inside fixture root' $true ($escapedTargets.Count -eq 0) 'Every restore target must resolve inside the disposable fixture root.' ([pscustomobject]@{ escapedTargetCount = $escapedTargets.Count }))
    )
    $blockingGateCount = @($gates | Where-Object { $_.blocking }).Count
    $canRestore = ($blockingGateCount -eq 0)
    $restored = New-Object System.Collections.Generic.List[object]

    if ($canRestore) {
        foreach ($backup in $backups) {
            $source = [string](Get-RooUninstallPropertyValue $backup 'backupPath' '')
            $target = [string](Get-RooUninstallPropertyValue $backup 'source' '')
            $type = [string](Get-RooUninstallPropertyValue $backup 'type' '')
            if (-not (Test-CleanupRestorePathInsideRoot $target $fixtureRoot)) { throw "Restore target escaped fixture root: $target" }
            Ensure-RooUninstallDirectory (Split-Path $target -Parent)
            if ($type -eq 'folder') {
                Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
            } else {
                Copy-Item -LiteralPath $source -Destination $target -Force
            }
            $restored.Add([pscustomobject]@{
                itemId = [string](Get-RooUninstallPropertyValue $backup 'itemId' '')
                type = $type
                backupPath = $source
                target = $target
                restored = $true
            }) | Out-Null
        }
    }

    $result = [pscustomobject]@{
        actionId = 'apps.restoreUninstallCleanupExecution'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        dryRun = (-not $canRestore)
        status = if ($canRestore) { 'success' } elseif ($ConfirmApply) { 'blocked' } else { 'preview' }
        executionMode = if ($canRestore) { 'disposable-fixture-restore' } else { 'preview-or-blocked' }
        rollbackManifestPath = $manifestPath
        gates = @($gates)
        restoredItems = @($restored.ToArray())
        summary = [pscustomobject]@{
            restoredCount = $restored.Count
            blockingGateCount = $blockingGateCount
            willRestoreFixtureFiles = $canRestore
            willChangeRealSystem = $false
            willWriteState = $false
        }
        warnings = @((New-RooUninstallIssue 'CLEANUP_RESTORE_FIXTURE_ONLY' 'Cleanup restore is limited to disposable temp fixtures.' 'warning' 'apps.restoreUninstallCleanupExecution' (Get-RooUninstallPropertyValue $manifest 'sourceManifestId' $null) $true 'Use this restore path to validate rollback manifests for copied files and folders.' $null))
        errors = @()
        logs = @((New-RooUninstallLog 'Uninstall cleanup fixture restore evaluated.'))
    }
    Write-RooUninstallJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'apps.restoreUninstallCleanupExecution'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        dryRun = $true
        status = 'failed'
        executionMode = 'blocked'
        restoredItems = @()
        summary = [pscustomobject]@{ restoredCount = 0; willChangeRealSystem = $false; nextEngineeringStep = 'Check rollback manifest, fixture root, backup paths, and restore gates.' }
        warnings = @()
        errors = @((New-RooUninstallIssue 'CLEANUP_RESTORE_FAILED' $_.Exception.Message 'error' 'apps.restoreUninstallCleanupExecution' $null $true 'Check rollback manifest, fixture root, backup paths, and restore gates.' $null))
        logs = @((New-RooUninstallLog 'Uninstall cleanup fixture restore failed.' 'error'))
    }
    Write-RooUninstallJsonOutput $errorResult $OutputPath
    exit 1
}
