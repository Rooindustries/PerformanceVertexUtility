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
    'backend\contracts\roo-backend-contracts.schema.json',
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
    'backend\samples\installed-app-inventory.sample.json',
    'backend\samples\app-classification.sample.json',
    'backend\samples\uninstall-queue.sample.json',
    'backend\samples\official-uninstall-preview.sample.json',
    'backend\samples\leftover-scan-preview.sample.json',
    'backend\samples\cleanup-deletion-manifest.sample.json',
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
    'backend\scripts\Test-ProcessProfileBackend.ps1',
    'backend\scripts\Get-InstalledAppInventory.ps1',
    'backend\scripts\UninstallCleanup.Common.ps1',
    'backend\scripts\Get-AppClassification.ps1',
    'backend\scripts\Preview-UninstallQueue.ps1',
    'backend\scripts\Preview-OfficialUninstall.ps1',
    'backend\scripts\Preview-LeftoverScan.ps1',
    'backend\scripts\New-CleanupDeletionManifest.ps1',
    'backend\scripts\Test-UninstallCleanupBackend.ps1',
    'backend\scripts\Get-DriverHardwareSummary.ps1'
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
    (Join-Path $repoRoot 'backend\uninstall')
)

foreach ($root in $jsonRoots) {
    if (Test-Path -LiteralPath $root) {
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -Recurse -File) {
            Test-JsonFile $file.FullName
        }
    }
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
