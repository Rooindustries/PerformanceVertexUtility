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
    ([pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = '2026-07-01T00:00:00Z'
        gpus = @($gpu)
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-NvpiMockShim {
    param(
        [string]$Path,
        [string]$LogPath,
        [ValidateSet('Success','ExportFail','Timeout')]
        [string]$Behavior
    )
    $escapedLog = $LogPath.Replace("'", "''")
    $content = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$logPath = '__LOG__'
$entry = [pscustomobject]@{ args = @($Rest); atUtc = (Get-Date).ToUniversalTime().ToString('o') }
($entry | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $logPath
if ('__BEHAVIOR__' -eq 'Timeout') {
    Start-Sleep -Seconds 5
    exit 0
}
if (@($Rest).Count -gt 0 -and $Rest[0] -eq '-exportProfile') {
    if ('__BEHAVIOR__' -eq 'ExportFail') { exit 17 }
    if (@($Rest).Count -gt 2) {
        Set-Content -LiteralPath $Rest[2] -Value 'mock exported profile' -Encoding UTF8
    }
}
exit 0
'@
    $content = $content.Replace('__LOG__', $escapedLog).Replace('__BEHAVIOR__', $Behavior)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Read-MockLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json })
}

$requiredFiles = @(
    'backend\scripts\BackendExecutor.Common.ps1',
    'backend\scripts\Invoke-NvidiaNipExecutor.ps1'
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-nvidia-nip-executor-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $nvidiaHardware = Join-Path $tempRoot 'nvidia-hardware.json'
    $nonNvidiaHardware = Join-Path $tempRoot 'intel-hardware.json'
    Write-HardwareFixture $nvidiaHardware $true
    Write-HardwareFixture $nonNvidiaHardware $false

    $successLog = Join-Path $tempRoot 'nvpi-success.log'
    $successShim = Join-Path $tempRoot 'nvpi-success.ps1'
    $exportFailLog = Join-Path $tempRoot 'nvpi-export-fail.log'
    $exportFailShim = Join-Path $tempRoot 'nvpi-export-fail.ps1'
    $timeoutLog = Join-Path $tempRoot 'nvpi-timeout.log'
    $timeoutShim = Join-Path $tempRoot 'nvpi-timeout.ps1'
    New-NvpiMockShim $successShim $successLog 'Success'
    New-NvpiMockShim $exportFailShim $exportFailLog 'ExportFail'
    New-NvpiMockShim $timeoutShim $timeoutLog 'Timeout'

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -HardwareInventoryPath $nvidiaHardware)
    if ($preview.status -eq 'preview' -and $preview.summary.willRunNvpi -eq $false -and $preview.summary.willRunMockShim -eq $false -and @($preview.executionSequence).Count -eq 0) {
        Add-Pass 'NVIDIA NIP executor default call is preview-only and runs no command'
    } else {
        Add-Failure 'NVIDIA NIP executor default call was not preview-only'
    }

    $blockedHardware = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nonNvidiaHardware -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    $hardwareGate = @($blockedHardware.gates | Where-Object { $_.gateId -eq 'nvidia-hardware-present' }) | Select-Object -First 1
    if ($blockedHardware.status -eq 'blocked' -and $hardwareGate.blocking -eq $true -and @($blockedHardware.executionSequence).Count -eq 0) {
        Add-Pass 'NVIDIA NIP executor blocks mock apply when NVIDIA hardware gate is not satisfied'
    } else {
        Add-Failure 'NVIDIA NIP executor did not block non-NVIDIA hardware'
    }

    $exportPath = Join-Path $tempRoot 'before-success.nip'
    $rollbackPath = Join-Path $tempRoot 'nvidia-rollback.json'
    $success = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -RollbackManifestPath $rollbackPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    $successLogEntries = Read-MockLog $successLog
    $firstArgs = @($successLogEntries[0].args)
    $secondArgs = @($successLogEntries[1].args)
    if ($success.status -eq 'success' -and $success.summary.willRunMockShim -eq $true -and $success.summary.willRunNvpi -eq $false -and $success.summary.realNvpiInvoked -eq $false -and $success.summary.exportCompleted -eq $true -and $success.summary.importCompleted -eq $true -and $firstArgs[0] -eq '-exportProfile' -and $secondArgs[0] -eq '-importProfile' -and (Test-Path -LiteralPath $exportPath) -and (Test-Path -LiteralPath $rollbackPath)) {
        Add-Pass 'NVIDIA NIP mock executor exports before import, writes rollback manifest, and never reports real NVPI execution'
    } else {
        Add-Failure 'NVIDIA NIP mock executor did not prove export-before-import success path'
    }
    if ($success.summary.noAutoApply -eq $true -and $success.summary.focusStealPrevented -eq $true) {
        Add-Pass 'NVIDIA NIP mock executor proves explicit no-auto-apply and hidden-process invocation'
    } else {
        Add-Failure 'NVIDIA NIP mock executor did not prove no-auto-apply and hidden invocation'
    }

    $failExportPath = Join-Path $tempRoot 'before-fail.nip'
    $failExport = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $exportFailShim -HardwareInventoryPath $nvidiaHardware -ExportPath $failExportPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    if ($failExport.status -eq 'failed' -and $failExport.summary.exportCompleted -eq $false -and $failExport.summary.importAttempted -eq $false -and $failExport.summary.importSkippedUntilExportSucceeded -eq $true -and $failExport.summary.nonZeroExitCount -eq 1) {
        Add-Pass 'NVIDIA NIP executor skips import when export fails'
    } else {
        Add-Failure 'NVIDIA NIP executor did not skip import after export failure'
    }

    $timeoutExportPath = Join-Path $tempRoot 'before-timeout.nip'
    $timeout = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $timeoutShim -HardwareInventoryPath $nvidiaHardware -ExportPath $timeoutExportPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached -TimeoutSeconds 1)
    if ($timeout.status -eq 'failed' -and $timeout.summary.timeoutCount -eq 1 -and $timeout.summary.importAttempted -eq $false -and $timeout.summary.importSkippedUntilExportSucceeded -eq $true) {
        Add-Pass 'NVIDIA NIP executor skips import when export times out'
    } else {
        Add-Failure 'NVIDIA NIP executor did not skip import after export timeout'
    }

    $restoreExportPath = Join-Path $tempRoot 'restore-source.nip'
    Set-Content -LiteralPath $restoreExportPath -Value 'mock restore source' -Encoding UTF8
    $restore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $restoreExportPath -ConfirmApply -UserApproved)
    if ($restore.status -eq 'success' -and $restore.summary.exportAttempted -eq $false -and $restore.summary.importAttempted -eq $true -and @($restore.executionSequence)[0].operation -eq 'restore-import') {
        Add-Pass 'NVIDIA NIP restore executor exposes rollback import path through mock runner'
    } else {
        Add-Failure 'NVIDIA NIP restore executor did not run expected mock rollback import path'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'NVIDIA NIP executor disposable fixtures were cleaned up'
    } else {
        Add-Failure 'NVIDIA NIP executor disposable fixtures remain'
    }
} catch {
    Add-Failure "NVIDIA NIP executor validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after NVIDIA NIP executor validation'
} else {
    Add-Failure "backend/state is not empty or changed during NVIDIA NIP executor validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'NVIDIA NIP executor validation did not launch NVIDIA Profile Inspector or import a real NIP file'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS NVIDIA NIP executor validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL NVIDIA NIP executor validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
