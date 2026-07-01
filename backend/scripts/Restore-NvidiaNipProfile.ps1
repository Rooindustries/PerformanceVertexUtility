param(
    [string]$RollbackManifestPath = '',
    [string]$ProfileId = 'framesync',
    [string]$CatalogPath = '',
    [string]$HardwareInventoryPath = '',
    [string]$NvpiExecutablePath = '',
    [string]$ExportPath = '',
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowFutureNvpiExecution,
    [switch]$UserApproved
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NvidiaNip.Common.ps1')

try {
    $catalog = Read-RooNvidiaNipCatalog $CatalogPath
    $profile = Get-RooNvidiaNipProfile $catalog $ProfileId
    $profileName = [string](Get-RooPropertyValue $profile 'profileNameInNip' (Get-RooPropertyValue $profile 'name' $ProfileId))
    $manifest = $null
    if (-not [string]::IsNullOrWhiteSpace($RollbackManifestPath)) {
        $manifest = Read-RooJsonFile (Resolve-RooPath $RollbackManifestPath $RollbackManifestPath)
        if ([string]::IsNullOrWhiteSpace($ExportPath)) {
            $ExportPath = [string](Get-RooPropertyValue $manifest 'exportPath' '')
        }
    }
    if ([string]::IsNullOrWhiteSpace($NvpiExecutablePath)) {
        $NvpiExecutablePath = [string](Get-RooPropertyValue (Get-RooPropertyValue $catalog 'toolAsset' $null) 'archivePath' 'Utilities\Other\NVPI\nvidiaProfileInspector.exe')
    }
    if ([string]::IsNullOrWhiteSpace($ExportPath)) {
        $ExportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("roo-nvidia-nip-export-{0}-restore-source.nip" -f (ConvertTo-RooNvidiaSafeId $ProfileId))
    }

    $hardware = Get-RooNvidiaHardwareEvidence $HardwareInventoryPath
    $restoreCommand = New-RooNvidiaNipCommand -Operation 'import' -ExecutablePath $NvpiExecutablePath -ProfileName $profileName -NipPath $ExportPath -ExportPath $ExportPath
    $gates = @(
        (New-RooNvidiaNipGate 'confirm-restore' 'Confirmed restore requested' $true ([bool]$ConfirmApply) 'Restore remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooNvidiaNipGate 'nvidia-hardware-present' 'NVIDIA hardware detected' $true ([bool]$hardware.nvidiaGpuPresent) 'NIP restore is blocked without detected NVIDIA hardware.' $hardware),
        (New-RooNvidiaNipGate 'rollback-export-present' 'Rollback export path supplied' $true (-not [string]::IsNullOrWhiteSpace($ExportPath)) 'A previous export path is required for restore.' ([pscustomobject]@{ exportPath = $ExportPath })),
        (New-RooNvidiaNipGate 'explicit-user-approval' 'Explicit restore approval captured' $true ([bool]$UserApproved) 'A future restore executor must capture approval.' $null),
        (New-RooNvidiaNipGate 'future-nvpi-execution-flag' 'Future NVPI execution flag supplied' $true ([bool]$AllowFutureNvpiExecution) 'Real NVIDIA Profile Inspector execution is blocked unless an explicit future flag is supplied.' $null),
        (New-RooNvidiaNipGate 'nvpi-executor-implemented' 'NVPI process executor implemented' $true $false 'This backend has restore command scaffolding only; it intentionally contains no NVPI process launch path.' $null)
    )
    $blockingGateCount = @($gates | Where-Object { $_.blocking }).Count

    $result = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.restoreProfile'
        schemaVersion = 1
        productName = $script:RooNvidiaNipProductName
        capturedAtUtc = Get-RooUtcStamp
        profileId = $ProfileId
        dryRun = (-not $ConfirmApply)
        status = if ($blockingGateCount -gt 0) { if ($ConfirmApply) { 'blocked' } else { 'preview' } } else { 'ready-for-future-executor' }
        executionMode = if ($AllowFutureNvpiExecution) { 'future-flag-scaffold' } else { 'preview-or-blocked' }
        rollbackManifest = $manifest
        command = $restoreCommand
        gates = @($gates)
        summary = [pscustomobject]@{
            willRunNvpi = $false
            willImportProfile = $false
            willWriteState = $false
            blockingGateCount = $blockingGateCount
            restoreSupported = $true
        }
        warnings = @((New-RooNvidiaNipIssue 'NVIDIA_NIP_RESTORE_PREVIEW_ONLY' 'NVIDIA profile restore command metadata was built without launching NVIDIA Profile Inspector.' 'info' $ProfileId $false 'Review the rollback export before any future explicitly-enabled restore executor.' $null))
        errors = @()
        logs = @((New-RooLog 'NVIDIA NIP restore contract evaluated without process launch.'))
    }

    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.restoreProfile'
        schemaVersion = 1
        productName = $script:RooNvidiaNipProductName
        capturedAtUtc = Get-RooUtcStamp
        profileId = $ProfileId
        dryRun = (-not $ConfirmApply)
        status = 'failed'
        executionMode = 'blocked'
        summary = [pscustomobject]@{ willRunNvpi = $false; willImportProfile = $false; willWriteState = $false }
        warnings = @()
        errors = @((New-RooNvidiaNipIssue 'NVIDIA_NIP_RESTORE_FAILED' $_.Exception.Message 'error' $ProfileId $true 'Check rollback manifest or export path.' $null))
        logs = @((New-RooLog 'NVIDIA NIP restore contract failed.' 'error'))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
