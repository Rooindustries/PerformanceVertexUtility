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

function Test-JsonFile {
    param([string]$Path)
    try {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json | Out-Null
        Add-Pass "JSON parsed: $((Resolve-Path -LiteralPath $Path).Path.Substring($repoRoot.Path.Length + 1))"
    } catch {
        Add-Failure "JSON parse failed: $Path :: $($_.Exception.Message)"
    }
}

$requiredFiles = @(
    'backend\contracts\validation-map.json',
    'backend\scripts\Test-JsonSchemaContracts.ps1',
    'backend\scripts\Test-LegacyModuleRollback.ps1',
    'backend\contracts\roo-industries-backend-contracts.schema.json',
    'backend\contracts\contract-catalog.json',
    'backend\samples\product-backend-status.sample.json',
    'backend\samples\dashboard-backend-status.sample.json',
    'backend\samples\process-inventory.sample.json',
    'backend\samples\process-classification.sample.json',
    'backend\samples\game-session-profile-preview.sample.json',
    'backend\samples\process-profile-preview.sample.json',
    'backend\samples\process-profile-dry-run-result.sample.json',
    'backend\samples\process-profile-rollback-preview.sample.json',
    'backend\samples\process-profile-backup.sample.json',
    'backend\samples\game-tune-session-dry-run.sample.json',
    'backend\samples\game-tune-session-confirmed.sample.json',
    'backend\samples\game-tune-session-status.sample.json',
    'backend\samples\game-tune-session-restore-preview.sample.json',
    'backend\samples\game-tune-session-restore-result.sample.json',
    'backend\profiles\probalance-governor.profile.json',
    'backend\scripts\ProcessGovernor.Common.ps1',
    'backend\scripts\Preview-ProcessGovernor.ps1',
    'backend\scripts\Start-ProcessGovernorSession.ps1',
    'backend\scripts\Stop-ProcessGovernorSession.ps1',
    'backend\scripts\Get-ProcessGovernorSessionStatus.ps1',
    'backend\scripts\Test-ProcessGovernorRuntime.ps1',
    'backend\scripts\Test-ProcessGovernorReliability.ps1',
    'backend\samples\process-governor-preview.sample.json',
    'backend\samples\process-governor-session-confirmed.sample.json',
    'backend\samples\process-governor-session-status.sample.json',
    'backend\samples\process-governor-stop-preview.sample.json',
    'backend\samples\process-governor-stop-result.sample.json',
    'backend\profiles\persistent-policy.profile.json',
    'backend\scripts\ProcessPolicy.Common.ps1',
    'backend\scripts\Preview-ProcessPolicy.ps1',
    'backend\scripts\Start-ProcessPolicySession.ps1',
    'backend\scripts\Stop-ProcessPolicySession.ps1',
    'backend\scripts\Get-ProcessPolicySessionStatus.ps1',
    'backend\scripts\Test-ProcessPolicyRuntime.ps1',
    'backend\samples\process-policy-preview.sample.json',
    'backend\samples\process-policy-session-confirmed.sample.json',
    'backend\samples\process-policy-session-status.sample.json',
    'backend\samples\process-policy-stop-preview.sample.json',
    'backend\samples\process-policy-stop-result.sample.json',
    'backend\profiles\lightweight-governor-budget.profile.json',
    'backend\scripts\ResidentSessionHost.Common.ps1',
    'backend\scripts\Measure-RooIndustriesBackendFootprint.ps1',
    'backend\scripts\Start-RooIndustriesResidentSessionHost.ps1',
    'backend\scripts\Get-RooIndustriesResidentHostStatus.ps1',
    'backend\scripts\Test-RooIndustriesResidentBackendRuntime.ps1',
    'backend\samples\backend-footprint-result.sample.json',
    'backend\samples\lightweight-governor-budget.sample.json',
    'backend\samples\resident-host-status.sample.json',
    'backend\samples\all-control-policy-validation-result.sample.json',
    'backend\native\ProcessGovernor\RooIndustriesProcessGovernor.cs',
    'backend\scripts\Get-NativeProcessGovernorToolchain.ps1',
    'backend\scripts\Build-NativeProcessGovernor.ps1',
    'backend\scripts\Start-NativeProcessGovernorSession.ps1',
    'backend\scripts\Test-NativeProcessGovernorRuntime.ps1',
    'backend\scripts\BackendExecutor.Common.ps1',
    'backend\samples\installed-app-inventory.sample.json',
    'backend\samples\app-classification.sample.json',
    'backend\samples\uninstall-queue.sample.json',
    'backend\samples\official-uninstall-preview.sample.json',
    'backend\samples\leftover-scan-preview.sample.json',
    'backend\samples\cleanup-deletion-manifest.sample.json',
    'backend\samples\uninstall-cleanup-fixture-execution.sample.json',
    'backend\samples\nvidia-nip-preview.sample.json',
    'backend\samples\stutter-optimization-preview.sample.json',
    'backend\uninstall\protected-apps.json',
    'backend\uninstall\leftover-scan-rules.json',
    'backend\uninstall\uninstall-policy.json',
    'backend\samples\driver-hardware-summary.sample.json',
    'backend\samples\driver-recommendation-catalog.sample.json',
    'backend\samples\nvidia-profile-catalog.sample.json',
    'backend\samples\telemetry-snapshot.sample.json',
    'backend\samples\report-summary.sample.json',
    'backend\profiles\game-session.profile.json',
    'backend\profiles\protected-processes.json',
    'backend\profiles\background-demotion.profile.json',
    'backend\scripts\Get-ProcessInventory.ps1',
    'backend\scripts\Get-ProcessClassification.ps1',
    'backend\scripts\Preview-ProcessProfile.ps1',
    'backend\scripts\Apply-ProcessProfile.ps1',
    'backend\scripts\Restore-ProcessProfileBackup.ps1',
    'backend\scripts\GameTuneSession.Common.ps1',
    'backend\scripts\Start-GameTuneSession.ps1',
    'backend\scripts\Stop-GameTuneSession.ps1',
    'backend\scripts\Get-GameTuneSessionStatus.ps1',
    'backend\scripts\Test-GameTuneSessionRuntime.ps1',
    'backend\scripts\Test-ProcessProfileBackend.ps1',
    'backend\scripts\Get-InstalledAppInventory.ps1',
    'backend\scripts\UninstallCleanup.Common.ps1',
    'backend\scripts\Get-AppClassification.ps1',
    'backend\scripts\Preview-UninstallQueue.ps1',
    'backend\scripts\Preview-OfficialUninstall.ps1',
    'backend\scripts\Preview-LeftoverScan.ps1',
    'backend\scripts\New-CleanupDeletionManifest.ps1',
    'backend\scripts\Test-UninstallCleanupBackend.ps1',
    'backend\scripts\Invoke-UninstallCleanupExecution.ps1',
    'backend\scripts\Restore-UninstallCleanupExecution.ps1',
    'backend\scripts\Test-UninstallCleanupRestore.ps1',
    'backend\scripts\Invoke-UninstallCleanupApplyPackage.ps1',
    'backend\scripts\Test-UninstallCleanupApplyPackage.ps1',
    'backend\scripts\Invoke-UninstallCleanupRunners.ps1',
    'backend\scripts\Test-UninstallCleanupRunnerContracts.ps1',
    'backend\scripts\Invoke-OfficialUninstallCommandRunner.ps1',
    'backend\scripts\Test-OfficialUninstallCommandRunner.ps1',
    'backend\scripts\Get-DriverHardwareSummary.ps1',
    'backend\scripts\NvidiaNip.Common.ps1',
    'backend\scripts\Preview-NvidiaNipProfile.ps1',
    'backend\scripts\Invoke-NvidiaNipProfile.ps1',
    'backend\scripts\Restore-NvidiaNipProfile.ps1',
    'backend\scripts\Test-NvidiaNipExecutionContract.ps1',
    'backend\scripts\Invoke-NvidiaNipExecutor.ps1',
    'backend\scripts\Test-NvidiaNipExecutor.ps1',
    'backend\scripts\Invoke-NvidiaNipCapabilityProbe.ps1',
    'backend\scripts\Invoke-NvidiaNipElevatedReadOnlyProbeHelper.ps1',
    'backend\scripts\Test-NvidiaNipCapabilityProbe.ps1',
    'backend\scripts\StutterOptimization.Common.ps1',
    'backend\scripts\Preview-StutterOptimization.ps1',
    'backend\scripts\Invoke-StutterOptimization.ps1',
    'backend\scripts\Restore-StutterOptimization.ps1',
    'backend\scripts\Test-StutterOptimizationContracts.ps1',
    'backend\scripts\Invoke-StutterOptimizationExecutor.ps1',
    'backend\scripts\Test-StutterOptimizationExecutorContracts.ps1',
    'backend\scripts\Invoke-TimerResolutionSession.ps1',
    'backend\scripts\Invoke-StutterOptimizationRealExecutor.ps1',
    'backend\scripts\Test-StutterOptimizationRealExecutors.ps1',
    'backend\scripts\Build-StandbyMemoryHelper.ps1',
    'backend\scripts\Get-RooIndustriesValidationTempArtifacts.ps1',
    'backend\scripts\Test-RooIndustriesValidationTempArtifacts.ps1',
    'backend\native\StandbyMemoryHelper\RooIndustriesStandbyMemoryHelper.cs',
    'backend\catalogs\fsosx-playbook-capabilities.json',
    'backend\catalogs\fsosx-dash-capabilities.json',
    'backend\catalogs\fsosx-gap-map.json',
    'backend\scripts\Test-FSOSXCatalogs.ps1',
    'backend\catalogs\utilities-bundle-catalog.json',
    'backend\samples\utilities-bundle-inventory.sample.json',
    'backend\samples\utilities-bundle-catalog.sample.json',
    'backend\scripts\Get-UtilitiesBundleInventory.ps1',
    'backend\scripts\Test-UtilitiesBundleCatalog.ps1'
)

