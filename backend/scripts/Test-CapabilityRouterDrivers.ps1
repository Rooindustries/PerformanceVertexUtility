Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$passes = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]
$script:ToolWatchJob = $null

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

function Add-Check {
    param(
        [bool]$Condition,
        [string]$PassMessage,
        [string]$FailureMessage
    )

    if ($Condition) {
        Add-Pass $PassMessage
    } else {
        Add-Failure $FailureMessage
    }
}

function Has-Property {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if (-not (Has-Property $Object $Name)) { return $Default }
    return $Object.PSObject.Properties[$Name].Value
}

function Get-StateEntryCount {
    param([string]$RepoRoot)

    $stateRoot = Join-Path $RepoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Resolve-RepoPath {
    param(
        [string]$RepoRoot,
        [string]$RelativePath
    )

    $candidate = Join-Path $RepoRoot ($RelativePath -replace '/', '\')
    return [System.IO.Path]::GetFullPath($candidate)
}

function ConvertFrom-RouterJson {
    param(
        [object[]]$Output,
        [string]$Label
    )

    $text = ($Output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        Add-Failure "$Label emitted no JSON"
        return $null
    }

    try {
        return $text | ConvertFrom-Json
    } catch {
        Add-Failure "$Label JSON parse failed: $($_.Exception.Message)"
        Write-Host $text
        return $null
    }
}

function Invoke-Router {
    param([string[]]$Arguments)

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:RouterPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $json = ConvertFrom-RouterJson $output "Invoke-RooCapability $($Arguments -join ' ')"
    return [pscustomobject]@{
        exitCode = [int]$exitCode
        output = ($output | Out-String).Trim()
        json = $json
    }
}

function Test-CompleteEnvelope {
    param(
        [object]$Envelope,
        [string]$Label
    )

    $requiredFields = @(
        'actionId',
        'schemaVersion',
        'correlationId',
        'startedAtUtc',
        'completedAtUtc',
        'capabilityId',
        'family',
        'displayName',
        'frontendLabel',
        'frontendTab',
        'action',
        'dryRun',
        'status',
        'requiresApproval',
        'approvalSatisfied',
        'machineAvailable',
        'unavailableReason',
        'applyStatus',
        'restoreStatus',
        'routedScript',
        'wouldChange',
        'changed',
        'restoreAvailable',
        'evidence',
        'errors',
        'nextRequiredStep'
    )

    foreach ($field in $requiredFields) {
        Add-Check (Has-Property $Envelope $field) "$Label has envelope field $field" "$Label missing envelope field $field"
    }

    if ($null -ne $Envelope) {
        Add-Check ([string](Get-PropertyValue $Envelope 'actionId' '') -eq 'backend.capability.invoke') "$Label actionId is valid" "$Label actionId is invalid"
        Add-Check ([int](Get-PropertyValue $Envelope 'schemaVersion' 0) -eq 1) "$Label schemaVersion is 1" "$Label schemaVersion is not 1"
        Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $Envelope 'correlationId' ''))) "$Label correlationId is present" "$Label correlationId is missing"
        Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $Envelope 'startedAtUtc' ''))) "$Label startedAtUtc is present" "$Label startedAtUtc is missing"
        Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $Envelope 'completedAtUtc' ''))) "$Label completedAtUtc is present" "$Label completedAtUtc is missing"
        Add-Check ((Get-PropertyValue $Envelope 'dryRun' $null) -is [bool]) "$Label dryRun is boolean" "$Label dryRun is not boolean"
        Add-Check ((Get-PropertyValue $Envelope 'requiresApproval' $null) -is [bool]) "$Label requiresApproval is boolean" "$Label requiresApproval is not boolean"
        Add-Check ((Get-PropertyValue $Envelope 'approvalSatisfied' $null) -is [bool]) "$Label approvalSatisfied is boolean" "$Label approvalSatisfied is not boolean"
        Add-Check ((Get-PropertyValue $Envelope 'machineAvailable' $null) -is [bool]) "$Label machineAvailable is boolean" "$Label machineAvailable is not boolean"
        Add-Check ((Get-PropertyValue $Envelope 'wouldChange' $null) -is [bool]) "$Label wouldChange is boolean" "$Label wouldChange is not boolean"
        Add-Check ((Get-PropertyValue $Envelope 'changed' $null) -is [bool]) "$Label changed is boolean" "$Label changed is not boolean"
        Add-Check ((Get-PropertyValue $Envelope 'restoreAvailable' $null) -is [bool]) "$Label restoreAvailable is boolean" "$Label restoreAvailable is not boolean"
        Add-Check ($null -ne (Get-PropertyValue $Envelope 'evidence' $null)) "$Label evidence is present" "$Label evidence is missing"
    }
}

