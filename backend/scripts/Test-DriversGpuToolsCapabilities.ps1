Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$fragmentPath = Join-Path $repoRoot 'backend\capabilities\drivers-gpu-tools.json'
$detectorPath = Join-Path $repoRoot 'backend\scripts\Get-RooUtilitiesInventory.ps1'
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

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
    return $null -ne ($Object.PSObject.Properties[$Name])
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if (Has-Property $Object $Name) { return $Object.PSObject.Properties[$Name].Value }
    return $Default
}

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Failure "$Label missing: $Path"
        return $null
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        Add-Pass "$Label JSON parsed"
        return $json
    } catch {
        Add-Failure "$Label JSON parse failed: $($_.Exception.Message)"
        return $null
    }
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

function Resolve-UtilitiesTokenPath {
    param(
        [string]$Target,
        [string]$UtilitiesRoot
    )

    $resolved = ([string]$Target).Replace('{utilitiesRoot}', $UtilitiesRoot)
    return [System.IO.Path]::GetFullPath($resolved)
}

function Test-DetectionRule {
    param(
        [object]$Rule,
        [string]$CapabilityId,
        [string]$UtilitiesRoot,
        [object[]]$VideoControllers
    )

    $method = [string](Get-PropertyValue $Rule 'method' '')
    $target = [string](Get-PropertyValue $Rule 'target' '')

    switch ($method) {
        'file-exists' {
            try {
                $path = Resolve-UtilitiesTokenPath $target $UtilitiesRoot
                $rooted = [System.IO.Path]::IsPathRooted($path)
                $exists = Test-Path -LiteralPath $path -PathType Leaf
                Add-Check $rooted "Detection file path resolved for $CapabilityId -> $path (exists=$exists)" "Detection file path is not absolute for $CapabilityId -> $target"
            } catch {
                Add-Failure "Detection file path failed for $CapabilityId target=$target error=$($_.Exception.Message)"
            }
        }
        'hardware-gpu-vendor' {
            $match = @($VideoControllers | Where-Object {
                $text = ((Get-PropertyValue $_ 'Name' '') + ' ' + (Get-PropertyValue $_ 'PNPDeviceID' '')).ToString()
                if ($target -eq 'NVIDIA') { $text -match 'NVIDIA|VEN_10DE' }
                elseif ($target -eq 'AMD') { $text -match 'AMD|Advanced Micro Devices|VEN_1002' }
                elseif ($target -eq 'Intel') { $text -match 'Intel|VEN_8086' }
                else { $false }
            })
            Add-Pass "Detection hardware-gpu-vendor for $CapabilityId target=$target matched=$($match.Count -gt 0)"
        }
        'windows-feature' {
            try {
                $feature = $null
                if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
                    $feature = Get-WindowsOptionalFeature -Online -FeatureName $target -ErrorAction SilentlyContinue
                }
                $state = if ($null -ne $feature) { [string](Get-PropertyValue $feature 'State' 'unknown') } else { 'unavailable' }
                Add-Pass "Detection windows-feature for $CapabilityId target=$target state=$state"
            } catch {
                Add-Pass "Detection windows-feature for $CapabilityId target=$target query-error=$($_.Exception.Message)"
            }
        }
        default {
            Add-Pass "Detection $method for $CapabilityId target=$target is syntactically valid"
        }
    }
}

$stateBefore = Get-StateEntryCount

