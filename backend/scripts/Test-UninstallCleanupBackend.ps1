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

function Test-RequiredFile {
    param([string]$RelativePath)
    $path = Join-Path $repoRoot $RelativePath
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $RelativePath"
    } else {
        Add-Failure "Required file missing: $RelativePath"
    }
}

function Test-JsonFile {
    param([string]$RelativePath)
    $path = Join-Path $repoRoot $RelativePath
    try {
        Get-Content -LiteralPath $path -Raw | ConvertFrom-Json | Out-Null
        Add-Pass "JSON parsed: $RelativePath"
    } catch {
        Add-Failure "JSON parse failed: $RelativePath :: $($_.Exception.Message)"
    }
}

function Invoke-JsonScript {
    param(
        [string]$ScriptPath,
        [object[]]$Arguments = @()
    )
    $output = & $ScriptPath @Arguments
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

$requiredFiles = @(
    'backend\uninstall\protected-apps.json',
    'backend\uninstall\leftover-scan-rules.json',
    'backend\uninstall\uninstall-policy.json',
    'backend\scripts\UninstallCleanup.Common.ps1',
    'backend\scripts\Get-InstalledAppInventory.ps1',
    'backend\scripts\Get-AppClassification.ps1',
    'backend\scripts\Preview-UninstallQueue.ps1',
    'backend\scripts\Preview-OfficialUninstall.ps1',
    'backend\scripts\Preview-LeftoverScan.ps1',
    'backend\scripts\New-CleanupDeletionManifest.ps1',
    'backend\scripts\New-UninstallCleanupExecutionPlan.ps1',
    'backend\scripts\Invoke-UninstallCleanupExecution.ps1',
    'backend\scripts\Test-UninstallCleanupBackend.ps1',
    'backend\samples\installed-app-inventory.sample.json',
    'backend\samples\app-classification.sample.json',
    'backend\samples\uninstall-queue.sample.json',
    'backend\samples\official-uninstall-preview.sample.json',
    'backend\samples\uninstall-cleanup-execution-plan.sample.json',
    'backend\samples\leftover-scan-preview.sample.json',
    'backend\samples\cleanup-deletion-manifest.sample.json'
)

foreach ($relative in $requiredFiles) {
    Test-RequiredFile $relative
}

foreach ($relative in @(
    'backend\uninstall\protected-apps.json',
    'backend\uninstall\leftover-scan-rules.json',
    'backend\uninstall\uninstall-policy.json',
    'backend\samples\installed-app-inventory.sample.json',
    'backend\samples\app-classification.sample.json',
    'backend\samples\uninstall-queue.sample.json',
    'backend\samples\official-uninstall-preview.sample.json',
    'backend\samples\uninstall-cleanup-execution-plan.sample.json',
    'backend\samples\leftover-scan-preview.sample.json',
    'backend\samples\cleanup-deletion-manifest.sample.json'
)) {
    Test-JsonFile $relative
}

$stateBefore = Get-StateEntryCount

$sampleInventory = Join-Path $repoRoot 'backend\samples\installed-app-inventory.sample.json'
$sampleScan = Join-Path $repoRoot 'backend\samples\leftover-scan-preview.sample.json'
$sampleOfficialPreview = Join-Path $repoRoot 'backend\samples\official-uninstall-preview.sample.json'
$sampleCleanupManifest = Join-Path $repoRoot 'backend\samples\cleanup-deletion-manifest.sample.json'

try {
    $classificationOutput = & (Join-Path $PSScriptRoot 'Get-AppClassification.ps1') -InventoryPath $sampleInventory
    $classification = ($classificationOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($classification.productName -eq 'Roo Industries Optimization Suite' -and $classification.summary.appCount -gt 0) {
        Add-Pass "App classification returned $($classification.summary.appCount) app classifications"
    } else {
        Add-Failure 'App classification returned an unexpected shape'
    }
    $webview = @($classification.apps | Where-Object { $_.appId -eq 'registry:microsoft-edge-webview2-runtime' }) | Select-Object -First 1
    if ($webview.protected -eq $true -and $webview.blockByDefault -eq $true) {
        Add-Pass 'WebView2 runtime is protected and blocked by default'
    } else {
        Add-Failure 'WebView2 runtime was not protected by classification'
    }
} catch {
    Add-Failure "App classification failed: $($_.Exception.Message)"
}

try {
    $queueOutput = & (Join-Path $PSScriptRoot 'Preview-UninstallQueue.ps1') -InventoryPath $sampleInventory -AppId @('registry:overwolf', 'registry:microsoft-edge-webview2-runtime')
    $queue = ($queueOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($queue.dryRun -eq $true -and $queue.status -eq 'preview' -and $queue.summary.willRunUninstallers -eq $false -and $queue.summary.willDeleteLeftovers -eq $false) {
        Add-Pass 'Uninstall queue preview is dry-run and does not run uninstallers or delete leftovers'
    } else {
        Add-Failure 'Uninstall queue preview reported unsafe execution state'
    }
    if (@($queue.selectedApps).Count -eq 1 -and @($queue.blockedApps).Count -eq 1) {
        Add-Pass 'Uninstall queue selected normal app and blocked protected app'
    } else {
        Add-Failure 'Uninstall queue did not block protected app by default'
    }
} catch {
    Add-Failure "Uninstall queue preview failed: $($_.Exception.Message)"
}

try {
    $officialOutput = & (Join-Path $PSScriptRoot 'Preview-OfficialUninstall.ps1') -InventoryPath $sampleInventory -AppId 'registry:overwolf'
    $official = ($officialOutput -join [Environment]::NewLine) | ConvertFrom-Json
    $command = @($official.commands) | Select-Object -First 1
    if ($official.dryRun -eq $true -and $official.summary.willRunUninstallers -eq $false -and $command.executionAllowed -eq $false) {
        Add-Pass 'Official uninstall preview exposes metadata without command execution'
    } else {
        Add-Failure 'Official uninstall preview reported executable state'
    }
} catch {
    Add-Failure "Official uninstall preview failed: $($_.Exception.Message)"
}

try {
    $scanOutput = & (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -InventoryPath $sampleInventory -AppId 'registry:overwolf'
    $scan = ($scanOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($scan.dryRun -eq $true -and $scan.summary.deletionMode -eq 'preview-only' -and $scan.summary.willDeleteLeftovers -eq $false) {
        Add-Pass "Leftover scan preview returned $($scan.summary.itemCount) candidate item(s) without deletion"
    } else {
        Add-Failure 'Leftover scan preview reported unsafe deletion state'
    }
    $fuzzyShared = @($scan.items | Where-Object { $_.matchedBy -contains 'fuzzyName' -and $_.defaultSelected -eq $true })
    if ($fuzzyShared.Count -eq 0) {
        Add-Pass 'Leftover scan does not default-select fuzzy shared paths'
    } else {
        Add-Failure 'Leftover scan default-selected a fuzzy shared path'
    }
} catch {
    Add-Failure "Leftover scan preview failed: $($_.Exception.Message)"
}

try {
    $manifestOutput = & (Join-Path $PSScriptRoot 'New-CleanupDeletionManifest.ps1') -ScanPath $sampleScan
    $manifest = ($manifestOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($manifest.dryRun -eq $true -and $manifest.summary.willDeleteOnApply -eq $false -and $manifest.summary.willEditRegistry -eq $false -and $manifest.summary.willEditServices -eq $false -and $manifest.summary.willEditScheduledTasks -eq $false) {
        Add-Pass 'Cleanup deletion manifest is dry-run and reports no apply path'
    } else {
        Add-Failure 'Cleanup deletion manifest reported unsafe apply state'
    }
    $rollbackProps = $manifest.rollback.PSObject.Properties
    if ($null -ne $rollbackProps['fileBackupRequirements'] -and $null -ne $rollbackProps['registryExportRequirements'] -and $null -ne $rollbackProps['serviceStateBackupRequirements'] -and $null -ne $rollbackProps['scheduledTaskBackupRequirements']) {
        Add-Pass 'Cleanup deletion manifest includes rollback and export requirement metadata'
    } else {
        Add-Failure 'Cleanup deletion manifest is missing rollback/export metadata'
    }
} catch {
    Add-Failure "Cleanup deletion manifest preview failed: $($_.Exception.Message)"
}

try {
    $planOutput = & (Join-Path $PSScriptRoot 'New-UninstallCleanupExecutionPlan.ps1') -OfficialPreviewPath $sampleOfficialPreview -CleanupManifestPath $sampleCleanupManifest
    $plan = ($planOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($plan.dryRun -eq $true -and $plan.executionMode -eq 'guarded-fixture-ready' -and $plan.capabilities.fixtureExecutorImplemented -eq $true -and $plan.capabilities.realSystemExecutorImplemented -eq $true -and $plan.capabilities.canRunAllowlistedOfficialCommand -eq $true -and $plan.capabilities.canRunUninstallers -eq $false -and $plan.capabilities.canDeleteLeftovers -eq $false -and $plan.summary.executionReady -eq $false) {
        Add-Pass 'Uninstall cleanup execution plan is fixture-ready and exposes the controlled allowlisted runner'
    } else {
        Add-Failure 'Uninstall cleanup execution plan reported executable state'
    }
    $policyGate = @($plan.gates | Where-Object { $_.gateId -eq 'policy-confirmed-execution-enabled' }) | Select-Object -First 1
    $backupGate = @($plan.gates | Where-Object { $_.gateId -eq 'backup-exports-complete' }) | Select-Object -First 1
    $realExecutorGate = @($plan.gates | Where-Object { $_.gateId -eq 'real-system-executor-implemented' }) | Select-Object -First 1
    if ($policyGate.blocking -eq $true -and $backupGate.blocking -eq $true -and $realExecutorGate.satisfied -eq $true -and $realExecutorGate.blocking -eq $false -and $plan.summary.disposableFixtureExecutionReady -eq $true -and $plan.summary.allowlistedOfficialRunnerReady -eq $true) {
        Add-Pass 'Execution plan exposes blocking real-system policy and backup gates while controlled runner and fixture validation are ready'
    } else {
        Add-Failure 'Execution plan did not expose expected blocking gates'
    }
    if ($plan.summary.willRunUninstallers -eq $false -and $plan.summary.willDeleteLeftovers -eq $false -and $plan.summary.dryRunWritesState -eq $false) {
        Add-Pass 'Execution plan preserves no-uninstall, no-delete, no-state-write invariant'
    } else {
        Add-Failure 'Execution plan violated dry-run invariant'
    }
} catch {
    Add-Failure "Uninstall cleanup execution plan failed: $($_.Exception.Message)"
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-uninstall-cleanup-fixture-$([guid]::NewGuid().ToString('N'))"
$fixtureCleanupDone = $false
try {
    $appFolder = Join-Path $fixtureRoot 'FakeApp'
    $cacheFolder = Join-Path $fixtureRoot 'FakeAppCache'
    $looseFile = Join-Path $fixtureRoot 'loose-cache.bin'
    New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $cacheFolder -Force | Out-Null
    'fixture app file' | Set-Content -LiteralPath (Join-Path $appFolder 'app.txt') -Encoding UTF8
    'fixture cache file' | Set-Content -LiteralPath (Join-Path $cacheFolder 'cache.txt') -Encoding UTF8
    'fixture loose file' | Set-Content -LiteralPath $looseFile -Encoding UTF8

    $officialFixturePath = Join-Path $fixtureRoot 'official-preview.json'
    $manifestFixturePath = Join-Path $fixtureRoot 'cleanup-manifest.json'
    $officialFixture = [pscustomobject]@{
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
                commandType = 'fixture-uninstall-string'
                rawCommand = '"C:\Fixture\FakeUninstaller.exe"'
                executable = 'C:\Fixture\FakeUninstaller.exe'
                arguments = $null
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
    $cleanupFixture = [pscustomobject]@{
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
            [pscustomobject]@{
                itemId = 'folder:fixture-cache'
                type = 'folder'
                target = $cacheFolder
                matchedBy = @('fixture')
                confidence = 'high'
                risk = 'low'
                defaultSelected = $true
                protected = $false
                reason = 'Disposable fixture folder.'
            },
            [pscustomobject]@{
                itemId = 'file:fixture-loose-cache'
                type = 'file'
                target = $looseFile
                matchedBy = @('fixture')
                confidence = 'high'
                risk = 'low'
                defaultSelected = $true
                protected = $false
                reason = 'Disposable fixture file.'
            }
        )
        excludedItems = @()
        rollback = [pscustomobject]@{
            backupRoot = (Join-Path $fixtureRoot '_roo-cleanup-backup')
            rollbackActionId = 'apps.rollbackCleanup'
            rollbackSupported = $true
            restorePoint = [pscustomobject]@{ requiredBeforeFutureApply = $false; created = $false; previewOnly = $true }
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
    ($officialFixture | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $officialFixturePath -Encoding UTF8
    ($cleanupFixture | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $manifestFixturePath -Encoding UTF8

    $fixturePreview = & (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupExecution.ps1') -OfficialPreviewPath $officialFixturePath -CleanupManifestPath $manifestFixturePath -FixtureRoot $fixtureRoot
    $fixturePreviewJson = ($fixturePreview -join [Environment]::NewLine) | ConvertFrom-Json
    if ($fixturePreviewJson.status -eq 'preview' -and $fixturePreviewJson.summary.willRunUninstallers -eq $false -and (Test-Path -LiteralPath $cacheFolder) -and (Test-Path -LiteralPath $looseFile)) {
        Add-Pass 'Cleanup executor preview leaves disposable fixture files untouched'
    } else {
        Add-Failure 'Cleanup executor preview changed fixture files or reported unsafe state'
    }

    $fixtureBlocked = & (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupExecution.ps1') -OfficialPreviewPath $officialFixturePath -CleanupManifestPath $manifestFixturePath -FixtureRoot $fixtureRoot -ConfirmApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved
    $fixtureBlockedJson = ($fixtureBlocked -join [Environment]::NewLine) | ConvertFrom-Json
    if ($fixtureBlockedJson.status -eq 'blocked' -and $fixtureBlockedJson.summary.deletedCount -eq 0 -and (Test-Path -LiteralPath $cacheFolder) -and (Test-Path -LiteralPath $looseFile)) {
        Add-Pass 'Cleanup executor blocks confirmed fixture deletion without disposable-fixture flag'
    } else {
        Add-Failure 'Cleanup executor did not block missing disposable-fixture flag'
    }

    $fixtureApply = & (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupExecution.ps1') -OfficialPreviewPath $officialFixturePath -CleanupManifestPath $manifestFixturePath -FixtureRoot $fixtureRoot -ConfirmApply -AllowDisposableFixtureApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved
    $fixtureApplyJson = ($fixtureApply -join [Environment]::NewLine) | ConvertFrom-Json
    if ($fixtureApplyJson.status -eq 'success' -and $fixtureApplyJson.summary.deletedCount -eq 2 -and $fixtureApplyJson.capabilities.canRunUninstallers -eq $false -and (Test-Path -LiteralPath $fixtureApplyJson.rollback.rollbackManifestPath) -and -not (Test-Path -LiteralPath $cacheFolder) -and -not (Test-Path -LiteralPath $looseFile)) {
        Add-Pass 'Cleanup executor backs up and deletes only disposable fixture leftovers after approval gates'
    } else {
        Add-Failure 'Cleanup executor fixture apply did not produce expected backup/delete result'
    }

    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    $fixtureCleanupDone = $true
    if (-not (Test-Path -LiteralPath $fixtureRoot)) {
        Add-Pass 'Cleanup executor disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Cleanup executor disposable fixtures remain'
    }
} catch {
    Add-Failure "Cleanup executor fixture validation failed: $($_.Exception.Message)"
} finally {
    if (-not $fixtureCleanupDone -and (Test-Path -LiteralPath $fixtureRoot)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after uninstall cleanup dry-run validation'
} else {
    Add-Failure "backend/state is not empty or changed during validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Validation did not call uninstall, deletion, registry edit, service edit, task edit, driver cleanup, or confirmed apply scripts'

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "PASS Uninstall cleanup backend validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Uninstall cleanup backend validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
