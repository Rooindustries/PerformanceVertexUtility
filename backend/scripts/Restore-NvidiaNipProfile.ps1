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
    $catalog = Read-RooIndustriesNvidiaNipCatalog $CatalogPath
    $profile = Get-RooIndustriesNvidiaNipProfile $catalog $ProfileId
    $profileName = [string](Get-RooIndustriesPropertyValue $profile 'profileNameInNip' (Get-RooIndustriesPropertyValue $profile 'name' $ProfileId))
    $manifest = $null
    $manifestBound = $false
    if (-not [string]::IsNullOrWhiteSpace($RollbackManifestPath)) {
        $manifest = Read-RooIndustriesJsonFile (Resolve-RooIndustriesPath $RollbackManifestPath $RollbackManifestPath)
        $manifestExportPath = [string](Get-RooIndustriesPropertyValue $manifest 'exportPath' '')
        $manifestBound = (
            [string](Get-RooIndustriesPropertyValue $manifest 'actionId' '') -ceq 'drivers.nvidiaNip.rollbackManifest' -and
            [string](Get-RooIndustriesPropertyValue $manifest 'restoreActionId' '') -ceq 'drivers.nvidiaNip.restoreProfile' -and
            [string](Get-RooIndustriesPropertyValue $manifest 'profileId' '') -ceq $ProfileId -and
            [bool](Get-RooIndustriesPropertyValue $manifest 'rollbackSupported' $false) -and
            [bool](Get-RooIndustriesPropertyValue $manifest 'exportCompleted' $false) -and
            -not [string]::IsNullOrWhiteSpace($manifestExportPath) -and
            ([string]::IsNullOrWhiteSpace($ExportPath) -or (Resolve-RooIndustriesPath $ExportPath $ExportPath) -ceq (Resolve-RooIndustriesPath $manifestExportPath $manifestExportPath))
        )
        if ([string]::IsNullOrWhiteSpace($ExportPath)) { $ExportPath = $manifestExportPath }
    }
    if ([string]::IsNullOrWhiteSpace($NvpiExecutablePath)) {
        $NvpiExecutablePath = [string](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $catalog 'toolAsset' $null) 'archivePath' 'Utilities\Other\NVPI\nvidiaProfileInspector.exe')
    }
    $exportPresent = $manifestBound -and -not [string]::IsNullOrWhiteSpace($ExportPath) -and (Test-Path -LiteralPath (Resolve-RooIndustriesPath $ExportPath $ExportPath))

    $hardware = Get-RooIndustriesNvidiaHardwareEvidence $HardwareInventoryPath
    $restoreCommand = New-RooIndustriesNvidiaNipCommand -Operation 'import' -ExecutablePath $NvpiExecutablePath -ProfileName $profileName -NipPath $ExportPath -ExportPath $ExportPath
    $gates = @(
        (New-RooIndustriesNvidiaNipGate 'confirm-restore' 'Confirmed restore requested' $true ([bool]$ConfirmApply) 'Restore remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooIndustriesNvidiaNipGate 'nvidia-hardware-present' 'NVIDIA hardware detected' $true ([bool]$hardware.nvidiaGpuPresent) 'NIP restore is blocked without detected NVIDIA hardware.' $hardware),
        (New-RooIndustriesNvidiaNipGate 'rollback-manifest-bound' 'Rollback manifest matches this profile' $true $manifestBound 'Restore requires the exact rollback manifest written by the selected profile apply.' ([pscustomobject]@{ rollbackManifestPath = $RollbackManifestPath })),
        (New-RooIndustriesNvidiaNipGate 'rollback-export-present' 'Rollback export file present' $true $exportPresent 'The rollback export named by the manifest is required for restore.' ([pscustomobject]@{ exportPath = $ExportPath })),
        (New-RooIndustriesNvidiaNipGate 'explicit-user-approval' 'Explicit restore approval captured' $true ([bool]$UserApproved) 'A future restore executor must capture approval.' $null),
        (New-RooIndustriesNvidiaNipGate 'future-nvpi-execution-flag' 'Future NVPI execution flag supplied' $true ([bool]$AllowFutureNvpiExecution) 'Real NVIDIA Profile Inspector execution is blocked unless an explicit future flag is supplied.' $null),
        (New-RooIndustriesNvidiaNipGate 'nvpi-executor-implemented' 'NVPI process executor implemented' $true $false 'This backend has restore command scaffolding only; it intentionally contains no NVPI process launch path.' $null)
    )
    $blockingGateCount = @($gates | Where-Object { $_.blocking }).Count

    $result = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.restoreProfile'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
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
            restoreSupported = ($manifestBound -and $exportPresent)
        }
        warnings = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_RESTORE_PREVIEW_ONLY' 'NVIDIA profile restore command metadata was built without launching NVIDIA Profile Inspector.' 'info' $ProfileId $false 'Review the rollback export before any future explicitly-enabled restore executor.' $null))
        errors = @()
        logs = @((New-RooIndustriesLog 'NVIDIA NIP restore contract evaluated without process launch.'))
    }

    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.restoreProfile'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        profileId = $ProfileId
        dryRun = (-not $ConfirmApply)
        status = 'failed'
        executionMode = 'blocked'
        summary = [pscustomobject]@{ willRunNvpi = $false; willImportProfile = $false; willWriteState = $false }
        warnings = @()
        errors = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_RESTORE_FAILED' $_.Exception.Message 'error' $ProfileId $true 'Check rollback manifest or export path.' $null))
        logs = @((New-RooIndustriesLog 'NVIDIA NIP restore contract failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
