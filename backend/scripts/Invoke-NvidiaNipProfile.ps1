param(
    [string]$ProfileId = 'base-profile',
    [string]$CatalogPath = '',
    [string]$HardwareInventoryPath = '',
    [string]$NvpiExecutablePath = '',
    [string]$NipSourcePath = '',
    [string]$ExportPath = '',
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowFutureNvpiExecution,
    [switch]$ExportCompleted,
    [switch]$UserApproved,
    [switch]$BenchmarkEvidenceAttached
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NvidiaNip.Common.ps1')

try {
    $preview = (& (Join-Path $PSScriptRoot 'Preview-NvidiaNipProfile.ps1') `
        -ProfileId $ProfileId `
        -CatalogPath $CatalogPath `
        -HardwareInventoryPath $HardwareInventoryPath `
        -NvpiExecutablePath $NvpiExecutablePath `
        -NipSourcePath $NipSourcePath `
        -ExportPath $ExportPath) | ConvertFrom-Json

    $hardwareSatisfied = [bool](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $preview 'hardwareGate' $null) 'nvidiaGpuPresent' $false)
    $gates = @(
        (New-RooIndustriesNvidiaNipGate 'confirm-apply' 'Confirmed apply requested' $true ([bool]$ConfirmApply) 'Apply remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooIndustriesNvidiaNipGate 'nvidia-hardware-present' 'NVIDIA hardware detected' $true $hardwareSatisfied 'NIP import is blocked without detected NVIDIA hardware.' (Get-RooIndustriesPropertyValue $preview 'hardwareGate' $null)),
        (New-RooIndustriesNvidiaNipGate 'export-before-import' 'Current profile export completed' $true ([bool]$ExportCompleted) 'A verified current-profile export is required before import.' ([pscustomobject]@{ exportPath = Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $preview 'rollbackManifest' $null) 'exportPath' $null })),
        (New-RooIndustriesNvidiaNipGate 'explicit-user-approval' 'Explicit user approval captured' $true ([bool]$UserApproved) 'A future executor must capture exact-profile approval.' $null),
        (New-RooIndustriesNvidiaNipGate 'future-nvpi-execution-flag' 'Future NVPI execution flag supplied' $true ([bool]$AllowFutureNvpiExecution) 'Real NVIDIA Profile Inspector execution is blocked unless an explicit future flag is supplied.' $null),
        (New-RooIndustriesNvidiaNipGate 'local-benchmark-evidence' 'Benchmark evidence attached' $true ([bool]$BenchmarkEvidenceAttached) 'Profile imports require benchmark evidence before recommendation.' $null),
        (New-RooIndustriesNvidiaNipGate 'nvpi-executor-implemented' 'NVPI process executor implemented' $true $false 'This backend has command and rollback scaffolding only; it intentionally contains no NVPI process launch path.' $null)
    )
    $blockingGateCount = @($gates | Where-Object { $_.blocking }).Count

    $result = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.applyProfile'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        profileId = $ProfileId
        dryRun = (-not $ConfirmApply)
        status = if ($blockingGateCount -gt 0) { 'blocked' } else { 'ready-for-future-executor' }
        executionMode = if ($AllowFutureNvpiExecution) { 'future-flag-scaffold' } else { 'blocked-without-future-flag' }
        preview = $preview
        commands = Get-RooIndustriesPropertyValue $preview 'commands' $null
        rollbackManifest = Get-RooIndustriesPropertyValue $preview 'rollbackManifest' $null
        gates = @($gates)
        capabilities = [pscustomobject]@{
            commandConstructionReady = $true
            rollbackManifestReady = $true
            nvpiProcessLaunchImplemented = $false
            realNvpiExecutionAllowedNow = $false
            autoApplyAllowed = $false
        }
        summary = [pscustomobject]@{
            willRunNvpi = $false
            willImportProfile = $false
            willExportProfile = $false
            willWriteState = $false
            blockingGateCount = $blockingGateCount
            noAutoApply = $true
        }
        warnings = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_APPLY_BLOCKED' 'NVIDIA profile apply is contract-ready but process execution is blocked in this build.' 'warning' $ProfileId $true 'Keep NVPI execution disabled until a future audited executor is explicitly enabled.' $null))
        errors = @()
        logs = @((New-RooIndustriesLog 'NVIDIA NIP apply contract evaluated without process launch.'))
    }

    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.applyProfile'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        profileId = $ProfileId
        dryRun = (-not $ConfirmApply)
        status = 'failed'
        executionMode = 'blocked'
        summary = [pscustomobject]@{ willRunNvpi = $false; willImportProfile = $false; willWriteState = $false }
        warnings = @()
        errors = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_APPLY_FAILED' $_.Exception.Message 'error' $ProfileId $true 'Check profile inputs and retry preview.' $null))
        logs = @((New-RooIndustriesLog 'NVIDIA NIP apply contract failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
