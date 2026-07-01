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

function New-NvpiConsoleShim {
    param([string]$Path)
    $source = @"
using System;
using System.IO;
public static class Program {
    public static int Main(string[] args) {
        Console.WriteLine("shim-stdout:" + string.Join("|", args));
        Console.Error.WriteLine("shim-stderr:" + args.Length.ToString());
        if (args.Length > 0 && args[0] == "-exportProfile") {
            if (args.Length < 3) { return 64; }
            File.WriteAllText(args[2], "mock exported profile");
            return 0;
        }
        if (args.Length > 0 && args[0] == "-?") { return 0; }
        return 2;
    }
}
"@
    Add-Type -TypeDefinition $source -OutputAssembly $Path -OutputType ConsoleApplication -ErrorAction Stop
}

$requiredFiles = @(
    'backend\scripts\BackendExecutor.Common.ps1',
    'backend\scripts\Invoke-NvidiaNipCapabilityProbe.ps1'
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-nvidia-nip-capability-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $shimExe = Join-Path $tempRoot 'NvpiShim.exe'
    New-NvpiConsoleShim $shimExe
    $exportPath = Join-Path $tempRoot 'readonly-export.nip'

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -NvpiExecutablePath $shimExe -ExportPath $exportPath)
    if ($preview.status -eq 'preview' -and $preview.summary.processRunnerInvoked -eq $false) {
        Add-Pass 'NVIDIA capability probe defaults to no-launch preview'
    } else {
        Add-Failure 'NVIDIA capability probe default call launched or did not preview'
    }

    $success = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -NvpiExecutablePath $shimExe -ExportPath $exportPath -AllowReadOnlyNvpiProbe -PreserveProbeArtifacts)
    if ($success.status -eq 'success' -and $success.capabilities.realNvpiProcessRunnerImplemented -eq $true -and $success.capabilities.realNvpiHelpProbeAttempted -eq $true -and $success.capabilities.realNvpiExportProbeAttempted -eq $true -and $success.capabilities.realNvpiExportSucceeded -eq $true -and $success.capabilities.realNvpiImportAttempted -eq $false -and $success.summary.focusStealPrevented -eq $true -and $success.summary.stdoutCaptured -eq $true -and $success.summary.stderrCaptured -eq $true -and (Test-Path -LiteralPath $exportPath)) {
        Add-Pass 'NVIDIA capability probe runs real hidden process help/export checks and captures stdout/stderr without import'
    } else {
        Add-Failure 'NVIDIA capability probe did not prove real hidden help/export capability'
    }

    $outsidePath = Join-Path $repoRoot 'not-temp-export.nip'
    $blockedPath = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -NvpiExecutablePath $shimExe -ExportPath $outsidePath -AllowReadOnlyNvpiProbe)
    $tempGate = @($blockedPath.gates | Where-Object { $_.gateId -eq 'export-path-temp' }) | Select-Object -First 1
    if ($blockedPath.status -eq 'blocked' -and $tempGate.blocking -eq $true -and $blockedPath.summary.processRunnerInvoked -eq $false) {
        Add-Pass 'NVIDIA capability probe blocks export paths outside temp'
    } else {
        Add-Failure 'NVIDIA capability probe did not block unsafe export path'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'NVIDIA capability probe disposable fixtures were cleaned up'
    } else {
        Add-Failure 'NVIDIA capability probe disposable fixtures remain'
    }
} catch {
    Add-Failure "NVIDIA capability probe validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after NVIDIA capability probe validation'
} else {
    Add-Failure "backend/state is not empty or changed during NVIDIA capability probe validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'NVIDIA capability probe validation did not invoke real NVPI import'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS NVIDIA NIP capability probe validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL NVIDIA NIP capability probe validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