function Start-ToolProcessWatch {
    param([string[]]$ForbiddenProcessNames)

    try {
        $script:ToolWatchJob = Start-Job -ScriptBlock {
            param([string[]]$Names)

            $lookup = @{}
            foreach ($name in $Names) {
                $lookup[$name.ToLowerInvariant()] = $true
            }

            $seen = @{}
            $initialized = $false
            while ($true) {
                $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                    $processName = ([string]$_.ProcessName).ToLowerInvariant()
                    $lookup.ContainsKey($processName)
                })

                foreach ($process in $processes) {
                    $processId = [int]$process.ProcessId
                    if (-not $seen.ContainsKey($processId)) {
                        $seen[$processId] = $true
                        if ($initialized) {
                            [pscustomobject]@{
                                processName = [string]$process.ProcessName
                                processId = $processId
                                parentProcessId = [int]$process.ParentProcessId
                                commandLine = [string]$process.CommandLine
                            }
                        }
                    }
                }

                $initialized = $true
                Start-Sleep -Milliseconds 75
            }
        } -ArgumentList (, $ForbiddenProcessNames)
        Start-Sleep -Milliseconds 200
        Add-Pass 'third-party tool process watcher registered'
    } catch {
        Add-Failure "third-party tool process watcher could not start: $($_.Exception.Message)"
    }
}

function Stop-ToolProcessWatch {
    param([string[]]$ForbiddenProcessNames)

    Start-Sleep -Milliseconds 300
    $launched = @()
    if ($null -ne $script:ToolWatchJob) {
        Stop-Job -Job $script:ToolWatchJob -ErrorAction SilentlyContinue
        $launched = @(Receive-Job -Job $script:ToolWatchJob -ErrorAction SilentlyContinue)
        Remove-Job -Job $script:ToolWatchJob -Force -ErrorAction SilentlyContinue
    }
    return @($launched)
}

