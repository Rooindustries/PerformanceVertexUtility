param(
    [string]$ProfileId = 'framesync',
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
    $catalog = Read-RooIndustriesNvidiaNipCatalog $CatalogPath
    $profile = Get-RooIndustriesNvidiaNipProfile $catalog $ProfileId
    $hardware = Get-RooIndustriesNvidiaHardwareEvidence $HardwareInventoryPath
    $toolAsset = Get-RooIndustriesPropertyValue $catalog 'toolAsset' $null
    $profileName = [string](Get-RooIndustriesPropertyValue $profile 'profileNameInNip' (Get-RooIndustriesPropertyValue $profile 'name' $ProfileId))
    if ([string]::IsNullOrWhiteSpace($NvpiExecutablePath)) {
        $NvpiExecutablePath = [string](Get-RooIndustriesPropertyValue $toolAsset 'archivePath' 'Utilities\Other\NVPI\nvidiaProfileInspector.exe')
    }
    if ([string]::IsNullOrWhiteSpace($NipSourcePath)) {
        $NipSourcePath = [string](Get-RooIndustriesPropertyValue $profile 'sourceFile' '')
    }
    if ([string]::IsNullOrWhiteSpace($ExportPath)) {
        $ExportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("roo-industries-nvidia-nip-export-{0}-{1}.nip" -f (ConvertTo-RooIndustriesNvidiaSafeId $ProfileId), (Get-RooIndustriesFileStamp))
    }

    $exportCommand = New-RooIndustriesNvidiaNipCommand -Operation 'export' -ExecutablePath $NvpiExecutablePath -ProfileName $profileName -NipPath $NipSourcePath -ExportPath $ExportPath
    $importCommand = New-RooIndustriesNvidiaNipCommand -Operation 'import' -ExecutablePath $NvpiExecutablePath -ProfileName $profileName -NipPath $NipSourcePath -ExportPath $ExportPath
    $rollback = New-RooIndustriesNvidiaNipRollbackManifest -Profile $profile -ExportCommand $exportCommand -ExportPath $ExportPath

    $gates = @(
        (New-RooIndustriesNvidiaNipGate 'nvidia-hardware-present' 'NVIDIA hardware detected' $true ([bool]$hardware.nvidiaGpuPresent) 'NIP profile import is NVIDIA-only.' $hardware),
        (New-RooIndustriesNvidiaNipGate 'export-before-import' 'Current NVIDIA profile export completed' $true $false 'The current profile must be exported before any import can be considered.' ([pscustomobject]@{ exportPath = $ExportPath; exportCommand = $exportCommand.commandLine })),
        (New-RooIndustriesNvidiaNipGate 'explicit-user-approval' 'Explicit profile import approval captured' $true $false 'A future apply path must capture fresh approval for this exact profile and export path.' $null),
        (New-RooIndustriesNvidiaNipGate 'future-nvpi-execution-flag' 'Future NVPI execution flag supplied' $true $false 'Backend validation and normal previews must not launch NVIDIA Profile Inspector.' $null),
        (New-RooIndustriesNvidiaNipGate 'local-benchmark-evidence' 'Local benchmark evidence attached' $true $false 'Profile recommendations require before/after benchmark evidence.' ([pscustomobject]@{ benchmarkStatus = Get-RooIndustriesPropertyValue $profile 'benchmarkStatus' $null }))
    )

    $result = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.previewProfile'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        profileId = $ProfileId
        dryRun = $true
        status = if ($hardware.nvidiaGpuPresent) { 'preview' } else { 'blocked' }
        executionMode = 'preview-only'
        catalogPath = Get-RooIndustriesNvidiaNipCatalogPath $CatalogPath
        profile = [pscustomobject]@{
            profileId = [string](Get-RooIndustriesPropertyValue $profile 'profileId' '')
            name = [string](Get-RooIndustriesPropertyValue $profile 'name' '')
            profileNameInNip = $profileName
            sourceFile = $NipSourcePath
            sourceSha256 = Get-RooIndustriesPropertyValue $profile 'sourceSha256' $null
            settingCount = Get-RooIndustriesPropertyValue $profile 'settingCount' $null
            supportedHardware = @(Get-RooIndustriesPropertyArray $profile 'supportedHardware')
            risk = Get-RooIndustriesPropertyValue $profile 'risk' 'medium'
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
        warnings = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_PREVIEW_ONLY' 'NVPI command metadata and rollback manifest were built without launching NVIDIA Profile Inspector.' 'info' $ProfileId $false 'Use this preview to review export/import gates before a future explicitly-enabled executor.' $null))
        errors = @()
        logs = @((New-RooIndustriesLog 'NVIDIA NIP profile preview completed without process launch.'))
    }

    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.previewProfile'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        profileId = $ProfileId
        dryRun = $true
        status = 'failed'
        executionMode = 'preview-only'
        summary = [pscustomobject]@{ willRunNvpi = $false; willImportProfile = $false; willWriteState = $false }
        warnings = @()
        errors = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_PREVIEW_FAILED' $_.Exception.Message 'error' $ProfileId $true 'Check the catalog, profile id, and hardware inventory path.' $null))
        logs = @((New-RooIndustriesLog 'NVIDIA NIP profile preview failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}

