param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]
$evidence = [ordered]@{ schemaVersion = 1; test = 'nvidia-probe-path'; cases = [ordered]@{} }
if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $EvidencePath = Join-Path $repoRoot 'artifacts\validation\nvidia-probe-path.json' }

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
    param(
        [string]$Path,
        [switch]$SleepOnHelp
    )
    $sleepValue = if ($SleepOnHelp) { 'true' } else { 'false' }
    $source = @"
using System;
using System.IO;
using System.Threading;
public static class Program {
    public static int Main(string[] args) {
        bool sleepOnHelp = String.Equals("__SLEEP_ON_HELP__", "true", StringComparison.OrdinalIgnoreCase);
        Console.WriteLine("shim-stdout:" + string.Join("|", args));
        Console.Error.WriteLine("shim-stderr:" + args.Length.ToString());
        if (sleepOnHelp && args.Length > 0 && args[0] == "-?") {
            Thread.Sleep(5000);
            return 0;
        }
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
    $source = $source.Replace('__SLEEP_ON_HELP__', $sleepValue)
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-nvidia-nip-capability-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $shimExe = Join-Path $tempRoot 'NvpiShim.exe'
    $timeoutShimExe = Join-Path $tempRoot 'NvpiTimeoutShim.exe'
    New-NvpiConsoleShim $shimExe
    New-NvpiConsoleShim $timeoutShimExe -SleepOnHelp
    $exportPath = Join-Path $tempRoot 'readonly-export.nip'

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -NvpiExecutablePath $shimExe -ExportPath $exportPath)
    if ($preview.status -eq 'preview' -and $preview.summary.processRunnerInvoked -eq $false) {
        Add-Pass 'NVIDIA capability probe defaults to no-launch preview'
    } else {
        Add-Failure 'NVIDIA capability probe default call launched or did not preview'
    }