function Get-RouteById {
    param(
        [object]$Manifest,
        [string]$CapabilityId
    )

    $matches = @($Manifest.routes | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq $CapabilityId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-RouteSection {
    param(
        [object]$Route,
        [string]$SectionName
    )

    if ($null -eq $Route) { return $null }
    return Get-PropertyValue $Route $SectionName $null
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:RouterPath = Join-Path $repoRoot 'backend\scripts\Invoke-RooCapability.ps1'
$fragmentPath = Join-Path $repoRoot 'backend\capabilities\drivers-gpu-tools.json'
$manifestPath = Join-Path $repoRoot 'backend\capabilities\routing\drivers-gpu-tools.routes.json'

$forbiddenToolProcesses = @(
    'nvidiaProfileInspector.exe',
    'Display Driver Uninstaller.exe',
    'DDU.exe',
    'NVCleanstall.exe',
    'cpu-z_2.17-en.exe',
    'cpuz.exe',
    'cpuz_x64.exe',
    'GPU-Z.2.68.0.exe',
    'GPU-Z.exe',
    'MSIAfterburnerInstaller466.exe',
    'MSIAfterburner.exe',
    'MSI_Kombustor4_Setup_v4.1.36_x64.exe',
    'MSIKombustor.exe',
    'Kombustor.exe',
    'LatencyMon.exe',
    'DL_SCEWIN.exe',
    'SCEWIN.exe',
    'hwi_834x.exe',
    'HWiNFO64.EXE',
    'HWiNFO32.EXE',
    'NVIDIA_595.79_NO_Nvidia_App.exe',
    'NVIDIA_595.79_With_Nvidia_App.exe',
    'AMD 26.2.2.exe',
    'AMD CHIPSET 8.02.18.557.exe',
    'Intel Chipset.exe',
    'SetupBD.exe',
    'Install_PCIE_Win11_11027_20_0920_DMAROFF_11282025.exe',
    'driver_booster_setup.exe',
    'dotNetFx35setup.exe',
    'DXSETUP.exe'
)

$expectedApplySteps = @{
    'drivers-gpu-tools.nvidia-nip-profile-preview' = 'Use Invoke-NvidiaNipExecutor.ps1 in Preview mode to collect export-before-import gate evidence; no NVIDIA settings are changed by this preview.'
    'drivers-gpu-tools.nvidia-nip-export-probe' = 'Run Invoke-NvidiaNipCapabilityProbe.ps1 with -AllowReadOnlyNvpiProbe only for an explicit temp-path read-only probe; import remains disabled.'
    'drivers-gpu-tools.nvidia-nip-gated-import' = 'Use Invoke-NvidiaNipExecutor.ps1 -ExecutorMode Mock with -ConfirmApply -UserApproved -BenchmarkEvidenceAttached for validation; real NVPI import is not enabled.'
    'drivers-gpu-tools.nvidia-nip-restore-manifest' = 'Use Restore-NvidiaNipProfile.ps1 to review rollback command metadata; restore imports remain behind controlled executor gates.'
    'drivers-gpu-tools.nvidia-nip-base-catalog' = 'Use Preview-NvidiaNipProfile.ps1 to review catalog command metadata; do not treat catalog metadata as applied desired state.'
    'drivers-gpu-tools.driver-package-nvidia-59579-no-app' = 'Create a restore-point-gated package selection contract with hardware match and explicit user handoff; no installer launch is implemented.'
    'drivers-gpu-tools.driver-package-nvidia-59579-with-app' = 'Create a restore-point-gated package selection contract with hardware match and explicit user handoff; no installer launch is implemented.'
    'drivers-gpu-tools.driver-package-amd-26-2-2' = 'Create a restore-point-gated package selection contract with AMD hardware match and explicit user handoff; no installer launch is implemented.'
    'drivers-gpu-tools.driver-package-amd-chipset-8-02-18-557' = 'Create chipset hardware matching plus restore-point-gated explicit user handoff; no installer launch is implemented.'
    'drivers-gpu-tools.driver-package-intel-chipset' = 'Create chipset hardware matching plus restore-point-gated explicit user handoff; no installer launch is implemented.'
    'drivers-gpu-tools.driver-package-intel-network' = 'Create network adapter hardware matching, connectivity rollback guidance, and explicit user handoff; no installer launch is implemented.'
    'drivers-gpu-tools.driver-package-realtek-network' = 'Create network adapter hardware matching, connectivity rollback guidance, and explicit user handoff; no installer launch is implemented.'
    'drivers-gpu-tools.driver-booster-package' = 'Create an allowlisted recommendation-only workflow; no third-party update tool launch or automation is implemented.'
    'drivers-gpu-tools.driver-cleanup-ddu' = 'Create a guided DDU plan with restore point, safe-mode/network guidance, and explicit manual handoff; no DDU automation is implemented.'
    'drivers-gpu-tools.nvcleanstall' = 'Add an explicit local tool reference and a manual NVIDIA-only builder handoff contract; no builder automation is implemented.'
    'drivers-gpu-tools.hwinfo-installer' = 'Create an install/launch consent contract or shared-memory sensor reader; no installer launch is implemented.'
    'drivers-gpu-tools.hwinfo-installed-sensor-monitoring' = 'Create a read-only HWiNFO shared-memory or exported-sensors adapter; no process launch is implemented.'
    'drivers-gpu-tools.cpu-z-diagnostics' = 'Create a manual-launch or exported-report parsing contract; no tool launch is implemented.'
    'drivers-gpu-tools.gpu-z-diagnostics' = 'Create a manual-launch or exported-report parsing contract; no tool launch is implemented.'
    'drivers-gpu-tools.msi-afterburner' = 'Create a helper contract for explicit user-approved profile import/export; no Afterburner automation is implemented.'
    'drivers-gpu-tools.msi-kombustor' = 'Create an explicit benchmark-provider contract with thermal safety gates; no Kombustor automation is implemented.'
    'drivers-gpu-tools.latencymon' = 'Create a read-only diagnostic report ingestion contract; no tool launch is implemented.'
    'drivers-gpu-tools.scewin' = 'Create an explicit helper manifest, platform allowlist, and backup/export contract; no SCEWIN automation is implemented.'
    'drivers-gpu-tools.prerequisite-dotnetfx35' = 'Create a Windows-feature/package prerequisite plan; no DISM or installer execution is implemented.'
    'drivers-gpu-tools.prerequisite-directx-june2010' = 'Create a prerequisite install plan with explicit user approval; no DXSETUP execution is implemented.'
}

$expectedRestoreSteps = @{
    'drivers-gpu-tools.nvidia-nip-profile-preview' = 'Use Restore-NvidiaNipProfile.ps1 to review rollback command metadata; real NVPI restore is not dispatched by the router.'
    'drivers-gpu-tools.nvidia-nip-export-probe' = 'Use Invoke-NvidiaNipCapabilityProbe.ps1 preview evidence only; read-only probes have no restore path.'
    'drivers-gpu-tools.nvidia-nip-gated-import' = 'Use Invoke-NvidiaNipExecutor.ps1 in Preview mode for rollback manifest review; real restore import is not dispatched by the router.'
    'drivers-gpu-tools.nvidia-nip-restore-manifest' = 'Use Restore-NvidiaNipProfile.ps1 to review prior-export rollback metadata; real restore import is not dispatched by the router.'
    'drivers-gpu-tools.nvidia-nip-base-catalog' = 'Use Preview-NvidiaNipProfile.ps1 for catalog review; catalog-only metadata has no restore path.'
    'drivers-gpu-tools.driver-package-nvidia-59579-no-app' = 'Create a driver rollback plan before adding a restore route; no driver rollback script is implemented.'
    'drivers-gpu-tools.driver-package-nvidia-59579-with-app' = 'Create a driver rollback plan before adding a restore route; no driver rollback script is implemented.'
    'drivers-gpu-tools.driver-package-amd-26-2-2' = 'Create a driver rollback plan before adding a restore route; no driver rollback script is implemented.'
    'drivers-gpu-tools.driver-package-amd-chipset-8-02-18-557' = 'Create a driver rollback plan before adding a restore route; no driver rollback script is implemented.'
    'drivers-gpu-tools.driver-package-intel-chipset' = 'Create a driver rollback plan before adding a restore route; no driver rollback script is implemented.'
    'drivers-gpu-tools.driver-package-intel-network' = 'Create a driver rollback plan before adding a restore route; no driver rollback script is implemented.'
    'drivers-gpu-tools.driver-package-realtek-network' = 'Create a driver rollback plan before adding a restore route; no driver rollback script is implemented.'
    'drivers-gpu-tools.driver-booster-package' = 'Create a driver rollback plan before adding a restore route; no driver rollback script is implemented.'
    'drivers-gpu-tools.driver-cleanup-ddu' = 'Create a restore-point and driver reinstall plan before adding a restore route; no DDU restore automation is implemented.'
    'drivers-gpu-tools.nvcleanstall' = 'Add NVCleanstall at the expected path before defining a restore route; no restore automation is implemented.'
    'drivers-gpu-tools.hwinfo-installer' = 'Create an uninstall contract before adding a restore route; no HWiNFO uninstall automation is implemented.'
    'drivers-gpu-tools.hwinfo-installed-sensor-monitoring' = 'Use Get-RooUtilitiesInventory.ps1 for read-only monitoring inventory; installed sensor monitoring has no restore path.'
    'drivers-gpu-tools.cpu-z-diagnostics' = 'Use Get-RooUtilitiesInventory.ps1 for diagnostics inventory; diagnostics-only capabilities have no restore path.'
    'drivers-gpu-tools.gpu-z-diagnostics' = 'Use Get-RooUtilitiesInventory.ps1 for diagnostics inventory; diagnostics-only capabilities have no restore path.'
    'drivers-gpu-tools.msi-afterburner' = 'Create a GPU profile rollback contract before adding a restore route; no Afterburner automation is implemented.'
    'drivers-gpu-tools.msi-kombustor' = 'Use Get-RooUtilitiesInventory.ps1 for benchmark package inventory; benchmark-only capability has no restore path.'
    'drivers-gpu-tools.latencymon' = 'Use Get-RooUtilitiesInventory.ps1 for diagnostics inventory; diagnostics-only capabilities have no restore path.'
    'drivers-gpu-tools.scewin' = 'Create a firmware restore manifest before adding a restore route; no SCEWIN automation is implemented.'
    'drivers-gpu-tools.prerequisite-dotnetfx35' = 'Create a feature restore plan before adding a restore route; no DISM or installer execution is implemented.'
    'drivers-gpu-tools.prerequisite-directx-june2010' = 'Create a feature restore plan before adding a restore route; no DXSETUP execution is implemented.'
}

$stateBefore = Get-StateEntryCount $repoRoot
Add-Check ($stateBefore -eq 0) 'backend/state is absent or empty before drivers router validation' "backend/state is not empty before drivers router validation: $stateBefore item(s)"

Start-ToolProcessWatch $forbiddenToolProcesses

$fragment = Get-Content -LiteralPath $fragmentPath -Raw | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$capabilities = @($fragment.capabilities)
$routes = @($manifest.routes)

Add-Check ([int](Get-PropertyValue $manifest 'schemaVersion' 0) -eq 1) 'drivers route manifest schemaVersion is 1' 'drivers route manifest schemaVersion mismatch'
Add-Check ([string](Get-PropertyValue $manifest 'family' '') -eq 'drivers-gpu-tools') 'drivers route manifest family is drivers-gpu-tools' 'drivers route manifest family mismatch'
Add-Check ($capabilities.Count -eq 25) 'drivers registry fragment has 25 capabilities' "drivers registry fragment expected 25 capabilities, found $($capabilities.Count)"
Add-Check ($routes.Count -eq $capabilities.Count) 'drivers route manifest has one route per capability' "drivers route count expected $($capabilities.Count), found $($routes.Count)"

$routeIds = @($routes | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })
$duplicateRouteIds = @($routeIds | Group-Object | Where-Object { $_.Count -ne 1 })
$duplicateRouteText = if ($duplicateRouteIds.Count -eq 0) { '' } else { @($duplicateRouteIds | ForEach-Object { $_.Name }) -join ', ' }
Add-Check ($duplicateRouteIds.Count -eq 0) 'drivers route manifest has no duplicate capabilityIds' "drivers route manifest duplicate ids: $duplicateRouteText"

$statusResults = @{}
$explainResults = @{}
$previewResults = @{}

foreach ($capability in $capabilities) {
    $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
    $route = Get-RouteById $manifest $capabilityId
    Add-Check ($null -ne $route) "$capabilityId has a route" "$capabilityId is missing a route"
    if ($null -eq $route) { continue }

    foreach ($sectionName in @('preview', 'apply', 'restore')) {
        $section = Get-RouteSection $route $sectionName
        Add-Check ($null -ne $section) "$capabilityId has $sectionName section" "$capabilityId missing $sectionName section"
        if ($null -eq $section) { continue }

        $statusOnly = [bool](Get-PropertyValue $section 'statusOnly' $false)
        $script = [string](Get-PropertyValue $section 'script' '')
        if (-not $statusOnly) {
            $scriptPath = Resolve-RepoPath $repoRoot $script
            Add-Check (-not [string]::IsNullOrWhiteSpace($script)) "$capabilityId $sectionName declares script" "$capabilityId $sectionName missing script"
            Add-Check (Test-Path -LiteralPath $scriptPath -PathType Leaf) "$capabilityId $sectionName referenced script exists" "$capabilityId $sectionName referenced script missing: $script"
        } else {
            Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $section 'reason' ''))) "$capabilityId $sectionName statusOnly reason is present" "$capabilityId $sectionName statusOnly reason is missing"
            Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $section 'nextRequiredStep' ''))) "$capabilityId $sectionName statusOnly nextRequiredStep is present" "$capabilityId $sectionName statusOnly nextRequiredStep is missing"
        }
    }

    $applySection = Get-RouteSection $route 'apply'
    $restoreSection = Get-RouteSection $route 'restore'
    Add-Check ([bool](Get-PropertyValue $applySection 'statusOnly' $false)) "$capabilityId apply is statusOnly" "$capabilityId apply is not statusOnly"
    Add-Check ([bool](Get-PropertyValue $restoreSection 'statusOnly' $false)) "$capabilityId restore is statusOnly" "$capabilityId restore is not statusOnly"
    Add-Check ([string](Get-PropertyValue $applySection 'nextRequiredStep' '') -eq [string]$expectedApplySteps[$capabilityId]) "$capabilityId apply next step matches route contract" "$capabilityId apply next step mismatch"
    Add-Check ([string](Get-PropertyValue $restoreSection 'nextRequiredStep' '') -eq [string]$expectedRestoreSteps[$capabilityId]) "$capabilityId restore next step matches route contract" "$capabilityId restore next step mismatch"

    $implementedBy = [string](Get-PropertyValue $capability 'implementedBy' '')
    $source = [string](Get-PropertyValue $capability 'source' '')
    if ($implementedBy -in @('external-tool', 'not-implemented') -or $source -eq 'utilities-folder') {
        $previewSection = Get-RouteSection $route 'preview'
        $previewStatusOnly = [bool](Get-PropertyValue $previewSection 'statusOnly' $false)
        $previewScript = [string](Get-PropertyValue $previewSection 'script' '')
        Add-Check (($previewStatusOnly -eq $true) -or ($previewScript -eq 'backend/scripts/Get-RooUtilitiesInventory.ps1')) "$capabilityId external-tool preview routes to inventory or statusOnly" "$capabilityId external-tool preview route is not inventory/statusOnly"
    }
}

