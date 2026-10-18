param(
    [string]$ArchivePath = '',
    [string]$SourceArchiveLabel = 'vendor\Utilities.zip',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Get-RooIndustriesUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Resolve-UtilitiesArchive {
    param([string]$Path)

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $candidates.Add($Path) | Out-Null
    }

    $repoRelative = Join-Path $repoRoot 'vendor\Utilities.zip'
    $candidates.Add($repoRelative) | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($env:ROO_INDUSTRIES_UTILITIES_ARCHIVE)) {
        $candidates.Add($env:ROO_INDUSTRIES_UTILITIES_ARCHIVE) | Out-Null
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $resolved = [System.IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return $resolved
        }
    }

    throw "Utilities archive not found. Provide -ArchivePath or set ROO_INDUSTRIES_UTILITIES_ARCHIVE."
}

function ConvertTo-RooIndustriesId {
    param([string]$Value)

    $text = ([string]$Value).ToLowerInvariant()
    $text = $text -replace '^utilities[\\/]', ''
    $text = [System.IO.Path]::ChangeExtension($text, $null)
    $text = $text -replace '[^a-z0-9]+', '-'
    $text = $text.Trim('-')
    if ([string]::IsNullOrWhiteSpace($text)) { return 'utilities-entry' }
    return $text
}

