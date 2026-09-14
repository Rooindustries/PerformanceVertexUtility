param(
    [string]$UtilitiesRoot = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RooUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Resolve-RooUtilitiesRoot {
    param([string]$Path)

    $candidate = $Path
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $env:ROO_UTILITIES_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Utilities')
    }

    return [System.IO.Path]::GetFullPath($candidate)
}

function Convert-ToCleanString {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Join-RooUtilitiesPath {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $Root }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
}

function Get-RooFileEvidence {
    param(
        [string]$Path,
        [string]$PathKind
    )

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    if (-not $exists) {
        return [pscustomobject]@{
            path = $Path
            pathKind = $PathKind
            exists = $false
            sizeBytes = $null
            lastWriteTimeUtc = $null
            fileVersion = $null
            productVersion = $null
            companyName = $null
            productName = $null
            originalFilename = $null
        }
    }

    $item = Get-Item -LiteralPath $Path
    $version = $item.VersionInfo
    return [pscustomobject]@{
        path = $item.FullName
        pathKind = $PathKind
        exists = $true
        sizeBytes = [uint64]$item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        fileVersion = Convert-ToCleanString $version.FileVersion
        productVersion = Convert-ToCleanString $version.ProductVersion
        companyName = Convert-ToCleanString $version.CompanyName
        productName = Convert-ToCleanString $version.ProductName
        originalFilename = Convert-ToCleanString $version.OriginalFilename
    }
}

function New-RooInventoryTool {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Category,
        [string]$RiskLevel,
        [object[]]$PathSpecs,
        [string]$Notes = ''
    )

    return [pscustomobject]@{
        id = $Id
        name = $Name
        category = $Category
        riskLevel = $RiskLevel
        pathSpecs = @($PathSpecs)
        notes = $Notes
    }
}

function New-RooPathSpec {
    param(
        [string]$Kind,
        [string]$RelativePath = '',
        [string]$AbsolutePath = ''
    )

    return [pscustomobject]@{
        kind = $Kind
        relativePath = $RelativePath
        absolutePath = $AbsolutePath
    }
}

$startedAtUtc = Get-RooUtcStamp
$correlationId = [guid]::NewGuid().ToString('N')
$resolvedUtilitiesRoot = Resolve-RooUtilitiesRoot $UtilitiesRoot