$probeRoute = Get-RouteById $manifest 'drivers-gpu-tools.nvidia-nip-export-probe'
$probePreview = Get-RouteSection $probeRoute 'preview'
$probeArgs = @((Get-PropertyValue $probePreview 'args' @()))
Add-Check (-not ($probeArgs -contains '-AllowReadOnlyNvpiProbe')) 'NVPI export probe route does not pass -AllowReadOnlyNvpiProbe by default' 'NVPI export probe route unexpectedly passes -AllowReadOnlyNvpiProbe'

$executorRoute = Get-RouteById $manifest 'drivers-gpu-tools.nvidia-nip-gated-import'
$executorPreview = Get-RouteSection $executorRoute 'preview'
$executorArgs = @((Get-PropertyValue $executorPreview 'args' @()))
Add-Check (-not ($executorArgs -contains '-AllowRealNvpiExecution')) 'NVPI executor route does not pass -AllowRealNvpiExecution' 'NVPI executor route unexpectedly passes -AllowRealNvpiExecution'
Add-Check (-not ($executorArgs -contains 'Real')) 'NVPI executor route does not select Real mode' 'NVPI executor route unexpectedly selects Real mode'

foreach ($capability in $capabilities) {
    $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')

    foreach ($action in @('status', 'explain')) {
        $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', $action)
        if ($action -eq 'status') { $statusResults[$capabilityId] = $result } else { $explainResults[$capabilityId] = $result }
        $label = "$capabilityId $action"
        Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
        Test-CompleteEnvelope $result.json $label
        if ($null -eq $result.json) { continue }
        Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'completed') "$label status is completed" "$label status mismatch"
        Add-Check ([string](Get-PropertyValue $result.json 'family' '') -eq 'drivers-gpu-tools') "$label family is drivers-gpu-tools" "$label family mismatch"
        Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
        Add-Check ($null -ne (Get-PropertyValue (Get-PropertyValue $result.json 'evidence' $null) 'availability' $null)) "$label embeds availability evidence" "$label missing availability evidence"
    }
}