function New-Classification {
    param([string]$ArchivePath)

    $path = $ArchivePath -replace '\\', '/'
    $pathLower = $path.ToLowerInvariant()
    $extension = [System.IO.Path]::GetExtension($pathLower)
    $defaults = [ordered]@{
        toolId = ConvertTo-RooIndustriesId $path
        displayName = [System.IO.Path]::GetFileName($path)
        category = 'bundle-metadata'
        risk = 'medium'
        productRole = 'inventory-metadata'
        allowedExecutionMode = 'metadata-only'
        hardwareGates = @('none')
        restoreBackupRequirement = 'Not required for metadata-only inventory.'
        integrationPlan = 'Keep this archive entry in metadata coverage. Do not execute it during backend validation.'
        executionClass = 'read-only-detector'
    }

    switch -Regex ($pathLower) {
        '^utilities/afftool/intpolicy_' {
            $defaults.toolId = 'afftool-intpolicy'
            $defaults.displayName = 'AffTool intPolicy'
            $defaults.category = 'interrupt-affinity-policy'
            $defaults.risk = 'high'
            $defaults.productRole = 'interrupt-policy-research'
            $defaults.allowedExecutionMode = 'metadata-only-read-only-detector'
            $defaults.hardwareGates = @('windows', 'architecture-match-required')
            $defaults.restoreBackupRequirement = 'Future apply would require exported interrupt policy state first.'
            $defaults.integrationPlan = 'Research/status first for interrupt affinity policy. Do not blind-apply bundled intPolicy binaries.'
            $defaults.executionClass = 'read-only-detector'
            break
        }
        '^utilities/autoruns\.exe$' {
            $defaults.toolId = 'autoruns'
            $defaults.displayName = 'Autoruns'
            $defaults.category = 'startup-inspection'
            $defaults.risk = 'medium'
            $defaults.productRole = 'advanced-startup-inspector'
            $defaults.allowedExecutionMode = 'manual-launcher-only'
            $defaults.hardwareGates = @('windows')
            $defaults.restoreBackupRequirement = 'Export startup/service/task state before any future removal workflow.'
            $defaults.integrationPlan = 'Keep as advanced manual reference while native startup inventory handles safe defaults.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/cpu-z_' {
            $defaults.toolId = 'cpu-z'
            $defaults.displayName = 'CPU-Z'
            $defaults.category = 'hardware-diagnostics'
            $defaults.risk = 'low'
            $defaults.productRole = 'manual-diagnostics'
            $defaults.allowedExecutionMode = 'manual-launcher-only'
            $defaults.hardwareGates = @('windows')
            $defaults.integrationPlan = 'Manual diagnostic/report-parser candidate for CPU, memory, motherboard, and BIOS details.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/dl_scewin\.exe$' {
            $defaults.toolId = 'scewin'
            $defaults.displayName = 'DL_SCEWIN'
            $defaults.category = 'firmware-configuration'
            $defaults.risk = 'critical'
            $defaults.productRole = 'firmware-reference-only'
            $defaults.allowedExecutionMode = 'never-auto-run'
            $defaults.hardwareGates = @('exact-platform-match-required', 'firmware-support-required')
            $defaults.restoreBackupRequirement = 'Exact firmware setting export and rollback plan required before any manual use.'
            $defaults.integrationPlan = 'Do not integrate as optimizer action. Treat as dangerous manual-only firmware tooling.'
            $defaults.executionClass = 'dangerous-manual-only'
            break
        }
        '^utilities/drivers/chipset/amd ' {
            $defaults.toolId = 'amd-chipset-driver'
            $defaults.displayName = 'AMD Chipset Driver Package'
            $defaults.category = 'driver-installer'
            $defaults.risk = 'high'
            $defaults.productRole = 'hardware-gated-driver-recommendation'
            $defaults.allowedExecutionMode = 'manual-confirmation-required'
            $defaults.hardwareGates = @('amd-chipset-detected')
            $defaults.restoreBackupRequirement = 'Create restore point and capture installed driver inventory before install.'
            $defaults.integrationPlan = 'Recommend only when AMD platform hardware is detected. Never install silently.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/drivers/chipset/intel ' {
            $defaults.toolId = 'intel-chipset-driver'
            $defaults.displayName = 'Intel Chipset Driver Package'
            $defaults.category = 'driver-installer'
            $defaults.risk = 'high'
            $defaults.productRole = 'hardware-gated-driver-recommendation'
            $defaults.allowedExecutionMode = 'manual-confirmation-required'
            $defaults.hardwareGates = @('intel-chipset-detected')
            $defaults.restoreBackupRequirement = 'Create restore point and capture installed driver inventory before install.'
            $defaults.integrationPlan = 'Recommend only when Intel platform hardware is detected. Never install silently.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/drivers/driver_booster_setup\.exe$' {
            $defaults.toolId = 'driver-booster'
            $defaults.displayName = 'Driver Booster'
            $defaults.category = 'third-party-driver-updater'
            $defaults.risk = 'critical'
            $defaults.productRole = 'excluded-driver-strategy'
            $defaults.allowedExecutionMode = 'excluded-never-run'
            $defaults.hardwareGates = @('none')
            $defaults.restoreBackupRequirement = 'Not applicable because this updater is excluded from default integration.'
            $defaults.integrationPlan = 'Exclude from default driver strategy. Prefer hardware-gated recommendations and manual driver packages.'
            $defaults.executionClass = 'excluded'
            break
        }
        '^utilities/drivers/graphics/amd ' {
            $defaults.toolId = 'amd-graphics-driver'
            $defaults.displayName = 'AMD Graphics Driver Package'
            $defaults.category = 'driver-installer'
            $defaults.risk = 'high'
            $defaults.productRole = 'hardware-gated-driver-recommendation'
            $defaults.allowedExecutionMode = 'manual-confirmation-required'
            $defaults.hardwareGates = @('pci-ven-1002')
            $defaults.restoreBackupRequirement = 'Create restore point, capture current GPU driver, and provide rollback instructions before install.'
            $defaults.integrationPlan = 'Recommend only on AMD GPU systems. Manual confirmation required.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/drivers/graphics/nvidia_595\.79_no_nvidia_app\.exe$' {
            $defaults.toolId = 'nvidia-59579-no-app'
            $defaults.displayName = 'NVIDIA 595.79 Driver Package (No NVIDIA App)'
            $defaults.category = 'driver-installer'
            $defaults.risk = 'high'
            $defaults.productRole = 'hardware-gated-driver-recommendation'
            $defaults.allowedExecutionMode = 'manual-confirmation-required'
            $defaults.hardwareGates = @('pci-ven-10de')
            $defaults.restoreBackupRequirement = 'Create restore point, capture current GPU driver, and provide rollback instructions before install.'
            $defaults.integrationPlan = 'Recommend only on NVIDIA GPU systems. Manual confirmation required.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/drivers/graphics/nvidia_595\.79_with_nvidia_app\.exe$' {
            $defaults.toolId = 'nvidia-59579-with-app'
            $defaults.displayName = 'NVIDIA 595.79 Driver Package (With NVIDIA App)'
            $defaults.category = 'driver-installer'
            $defaults.risk = 'high'
            $defaults.productRole = 'hardware-gated-driver-recommendation'
            $defaults.allowedExecutionMode = 'manual-confirmation-required'
            $defaults.hardwareGates = @('pci-ven-10de')
            $defaults.restoreBackupRequirement = 'Create restore point, capture current GPU driver, and provide rollback instructions before install.'
            $defaults.integrationPlan = 'Recommend only on NVIDIA GPU systems. Manual confirmation required.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/drivers/network/intel network/setupbd\.exe$' {
            $defaults.toolId = 'intel-proset-setupbd'
            $defaults.displayName = 'Intel PROSet SetupBD'
            $defaults.category = 'network-driver-installer'
            $defaults.risk = 'high'
            $defaults.productRole = 'hardware-gated-driver-recommendation'
            $defaults.allowedExecutionMode = 'manual-confirmation-required'
            $defaults.hardwareGates = @('intel-network-adapter-detected')
            $defaults.restoreBackupRequirement = 'Create restore point and capture current network adapter driver inventory before install.'
            $defaults.integrationPlan = 'Recommend only for matching Intel network adapters. Never install silently.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/drivers/network/intel network/.*/prounstl\.exe$' {
            $defaults.toolId = 'intel-proset-prounstl'
            $defaults.displayName = 'Intel PROSet PROUnstl Helper'
            $defaults.category = 'network-driver-uninstaller-helper'
            $defaults.risk = 'critical'
            $defaults.productRole = 'driver-package-helper-reference'
            $defaults.allowedExecutionMode = 'dangerous-manual-only'
            $defaults.hardwareGates = @('intel-network-adapter-detected')
            $defaults.restoreBackupRequirement = 'Create restore point and export network adapter driver state before any manual use.'
            $defaults.integrationPlan = 'Catalog only as a bundled helper executable. Do not expose as default cleanup or optimization action.'
            $defaults.executionClass = 'dangerous-manual-only'
            break
        }
        '^utilities/drivers/network/intel network/' {
            $defaults.toolId = 'intel-network-driver-payload'
            $defaults.displayName = 'Intel Network Driver Payload'
            $defaults.category = 'driver-package-payload'
            $defaults.risk = 'high'
            $defaults.productRole = 'driver-package-metadata'
            $defaults.allowedExecutionMode = 'metadata-only'
            $defaults.hardwareGates = @('intel-network-adapter-detected')
            $defaults.restoreBackupRequirement = 'Not required for metadata-only driver payload inventory.'
            $defaults.integrationPlan = 'Use INF/SYS/CAT/DLL metadata to support hardware-gated recommendations. Do not stage drivers automatically.'
            $defaults.executionClass = 'read-only-detector'
            break
        }
        '^utilities/drivers/network/realtek network/' {
            $defaults.toolId = 'realtek-network-driver'
            $defaults.displayName = 'Realtek Network Driver Package'
            $defaults.category = 'network-driver-installer'
            $defaults.risk = 'high'
            $defaults.productRole = 'hardware-gated-driver-recommendation'
            $defaults.allowedExecutionMode = 'manual-confirmation-required'
            $defaults.hardwareGates = @('realtek-network-adapter-detected')
            $defaults.restoreBackupRequirement = 'Create restore point and capture current network adapter driver inventory before install.'
            $defaults.integrationPlan = 'Recommend only for matching Realtek network adapters. Never install silently.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/gpu-z' {
            $defaults.toolId = 'gpu-z'
            $defaults.displayName = 'GPU-Z'
            $defaults.category = 'gpu-diagnostics'
            $defaults.risk = 'low'
            $defaults.productRole = 'optional-manual-diagnostics'
            $defaults.allowedExecutionMode = 'manual-launcher-only'
            $defaults.hardwareGates = @('windows')
            $defaults.integrationPlan = 'Optional manual GPU diagnostics for VRAM, PCIe, driver, and sensor checks.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/hwi_' {
            $defaults.toolId = 'hwinfo'
            $defaults.displayName = 'HWiNFO'
            $defaults.category = 'hardware-monitoring'
            $defaults.risk = 'low'
            $defaults.productRole = 'monitoring-provider'
            $defaults.allowedExecutionMode = 'read-only-detector-or-manual-launcher'
            $defaults.hardwareGates = @('windows')
            $defaults.integrationPlan = 'Prefer read-only shared-memory/exported sensor integration when present; installer remains manual.'
            $defaults.executionClass = 'read-only-detector'
            break
        }
        '^utilities/latencymon\.exe$' {
            $defaults.toolId = 'latencymon'
            $defaults.displayName = 'LatencyMon'
            $defaults.category = 'latency-diagnostics'
            $defaults.risk = 'low'
            $defaults.productRole = 'dpc-isr-diagnostic-workflow'
            $defaults.allowedExecutionMode = 'manual-diagnostics-only'
            $defaults.hardwareGates = @('windows')
            $defaults.integrationPlan = 'Diagnostics workflow for DPC/ISR latency evidence. Do not treat as optimizer action.'
            $defaults.executionClass = 'read-only-detector'
            break
        }
        '^utilities/msi_kombustor' {
            $defaults.toolId = 'msi-kombustor'
            $defaults.displayName = 'MSI Kombustor'
            $defaults.category = 'stress-benchmark'
            $defaults.risk = 'high'
            $defaults.productRole = 'optional-separate-benchmark'
            $defaults.allowedExecutionMode = 'manual-confirmation-required-never-auto-run'
            $defaults.hardwareGates = @('discrete-gpu-recommended')
            $defaults.restoreBackupRequirement = 'Confirm thermals, power, and user consent before any separate benchmark workflow.'
            $defaults.integrationPlan = 'Keep separate from main optimizer. Never auto-run stress or benchmark workloads.'
            $defaults.executionClass = 'dangerous-manual-only'
            break
        }
        '^utilities/msiafterburner' {
            $defaults.toolId = 'msi-afterburner'
            $defaults.displayName = 'MSI Afterburner'
            $defaults.category = 'gpu-tuning'
            $defaults.risk = 'high'
            $defaults.productRole = 'user-approved-gpu-profile-runtime'
            $defaults.allowedExecutionMode = 'controlled-user-approved-launch-only'
            $defaults.hardwareGates = @('discrete-gpu-detected')
            $defaults.restoreBackupRequirement = 'Export current profile and require user-approved rollback before any profile automation.'
            $defaults.integrationPlan = 'Installer is manual; profile/runtime management must stay user-approved with no default overclock.'
            $defaults.executionClass = 'controlled-reversible-executor'
            break
        }
        '^utilities/other/ddu ' {
            if ($pathLower -match 'display driver uninstaller\.exe$') {
                $defaults.toolId = 'ddu'
                $defaults.displayName = 'Display Driver Uninstaller'
                $defaults.category = 'driver-cleanup'
                $defaults.risk = 'critical'
                $defaults.productRole = 'guided-driver-clean-room'
                $defaults.allowedExecutionMode = 'dangerous-manual-only'
                $defaults.hardwareGates = @('display-driver-cleanup-needed')
                $defaults.restoreBackupRequirement = 'Create restore point, capture driver inventory, and require explicit safe-mode/user confirmation.'
                $defaults.integrationPlan = 'Guided clean-room workflow only. Never run silently or during validation.'
                $defaults.executionClass = 'dangerous-manual-only'
            } elseif ($extension -eq '.xml' -and $pathLower -match '/ddu logs/') {
                $defaults.toolId = 'ddu-log-archive'
                $defaults.displayName = 'DDU Log Archive'
                $defaults.category = 'driver-cleanup-log'
                $defaults.risk = 'medium'
                $defaults.productRole = 'historical-cleanup-evidence'
                $defaults.allowedExecutionMode = 'metadata-only'
                $defaults.restoreBackupRequirement = 'Not required for metadata-only log presence inventory.'
                $defaults.integrationPlan = 'Catalog log artifacts by path only; do not parse machine history in backend validation.'
                $defaults.executionClass = 'read-only-detector'
            } else {
                $defaults.toolId = 'ddu-configuration'
                $defaults.displayName = 'DDU Configuration and Localization'
                $defaults.category = 'driver-cleanup-configuration'
                $defaults.risk = 'high'
                $defaults.productRole = 'driver-cleanup-reference-metadata'
                $defaults.allowedExecutionMode = 'metadata-only'
                $defaults.restoreBackupRequirement = 'Not required for metadata-only DDU configuration inventory.'
                $defaults.integrationPlan = 'Use as reference metadata only. Native cleanup paths need explicit backup and approval.'
                $defaults.executionClass = 'read-only-detector'
            }
            break
        }
        '^utilities/other/devicecleanup\.exe$' {
            $defaults.toolId = 'device-cleanup'
            $defaults.displayName = 'Device Cleanup'
            $defaults.category = 'dead-device-cleanup'
            $defaults.risk = 'medium'
            $defaults.productRole = 'native-dead-device-cleanup-reference'
            $defaults.allowedExecutionMode = 'manual-launcher-only'
            $defaults.hardwareGates = @('windows-pnp')
            $defaults.restoreBackupRequirement = 'Export before/after PnP inventory before any native cleanup.'
            $defaults.integrationPlan = 'Build native non-present-device preview and cleanup with backup/export; bundled tool remains optional manual reference.'
            $defaults.executionClass = 'native-replacement'
            break
        }
        '^utilities/other/devicecleanup\.ini$' {
            $defaults.toolId = 'device-cleanup-config'
            $defaults.displayName = 'Device Cleanup Configuration'
            $defaults.category = 'dead-device-cleanup-configuration'
            $defaults.risk = 'medium'
            $defaults.productRole = 'reference-configuration'
            $defaults.allowedExecutionMode = 'metadata-only'
            $defaults.hardwareGates = @('windows-pnp')
            $defaults.integrationPlan = 'Catalog as reference configuration for native dead-device cleanup rules.'
            $defaults.executionClass = 'read-only-detector'
            break
        }
        '^utilities/other/framesync\.nip$' {
            $defaults.toolId = 'framesync-nip'
            $defaults.displayName = 'FrameSync NIP Profile'
            $defaults.category = 'nvidia-profile'
            $defaults.risk = 'medium'
            $defaults.productRole = 'seed-profile-metadata'
            $defaults.allowedExecutionMode = 'metadata-only-manual-apply-required'
            $defaults.hardwareGates = @('pci-ven-10de')
            $defaults.restoreBackupRequirement = 'Export current NVIDIA profile before any future manual import.'
            $defaults.integrationPlan = 'Catalog as seed NIP profile; never auto-import from backend validation.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/other/nvpi/nvidiaprofileinspector\.exe$' {
            $defaults.toolId = 'nvidia-profile-inspector'
            $defaults.displayName = 'NVIDIA Profile Inspector'
            $defaults.category = 'nvidia-profile'
            $defaults.risk = 'medium'
            $defaults.productRole = 'profile-import-and-test'
            $defaults.allowedExecutionMode = 'manual-launcher-or-read-only-probe-only'
            $defaults.hardwareGates = @('pci-ven-10de')
            $defaults.restoreBackupRequirement = 'Export current NVIDIA profile before import/apply.'
            $defaults.integrationPlan = 'Metadata catalog, manual import/export guidance, benchmark comparison, and no validation-time launch.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/other/nvpi/reference\.xml$' {
            $defaults.toolId = 'nvidia-profile-inspector-reference'
            $defaults.displayName = 'NVIDIA Profile Inspector Reference.xml'
            $defaults.category = 'nvidia-profile-reference'
            $defaults.risk = 'medium'
            $defaults.productRole = 'profile-setting-reference'
            $defaults.allowedExecutionMode = 'metadata-only'
            $defaults.hardwareGates = @('pci-ven-10de')
            $defaults.integrationPlan = 'Reference settings metadata for profile cataloging. Do not launch NVPI.'
            $defaults.executionClass = 'read-only-detector'
            break
        }
        '^utilities/prerequisites/dotnetfx35setup\.exe$' {
            $defaults.toolId = 'dotnetfx35'
            $defaults.displayName = '.NET Framework 3.5 Prerequisite'
            $defaults.category = 'prerequisite-installer'
            $defaults.risk = 'medium'
            $defaults.productRole = 'dependency-repair-workflow'
            $defaults.allowedExecutionMode = 'manual-confirmation-required'
            $defaults.hardwareGates = @('windows-feature-missing')
            $defaults.restoreBackupRequirement = 'Create restore point before dependency repair/install.'
            $defaults.integrationPlan = 'Dependency repair/install workflow only, with explicit confirmation required.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/prerequisites/dx/' {
            $defaults.toolId = 'directx-runtime'
            $defaults.displayName = 'DirectX Runtime Prerequisite'
            $defaults.category = 'prerequisite-runtime'
            $defaults.risk = 'medium'
            $defaults.productRole = 'dependency-repair-workflow'
            $defaults.allowedExecutionMode = if ($extension -in @('.exe', '.bat')) { 'manual-confirmation-required' } else { 'metadata-only' }
            $defaults.hardwareGates = @('directx-legacy-runtime-missing')
            $defaults.restoreBackupRequirement = 'Create restore point before dependency repair/install.'
            $defaults.integrationPlan = 'Dependency repair/install workflow only, with explicit confirmation required.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/prerequisites/vcredist/' {
            $defaults.toolId = 'vcredist-runtime'
            $defaults.displayName = 'Visual C++ Redistributable Prerequisite'
            $defaults.category = 'prerequisite-runtime'
            $defaults.risk = 'medium'
            $defaults.productRole = 'dependency-repair-workflow'
            $defaults.allowedExecutionMode = if ($extension -in @('.exe', '.bat')) { 'manual-confirmation-required' } else { 'metadata-only' }
            $defaults.hardwareGates = @('vcredist-runtime-missing')
            $defaults.restoreBackupRequirement = 'Create restore point before dependency repair/install.'
            $defaults.integrationPlan = 'Dependency repair/install workflow only, with explicit confirmation required.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/processlassosetup64\.exe$' {
            $defaults.toolId = 'process-lasso'
            $defaults.displayName = 'Process Lasso'
            $defaults.category = 'process-control-reference'
            $defaults.risk = 'medium'
            $defaults.productRole = 'native-process-governor-replacement-target'
            $defaults.allowedExecutionMode = 'manual-reference-only'
            $defaults.hardwareGates = @('windows')
            $defaults.restoreBackupRequirement = 'Native process controls must capture original process state before apply.'
            $defaults.integrationPlan = 'Do not require or launch Process Lasso. Build native priority, affinity, I/O priority, and per-game rules.'
            $defaults.executionClass = 'native-replacement'
            break
        }
        '^utilities/revosetup\.exe$' {
            $defaults.toolId = 'bulk-uninstaller-native'
            $defaults.displayName = 'Revo Replacement Reference'
            $defaults.category = 'uninstall-cleanup-reference'
            $defaults.risk = 'high'
            $defaults.productRole = 'native-bulk-uninstaller-replacement-target'
            $defaults.allowedExecutionMode = 'manual-reference-only'
            $defaults.hardwareGates = @('windows')
            $defaults.restoreBackupRequirement = 'Native cleanup must export uninstall metadata, registry state, and deletion manifest before apply.'
            $defaults.integrationPlan = 'Build native bulk uninstaller and leftover scanner. Do not clone or bypass Revo licensing.'
            $defaults.executionClass = 'native-replacement'
            break
        }
        '^utilities/stock only \(otherwise not necessary\)/inspectre\.exe$' {
            $defaults.toolId = 'inspectre'
            $defaults.displayName = 'InSpectre'
            $defaults.category = 'security-mitigation-status'
            $defaults.risk = 'critical'
            $defaults.productRole = 'security-mitigation-detector'
            $defaults.allowedExecutionMode = 'read-only-detector-first'
            $defaults.hardwareGates = @('windows')
            $defaults.restoreBackupRequirement = 'Registry export and restore point required before any manual Spectre/Meltdown mitigation changes.'
            $defaults.integrationPlan = 'Detector first. Disabling Spectre/Meltdown mitigations is high-risk/manual-only and never silent.'
            $defaults.executionClass = 'read-only-detector'
            break
        }
        '^utilities/stock only \(otherwise not necessary\)/msi_util_v3\.exe$' {
            $defaults.toolId = 'msi-util-v3'
            $defaults.displayName = 'MSI Utility v3'
            $defaults.category = 'device-msi-mode-status'
            $defaults.risk = 'high'
            $defaults.productRole = 'msi-mode-read-only-detector'
            $defaults.allowedExecutionMode = 'read-only-detector-first'
            $defaults.hardwareGates = @('windows-pnp')
            $defaults.restoreBackupRequirement = 'Export device and registry MSI mode state before any future apply.'
            $defaults.integrationPlan = 'Read-only MSI mode/status detector first. Apply only later with restore/export proof.'
            $defaults.executionClass = 'read-only-detector'
            break
        }
        '^utilities/stock only \(otherwise not necessary\)/nvcleanstall' {
            $defaults.toolId = 'nvcleanstall'
            $defaults.displayName = 'NVCleanstall'
            $defaults.category = 'nvidia-driver-builder'
            $defaults.risk = 'high'
            $defaults.productRole = 'manual-nvidia-driver-builder'
            $defaults.allowedExecutionMode = 'manual-confirmation-required'
            $defaults.hardwareGates = @('pci-ven-10de')
            $defaults.restoreBackupRequirement = 'Create restore point and capture current NVIDIA driver inventory before use.'
            $defaults.integrationPlan = 'NVIDIA-only manual driver build workflow. Gate by hardware detection.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/stock only \(otherwise not necessary\)/oosu10\.exe$' {
            $defaults.toolId = 'oosu10'
            $defaults.displayName = 'O&O ShutUp10++'
            $defaults.category = 'privacy-reference'
            $defaults.risk = 'medium'
            $defaults.productRole = 'privacy-reference-or-manual-launch'
            $defaults.allowedExecutionMode = 'manual-launcher-only'
            $defaults.hardwareGates = @('windows')
            $defaults.restoreBackupRequirement = 'Export privacy-related registry/policy state before any native apply.'
            $defaults.integrationPlan = 'Manual launcher/reference only. Native app should implement a safe privacy subset with rollback.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/stock only \(otherwise not necessary\)/unparkcpu\.exe$' {
            $defaults.toolId = 'unparkcpu'
            $defaults.displayName = 'UnparkCPU'
            $defaults.category = 'cpu-core-parking'
            $defaults.risk = 'medium'
            $defaults.productRole = 'native-power-plan-reference'
            $defaults.allowedExecutionMode = 'manual-reference-only'
            $defaults.hardwareGates = @('windows-power-policy')
            $defaults.restoreBackupRequirement = 'Export active power plan before any native parking change.'
            $defaults.integrationPlan = 'Prefer native power-plan/core-parking controls. Bundled tool stays manual/reference unless reversible native executor exists.'
            $defaults.executionClass = 'native-replacement'
            break
        }
        '^utilities/stock only \(otherwise not necessary\)/wpd\.exe$' {
            $defaults.toolId = 'wpd'
            $defaults.displayName = 'WPD'
            $defaults.category = 'privacy-reference'
            $defaults.risk = 'medium'
            $defaults.productRole = 'privacy-reference-or-manual-launch'
            $defaults.allowedExecutionMode = 'manual-launcher-only'
            $defaults.hardwareGates = @('windows')
            $defaults.restoreBackupRequirement = 'Export privacy-related registry/policy state before any native apply.'
            $defaults.integrationPlan = 'Manual launcher/reference only. Native app should implement validated privacy toggles with rollback.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/thorium_' {
            $defaults.toolId = 'thorium'
            $defaults.displayName = 'Thorium'
            $defaults.category = 'browser-installer'
            $defaults.risk = 'low'
            $defaults.productRole = 'excluded-by-default'
            $defaults.allowedExecutionMode = 'excluded-never-run'
            $defaults.hardwareGates = @('none')
            $defaults.restoreBackupRequirement = 'Not applicable because this browser installer is excluded from default workflow.'
            $defaults.integrationPlan = 'Do not include in default optimization workflow.'
            $defaults.executionClass = 'excluded'
            break
        }
        '^utilities/userdiag\.exe$' {
            $defaults.toolId = 'userdiag'
            $defaults.displayName = 'UserDiag'
            $defaults.category = 'diagnostics'
            $defaults.risk = 'medium'
            $defaults.productRole = 'diagnostic-and-sales-funnel'
            $defaults.allowedExecutionMode = 'manual-launcher-only'
            $defaults.hardwareGates = @('windows')
            $defaults.restoreBackupRequirement = 'Not required for manual diagnostic launch; native diagnostics should keep report artifacts user-visible.'
            $defaults.integrationPlan = 'Separate diagnostics section.'
            $defaults.executionClass = 'manual-launcher'
            break
        }
        '^utilities/vesktop-' {
            $defaults.toolId = 'vesktop'
            $defaults.displayName = 'Vesktop'
            $defaults.category = 'communication-app-installer'
            $defaults.risk = 'low'
            $defaults.productRole = 'excluded-by-default'
            $defaults.allowedExecutionMode = 'excluded-never-run'
            $defaults.hardwareGates = @('none')
            $defaults.restoreBackupRequirement = 'Not applicable because this installer is excluded from default workflow.'
            $defaults.integrationPlan = 'Do not include in default optimization workflow.'
            $defaults.executionClass = 'excluded'
            break
        }
    }

    if ($extension -in @('.inf', '.sys', '.cat') -and $defaults.category -eq 'bundle-metadata') {
        $defaults.category = 'driver-package-payload'
        $defaults.risk = 'high'
        $defaults.productRole = 'driver-package-metadata'
        $defaults.hardwareGates = @('matching-device-id-required')
        $defaults.integrationPlan = 'Use as driver metadata for hardware-gated recommendations. Do not stage or install automatically.'
    } elseif ($extension -eq '.cab' -and $defaults.category -eq 'bundle-metadata') {
        $defaults.category = 'redistributable-payload'
        $defaults.risk = 'medium'
        $defaults.productRole = 'dependency-payload-metadata'
        $defaults.integrationPlan = 'Catalog dependency payload metadata only. Installation requires explicit confirmation.'
    } elseif ($extension -in @('.ini', '.cfg', '.config', '.xml', '.nip') -and $defaults.category -eq 'bundle-metadata') {
        $defaults.category = 'configuration-metadata'
        $defaults.risk = 'medium'
        $defaults.productRole = 'configuration-reference'
        $defaults.integrationPlan = 'Catalog configuration/reference metadata only.'
    } elseif ($extension -eq '.dll' -and $defaults.category -eq 'bundle-metadata') {
        $defaults.category = 'library-payload'
        $defaults.risk = 'medium'
        $defaults.productRole = 'payload-metadata'
        $defaults.integrationPlan = 'Catalog payload metadata only. Do not load libraries during validation.'
    }

    return [pscustomobject]$defaults
}

function Get-EntryKind {
    param([string]$Extension)

    $executableScriptExtensions = @('.exe', '.msi', '.msu', '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.js', '.reg')
    if ($executableScriptExtensions -contains $Extension) { return 'executable-script' }
    if ($Extension -in @('.inf', '.sys', '.cat')) { return 'driver-package-metadata' }
    if ($Extension -eq '.cab') { return 'redistributable-payload' }
    if ($Extension -eq '.dll') { return 'library-payload' }
    return 'configuration-metadata'
}

$resolvedArchivePath = Resolve-UtilitiesArchive $ArchivePath
$archiveItem = Get-Item -LiteralPath $resolvedArchivePath

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($resolvedArchivePath)
try {
    $allEntries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | Sort-Object FullName)
    $executableScriptExtensions = @('.exe', '.msi', '.msu', '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.js', '.reg')
    $catalogExtensions = @('.exe', '.msi', '.msu', '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.js', '.reg', '.inf', '.ini', '.cfg', '.config', '.xml', '.nip', '.cab', '.dll', '.sys', '.cat')
    $executableScriptEntries = @($allEntries | Where-Object { $executableScriptExtensions -contains ([System.IO.Path]::GetExtension($_.FullName).ToLowerInvariant()) })
    $catalogSourceEntries = @($allEntries | Where-Object { $catalogExtensions -contains ([System.IO.Path]::GetExtension($_.FullName).ToLowerInvariant()) })

    $catalogEntries = @($catalogSourceEntries | ForEach-Object {
        $entry = $_
        $entryPath = $entry.FullName -replace '/', '\'
        $extension = [System.IO.Path]::GetExtension($entry.FullName).ToLowerInvariant()
        $classification = New-Classification ($entry.FullName)
        [pscustomobject]@{
            archivePath = $entryPath
            normalizedId = ConvertTo-RooIndustriesId $entry.FullName
            toolId = $classification.toolId
            displayName = $classification.displayName
            entryKind = Get-EntryKind $extension
            extension = $extension
            category = $classification.category
            risk = $classification.risk
            productRole = $classification.productRole
            executionClass = $classification.executionClass
            allowedExecutionMode = $classification.allowedExecutionMode
            hardwareGates = @($classification.hardwareGates)
            restoreBackupRequirement = $classification.restoreBackupRequirement
            integrationPlan = $classification.integrationPlan
            lengthBytes = [uint64]$entry.Length
            compressedLengthBytes = [uint64]$entry.CompressedLength
        }
    })

    $extensionCounts = [ordered]@{}
    foreach ($group in @($allEntries | Group-Object { [System.IO.Path]::GetExtension($_.FullName).ToLowerInvariant() } | Sort-Object Name)) {
        $name = if ([string]::IsNullOrWhiteSpace([string]$group.Name)) { '<none>' } else { [string]$group.Name }
        $extensionCounts[$name] = [int]$group.Count
    }

    $categoryCounts = [ordered]@{}
    foreach ($group in @($catalogEntries | Group-Object category | Sort-Object Name)) {
        $categoryCounts[[string]$group.Name] = [int]$group.Count
    }

    $executionClassCounts = [ordered]@{}
    foreach ($group in @($catalogEntries | Group-Object executionClass | Sort-Object Name)) {
        $executionClassCounts[[string]$group.Name] = [int]$group.Count
    }

    $result = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        catalogId = 'utilities-bundle-catalog'
        sourceArchive = $SourceArchiveLabel
        generatedAtUtc = Get-RooIndustriesUtcStamp
        sourceArchiveSizeBytes = [uint64]$archiveItem.Length
        entryCount = [int]$allEntries.Count
        executableScriptCount = [int]$executableScriptEntries.Count
        catalogedEntryCount = [int]$catalogEntries.Count
        sourceBoundary = [pscustomobject]@{
            archiveMetadataOnly = $true
            fullExtractionAllowed = $false
            utilityExecutionAllowed = $false
            systemMutationAllowed = $false
            privatePathRedaction = 'sourceArchive is repo-relative in committed artifacts'
        }
        summary = [pscustomobject]@{
            extensionCounts = [pscustomobject]$extensionCounts
            categoryCounts = [pscustomobject]$categoryCounts
            executionClassCounts = [pscustomobject]$executionClassCounts
        }
        catalogEntries = $catalogEntries
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
} finally {
    $zip.Dispose()
}