$toolDefinitions = @(
    (New-RooInventoryTool 'nvidia-profile-inspector' 'NVIDIA Profile Inspector' 'nvidia-profile' 'medium' @(
        (New-RooPathSpec 'tool-executable' 'Other\NVPI\nvidiaProfileInspector.exe'),
        (New-RooPathSpec 'reference-metadata' 'Other\NVPI\Reference.xml')
    ) 'NVPI is inspected by file metadata only.'),
    (New-RooInventoryTool 'base-profile-nip' 'Base NIP Profile' 'nvidia-profile' 'medium' @(
        (New-RooPathSpec 'profile-file' 'Other\base-profile.nip')
    ) 'Seed NIP profile source file; no import is attempted.'),
    (New-RooInventoryTool 'nvidia-59579-no-app' 'NVIDIA 595.79 Driver Package (No NVIDIA App)' 'driver-package' 'high' @(
        (New-RooPathSpec 'installer-package' 'Drivers\Graphics\NVIDIA_595.79_NO_Nvidia_App.exe')
    ) 'Installer package is not launched.'),
    (New-RooInventoryTool 'nvidia-59579-with-app' 'NVIDIA 595.79 Driver Package (With NVIDIA App)' 'driver-package' 'high' @(
        (New-RooPathSpec 'installer-package' 'Drivers\Graphics\NVIDIA_595.79_With_Nvidia_App.exe')
    ) 'Installer package is not launched.'),
    (New-RooInventoryTool 'amd-graphics-26-2-2' 'AMD Graphics Driver Package 26.2.2' 'driver-package' 'high' @(
        (New-RooPathSpec 'installer-package' 'Drivers\Graphics\AMD 26.2.2.exe')
    ) 'Installer package is not launched.'),
    (New-RooInventoryTool 'amd-chipset-8-02-18-557' 'AMD Chipset Driver Package 8.02.18.557' 'driver-package' 'high' @(
        (New-RooPathSpec 'installer-package' 'Drivers\Chipset\AMD CHIPSET 8.02.18.557.exe')
    ) 'Installer package is not launched.'),
    (New-RooInventoryTool 'intel-chipset' 'Intel Chipset Driver Package' 'driver-package' 'high' @(
        (New-RooPathSpec 'installer-package' 'Drivers\Chipset\Intel Chipset.exe')
    ) 'Installer package is not launched.'),
    (New-RooInventoryTool 'intel-network' 'Intel Network Driver Package' 'driver-package' 'high' @(
        (New-RooPathSpec 'installer-package' 'Drivers\Network\Intel Network\SetupBD.exe')
    ) 'Network installer package is not launched.'),
    (New-RooInventoryTool 'realtek-network' 'Realtek Network Driver Package' 'driver-package' 'high' @(
        (New-RooPathSpec 'installer-package' 'Drivers\Network\Realtek Network\Install_PCIE_Win11_11027_20_0920_DMAROFF_11282025.exe')
    ) 'Network installer package is not launched.'),
    (New-RooInventoryTool 'driver-booster' 'Driver Booster' 'driver-package' 'high' @(
        (New-RooPathSpec 'installer-package' 'Drivers\driver_booster_setup.exe')
    ) 'Third-party updater is inventory-only.'),
    (New-RooInventoryTool 'ddu' 'Display Driver Uninstaller' 'driver-cleanup' 'high' @(
        (New-RooPathSpec 'tool-executable' 'Other\DDU v18.0.8.9\Display Driver Uninstaller.exe')
    ) 'DDU is not launched.'),
    (New-RooInventoryTool 'nvcleanstall' 'NVCleanstall' 'driver-package' 'high' @(
        (New-RooPathSpec 'tool-executable' 'NVCleanstall.exe')
    ) 'Lane scope marks NVCleanstall unavailable unless explicitly added at the expected path.'),
    (New-RooInventoryTool 'hwinfo-installer' 'HWiNFO Installer' 'monitoring' 'low' @(
        (New-RooPathSpec 'installer-package' 'hwi_834x.exe')
    ) 'Installer package is not launched.'),
    (New-RooInventoryTool 'hwinfo-installed' 'HWiNFO Installed Binary' 'monitoring' 'low' @(
        (New-RooPathSpec 'installed-binary' '' 'C:\Program Files\HWiNFO64\HWiNFO64.EXE')
    ) 'Installed binary is inspected by file metadata only.'),
    (New-RooInventoryTool 'cpu-z' 'CPU-Z' 'diagnostics' 'low' @(
        (New-RooPathSpec 'tool-executable' 'cpu-z_2.17-en.exe')
    ) 'Diagnostic tool is not launched.'),
    (New-RooInventoryTool 'gpu-z' 'GPU-Z' 'diagnostics' 'low' @(
        (New-RooPathSpec 'tool-executable' 'GPU-Z.2.68.0.exe')
    ) 'Diagnostic tool is not launched.'),
    (New-RooInventoryTool 'msi-afterburner' 'MSI Afterburner' 'gpu-tuning' 'high' @(
        (New-RooPathSpec 'installer-package' 'MSIAfterburnerInstaller466.exe')
    ) 'Installer and GPU profile automation are not launched.'),
    (New-RooInventoryTool 'msi-kombustor' 'MSI Kombustor' 'benchmark' 'medium' @(
        (New-RooPathSpec 'installer-package' 'MSI_Kombustor4_Setup_v4.1.36_x64.exe')
    ) 'Installer and stress test are not launched.'),
    (New-RooInventoryTool 'latencymon' 'LatencyMon' 'diagnostics' 'low' @(
        (New-RooPathSpec 'tool-executable' 'LatencyMon.exe')
    ) 'Diagnostic tool is not launched.'),
    (New-RooInventoryTool 'scewin' 'SCEWIN' 'firmware' 'critical' @(
        (New-RooPathSpec 'tool-executable' 'DL_SCEWIN.exe')
    ) 'Firmware configuration utility is not launched.'),
    (New-RooInventoryTool 'dotnetfx35' '.NET Framework 3.5 Prerequisite' 'prerequisite' 'safe' @(
        (New-RooPathSpec 'installer-package' 'Prerequisites\dotNetFx35setup.exe')
    ) 'Prerequisite installer is not launched.'),
    (New-RooInventoryTool 'directx-runtime' 'DirectX Runtime Prerequisite' 'prerequisite' 'safe' @(
        (New-RooPathSpec 'installer-package' 'Prerequisites\DX\DXSETUP.exe'),
        (New-RooPathSpec 'redistributable-cab' 'Prerequisites\DX\Jun2010_d3dx9_43_x64.cab')
    ) 'DirectX setup is not launched.')
)

$tools = @($toolDefinitions | ForEach-Object {
    $definition = $_
    $evidence = @($definition.pathSpecs | ForEach-Object {
        $spec = $_
        $path = if ([string]::IsNullOrWhiteSpace([string]$spec.absolutePath)) {
            Join-RooUtilitiesPath $resolvedUtilitiesRoot ([string]$spec.relativePath)
        } else {
            [System.IO.Path]::GetFullPath([string]$spec.absolutePath)
        }
        Get-RooFileEvidence $path ([string]$spec.kind)
    })

    [pscustomobject]@{
        id = $definition.id
        name = $definition.name
        category = $definition.category
        riskLevel = $definition.riskLevel
        present = (@($evidence | Where-Object { $_.exists -eq $true }).Count -gt 0)
        files = $evidence
        notes = $definition.notes
    }
})

$result = [pscustomobject]@{
    actionId = 'drivers.utilities.inventory'
    schemaVersion = 1
    productName = 'Roo Industries Optimization Suite'
    dryRun = $true
    status = 'success'
    correlationId = $correlationId
    startedAtUtc = $startedAtUtc
    completedAtUtc = Get-RooUtcStamp
    source = 'local-read-only'
    utilitiesRoot = $resolvedUtilitiesRoot
    utilitiesRootExists = (Test-Path -LiteralPath $resolvedUtilitiesRoot -PathType Container)
    summary = [pscustomobject]@{
        knownToolCount = $tools.Count
        presentToolCount = @($tools | Where-Object { $_.present -eq $true }).Count
        absentToolCount = @($tools | Where-Object { $_.present -ne $true }).Count
        noProcessesLaunched = $true
        noSystemMutation = $true
    }
    tools = $tools
}

$json = $result | ConvertTo-Json -Depth 10
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path $resolvedOutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $resolvedOutputPath -Value $json -Encoding UTF8
}

$json