$previewDispatchCount = 0
$inventoryPreviewDispatchCount = 0
foreach ($capability in $capabilities) {
    $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
    $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', 'preview')
    $previewResults[$capabilityId] = $result
    $label = "$capabilityId preview"
    Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
    Test-CompleteEnvelope $result.json $label
    if ($null -eq $result.json) { continue }

    $machineAvailable = [bool](Get-PropertyValue $result.json 'machineAvailable' $false)
    $routedScript = Get-PropertyValue $result.json 'routedScript' $null
    if (-not $machineAvailable) {
        Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'unavailable') "$label returns unavailable when machine availability fails" "$label did not return unavailable"
        Add-Check ($null -eq $routedScript) "$label did not dispatch while unavailable" "$label dispatched while unavailable"
        Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $result.json 'nextRequiredStep' ''))) "$label reports a next required step while unavailable" "$label missing next required step while unavailable"
    } else {
        Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'completed') "$label completed when available" "$label did not complete when available"
        Add-Check ($null -ne $routedScript) "$label dispatched a preview script when available" "$label did not dispatch a preview script when available"
    }

    if ($null -ne $routedScript) {
        $previewDispatchCount += 1
        if ([string]$routedScript -eq 'backend/scripts/Get-RooUtilitiesInventory.ps1') {
            $inventoryPreviewDispatchCount += 1
            $evidence = Get-PropertyValue $result.json 'evidence' $null
            Add-Check ([string](Get-PropertyValue $evidence 'actionId' '') -eq 'drivers.utilities.inventory') "$label embeds utilities inventory evidence" "$label inventory evidence actionId mismatch"
            Add-Check ([bool](Get-PropertyValue (Get-PropertyValue $evidence 'summary' $null) 'noProcessesLaunched' $false)) "$label inventory evidence reports no process launch" "$label inventory evidence did not report no process launch"
        }
    }
}