$fragment = Read-JsonFile $fragmentPath 'drivers-gpu-tools capability fragment'
if ($null -ne $fragment) {
    Add-Check ((Get-PropertyValue $fragment 'family' '') -eq 'drivers-gpu-tools') 'Fragment family is drivers-gpu-tools' 'Fragment family is not drivers-gpu-tools'

    $capabilities = @(Get-PropertyValue $fragment 'capabilities' @())
    Add-Check ($capabilities.Count -gt 0) "Fragment has $($capabilities.Count) capabilities" 'Fragment has no capabilities'

    $requiredFields = @(
        'capabilityId',
        'family',
        'displayName',
        'technicalName',
        'source',
        'implementedBy',
        'frontendLabel',
        'frontendTab',
        'riskLevel',
        'approvalRequired',
        'availability',
        'preview',
        'apply',
        'restore',
        'unavailableReason',
        'testEvidence'
    )
    $families = @('process-controls', 'cleanup-uninstall', 'drivers-gpu-tools', 'system-optimizations')
    $sources = @('process-lasso', 'revo', 'nvpi', 'gaming-toggles', 'winutil', 'utilities-folder', 'roo-native')
    $implementedByValues = @('roo-native', 'roo-script', 'external-tool', 'not-implemented')
    $riskLevels = @('safe', 'low', 'medium', 'high', 'critical')
    $previewStatuses = @('implemented', 'not-implemented')
    $applyStatuses = @('live', 'fixture-proven', 'allowlist-shim', 'helper-contract', 'preview-only', 'not-implemented')
    $restoreStatuses = @('live', 'fixture-proven', 'manifest-ready', 'not-applicable', 'not-implemented')
    $detectionMethods = @('builtin', 'file-exists', 'registry-key', 'registry-value', 'service-exists', 'command-on-path', 'hardware-gpu-vendor', 'windows-feature')
    $unavailableReasons = @('tool-not-present', 'hardware-not-present', 'requires-admin-token', 'requires-helper-manifest', 'helper-packaging-pending', 'blocked-by-acl', 'cli-unsupported', 'not-safely-executable-yet')
    $allowedLiveCapabilityIds = @()

    $ids = @($capabilities | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })
    $duplicateIds = @($ids | Group-Object | Where-Object { $_.Count -gt 1 })
    $duplicateIdNames = @($duplicateIds | ForEach-Object { $_.Name })
    Add-Check ($duplicateIds.Count -eq 0) 'Capability IDs are unique' "Duplicate capability IDs: $($duplicateIdNames -join ', ')"

    foreach ($capability in $capabilities) {
        $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '<missing>')

        foreach ($field in $requiredFields) {
            Add-Check (Has-Property $capability $field) "$capabilityId has required field $field" "$capabilityId missing required field $field"
        }

        Add-Check ($families -contains [string](Get-PropertyValue $capability 'family' '')) "$capabilityId family enum is valid" "$capabilityId has invalid family"
        Add-Check ([string](Get-PropertyValue $capability 'family' '') -eq 'drivers-gpu-tools') "$capabilityId belongs to lane family" "$capabilityId is outside lane family"
        Add-Check ($sources -contains [string](Get-PropertyValue $capability 'source' '')) "$capabilityId source enum is valid" "$capabilityId has invalid source"
        Add-Check ($implementedByValues -contains [string](Get-PropertyValue $capability 'implementedBy' '')) "$capabilityId implementedBy enum is valid" "$capabilityId has invalid implementedBy"
        Add-Check ($riskLevels -contains [string](Get-PropertyValue $capability 'riskLevel' '')) "$capabilityId riskLevel enum is valid" "$capabilityId has invalid riskLevel"
        Add-Check ((Get-PropertyValue $capability 'approvalRequired' $null) -is [bool]) "$capabilityId approvalRequired is boolean" "$capabilityId approvalRequired is not boolean"

        $preview = Get-PropertyValue $capability 'preview' $null
        $apply = Get-PropertyValue $capability 'apply' $null
        $restore = Get-PropertyValue $capability 'restore' $null
        Add-Check ($previewStatuses -contains [string](Get-PropertyValue $preview 'status' '')) "$capabilityId preview.status enum is valid" "$capabilityId has invalid preview.status"
        Add-Check ($applyStatuses -contains [string](Get-PropertyValue $apply 'status' '')) "$capabilityId apply.status enum is valid" "$capabilityId has invalid apply.status"
        Add-Check ($restoreStatuses -contains [string](Get-PropertyValue $restore 'status' '')) "$capabilityId restore.status enum is valid" "$capabilityId has invalid restore.status"

        if ([string](Get-PropertyValue $apply 'status' '') -eq 'live') {
            Add-Check ($allowedLiveCapabilityIds -contains $capabilityId) "$capabilityId live apply status is allowlisted" "$capabilityId must not claim apply.status live"
        }

        foreach ($sectionName in @('preview', 'apply', 'restore')) {
            $section = Get-PropertyValue $capability $sectionName $null
            if (Has-Property $section 'script') {
                $relativeScript = [string](Get-PropertyValue $section 'script' '')
                $scriptPath = Join-Path $repoRoot $relativeScript
                Add-Check (Test-Path -LiteralPath $scriptPath -PathType Leaf) "$capabilityId ${sectionName}.script exists: $relativeScript" "$capabilityId ${sectionName}.script missing: $relativeScript"
            }
        }

        $availability = Get-PropertyValue $capability 'availability' $null
        $detections = @(Get-PropertyValue $availability 'detection' @())
        Add-Check ($detections.Count -gt 0) "$capabilityId has detection rules" "$capabilityId has no detection rules"
        foreach ($rule in $detections) {
            $method = [string](Get-PropertyValue $rule 'method' '')
            $target = [string](Get-PropertyValue $rule 'target' '')
            Add-Check ($detectionMethods -contains $method) "$capabilityId detection method is valid: $method" "$capabilityId detection method is invalid: $method"
            Add-Check (-not [string]::IsNullOrWhiteSpace($target)) "$capabilityId detection target is present" "$capabilityId detection target is missing"
            if ($method -eq 'hardware-gpu-vendor') {
                Add-Check (@('NVIDIA', 'AMD', 'Intel') -contains $target) "$capabilityId hardware vendor target is valid" "$capabilityId hardware vendor target is invalid: $target"
            }
        }

        $reason = Get-PropertyValue $capability 'unavailableReason' $null
        Add-Check (($null -eq $reason) -or ($unavailableReasons -contains [string]$reason)) "$capabilityId unavailableReason is valid" "$capabilityId has invalid unavailableReason"

        $evidenceItems = @(Get-PropertyValue $capability 'testEvidence' @())
        Add-Check ($evidenceItems.Count -gt 0) "$capabilityId has test evidence" "$capabilityId has no test evidence"
        foreach ($evidence in $evidenceItems) {
            $relativeTest = [string](Get-PropertyValue $evidence 'test' '')
            $testPath = Join-Path $repoRoot $relativeTest
            Add-Check (Test-Path -LiteralPath $testPath -PathType Leaf) "$capabilityId test evidence exists: $relativeTest" "$capabilityId test evidence missing: $relativeTest"
            Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $evidence 'proves' ''))) "$capabilityId test evidence describes proof" "$capabilityId test evidence is missing proves text"
        }
    }

    $liveCapabilities = @($capabilities | Where-Object { [string](Get-PropertyValue (Get-PropertyValue $_ 'apply' $null) 'status' '') -eq 'live' })
    Add-Check ($liveCapabilities.Count -eq 0) 'No drivers-gpu-tools capability claims live apply support' "Unexpected live apply capability IDs: $((@($liveCapabilities | ForEach-Object { Get-PropertyValue $_ 'capabilityId' '' })) -join ', ')"

    $forbiddenScopeMatches = @($capabilities | Where-Object {
        ([string](Get-PropertyValue $_ 'capabilityId' '') -match 'devicecleanup|device-cleanup|afftool|affinity-tool') -or
        ([string](Get-PropertyValue $_ 'displayName' '') -match 'DeviceCleanup|Device Cleanup|AffTool')
    })
    Add-Check ($forbiddenScopeMatches.Count -eq 0) 'Lane fragment does not include DeviceCleanup or AffTool' "Fragment includes out-of-scope entries: $((@($forbiddenScopeMatches | ForEach-Object { Get-PropertyValue $_ 'capabilityId' '' })) -join ', ')"

    $nvcleanstall = @($capabilities | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq 'drivers-gpu-tools.nvcleanstall' })
    Add-Check ($nvcleanstall.Count -eq 1) 'NVCleanstall capability is represented once' "NVCleanstall capability count is $($nvcleanstall.Count)"
    if ($nvcleanstall.Count -eq 1) {
        Add-Check ([string](Get-PropertyValue $nvcleanstall[0] 'unavailableReason' '') -eq 'tool-not-present') 'NVCleanstall is marked tool-not-present' 'NVCleanstall is not marked tool-not-present'
        Add-Check ([string](Get-PropertyValue (Get-PropertyValue $nvcleanstall[0] 'apply' $null) 'status' '') -eq 'not-implemented') 'NVCleanstall apply is not implemented' 'NVCleanstall apply status is not correct'
    }

    $utilitiesRoot = if ([string]::IsNullOrWhiteSpace($env:ROO_UTILITIES_ROOT)) { 'C:\Users\serviroo\Desktop\Utilities' } else { $env:ROO_UTILITIES_ROOT }
    $utilitiesRoot = [System.IO.Path]::GetFullPath($utilitiesRoot)
    $videoControllers = @()
    try {
        $videoControllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    } catch {
        $videoControllers = @()
        Add-Pass "GPU CIM inventory unavailable during detection evidence: $($_.Exception.Message)"
    }

    foreach ($capability in $capabilities) {
        $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
        foreach ($rule in @(Get-PropertyValue (Get-PropertyValue $capability 'availability' $null) 'detection' @())) {
            Test-DetectionRule $rule $capabilityId $utilitiesRoot $videoControllers
        }
    }
}

