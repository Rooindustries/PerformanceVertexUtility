param(
    [string]$ProfileId = 'base-profile',
    [string]$CatalogPath = '',
    [string]$NvpiExecutablePath = '',
    [string]$ExportPath = '',
    [int]$TimeoutSeconds = 10,
    [string]$OutputPath = '',
    [switch]$AllowReadOnlyNvpiProbe,
    [switch]$PreserveProbeArtifacts
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NvidiaNip.Common.ps1')
. (Join-Path $PSScriptRoot 'BackendExecutor.Common.ps1')

function Test-NvidiaProbePathInsideTemp {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Path).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-NvidiaFileVersionEvidence {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        path = $item.FullName
        exists = $true
        sizeBytes = [uint64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        productVersion = $item.VersionInfo.ProductVersion
        fileVersion = $item.VersionInfo.FileVersion
        companyName = $item.VersionInfo.CompanyName
    }
}

try {
    $catalog = Read-RooIndustriesNvidiaNipCatalog $CatalogPath
    $profile = Get-RooIndustriesNvidiaNipProfile $catalog $ProfileId
    $profileName = [string](Get-RooIndustriesPropertyValue $profile 'profileNameInNip' (Get-RooIndustriesPropertyValue $profile 'name' 'Base Profile'))
    $resolvedNvpi = if ([string]::IsNullOrWhiteSpace($NvpiExecutablePath)) { '' } else { Resolve-RooIndustriesPath $NvpiExecutablePath $NvpiExecutablePath }
    $toolExists = (-not [string]::IsNullOrWhiteSpace($resolvedNvpi) -and (Test-Path -LiteralPath $resolvedNvpi -PathType Leaf))

    $createdProbeRoot = $false
    if ([string]::IsNullOrWhiteSpace($ExportPath)) {
        $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('roo-industries-nvidia-nip-readonly-probe-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
        $createdProbeRoot = $true
        $resolvedExportPath = Join-Path $probeRoot 'current-profile-export.nip'
    } else {
        $resolvedExportPath = Resolve-RooIndustriesPath $ExportPath $ExportPath
        $probeRoot = Split-Path $resolvedExportPath -Parent
    }

    $exportPathInsideTemp = Test-NvidiaProbePathInsideTemp $resolvedExportPath
    $exportExtensionSafe = ([System.IO.Path]::GetExtension($resolvedExportPath) -ieq '.nip')
    $gates = @(
        (New-RooIndustriesBackendExecutorGate 'read-only-probe-flag' 'Read-only NVPI probe explicitly allowed' $true ([bool]$AllowReadOnlyNvpiProbe) 'Real NVPI process probes require -AllowReadOnlyNvpiProbe.' $null),
        (New-RooIndustriesBackendExecutorGate 'nvpi-tool-exists' 'NVPI executable exists' $true $toolExists 'A local NVIDIA Profile Inspector executable is required for real process probing.' ([pscustomobject]@{ nvpiExecutablePath = $resolvedNvpi })),
        (New-RooIndustriesBackendExecutorGate 'export-path-temp' 'Probe export path is under temp' $true $exportPathInsideTemp 'Read-only export probes must write only to a temp path.' ([pscustomobject]@{ exportPath = $resolvedExportPath })),
        (New-RooIndustriesBackendExecutorGate 'export-extension-nip' 'Probe export uses .nip extension' $true $exportExtensionSafe 'Export probe output must be a .nip file.' ([pscustomobject]@{ exportPath = $resolvedExportPath })),
        (New-RooIndustriesBackendExecutorGate 'real-import-forbidden' 'Real NVPI import is not part of capability probe' $true $true 'Capability probing never calls -importProfile.' $null)
    )
    $blockingGates = @($gates | Where-Object { $_.blocking })
    $canProbe = ($blockingGates.Count -eq 0)
    $runs = New-Object System.Collections.Generic.List[object]
    $exportEvidence = $null

    if ($canProbe) {
        Ensure-RooIndustriesDirectory (Split-Path $resolvedExportPath -Parent)
        $helpResult = Invoke-RooIndustriesBackendHiddenProcess -FilePath $resolvedNvpi -Arguments @('-?') -TimeoutSeconds $TimeoutSeconds
        $runs.Add([pscustomobject]@{ order = 1; probe = 'help'; arguments = @('-?'); result = $helpResult; destructive = $false }) | Out-Null

        $exportArgs = @('-exportProfile', $profileName, $resolvedExportPath)
        $exportResult = Invoke-RooIndustriesBackendHiddenProcess -FilePath $resolvedNvpi -Arguments $exportArgs -TimeoutSeconds $TimeoutSeconds
        if (Test-Path -LiteralPath $resolvedExportPath -PathType Leaf) {
            $exportItem = Get-Item -LiteralPath $resolvedExportPath
            $exportEvidence = [pscustomobject]@{
                path = $exportItem.FullName
                exists = $true
                sizeBytes = [uint64]$exportItem.Length
                sha256 = (Get-FileHash -LiteralPath $exportItem.FullName -Algorithm SHA256).Hash
                insideTemp = $exportPathInsideTemp
            }
        } else {
            $exportEvidence = [pscustomobject]@{ path = $resolvedExportPath; exists = $false; sizeBytes = 0; sha256 = $null; insideTemp = $exportPathInsideTemp }
        }
        $runs.Add([pscustomobject]@{ order = 2; probe = 'export-current-profile'; arguments = $exportArgs; result = $exportResult; destructive = $false; exportEvidence = $exportEvidence }) | Out-Null
    }

    $runArray = @($runs.ToArray())
    $exportSucceeded = ($null -ne $exportEvidence -and [bool](Get-RooIndustriesPropertyValue $exportEvidence 'exists' $false) -and @($runArray | Where-Object { $_.probe -eq 'export-current-profile' -and $_.result.timedOut -ne $true -and [int]$_.result.exitCode -eq 0 }).Count -gt 0)
    $timeoutCount = @($runArray | Where-Object { $_.result.timedOut -eq $true }).Count
    $nonZeroExitCount = @($runArray | Where-Object { $null -ne $_.result.exitCode -and [int]$_.result.exitCode -ne 0 }).Count

    $startErrors = @($runArray | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $_ 'result' $null) 'startError' '')) } | ForEach-Object { [string](Get-RooIndustriesPropertyValue $_.result 'startError' '') })
    $elevationRequired = (@($startErrors | Where-Object { $_ -match 'requires elevation|elevation|access is denied' }).Count -gt 0)
    $cliUnsupported = ($canProbe -and -not $exportSucceeded -and -not $elevationRequired -and (@($runArray | Where-Object { $null -ne $_.result.exitCode -and [int]$_.result.exitCode -ne 0 }).Count -gt 0))
    $status = if (-not $canProbe) {
        if ($AllowReadOnlyNvpiProbe) { 'approval-or-input-required' } else { 'preview' }
    } elseif ($exportSucceeded) {
        'success'
    } elseif ($elevationRequired) {
        'requires-elevation'
    } elseif ($cliUnsupported) {
        'cli-unsupported'
    } else {
        'probe-incomplete'
    }

    $elevationHelperPath = Join-Path $PSScriptRoot 'Invoke-NvidiaNipElevatedReadOnlyProbeHelper.ps1'
    $nextStep = if ($exportSucceeded) {
        'Use this runner layer for export-before-import validation; keep -importProfile behind future explicit approval.'
    } elseif (-not $toolExists) {
        'Provide a valid NVIDIA Profile Inspector executable path and rerun the read-only probe.'
    } elseif ($elevationRequired) {
        "Run the read-only NVPI capability probe through the elevated helper path: $elevationHelperPath"
    } elseif ($cliUnsupported) {
        'The NVPI executable started but the CLI probe did not support the expected help/export flags; inspect captured stdout/stderr/exit codes and update the CLI adapter.'
    } else {
        'Inspect captured help/export stdout, stderr, exit code, and timeout evidence; update NVPI CLI arguments if this NVPI build uses different flags.'
    }

    $result = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.capabilityProbe'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        profileId = $ProfileId
        dryRun = (-not $canProbe)
        status = $status
        executionMode = if ($canProbe) { 'real-readonly-probe' } else { 'preview-or-blocked' }
        nvpiExecutablePath = $resolvedNvpi
        exportPath = $resolvedExportPath
        gates = @($gates)
        fileVersion = Get-NvidiaFileVersionEvidence $resolvedNvpi
        executionSequence = $runArray
        capabilities = [pscustomobject]@{
            realNvpiProcessRunnerImplemented = $true
            realNvpiHelpProbeAttempted = @($runArray | Where-Object { $_.probe -eq 'help' }).Count -gt 0
            realNvpiExportProbeAttempted = @($runArray | Where-Object { $_.probe -eq 'export-current-profile' }).Count -gt 0
            realNvpiExportSucceeded = $exportSucceeded
            realNvpiImportImplementedButGated = $true
            realNvpiImportAttempted = $false
            elevationHelperPath = $elevationHelperPath
            elevationHelperExists = (Test-Path -LiteralPath $elevationHelperPath -PathType Leaf)
            elevationRequired = $elevationRequired
            cliUnsupported = $cliUnsupported
        }
        summary = [pscustomobject]@{
            processRunnerInvoked = ($runArray.Count -gt 0)
            exportFileCreated = [bool](Get-RooIndustriesPropertyValue $exportEvidence 'exists' $false)
            timeoutCount = $timeoutCount
            nonZeroExitCount = $nonZeroExitCount
            startErrorCount = $startErrors.Count
            startErrors = @($startErrors)
            stdoutCaptured = @($runArray | Where-Object { -not [string]::IsNullOrEmpty([string]$_.result.stdout) }).Count -gt 0
            stderrCaptured = @($runArray | Where-Object { -not [string]::IsNullOrEmpty([string]$_.result.stderr) }).Count -gt 0
            focusStealPrevented = (@($runArray | Where-Object { $_.result.invocation.focusStealPrevented -eq $false }).Count -eq 0)
            noImportAttempted = $true
            blockingGateCount = $blockingGates.Count
            nextEngineeringStep = $nextStep
        }
        warnings = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_REAL_READONLY_PROBE' 'Real NVPI process probing is limited to help/version/export checks and never imports a profile.' 'info' $ProfileId $false $nextStep $null))
        errors = @()
        logs = @((New-RooIndustriesLog 'NVIDIA NIP real read-only capability probe completed.'))
    }

    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.capabilityProbe'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        profileId = $ProfileId
        dryRun = $true
        status = 'failed'
        executionMode = 'blocked'
        executionSequence = @()
        summary = [pscustomobject]@{ processRunnerInvoked = $false; noImportAttempted = $true; nextEngineeringStep = 'Check NVPI path, export path, probe permissions, and timeout.' }
        warnings = @()
        errors = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_CAPABILITY_PROBE_FAILED' $_.Exception.Message 'error' $ProfileId $true 'Check NVPI path, export path, probe permissions, and timeout.' $null))
        logs = @((New-RooIndustriesLog 'NVIDIA NIP real read-only capability probe failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
} finally {
    if ($createdProbeRoot -and -not $PreserveProbeArtifacts -and -not [string]::IsNullOrWhiteSpace($probeRoot) -and (Test-Path -LiteralPath $probeRoot)) {
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