Add-Check ($previewDispatchCount -gt 0) 'at least one implemented drivers preview dispatched' 'no implemented drivers preview dispatched'
Add-Check ($inventoryPreviewDispatchCount -gt 0) 'at least one external-tool preview dispatched to Get-RooUtilitiesInventory.ps1' 'no external-tool preview dispatched to Get-RooUtilitiesInventory.ps1'

foreach ($capability in $capabilities) {
    $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
    $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', 'apply')
    $label = "$capabilityId apply without confirmation"
    Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
    Test-CompleteEnvelope $result.json $label
    if ($null -eq $result.json) { continue }
    $status = [string](Get-PropertyValue $result.json 'status' '')
    Add-Check ($status -in @('approval-required', 'not-executable', 'unavailable')) "$label returns a non-mutating router status" "$label returned unexpected status $status"
    Add-Check ((Get-PropertyValue $result.json 'dryRun' $false) -eq $true) "$label is dryRun" "$label is not dryRun"
    Add-Check ((Get-PropertyValue $result.json 'changed' $true) -eq $false) "$label changed is false" "$label changed is not false"
    Add-Check ((Get-PropertyValue $result.json 'approvalSatisfied' $true) -eq $false) "$label approvalSatisfied is false" "$label approvalSatisfied is not false"
    Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
}

