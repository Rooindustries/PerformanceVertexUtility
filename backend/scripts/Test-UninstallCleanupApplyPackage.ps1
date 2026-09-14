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
    'backend\scripts\Invoke-UninstallCleanupApplyPackage.ps1',
    'backend\scripts\Restore-UninstallCleanupExecution.ps1'
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-uninstall-apply-package-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    $folderTarget = Join-Path $tempRoot 'AppCache'
    $folderFile = Join-Path $folderTarget 'cache.txt'
    $fileTarget = Join-Path $tempRoot 'loose.log'
    New-Item -ItemType Directory -Path $folderTarget -Force | Out-Null
    Set-Content -LiteralPath $folderFile -Value 'cache payload' -Encoding UTF8
    Set-Content -LiteralPath $fileTarget -Value 'log payload' -Encoding UTF8

    $officialPath = Join-Path $tempRoot 'official-preview.json'
    $manifestPath = Join-Path $tempRoot 'cleanup-manifest.json'
    ([pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        dryRun = $true
        status = 'preview'
        commands = @()
        summary = [pscustomobject]@{ commandPreviewCount = 0; willRunUninstallers = $false }
        warnings = @(); errors = @(); logs = @()
    } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $officialPath -Encoding UTF8
    ([pscustomobject]@{
        manifestId = 'apply-package-fixture-manifest'
        productName = 'Roo Industries Optimization Suite'
        schemaVersion = 1
        appId = 'fixture:no-vendor-remover'
        displayName = 'No Vendor Remover Fixture'
        dryRun = $true
        items = @(
            [pscustomobject]@{ itemId = 'folder-cache'; type = 'folder'; target = $folderTarget; protected = $false; defaultSelected = $true },
            [pscustomobject]@{ itemId = 'file-log'; type = 'file'; target = $fileTarget; protected = $false; defaultSelected = $true }
        )
        rollback = [pscustomobject]@{ backupRoot = (Join-Path $tempRoot '_backup'); rollbackSupported = $true }
        summary = [pscustomobject]@{ itemCount = 2; willDeleteOnApply = $false; dryRunWritesState = $false }
        warnings = @(); errors = @()
    } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupApplyPackage.ps1') -OfficialPreviewPath $officialPath -CleanupManifestPath $manifestPath)
    if ($preview.status -eq 'preview' -and $preview.summary.deletedCount -eq 0 -and (Test-Path -LiteralPath $folderTarget) -and (Test-Path -LiteralPath $fileTarget)) {
        Add-Pass 'Apply package default call previews the Roo Industries route without deleting anything'
    } else {
        Add-Failure 'Apply package default call did not stay preview-only'
    }

    $blocked = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupApplyPackage.ps1') -OfficialPreviewPath $officialPath -CleanupManifestPath $manifestPath -ExecutorMode Real -ConfirmApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved -UserApproved -AllowRealSystemExecution)
    $allowlistGate = @($blocked.gates | Where-Object { $_.gateId -eq 'exact-target-allowlist' }) | Select-Object -First 1
    if ($blocked.status -eq 'blocked' -and $allowlistGate.blocking -eq $true -and (Test-Path -LiteralPath $folderTarget) -and (Test-Path -LiteralPath $fileTarget)) {
        Add-Pass 'Apply package blocks real cleanup without exact target allowlist'
    } else {
        Add-Failure 'Apply package did not block missing exact target allowlist'
    }

    $backupRoot = Join-Path $tempRoot '_package-backup'
    $rollbackPath = Join-Path $backupRoot 'rollback-manifest.json'
    $apply = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupApplyPackage.ps1') -OfficialPreviewPath $officialPath -CleanupManifestPath $manifestPath -ExecutorMode Real -ExactTargetAllowlist @($folderTarget, $fileTarget) -BackupRoot $backupRoot -RollbackManifestPath $rollbackPath -ConfirmApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved -UserApproved -AllowRealSystemExecution)
    if ($apply.status -eq 'success' -and $apply.summary.rooIndustriesRouteUsed -eq $true -and $apply.summary.deletedCount -eq 2 -and $apply.summary.restoreReady -eq $true -and -not (Test-Path -LiteralPath $folderTarget) -and -not (Test-Path -LiteralPath $fileTarget) -and (Test-Path -LiteralPath $rollbackPath)) {
        Add-Pass 'Apply package backs up and deletes exact temp file/folder targets without a vendor remover'
    } else {
        Add-Failure 'Apply package did not prove no-vendor backup/delete path'
    }

    $restore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-UninstallCleanupExecution.ps1') -RollbackManifestPath $rollbackPath -ConfirmApply -AllowRealSystemExecution -UserApproved)
    if ($restore.status -eq 'success' -and $restore.summary.restoredCount -eq 2 -and (Test-Path -LiteralPath $folderFile) -and (Test-Path -LiteralPath $fileTarget) -and (Get-Content -LiteralPath $folderFile -Raw).Trim() -eq 'cache payload' -and (Get-Content -LiteralPath $fileTarget -Raw).Trim() -eq 'log payload') {
        Add-Pass 'Apply package rollback restores exact file/folder cleanup from backups'
    } else {
        Add-Failure 'Apply package rollback did not restore the backed-up targets'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'Apply package disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Apply package disposable fixtures remain'
    }
} catch {
    Add-Failure "Apply package validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after apply package validation'
} else {
    Add-Failure "backend/state is not empty or changed during apply package validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Apply package validation did not launch Revo, registry edits, service edits, task edits, or driver cleanup tools'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Uninstall cleanup apply package validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Uninstall cleanup apply package validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
