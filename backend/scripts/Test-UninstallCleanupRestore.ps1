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
    'backend\scripts\Invoke-UninstallCleanupExecution.ps1',
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-uninstall-restore-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    $folderTarget = Join-Path $tempRoot 'FakeAppCache'
    $folderFile = Join-Path $folderTarget 'cache.txt'
    $fileTarget = Join-Path $tempRoot 'loose.txt'
    New-Item -ItemType Directory -Path $folderTarget -Force | Out-Null
    Set-Content -LiteralPath $folderFile -Value 'folder payload' -Encoding UTF8
    Set-Content -LiteralPath $fileTarget -Value 'file payload' -Encoding UTF8

    $officialPath = Join-Path $tempRoot 'official-preview.json'
    $manifestPath = Join-Path $tempRoot 'cleanup-manifest.json'
    ([pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        dryRun = $true
        status = 'preview'
        commands = @([pscustomobject]@{ appId = 'fixture:restore-app'; displayName = 'Restore Fixture'; rawCommand = 'preview only'; executable = 'preview.exe'; arguments = @(); protected = $false; blocked = $false; executionAllowed = $false })
        summary = [pscustomobject]@{ commandPreviewCount = 1; willRunUninstallers = $false }
        warnings = @(); errors = @(); logs = @()
    } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $officialPath -Encoding UTF8
    ([pscustomobject]@{
        manifestId = 'restore-fixture-manifest'
        productName = 'Roo Industries Optimization Suite'
        schemaVersion = 1
        appId = 'fixture:restore-app'
        displayName = 'Restore Fixture'
        dryRun = $true
        items = @(
            [pscustomobject]@{ itemId = 'folder-cache'; type = 'folder'; target = $folderTarget; protected = $false; defaultSelected = $true },
            [pscustomobject]@{ itemId = 'file-cache'; type = 'file'; target = $fileTarget; protected = $false; defaultSelected = $true }
        )
        rollback = [pscustomobject]@{ backupRoot = (Join-Path $tempRoot '_backup'); rollbackSupported = $true }
        summary = [pscustomobject]@{ itemCount = 2; willDeleteOnApply = $false; dryRunWritesState = $false }
        warnings = @(); errors = @()
    } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $apply = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupExecution.ps1') -OfficialPreviewPath $officialPath -CleanupManifestPath $manifestPath -FixtureRoot $tempRoot -ConfirmApply -AllowDisposableFixtureApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved)
    if ($apply.status -eq 'success' -and $apply.summary.deletedCount -eq 2 -and -not (Test-Path -LiteralPath $folderTarget) -and -not (Test-Path -LiteralPath $fileTarget) -and (Test-Path -LiteralPath $apply.rollback.rollbackManifestPath)) {
        Add-Pass 'Cleanup fixture apply backed up and deleted disposable file and folder targets'
    } else {
        Add-Failure 'Cleanup fixture apply did not produce expected backup/delete state'
    }

    $restore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-UninstallCleanupExecution.ps1') -RollbackManifestPath $apply.rollback.rollbackManifestPath -ConfirmApply -AllowDisposableFixtureApply)
    if ($restore.status -eq 'success' -and $restore.summary.restoredCount -eq 2 -and (Test-Path -LiteralPath $folderFile) -and (Test-Path -LiteralPath $fileTarget) -and (Get-Content -LiteralPath $folderFile -Raw).Trim() -eq 'folder payload' -and (Get-Content -LiteralPath $fileTarget -Raw).Trim() -eq 'file payload') {
        Add-Pass 'Cleanup fixture restore rehydrated copied file and folder backups through rollback manifest'
    } else {
        Add-Failure 'Cleanup fixture restore did not rehydrate copied file and folder backups'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'Cleanup restore disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Cleanup restore disposable fixtures remain'
    }
} catch {
    Add-Failure "Cleanup restore validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after cleanup restore validation'
} else {
    Add-Failure "backend/state is not empty or changed during cleanup restore validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Cleanup restore validation did not launch real uninstallers or cleanup tools'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Uninstall cleanup restore validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Uninstall cleanup restore validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