foreach ($capability in $capabilities) {
    $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
    foreach ($action in @('apply', 'restore')) {
        $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', $action, '-ConfirmApply')
        $label = "$capabilityId $action with confirmation"
        Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
        Test-CompleteEnvelope $result.json $label
        if ($null -eq $result.json) { continue }
        $status = [string](Get-PropertyValue $result.json 'status' '')
        Add-Check ($status -in @('not-executable', 'unavailable')) "$label returns statusOnly or unavailable" "$label returned unexpected status $status"
        Add-Check ((Get-PropertyValue $result.json 'dryRun' $false) -eq $true) "$label remains dryRun" "$label is not dryRun"
        Add-Check ((Get-PropertyValue $result.json 'changed' $true) -eq $false) "$label changed is false" "$label changed is not false"
        Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
        Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $result.json 'nextRequiredStep' ''))) "$label reports next required step" "$label missing next required step"
    }
}

$nvidiaCapabilityIds = @($capabilities | Where-Object {
    $detection = @((Get-PropertyValue (Get-PropertyValue $_ 'availability' $null) 'detection' @()))
    @($detection | Where-Object { [string](Get-PropertyValue $_ 'method' '') -eq 'hardware-gpu-vendor' -and [string](Get-PropertyValue $_ 'target' '') -eq 'NVIDIA' }).Count -gt 0
} | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })

