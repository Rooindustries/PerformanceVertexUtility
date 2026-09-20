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

function Write-HardwareFixture {
    param(
        [string]$Path,
        [bool]$Nvidia
    )
    $gpu = if ($Nvidia) {
        [pscustomobject]@{
            name = 'NVIDIA GeForce RTX Fixture'
            vendor = 'NVIDIA'
            pnpDeviceId = 'PCI\VEN_10DE&DEV_0000'
            driverVersion = 'fixture'
        }
    } else {
        [pscustomobject]@{
            name = 'Intel UHD Fixture'
            vendor = 'Intel'
            pnpDeviceId = 'PCI\VEN_8086&DEV_0000'
            driverVersion = 'fixture'
        }
    }
    $fixture = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = '2026-07-01T00:00:00Z'
        gpus = @($gpu)
    }
    ($fixture | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

$requiredFiles = @(
    'backend\scripts\NvidiaNip.Common.ps1',
    'backend\scripts\Preview-NvidiaNipProfile.ps1',
    'backend\scripts\Invoke-NvidiaNipProfile.ps1',
    'backend\scripts\Restore-NvidiaNipProfile.ps1',
    'backend\catalogs\nvidia-profile-inspector-nip-catalog.json',
    'backend\samples\nvidia-profile-catalog.sample.json'
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-nvidia-nip-contract-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $nvidiaHardware = Join-Path $tempRoot 'nvidia-hardware.json'
    $nonNvidiaHardware = Join-Path $tempRoot 'intel-hardware.json'
    $rollbackPath = Join-Path $tempRoot 'rollback.json'
    Write-HardwareFixture $nvidiaHardware $true
    Write-HardwareFixture $nonNvidiaHardware $false

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Preview-NvidiaNipProfile.ps1') -HardwareInventoryPath $nvidiaHardware -ExportPath (Join-Path $tempRoot 'before.nip'))
    if ($preview.status -eq 'preview' -and $preview.dryRun -eq $true -and $preview.summary.willRunNvpi -eq $false -and $preview.commands.exportCurrentProfile.commandLine -match 'exportProfile' -and $preview.commands.importCandidateProfile.commandLine -match 'importProfile') {
        Add-Pass 'NVIDIA NIP preview constructs export/import NVPI commands without launching NVPI'
    } else {
        Add-Failure 'NVIDIA NIP preview did not expose the expected no-launch command contract'
    }
    $hardwareGate = @($preview.gates | Where-Object { $_.gateId -eq 'nvidia-hardware-present' }) | Select-Object -First 1
    $exportGate = @($preview.gates | Where-Object { $_.gateId -eq 'export-before-import' }) | Select-Object -First 1
    if ($hardwareGate.satisfied -eq $true -and $exportGate.blocking -eq $true -and $preview.rollbackManifest.exportBeforeImportRequired -eq $true) {
        Add-Pass 'NVIDIA NIP preview proves NVIDIA hardware gate and export-before-import rollback gate'
    } else {
        Add-Failure 'NVIDIA NIP preview did not prove hardware/export gates'
    }
    Set-Content -LiteralPath $preview.rollbackManifest.exportPath -Value 'mock exported NVIDIA profile' -Encoding UTF8
    $preview.rollbackManifest.exportCompleted = $true
    ($preview.rollbackManifest | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $rollbackPath -Encoding UTF8

    $blockedHardware = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Preview-NvidiaNipProfile.ps1') -HardwareInventoryPath $nonNvidiaHardware -ExportPath (Join-Path $tempRoot 'before-intel.nip'))
    if ($blockedHardware.status -eq 'blocked' -and $blockedHardware.hardwareGate.nvidiaGpuPresent -eq $false) {
        Add-Pass 'NVIDIA NIP preview blocks non-NVIDIA hardware'
    } else {
        Add-Failure 'NVIDIA NIP preview did not block non-NVIDIA hardware'
    }

    $applyOutput = & (Join-Path $PSScriptRoot 'Invoke-NvidiaNipProfile.ps1') -HardwareInventoryPath $nvidiaHardware -ConfirmApply
    $applyBlocked = ConvertFrom-ScriptJson $applyOutput
    if ($applyBlocked.status -eq 'blocked' -and $applyBlocked.summary.willRunNvpi -eq $false -and $applyBlocked.capabilities.nvpiProcessLaunchImplemented -eq $false) {
        Add-Pass 'NVIDIA NIP confirmed apply stays blocked without future flag, export, approval, benchmark, and executor'
    } else {
        Add-Failure 'NVIDIA NIP confirmed apply was not blocked as expected'
    }

    $restore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-NvidiaNipProfile.ps1') -RollbackManifestPath $rollbackPath -HardwareInventoryPath $nvidiaHardware)
    if ($restore.status -eq 'preview' -and $restore.summary.willRunNvpi -eq $false -and $restore.summary.restoreSupported -eq $true -and $restore.command.commandLine -match 'importProfile') {
        Add-Pass 'NVIDIA NIP restore preview constructs a manifest-bound rollback import command without launching NVPI'
    } else {
        Add-Failure 'NVIDIA NIP restore preview did not expose the expected rollback command'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'NVIDIA NIP disposable validation fixtures were cleaned up'
    } else {
        Add-Failure 'NVIDIA NIP disposable validation fixtures remain'
    }
} catch {
    Add-Failure "NVIDIA NIP execution contract validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after NVIDIA NIP execution contract validation'
} else {
    Add-Failure "backend/state is not empty or changed during NVIDIA NIP validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'NVIDIA NIP validation did not launch NVIDIA Profile Inspector or import a NIP file'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS NVIDIA NIP execution contract validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL NVIDIA NIP execution contract validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
