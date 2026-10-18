param(
    [string]$RollbackManifestPath,
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowDisposableFixtureApply,
    [switch]$AllowRealSystemExecution,
    [switch]$UserApproved
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

$restored = New-Object System.Collections.Generic.List[object]
$restoreStarted = $false
$lock = $null
try {
    if ([string]::IsNullOrWhiteSpace($RollbackManifestPath)) { throw 'RollbackManifestPath is required.' }
    $manifestPath = Resolve-RooIndustriesUninstallPath $RollbackManifestPath $RollbackManifestPath
    $manifest = Read-RooIndustriesUninstallJsonFile $manifestPath
    $fixtureRoot = [string](Get-RooIndustriesUninstallPropertyValue $manifest 'fixtureRoot' '')
    $realSystemRollback = [bool](Get-RooIndustriesUninstallPropertyValue $manifest 'realSystemRollback' $false)
    $fixtureRootInTemp = Test-CleanupRestorePathInsideTemp $fixtureRoot
    $backups = @(Get-RooIndustriesUninstallPropertyArray $manifest 'fileBackups' | Where-Object { (Get-RooIndustriesUninstallPropertyValue $_ 'copied' $true) -eq $true })
    $escapedTargets = @($backups | Where-Object { -not (Test-CleanupRestorePathInsideRoot ([string](Get-RooIndustriesUninstallPropertyValue $_ 'source' '')) $fixtureRoot) })
    $missingBackups = @($backups | Where-Object { -not (Test-Path -LiteralPath ([string](Get-RooIndustriesUninstallPropertyValue $_ 'backupPath' ''))) })
    $conflicts = @($backups | Where-Object { Test-Path -LiteralPath ([string]$_.backupPath) } | ForEach-Object {
        Get-RooIndustriesCleanupRestoreConflicts ([string]$_.backupPath) ([string]$_.source) ([string]$_.type)
    })
    if ($realSystemRollback) {
        $backupRoot = [string](Get-RooIndustriesUninstallPropertyValue $manifest 'backupRoot' '')
        $allowlist = @(Get-RooIndustriesUninstallPropertyArray $manifest 'exactTargetAllowlist')
        $invalidBackups = @($backups | Where-Object {
            $target = [System.IO.Path]::GetFullPath([string]$_.source)
            $allowed = @($allowlist | Where-Object { [System.IO.Path]::GetFullPath([string]$_).Equals($target, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            (-not $allowed) -or (-not (Test-RooIndustriesCleanupPathWithin ([string]$_.backupPath) $backupRoot)) -or
                (Test-RooIndustriesCleanupPathWithin $backupRoot $target) -or (Test-RooIndustriesCleanupReparsePath $target) -or
                (Test-RooIndustriesCleanupReparsePath ([string]$_.backupPath)) -or ([string]$_.type -notin @('file','folder'))
        })
        $gates = @(
            (New-CleanupRestoreGate 'confirm-restore' 'Confirmed restore requested' $true ([bool]$ConfirmApply) 'Restore remains preview-only until -ConfirmApply is supplied.' $null),
            (New-CleanupRestoreGate 'real-system-restore-flag' 'Real-system restore allowed' $true ([bool]$AllowRealSystemExecution) 'Restoring real cleanup targets requires the real-system restore flag.' $null),
            (New-CleanupRestoreGate 'explicit-user-approval' 'Explicit restore approval captured' $true ([bool]$UserApproved) 'Restoring real cleanup targets requires explicit user approval.' $null),
            (New-CleanupRestoreGate 'written-after-protection' 'Backup was made after the data folder was protected' $true (Test-RooIndustriesWrittenAfterProtection $manifestPath) ("This backup was made by an earlier version of the app, before its data folder was protected, so it can't be restored automatically. Its files are kept at "+(Split-Path $manifestPath -Parent)+'.') $null),
            (New-CleanupRestoreGate 'approved-restore-paths' 'Restore uses approved targets and backup storage' $true ($invalidBackups.Count -eq 0) 'Targets must match the saved allowlist; backups must stay inside the saved root without reparse paths.' $null),
            (New-CleanupRestoreGate 'backup-files-present' 'Backup files are present' $true ($missingBackups.Count -eq 0) 'Every backup referenced by the rollback manifest must exist.' ([pscustomobject]@{ missingBackupCount = $missingBackups.Count })),
            (New-CleanupRestoreGate 'restore-destinations-unchanged' 'Restore targets are unchanged since cleanup' $true ($conflicts.Count -eq 0) 'Some cleanup targets changed after cleanup, so nothing was restored. Move or rename the changed items listed here, then restore again.' ([pscustomobject]@{ conflictCount = $conflicts.Count; conflicts = @($conflicts | Select-Object -First 20) }))
        )
    } else {
        $gates = @(
            (New-CleanupRestoreGate 'confirm-restore' 'Confirmed restore requested' $true ([bool]$ConfirmApply) 'Restore remains preview-only until -ConfirmApply is supplied.' $null),
            (New-CleanupRestoreGate 'disposable-fixture-flag' 'Disposable fixture restore allowed' $true ([bool]$AllowDisposableFixtureApply) 'Cleanup restore is allowed only for disposable temp fixtures.' $null),
            (New-CleanupRestoreGate 'fixture-root-temp' 'Fixture root is inside temp' $true $fixtureRootInTemp 'Fixture restore root must be under the OS temp path.' ([pscustomobject]@{ fixtureRoot = $fixtureRoot })),
            (New-CleanupRestoreGate 'restore-targets-inside-fixture' 'Restore targets stay inside fixture root' $true ($escapedTargets.Count -eq 0) 'Every restore target must resolve inside the disposable fixture root.' ([pscustomobject]@{ escapedTargetCount = $escapedTargets.Count })),
            (New-CleanupRestoreGate 'backup-files-present' 'Backup files are present' $true ($missingBackups.Count -eq 0) 'Every backup referenced by the rollback manifest must exist.' ([pscustomobject]@{ missingBackupCount = $missingBackups.Count })),
            (New-CleanupRestoreGate 'restore-destinations-unchanged' 'Restore targets are unchanged since cleanup' $true ($conflicts.Count -eq 0) 'Some cleanup targets changed after cleanup, so nothing was restored. Move or rename the changed items listed here, then restore again.' ([pscustomobject]@{ conflictCount = $conflicts.Count; conflicts = @($conflicts | Select-Object -First 20) }))
        )
    }
    $blockingGateCount = @($gates | Where-Object { $_.blocking }).Count
    $canRestore = ($blockingGateCount -eq 0)
    if ($canRestore) {
        $lock = [System.IO.FileStream]::new($manifestPath + '.lock', [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::DeleteOnClose)
        foreach ($backup in $backups) {
            $source = [string](Get-RooIndustriesUninstallPropertyValue $backup 'backupPath' '')
            $target = [string](Get-RooIndustriesUninstallPropertyValue $backup 'source' '')
            $type = [string](Get-RooIndustriesUninstallPropertyValue $backup 'type' '')
            if ((-not $realSystemRollback) -and -not (Test-CleanupRestorePathInsideRoot $target $fixtureRoot)) { throw "Restore target escaped fixture root: $target" }
            if ((Test-RooIndustriesCleanupReparsePath $target) -or (Test-RooIndustriesCleanupReparsePath $source)) { throw 'Restore encountered a reparse path.' }
            $restoreStarted = $true
            Ensure-RooIndustriesUninstallDirectory (Split-Path $target -Parent)
            if ($type -eq 'folder') {
                $alreadyPresent = Copy-RooIndustriesCleanupRestoreTree $source $target
            } else {
                $alreadyPresent = Test-Path -LiteralPath $target
                if ($alreadyPresent) {
                    if (-not (Test-RooIndustriesCleanupSameFile $source $target)) { throw "Restore target changed after cleanup: $target" }
                } else {
                    [IO.File]::Copy($source, $target, $false)
                }
            }
            $restored.Add([pscustomobject]@{
                itemId = [string](Get-RooIndustriesUninstallPropertyValue $backup 'itemId' '')
                type = $type
                backupPath = $source
                target = $target
                restored = $true
                alreadyPresent = $alreadyPresent
            }) | Out-Null
        }
    }

    $result = [pscustomobject]@{
        actionId = 'apps.restoreUninstallCleanupExecution'
        schemaVersion = 1
        productName = $script:RooIndustriesUninstallProductName
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = (-not $canRestore)
        status = if ($canRestore) { 'success' } elseif ($ConfirmApply) { 'blocked' } else { 'preview' }
        executionMode = if ($canRestore -and $realSystemRollback) { 'real-system-restore' } elseif ($canRestore) { 'disposable-fixture-restore' } else { 'preview-or-blocked' }
        rollbackManifestPath = $manifestPath
        gates = @($gates)
        restoredItems = @($restored.ToArray())
        summary = [pscustomobject]@{
            restoredCount = $restored.Count
            blockingGateCount = $blockingGateCount
            willRestoreFixtureFiles = $canRestore
            willChangeRealSystem = ($canRestore -and $realSystemRollback)
            willWriteState = $false
        }
        warnings = @((New-RooIndustriesUninstallIssue 'CLEANUP_RESTORE_CONTROLLED' 'Cleanup restore is gated by rollback manifest, backup presence, and approval.' 'warning' 'apps.restoreUninstallCleanupExecution' (Get-RooIndustriesUninstallPropertyValue $manifest 'sourceManifestId' $null) (-not $canRestore) 'Use restore only for reviewed rollback manifests.' $null))
        errors = @()
        logs = @((New-RooIndustriesUninstallLog 'Uninstall cleanup fixture restore evaluated.'))
    }
    Write-RooIndustriesUninstallJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'apps.restoreUninstallCleanupExecution'
        schemaVersion = 1
        productName = $script:RooIndustriesUninstallProductName
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = (-not $restoreStarted)
        status = if ($restoreStarted) { 'partial' } else { 'failed' }
        executionMode = 'blocked'
        restoredItems = @($restored.ToArray())
        rollbackManifestPath = $RollbackManifestPath
        summary = [pscustomobject]@{ restoredCount = $restored.Count; willChangeRealSystem = ($restoreStarted -and $realSystemRollback); nextEngineeringStep = 'Check rollback manifest, fixture root, backup paths, and restore gates.' }
        warnings = @()
        errors = @((New-RooIndustriesUninstallIssue 'CLEANUP_RESTORE_FAILED' $_.Exception.Message 'error' 'apps.restoreUninstallCleanupExecution' $null $true 'Check rollback manifest, fixture root, backup paths, and restore gates.' $null))
        logs = @((New-RooIndustriesUninstallLog 'Uninstall cleanup fixture restore failed.' 'error'))
    }
    Write-RooIndustriesUninstallJsonOutput $errorResult $OutputPath
    exit 1
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