Add-Check ($nvidiaCapabilityIds.Count -eq 8) 'drivers registry has 8 NVIDIA-gated capabilities' "drivers registry NVIDIA-gated capability count expected 8, got $($nvidiaCapabilityIds.Count)"
foreach ($capabilityId in $nvidiaCapabilityIds) {
    $status = $statusResults[$capabilityId].json
    Add-Check ($null -ne $status) "$capabilityId NVIDIA status envelope was captured" "$capabilityId NVIDIA status envelope missing"
    if ($null -eq $status) { continue }
    Add-Check ([bool](Get-PropertyValue $status 'machineAvailable' $true) -eq $false) "$capabilityId machineAvailable is false on this Intel Arc machine" "$capabilityId machineAvailable was not false"
    Add-Check ([string](Get-PropertyValue $status 'unavailableReason' '') -eq 'hardware-not-present') "$capabilityId unavailableReason is hardware-not-present" "$capabilityId unavailableReason mismatch"
}

$nvpiPreview = $previewResults['drivers-gpu-tools.nvidia-nip-profile-preview'].json
Test-CompleteEnvelope $nvpiPreview 'NVPI profile preview router result'
if ($null -ne $nvpiPreview) {
    $routingEvidence = Get-PropertyValue (Get-PropertyValue $nvpiPreview 'evidence' $null) 'routing' $null
    $previewSummary = Get-PropertyValue $routingEvidence 'preview' $null
    Add-Check ([string](Get-PropertyValue $previewSummary 'script' '') -eq 'backend/scripts/Preview-NvidiaNipProfile.ps1') 'NVPI profile preview route points to Preview-NvidiaNipProfile.ps1' 'NVPI profile preview route script mismatch'
    if ([bool](Get-PropertyValue $nvpiPreview 'machineAvailable' $false)) {
        Add-Check ([string](Get-PropertyValue $nvpiPreview 'routedScript' '') -eq 'backend/scripts/Preview-NvidiaNipProfile.ps1') 'NVPI profile preview dispatched when available' 'NVPI profile preview did not dispatch when available'
        Add-Check ([string](Get-PropertyValue (Get-PropertyValue $nvpiPreview 'evidence' $null) 'actionId' '') -eq 'drivers.nvidiaNip.previewProfile') 'NVPI profile preview embedded script evidence when available' 'NVPI profile preview evidence mismatch when available'
        Add-Check ([bool](Get-PropertyValue (Get-PropertyValue (Get-PropertyValue $nvpiPreview 'evidence' $null) 'summary' $null) 'willRunNvpi' $true) -eq $false) 'NVPI profile preview evidence reports no NVPI launch' 'NVPI profile preview evidence did not report no NVPI launch'
    } else {
        Add-Check ([string](Get-PropertyValue $nvpiPreview 'status' '') -eq 'unavailable') 'NVPI profile preview returns unavailable before dispatch on this machine' 'NVPI profile preview did not return unavailable before dispatch'
        Add-Check ([string](Get-PropertyValue $nvpiPreview 'unavailableReason' '') -eq 'hardware-not-present') 'NVPI profile preview unavailableReason is hardware-not-present' 'NVPI profile preview unavailableReason mismatch'
        Add-Check ($null -eq (Get-PropertyValue $nvpiPreview 'routedScript' $null)) 'NVPI profile preview did not launch hardware-independent preview because router availability gates first' 'NVPI profile preview unexpectedly dispatched on unavailable hardware'
    }
}

$launchedTools = @(Stop-ToolProcessWatch $forbiddenToolProcesses)
$launchedToolText = if ($launchedTools.Count -eq 0) { '' } else { @($launchedTools | ForEach-Object { [string](Get-PropertyValue $_ 'processName' '') }) -join ', ' }
Add-Check ($launchedTools.Count -eq 0) 'no NVIDIA/DDU/CPU-Z/GPU-Z/Afterburner/Kombustor/LatencyMon/SCEWIN/prerequisite tool process launched during router validation' "forbidden tool process launched: $launchedToolText"

$stateAfter = Get-StateEntryCount $repoRoot
Add-Check ($stateAfter -eq 0) 'backend/state is absent or empty after drivers router validation' "backend/state is not empty after drivers router validation: $stateAfter item(s)"
Add-Check ($stateBefore -eq $stateAfter) "backend/state item count unchanged at $stateAfter" "backend/state item count changed: before=$stateBefore after=$stateAfter"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Capability router drivers validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Capability router drivers validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