Add-Check (Test-Path -LiteralPath $detectorPath -PathType Leaf) 'Utilities detector script exists' "Utilities detector script missing: $detectorPath"
if (Test-Path -LiteralPath $detectorPath -PathType Leaf) {
    try {
        $inventory = ConvertFrom-ScriptJson (& $detectorPath)
        Add-Check ([string](Get-PropertyValue $inventory 'actionId' '') -eq 'drivers.utilities.inventory') 'Utilities detector actionId is correct' 'Utilities detector actionId is incorrect'
        Add-Check ((Get-PropertyValue $inventory 'dryRun' $false) -eq $true) 'Utilities detector is dryRun true' 'Utilities detector is not dryRun true'
        Add-Check ([string](Get-PropertyValue $inventory 'status' '') -eq 'success') 'Utilities detector status is success' 'Utilities detector status is not success'
        Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $inventory 'correlationId' ''))) 'Utilities detector emits correlationId' 'Utilities detector missing correlationId'
        Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $inventory 'startedAtUtc' ''))) 'Utilities detector emits startedAtUtc' 'Utilities detector missing startedAtUtc'
        Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $inventory 'completedAtUtc' ''))) 'Utilities detector emits completedAtUtc' 'Utilities detector missing completedAtUtc'
        Add-Check ((Get-PropertyValue (Get-PropertyValue $inventory 'summary' $null) 'noProcessesLaunched' $false) -eq $true) 'Utilities detector reports no process launches' 'Utilities detector does not report no process launches'
        Add-Check ((Get-PropertyValue (Get-PropertyValue $inventory 'summary' $null) 'noSystemMutation' $false) -eq $true) 'Utilities detector reports no system mutation' 'Utilities detector does not report no system mutation'

        $tools = @(Get-PropertyValue $inventory 'tools' @())
        $expectedToolIds = @(
            'nvidia-profile-inspector',
            'base-profile-nip',
            'nvidia-59579-no-app',
            'nvidia-59579-with-app',
            'amd-graphics-26-2-2',
            'amd-chipset-8-02-18-557',
            'intel-chipset',
            'intel-network',
            'realtek-network',
            'driver-booster',
            'ddu',
            'nvcleanstall',
            'hwinfo-installer',
            'hwinfo-installed',
            'cpu-z',
            'gpu-z',
            'msi-afterburner',
            'msi-kombustor',
            'latencymon',
            'scewin',
            'dotnetfx35',
            'directx-runtime'
        )

        foreach ($toolId in $expectedToolIds) {
            $matches = @($tools | Where-Object { [string](Get-PropertyValue $_ 'id' '') -eq $toolId })
            Add-Check ($matches.Count -eq 1) "Utilities detector reports $toolId" "Utilities detector missing or duplicates $toolId"
            if ($matches.Count -eq 1) {
                $files = @(Get-PropertyValue $matches[0] 'files' @())
                Add-Check ($files.Count -gt 0) "Utilities detector gives file evidence for $toolId" "Utilities detector has no file evidence for $toolId"
                foreach ($file in $files) {
                    Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $file 'path' ''))) "Utilities detector file path present for $toolId" "Utilities detector file path missing for $toolId"
                    Add-Check ((Get-PropertyValue $file 'exists' $null) -is [bool]) "Utilities detector file exists flag is boolean for $toolId" "Utilities detector file exists flag invalid for $toolId"
                }
            }
        }

        $outOfScopeToolIds = @('device-cleanup', 'afftool')
        foreach ($toolId in $outOfScopeToolIds) {
            $matches = @($tools | Where-Object { [string](Get-PropertyValue $_ 'id' '') -eq $toolId })
            Add-Check ($matches.Count -eq 0) "Utilities detector excludes out-of-scope $toolId" "Utilities detector includes out-of-scope $toolId"
        }
    } catch {
        Add-Failure "Utilities detector failed: $($_.Exception.Message)"
    }
}

$stateAfter = Get-StateEntryCount
Add-Check ($stateBefore -eq $stateAfter) "backend/state item count unchanged at $stateAfter" "backend/state item count changed: before=$stateBefore after=$stateAfter"
Add-Check ($stateAfter -eq 0) 'backend/state remains absent or empty after drivers-gpu-tools validation' "backend/state is not empty after drivers-gpu-tools validation: $stateAfter item(s)"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS drivers-gpu-tools capability validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL drivers-gpu-tools capability validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
