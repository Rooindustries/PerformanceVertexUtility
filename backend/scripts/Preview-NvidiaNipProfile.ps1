param(
    [string]$ProfileId = 'base-profile',
    [string]$CatalogPath = '',
    [string]$HardwareInventoryPath = '',
    [string]$NvpiExecutablePath = '',
    [string]$NipSourcePath = '',
    [string]$ExportPath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NvidiaNip.Common.ps1')

try {
    $catalog = Read-RooNvidiaNipCatalog $CatalogPath
    $profile = Get-RooNvidiaNipProfile $catalog $ProfileId
    $hardware = Get-RooNvidiaHardwareEvidence $HardwareInventoryPath
    $toolAsset = Get-RooPropertyValue $catalog 'toolAsset' $null
    $profileName = [string](Get-RooPropertyValue $profile 'profileNameInNip' (Get-RooPropertyValue $profile 'name' $ProfileId))
    if ([string]::IsNullOrWhiteSpace($NvpiExecutablePath)) {
        $NvpiExecutablePath = [string](Get-RooPropertyValue $toolAsset 'archivePath' 'Utilities\Other\NVPI\nvidiaProfileInspector.exe')
    }
    if ([string]::IsNullOrWhiteSpace($NipSourcePath)) {
        $NipSourcePath = [string](Get-RooPropertyValue $profile 'sourceFile' '')
    }
    if ([string]::IsNullOrWhiteSpace($ExportPath)) {
        $ExportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("roo-nvidia-nip-export-{0}-{1}.nip" -f (ConvertTo-RooNvidiaSafeId $ProfileId), (Get-RooFileStamp))
    }

    $exportCommand = New-RooNvidiaNipCommand -Operation 'export' -ExecutablePath $NvpiExecutablePath -ProfileName $profileName -NipPath $NipSourcePath -ExportPath $ExportPath
    $importCommand = New-RooNvidiaNipCommand -Operation 'import' -ExecutablePath $NvpiExecutablePath -ProfileName $profileName -NipPath $NipSourcePath -ExportPath $ExportPath
    $rollback = New-RooNvidiaNipRollbackManifest -Profile $profile -ExportCommand $exportCommand -ExportPath $ExportPath

    $gates = @(
        (New-RooNvidiaNipGate 'nvidia-hardware-present' 'NVIDIA hardware detected' $true ([bool]$hardware.nvidiaGpuPresent) 'NIP profile import is NVIDIA-only.' $hardware),
        (New-RooNvidiaNipGate 'export-before-import' 'Current NVIDIA profile export completed' $true $false 'The current profile must be exported before any import can be considered.' ([pscustomobject]@{ exportPath = $ExportPath; exportCommand = $exportCommand.commandLine })),
        (New-RooNvidiaNipGate 'explicit-user-approval' 'Explicit profile import approval captured' $true $false 'A future apply path must capture fresh approval for this exact profile and export path.' $null),
        (New-RooNvidiaNipGate 'future-nvpi-execution-flag' 'Future NVPI execution flag supplied' $true $false 'Backend validation and normal previews must not launch NVIDIA Profile Inspector.' $null),
        (New-RooNvidiaNipGate 'local-benchmark-evidence' 'Local benchmark evidence attached' $true $false 'Profile recommendations require before/after benchmark evidence.' ([pscustomobject]@{ benchmarkStatus = Get-RooPropertyValue $profile 'benchmarkStatus' $null }))
    )

    $result = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.previewProfile'
        schemaVersion = 1
        productName = $script:RooNvidiaNipProductName
        capturedAtUtc = Get-RooUtcStamp
        profileId = $ProfileId
        dryRun = $true
        status = if ($hardware.nvidiaGpuPresent) { 'preview' } else { 'blocked' }
        executionMode = 'preview-only'
        catalogPath = Get-RooNvidiaNipCatalogPath $CatalogPath
        profile = [pscustomobject]@{
            profileId = [string](Get-RooPropertyValue $profile 'profileId' '')
            name = [string](Get-RooPropertyValue $profile 'name' '')
            profileNameInNip = $profileName
            sourceFile = $NipSourcePath
            sourceSha256 = Get-RooPropertyValue $profile 'sourceSha256' $null
            settingCount = Get-RooPropertyValue $profile 'settingCount' $null
            supportedHardware = @(Get-RooPropertyArray $profile 'supportedHardware')
            risk = Get-RooPropertyValue $profile 'risk' 'medium'
        }
        hardwareGate = $hardware
        commands = [pscustomobject]@{
            exportCurrentProfile = $exportCommand
            importCandidateProfile = $importCommand
        }
        rollbackManifest = $rollback
        gates = @($gates)
        summary = [pscustomobject]@{
            willRunNvpi = $false
            willImportProfile = $false
            willExportProfile = $false
            willWriteState = $false
            autoApplyAllowed = $false
            exportBeforeImportRequired = $true
            rollbackManifestReady = $true
            blockingGateCount = @($gates | Where-Object { $_.blocking }).Count
        }
        warnings = @((New-RooNvidiaNipIssue 'NVIDIA_NIP_PREVIEW_ONLY' 'NVPI command metadata and rollback manifest were built without launching NVIDIA Profile Inspector.' 'info' $ProfileId $false 'Use this preview to review export/import gates before a future explicitly-enabled executor.' $null))
        errors = @()
        logs = @((New-RooLog 'NVIDIA NIP profile preview completed without process launch.'))
    }

    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.previewProfile'
        schemaVersion = 1
        productName = $script:RooNvidiaNipProductName
        capturedAtUtc = Get-RooUtcStamp
        profileId = $ProfileId
        dryRun = $true
        status = 'failed'
        executionMode = 'preview-only'
        summary = [pscustomobject]@{ willRunNvpi = $false; willImportProfile = $false; willWriteState = $false }
        warnings = @()
        errors = @((New-RooNvidiaNipIssue 'NVIDIA_NIP_PREVIEW_FAILED' $_.Exception.Message 'error' $ProfileId $true 'Check the catalog, profile id, and hardware inventory path.' $null))
        logs = @((New-RooLog 'NVIDIA NIP profile preview failed.' 'error'))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}