foreach ($relative in $requiredFiles) {
    $path = Join-Path $repoRoot $relative
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $relative"
    } else {
        Add-Failure "Required file missing: $relative"
    }
}

$jsonRoots = @(
    (Join-Path $repoRoot 'modules'),
    (Join-Path $repoRoot 'backend\contracts'),
    (Join-Path $repoRoot 'backend\samples'),
    (Join-Path $repoRoot 'backend\profiles'),
    (Join-Path $repoRoot 'backend\uninstall'),
    (Join-Path $repoRoot 'backend\catalogs')
)

foreach ($root in $jsonRoots) {
    if (Test-Path -LiteralPath $root) {
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -Recurse -File) {
            Test-JsonFile $file.FullName
        }
    }
}

try {
    & (Join-Path $PSScriptRoot 'Test-JsonSchemaContracts.ps1')
    Add-Pass 'Declared JSON Schemas and negative control validated'
} catch {
    Add-Failure "JSON Schema validation failed: $($_.Exception.Message)"
}

try {
    $catalogTestOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-FSOSXCatalogs.ps1') 2>&1
    $catalogTestExitCode = $LASTEXITCODE
    $catalogTestOutput | ForEach-Object { Write-Host $_ }
    if ($catalogTestExitCode -eq 0) {
        Add-Pass 'FSOS-X playbook and Dash catalog guardrails passed'
    } else {
        Add-Failure "FSOS-X catalog guardrails failed with exit code $catalogTestExitCode"
    }
} catch {
    Add-Failure "FSOS-X catalog guardrails failed: $($_.Exception.Message)"
}

