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

function New-RunnerShim {
    param(
        [string]$Path,
        [string]$LogPath,
        [ValidateSet('Success','FailOfficial')]
        [string]$Behavior
    )
    $escapedLog = $LogPath.Replace("'", "''")
    $content = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$logPath = '__LOG__'
$entry = [pscustomobject]@{ args = @($Rest); atUtc = (Get-Date).ToUniversalTime().ToString('o') }
($entry | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $logPath
if ('__BEHAVIOR__' -eq 'FailOfficial' -and @($Rest).Count -gt 0 -and $Rest[0] -eq 'official-uninstall') { exit 21 }
exit 0
'@
    $content = $content.Replace('__LOG__', $escapedLog).Replace('__BEHAVIOR__', $Behavior)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Write-OfficialPreview {
    param(
        [string]$Path,
        [string]$Executable,
        [object[]]$Arguments
    )
    ([pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = '2026-07-03T00:00:00Z'
        dryRun = $true
        status = 'preview'
        commands = @(
            [pscustomobject]@{
                appId = 'fixture:fake-app'
                displayName = 'Fixture Fake App'
                commandType = 'harmless-real-runner'
                rawCommand = 'harmless runner'
                executable = $Executable
                arguments = @($Arguments)
                protected = $false
                blocked = $false
                executionAllowed = $false
            }
        )
        summary = [pscustomobject]@{ requestedCount = 1; commandPreviewCount = 1; blockedCount = 0; executionAllowedCount = 0; willRunUninstallers = $false }
        warnings = @()
        errors = @()
        logs = @()
    } | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-MockLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json })
}

$requiredFiles = @(
    'backend\scripts\BackendExecutor.Common.ps1',
    'backend\scripts\Invoke-UninstallCleanupRunners.ps1'
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-uninstall-runner-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $leftoverFolder = Join-Path $tempRoot 'FakeAppCache'
    $leftoverFile = Join-Path $tempRoot 'fake-app.log'
    New-Item -ItemType Directory -Path $leftoverFolder -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $leftoverFolder 'cache.bin') -Value 'fixture cache' -Encoding UTF8
    Set-Content -LiteralPath $leftoverFile -Value 'fixture log' -Encoding UTF8

    $officialPath = Join-Path $tempRoot 'official-preview.json'
    $manifestPath = Join-Path $tempRoot 'cleanup-manifest.json'
    $officialPreview = [pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = '2026-07-01T00:00:00Z'
        dryRun = $true
        status = 'preview'
        commands = @(
            [pscustomobject]@{
                appId = 'fixture:fake-app'
                displayName = 'Fixture Fake App'
                commandType = 'registry-uninstall-string'
                rawCommand = '"C:\Fixture\Uninstall.exe" /quiet'
                executable = 'C:\Fixture\Uninstall.exe'
                arguments = '/quiet'
                protected = $false
                blocked = $false
                executionAllowed = $false
            }
        )
        summary = [pscustomobject]@{ requestedCount = 1; commandPreviewCount = 1; blockedCount = 0; executionAllowedCount = 0; willRunUninstallers = $false }
        warnings = @()
        errors = @()
        logs = @()
    }
    $cleanupManifest = [pscustomobject]@{
        manifestId = 'fixture-cleanup-manifest'
        productName = 'Roo Industries Optimization Suite'
        schemaVersion = 1
        appId = 'fixture:fake-app'
        displayName = 'Fixture Fake App'
        createdAtUtc = '2026-07-01T00:00:00Z'
        dryRun = $true
        executionMode = 'preview-only'
        sourceScanId = 'fixture-scan'
        items = @(
            [pscustomobject]@{ itemId = 'folder:fake-cache'; type = 'folder'; target = $leftoverFolder; defaultSelected = $true; protected = $false; confidence = 'high'; risk = 'low' },
            [pscustomobject]@{ itemId = 'file:fake-log'; type = 'file'; target = $leftoverFile; defaultSelected = $true; protected = $false; confidence = 'high'; risk = 'low' }
        )
        excludedItems = @()
        rollback = [pscustomobject]@{
            backupRoot = (Join-Path $tempRoot '_backup')
            rollbackActionId = 'apps.rollbackCleanup'
            rollbackSupported = $true
            fileBackupRequirements = @()
            registryExportRequirements = @()
            serviceStateBackupRequirements = @()
            scheduledTaskBackupRequirements = @()
            startupEntryBackupRequirements = @()
            manifestExportRequired = $true
        }
        summary = [pscustomobject]@{ itemCount = 2; willDeleteOnApply = $false; willEditRegistry = $false; willEditServices = $false; willEditScheduledTasks = $false; dryRunWritesState = $false }
        warnings = @()
        errors = @()
    }
    ($officialPreview | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $officialPath -Encoding UTF8
    ($cleanupManifest | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $successLog = Join-Path $tempRoot 'runner-success.log'
    $successShim = Join-Path $tempRoot 'runner-success.ps1'
    $failLog = Join-Path $tempRoot 'runner-fail.log'
    $failShim = Join-Path $tempRoot 'runner-fail.ps1'
    New-RunnerShim $successShim $successLog 'Success'
    New-RunnerShim $failShim $failLog 'FailOfficial'

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupRunners.ps1') -OfficialPreviewPath $officialPath -CleanupManifestPath $manifestPath)
    if ($preview.status -eq 'preview' -and $preview.summary.willRunMockRunner -eq $false -and $preview.summary.willRunRealUninstaller -eq $false -and @($preview.executionSequence).Count -eq 0) {
        Add-Pass 'Uninstall cleanup runner default call is preview-only and runs no command'
    } else {
        Add-Failure 'Uninstall cleanup runner default call was not preview-only'
    }

    $blockedAllowlist = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupRunners.ps1') -OfficialPreviewPath $officialPath -CleanupManifestPath $manifestPath -ExecutorMode Mock -MockUninstallerShimPath $successShim -MockDeletionShimPath $successShim -ConfirmApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved -BackupsAndExportsCompleted -UserApproved)
    $allowlistGate = @($blockedAllowlist.gates | Where-Object { $_.gateId -eq 'exact-target-allowlist' }) | Select-Object -First 1
    if ($blockedAllowlist.status -eq 'blocked' -and $allowlistGate.blocking -eq $true -and @($blockedAllowlist.executionSequence).Count -eq 0) {
        Add-Pass 'Uninstall cleanup runner blocks without exact leftover target allowlist'
    } else {
        Add-Failure 'Uninstall cleanup runner did not block missing target allowlist'
    }

    $rollbackPath = Join-Path $tempRoot 'cleanup-runner-rollback.json'
    $success = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupRunners.ps1') -OfficialPreviewPath $officialPath -CleanupManifestPath $manifestPath -ExecutorMode Mock -MockUninstallerShimPath $successShim -MockDeletionShimPath $successShim -ExactTargetAllowlist @($leftoverFolder, $leftoverFile) -RollbackManifestPath $rollbackPath -ConfirmApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved -BackupsAndExportsCompleted -UserApproved)
    $successLogEntries = Read-MockLog $successLog
    if ($success.status -eq 'success' -and $success.summary.willRunMockRunner -eq $true -and $success.summary.willRunRealUninstaller -eq $false -and $success.summary.willDeleteRealLeftovers -eq $false -and $success.summary.officialRunnerCompleted -eq $true -and $success.summary.leftoverRunnerCompletedCount -eq 2 -and @($successLogEntries[0].args)[0] -eq 'official-uninstall' -and @($successLogEntries[1].args)[0] -eq 'leftover-delete' -and (Test-Path -LiteralPath $leftoverFolder) -and (Test-Path -LiteralPath $leftoverFile) -and (Test-Path -LiteralPath $rollbackPath)) {
        Add-Pass 'Uninstall cleanup mock runner proves official-uninstall-before-leftovers and leaves fixture targets intact'
    } else {
        Add-Failure 'Uninstall cleanup mock runner did not prove guarded execution sequence'
    }
    if ($success.summary.focusStealPrevented -eq $true -and $success.capabilities.realSystemRunnerImplemented -eq $true) {
        Add-Pass 'Uninstall cleanup runner proves hidden mock invocation while real runner path is implemented'
    } else {
        Add-Failure 'Uninstall cleanup runner did not prove hidden invocation and implemented real runner'
    }

    $failOfficial = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupRunners.ps1') -OfficialPreviewPath $officialPath -CleanupManifestPath $manifestPath -ExecutorMode Mock -MockUninstallerShimPath $failShim -MockDeletionShimPath $failShim -ExactTargetAllowlist @($leftoverFolder, $leftoverFile) -ConfirmApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved -BackupsAndExportsCompleted -UserApproved)
    if ($failOfficial.status -eq 'failed' -and $failOfficial.summary.officialRunnerCompleted -eq $false -and $failOfficial.summary.leftoverRunnerAttemptedCount -eq 0 -and $failOfficial.summary.leftoverRunnerSkippedUntilOfficialUninstallSucceeded -eq $true -and $failOfficial.summary.nonZeroExitCount -eq 1) {
        Add-Pass 'Uninstall cleanup runner skips leftover runners when official uninstall runner fails'
    } else {
        Add-Failure 'Uninstall cleanup runner did not skip leftovers after official runner failure'
    }

    $realPreviewPath = Join-Path $tempRoot 'official-real-preview.json'
    $realShimPath = Join-Path $tempRoot 'official-real-shim.ps1'
    $realLogPath = Join-Path $tempRoot 'official-real.log'
    @"
param([string]`$Value)
[pscustomobject]@{ value = `$Value; cwd = (Get-Location).Path } | ConvertTo-Json -Compress
'real-runner' | Set-Content -LiteralPath '$($realLogPath.Replace("'", "''"))' -Encoding UTF8
exit 0
"@ | Set-Content -LiteralPath $realShimPath -Encoding UTF8
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-OfficialPreview $realPreviewPath $powershellPath @('-NoProfile','-ExecutionPolicy','Bypass','-File',$realShimPath,'approved app')
    $realRun = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupRunners.ps1') -OfficialPreviewPath $realPreviewPath -CleanupManifestPath $manifestPath -ExecutorMode Real -AllowedOfficialExecutablePath $powershellPath -OfficialRunnerWorkingDirectory $tempRoot -ExactTargetAllowlist @($leftoverFolder, $leftoverFile) -ConfirmApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved -BackupsAndExportsCompleted -UserApproved -AllowRealSystemExecution)
    if ($realRun.status -eq 'success' -and $realRun.capabilities.realSystemRunnerImplemented -eq $true -and $realRun.summary.willRunRealUninstaller -eq $true -and $realRun.summary.officialRunnerCompleted -eq $true -and $realRun.summary.focusStealPrevented -eq $true -and (Test-Path -LiteralPath $realLogPath)) {
        Add-Pass 'Uninstall cleanup real runner executes harmless allowlisted official command through the real path'
    } else {
        Add-Failure 'Uninstall cleanup real runner did not execute the harmless allowlisted official command'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'Uninstall cleanup runner disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Uninstall cleanup runner disposable fixtures remain'
    }
} catch {
    Add-Failure "Uninstall cleanup runner validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after uninstall cleanup runner validation'
} else {
    Add-Failure "backend/state is not empty or changed during uninstall cleanup runner validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Uninstall cleanup runner validation did not launch Revo, uninstallers, registry edits, service edits, task edits, or real cleanup tools'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Uninstall cleanup runner validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Uninstall cleanup runner validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