    $success = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -NvpiExecutablePath $shimExe -ExportPath $exportPath -AllowReadOnlyNvpiProbe -PreserveProbeArtifacts)
    if ($success.status -eq 'success' -and $success.capabilities.realNvpiProcessRunnerImplemented -eq $true -and $success.capabilities.elevationHelperExists -eq $true -and $success.capabilities.realNvpiHelpProbeAttempted -eq $true -and $success.capabilities.realNvpiExportProbeAttempted -eq $true -and $success.capabilities.realNvpiExportSucceeded -eq $true -and $success.capabilities.realNvpiImportAttempted -eq $false -and $success.summary.focusStealPrevented -eq $true -and $success.summary.stdoutCaptured -eq $true -and $success.summary.stderrCaptured -eq $true -and (Test-Path -LiteralPath $exportPath)) {
        Add-Pass 'NVIDIA capability probe runs real hidden process help/export checks and captures stdout/stderr without import'
    } else {
        Add-Failure 'NVIDIA capability probe did not prove real hidden help/export capability'
    }

    $catalog = Get-Content -LiteralPath (Join-Path $repoRoot 'backend\catalogs\nvidia-profile-inspector-nip-catalog.json') -Raw | ConvertFrom-Json
    $catalog.toolAsset.archivePath = $shimExe
    $catalogPath = Join-Path $tempRoot 'catalog.json'
    $catalog | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $catalogPath -Encoding UTF8
    $catalogExportPath = Join-Path $tempRoot 'catalog-export.nip'
    $catalogProbe = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -CatalogPath $catalogPath -ExportPath $catalogExportPath -AllowReadOnlyNvpiProbe -PreserveProbeArtifacts)
    $toolGate = @($catalogProbe.gates | Where-Object { $_.gateId -eq 'nvpi-tool-exists' })
    $evidence.cases['catalog-tool'] = $catalogProbe
    if ($catalogProbe.status -eq 'success' -and $toolGate.Count -eq 1 -and $toolGate[0].satisfied -eq $true -and -not $toolGate[0].blocking -and
        $catalogProbe.nvpiExecutablePath -eq $shimExe -and @($catalogProbe.executionSequence).Count -eq 2 -and
        $catalogProbe.executionSequence[0].probe -eq 'help' -and $catalogProbe.executionSequence[1].probe -eq 'export-current-profile' -and
        $catalogProbe.capabilities.realNvpiHelpProbeAttempted -eq $true -and $catalogProbe.capabilities.realNvpiExportProbeAttempted -eq $true -and
        $catalogProbe.capabilities.realNvpiImportAttempted -eq $false -and (Test-Path -LiteralPath $catalogExportPath -PathType Leaf)) {
        Add-Pass 'NVIDIA capability probe uses the catalog tool path when no executable override is supplied'
    } else { Add-Failure 'NVIDIA capability probe must use the catalog tool path when no executable override is supplied' }

    $catalog.toolAsset.archivePath = Join-Path $tempRoot 'missing-nvpi.exe'
    $catalog | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $catalogPath -Encoding UTF8
    $missingCatalogProbe = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -CatalogPath $catalogPath -ExportPath (Join-Path $tempRoot 'missing-export.nip') -AllowReadOnlyNvpiProbe)
    $toolGate = @($missingCatalogProbe.gates | Where-Object { $_.gateId -eq 'nvpi-tool-exists' })
    $evidence.cases['missing-catalog-tool'] = $missingCatalogProbe
    if ($missingCatalogProbe.status -eq 'approval-or-input-required' -and $toolGate.Count -eq 1 -and $toolGate[0].blocking -eq $true -and
        $toolGate[0].satisfied -eq $false -and @($missingCatalogProbe.executionSequence).Count -eq 0 -and
        $missingCatalogProbe.summary.processRunnerInvoked -eq $false -and $missingCatalogProbe.capabilities.realNvpiImportAttempted -eq $false) {
        Add-Pass 'NVIDIA capability probe blocks a missing catalog tool without running any process'
    } else { Add-Failure 'NVIDIA capability probe must block a missing catalog tool without running any process' }

    $outsidePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('roo-industries-rejected-export-' + [guid]::NewGuid().ToString('N') + '.nip')
    $blockedPath = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -NvpiExecutablePath $shimExe -ExportPath $outsidePath -AllowReadOnlyNvpiProbe)
    $tempGate = @($blockedPath.gates | Where-Object { $_.gateId -eq 'export-path-temp' }) | Select-Object -First 1
    if ($blockedPath.status -eq 'approval-or-input-required' -and $tempGate.blocking -eq $true -and $blockedPath.summary.processRunnerInvoked -eq $false) {
        Add-Pass 'NVIDIA capability probe blocks export paths outside temp'
    } else {
        Add-Failure 'NVIDIA capability probe did not block unsafe export path'
    }

    $timeoutExportPath = Join-Path $tempRoot 'timeout-export.nip'
    $timeout = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -NvpiExecutablePath $timeoutShimExe -ExportPath $timeoutExportPath -AllowReadOnlyNvpiProbe -TimeoutSeconds 1 -PreserveProbeArtifacts)
    if ($timeout.status -in @('success','probe-incomplete','cli-unsupported') -and $timeout.summary.timeoutCount -ge 1 -and $timeout.summary.noImportAttempted -eq $true -and $timeout.summary.focusStealPrevented -eq $true) {
        Add-Pass 'NVIDIA capability probe captures timeout evidence without attempting import'
    } else {
        Add-Failure 'NVIDIA capability probe did not capture timeout evidence'
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

$evidence.scriptSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') -Algorithm SHA256).Hash
$evidence.passes = @($passes.ToArray()); $evidence.failures = @($failures.ToArray())
$evidence.stateBefore = $stateBefore; $evidence.stateAfter = $stateAfter; $evidence.fixturesRemoved = -not (Test-Path -LiteralPath $tempRoot)
[IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($EvidencePath)) -Parent)) | Out-Null
$evidence | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
Write-Host "Evidence: $EvidencePath"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS NVIDIA NIP capability probe validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL NVIDIA NIP capability probe validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