try {
    $utilitiesCatalogTestOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-UtilitiesBundleCatalog.ps1') 2>&1
    $utilitiesCatalogTestExitCode = $LASTEXITCODE
    $utilitiesCatalogTestOutput | ForEach-Object { Write-Host $_ }
    if ($utilitiesCatalogTestExitCode -eq 0) {
        Add-Pass 'Utilities bundle catalog guardrails passed'
    } else {
        Add-Failure "Utilities bundle catalog guardrails failed with exit code $utilitiesCatalogTestExitCode"
    }
} catch {
    Add-Failure "Utilities bundle catalog guardrails failed: $($_.Exception.Message)"
}

try {
    $processInventory = & (Join-Path $PSScriptRoot 'Get-ProcessInventory.ps1') | ConvertFrom-Json
    if ($processInventory.productName -eq 'Roo Industries Optimization Suite' -and $processInventory.summary.processCount -gt 0) {
        Add-Pass "Read-only process inventory returned $($processInventory.summary.processCount) processes"
    } else {
        Add-Failure "Read-only process inventory returned an unexpected shape"
    }
} catch {
    Add-Failure "Read-only process inventory failed: $($_.Exception.Message)"
}

try {
    $appInventory = & (Join-Path $PSScriptRoot 'Get-InstalledAppInventory.ps1') | ConvertFrom-Json
    if ($appInventory.productName -eq 'Roo Industries Optimization Suite' -and $null -ne $appInventory.summary.appCount) {
        Add-Pass "Read-only installed app inventory returned $($appInventory.summary.appCount) apps"
    } else {
        Add-Failure "Read-only installed app inventory returned an unexpected shape"
    }
} catch {
    Add-Failure "Read-only installed app inventory failed: $($_.Exception.Message)"
}

try {
    $driverSummary = & (Join-Path $PSScriptRoot 'Get-DriverHardwareSummary.ps1') | ConvertFrom-Json
    if ($driverSummary.productName -eq 'Roo Industries Optimization Suite' -and $null -ne $driverSummary.machine) {
        Add-Pass "Read-only driver and hardware summary returned machine metadata"
    } else {
        Add-Failure "Read-only driver and hardware summary returned an unexpected shape"
    }
} catch {
    Add-Failure "Read-only driver and hardware summary failed: $($_.Exception.Message)"
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "PASS Backend contract validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Backend contract validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
