Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$fragmentPath = Join-Path $repoRoot 'backend\capabilities\system-optimizations.json'
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
    if (-not (Has-Property -Object $Object -Name $Name)) { return $Default }
    return $Object.PSObject.Properties[$Name].Value
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Resolve-RepoPath {
    param([string]$RelativePath)
    return Join-Path $repoRoot $RelativePath
}

function Convert-RegistryTarget {
    param([string]$Target)
    $parts = $Target -split '\|', 2
    $path = $parts[0]
    $name = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    if ($path -match '^(HKLM|HKCU|HKCR|HKU|HKCC)\\') {
        $path = $path -replace '^(HKLM|HKCU|HKCR|HKU|HKCC)\\', '$1:\'
    }
    return [pscustomobject]@{
        path = $path
        name = $name
    }
}

function Resolve-DetectionFilePath {
    param([string]$Target)
    $utilitiesRoot = if ([string]::IsNullOrWhiteSpace($env:ROO_INDUSTRIES_UTILITIES_ROOT)) { (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Utilities') } else { $env:ROO_INDUSTRIES_UTILITIES_ROOT }
    $expanded = $Target.Replace('{utilitiesRoot}', $utilitiesRoot)
    $expanded = [Environment]::ExpandEnvironmentVariables($expanded)
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $repoRoot $expanded
    }
    return [System.IO.Path]::GetFullPath($expanded)
}

function Test-DetectionRule {
    param(
        [object]$Capability,
        [object]$Rule
    )

    $capabilityId = [string](Get-PropertyValue -Object $Capability -Name 'capabilityId')
    $method = [string](Get-PropertyValue -Object $Rule -Name 'method')
    $target = [string](Get-PropertyValue -Object $Rule -Name 'target')
    if ([string]::IsNullOrWhiteSpace($method) -or [string]::IsNullOrWhiteSpace($target)) {
        Add-Failure "$capabilityId has an incomplete detection rule"
        return
    }

    switch ($method) {
        'builtin' {
            Write-Host "INFO detection $capabilityId builtin target=$target result=assumed-present"
        }
        'file-exists' {
            try {
                $resolved = Resolve-DetectionFilePath -Target $target
                if (-not [System.IO.Path]::IsPathRooted($resolved)) {
                    Add-Failure "$capabilityId file-exists target did not resolve to absolute path: $target"
                    return
                }
                $exists = Test-Path -LiteralPath $resolved
                Write-Host "INFO detection $capabilityId file-exists target=$target resolved=$resolved exists=$exists"
            } catch {
                Add-Failure "$capabilityId file-exists target failed to resolve: $target :: $($_.Exception.Message)"
            }
        }
        'registry-key' {
            $registry = Convert-RegistryTarget -Target $target
            $exists = $false
            $errorText = $null
            try { $exists = Test-Path -LiteralPath $registry.path } catch { $errorText = $_.Exception.Message }
            Write-Host "INFO detection $capabilityId registry-key target=$($registry.path) exists=$exists error=$errorText"
        }
        'registry-value' {
            $registry = Convert-RegistryTarget -Target $target
            $exists = $false
            $valuePresent = $false
            $errorText = $null
            try {
                $exists = Test-Path -LiteralPath $registry.path
                if ($exists -and -not [string]::IsNullOrWhiteSpace($registry.name)) {
                    $item = Get-ItemProperty -LiteralPath $registry.path -Name $registry.name -ErrorAction Stop
                    $valuePresent = ($null -ne $item.PSObject.Properties[$registry.name])
                }
            } catch {
                $errorText = $_.Exception.Message
            }
            Write-Host "INFO detection $capabilityId registry-value target=$($registry.path)|$($registry.name) keyExists=$exists valuePresent=$valuePresent error=$errorText"
        }
        'service-exists' {
            $exists = $false
            $errorText = $null
            try {
                $service = Get-Service -Name $target -ErrorAction Stop
                $exists = ($null -ne $service)
            } catch {
                $errorText = $_.Exception.Message
            }
            Write-Host "INFO detection $capabilityId service-exists target=$target exists=$exists error=$errorText"
        }
        'command-on-path' {
            $available = $false
            $source = $null
            $errorText = $null
            try {
                $command = Get-Command -Name $target -ErrorAction Stop
                $available = ($null -ne $command)
                $source = [string]$command.Source
            } catch {
                $errorText = $_.Exception.Message
            }
            Write-Host "INFO detection $capabilityId command-on-path target=$target available=$available source=$source error=$errorText"
        }
        'hardware-gpu-vendor' {
            $matched = $false
            $errorText = $null
            try {
                $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
                $matched = (@($gpus | Where-Object { ([string]$_.Name) -match [regex]::Escape($target) -or ([string]$_.AdapterCompatibility) -match [regex]::Escape($target) }).Count -gt 0)
            } catch {
                $errorText = $_.Exception.Message
            }
            Write-Host "INFO detection $capabilityId hardware-gpu-vendor target=$target matched=$matched error=$errorText"
        }
        'windows-feature' {
            $state = $null
            $errorText = $null
            try {
                if (Get-Command -Name Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
                    $feature = Get-WindowsOptionalFeature -Online -FeatureName $target -ErrorAction Stop
                    $state = [string]$feature.State
                } else {
                    $errorText = 'Get-WindowsOptionalFeature command unavailable'
                }
            } catch {
                $message = $_.Exception.Message
                if ($message -match 'requires elevation') {
                    $errorText = 'requires-admin-token'
                } else {
                    $errorText = $message
                }
            }
            Write-Host "INFO detection $capabilityId windows-feature target=$target state=$state error=$errorText"
        }
        default {
            Add-Failure "$capabilityId uses unsupported detection method: $method"
        }
    }
}

function Test-RelativePathExists {
    param(
        [string]$RelativePath,
        [string]$Context
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        Add-Failure "$Context has an empty path"
        return
    }
    $path = Resolve-RepoPath -RelativePath $RelativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Add-Pass "$Context exists: $RelativePath"
    } else {
        Add-Failure "$Context missing: $RelativePath"
    }
}

$stateBefore = Get-StateEntryCount

$fragment = $null
try {
    $fragment = Get-Content -LiteralPath $fragmentPath -Raw | ConvertFrom-Json
    Add-Pass 'System optimization capability fragment parses as JSON'
} catch {
    Add-Failure "System optimization capability fragment failed JSON parse: $($_.Exception.Message)"
}

$capabilities = @()
if ($null -ne $fragment) {
    $capabilities = @(Get-PropertyValue -Object $fragment -Name 'capabilities' -Default @())
    if ($capabilities.Count -gt 0) {
        Add-Pass "System optimization fragment contains $($capabilities.Count) capabilities"
    } else {
        Add-Failure 'System optimization fragment contains no capabilities'
    }
}

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
$allowedFamilies = @('process-controls', 'cleanup-uninstall', 'drivers-gpu-tools', 'system-optimizations')
$allowedSources = @('process-lasso', 'revo', 'nvpi', 'fsosx-dash', 'winutil', 'utilities-folder', 'roo-industries-native')
$allowedImplementedBy = @('roo-industries-native', 'roo-industries-script', 'external-tool', 'not-implemented')
$allowedRisk = @('safe', 'low', 'medium', 'high', 'critical')
$allowedPreviewStatus = @('implemented', 'not-implemented')
$allowedApplyStatus = @('live', 'fixture-proven', 'allowlist-shim', 'helper-contract', 'preview-only', 'not-implemented')
$allowedRestoreStatus = @('live', 'fixture-proven', 'manifest-ready', 'not-applicable', 'not-implemented')
$allowedDetectionMethod = @('builtin', 'file-exists', 'registry-key', 'registry-value', 'service-exists', 'command-on-path', 'hardware-gpu-vendor', 'windows-feature')
$allowedUnavailableReason = @('tool-not-present', 'hardware-not-present', 'requires-admin-token', 'requires-helper-manifest', 'helper-packaging-pending', 'blocked-by-acl', 'cli-unsupported', 'not-safely-executable-yet')
$allowedFrontendTabs = @('Game Tune', 'Clean Junk', 'Drivers & Settings', 'Live Feel')
$allowedLiveCapabilityIds = @(
    'system-optimizations.timer-resolution',
    'system-optimizations.power-plan'
)

$seenCapabilityIds = @{}
foreach ($capability in $capabilities) {
    $capabilityId = [string](Get-PropertyValue -Object $capability -Name 'capabilityId' -Default '<missing>')
    foreach ($field in $requiredFields) {
        if (-not (Has-Property -Object $capability -Name $field)) {
            Add-Failure "$capabilityId missing required field: $field"
        }
    }

    if ($seenCapabilityIds.ContainsKey($capabilityId)) {
        Add-Failure "Duplicate capabilityId: $capabilityId"
    } else {
        $seenCapabilityIds[$capabilityId] = $true
    }

    if ($allowedFamilies -notcontains [string](Get-PropertyValue -Object $capability -Name 'family')) {
        Add-Failure "$capabilityId has invalid family"
    }
    if ([string](Get-PropertyValue -Object $capability -Name 'family') -ne 'system-optimizations') {
        Add-Failure "$capabilityId is outside lane family"
    }
    if ($allowedSources -notcontains [string](Get-PropertyValue -Object $capability -Name 'source')) {
        Add-Failure "$capabilityId has invalid source"
    }
    if ($allowedImplementedBy -notcontains [string](Get-PropertyValue -Object $capability -Name 'implementedBy')) {
        Add-Failure "$capabilityId has invalid implementedBy"
    }
    if ($allowedRisk -notcontains [string](Get-PropertyValue -Object $capability -Name 'riskLevel')) {
        Add-Failure "$capabilityId has invalid riskLevel"
    }
    if ($allowedFrontendTabs -notcontains [string](Get-PropertyValue -Object $capability -Name 'frontendTab')) {
        Add-Failure "$capabilityId has invalid frontendTab"
    }
    if ((Get-PropertyValue -Object $capability -Name 'approvalRequired') -isnot [bool]) {
        Add-Failure "$capabilityId approvalRequired is not boolean"
    }

    $preview = Get-PropertyValue -Object $capability -Name 'preview'
    $apply = Get-PropertyValue -Object $capability -Name 'apply'
    $restore = Get-PropertyValue -Object $capability -Name 'restore'
    $availability = Get-PropertyValue -Object $capability -Name 'availability'
    $testEvidence = @(Get-PropertyValue -Object $capability -Name 'testEvidence' -Default @())

    if ($allowedPreviewStatus -notcontains [string](Get-PropertyValue -Object $preview -Name 'status')) {
        Add-Failure "$capabilityId has invalid preview.status"
    }
    if ($allowedApplyStatus -notcontains [string](Get-PropertyValue -Object $apply -Name 'status')) {
        Add-Failure "$capabilityId has invalid apply.status"
    }
    if ($allowedRestoreStatus -notcontains [string](Get-PropertyValue -Object $restore -Name 'status')) {
        Add-Failure "$capabilityId has invalid restore.status"
    }

    $unavailableReason = Get-PropertyValue -Object $capability -Name 'unavailableReason'
    if ($null -ne $unavailableReason -and $allowedUnavailableReason -notcontains [string]$unavailableReason) {
        Add-Failure "$capabilityId has invalid unavailableReason"
    }

    foreach ($sectionName in @('preview', 'apply', 'restore')) {
        $section = Get-PropertyValue -Object $capability -Name $sectionName
        $script = Get-PropertyValue -Object $section -Name 'script'
        if ($null -ne $script -and -not [string]::IsNullOrWhiteSpace([string]$script)) {
            Test-RelativePathExists -RelativePath ([string]$script) -Context "$capabilityId $sectionName script"
        }
    }

    if ($testEvidence.Count -lt 1) {
        Add-Failure "$capabilityId has no testEvidence"
    }
    foreach ($evidence in $testEvidence) {
        $testPath = [string](Get-PropertyValue -Object $evidence -Name 'test')
        $proves = [string](Get-PropertyValue -Object $evidence -Name 'proves')
        Test-RelativePathExists -RelativePath $testPath -Context "$capabilityId testEvidence"
        if ([string]::IsNullOrWhiteSpace($proves)) {
            Add-Failure "$capabilityId has empty testEvidence.proves"
        }
    }

    $detectionRules = @(Get-PropertyValue -Object $availability -Name 'detection' -Default @())
    if ($detectionRules.Count -lt 1) {
        Add-Failure "$capabilityId has no availability detection rules"
    }
    foreach ($rule in $detectionRules) {
        $method = [string](Get-PropertyValue -Object $rule -Name 'method')
        if ($allowedDetectionMethod -notcontains $method) {
            Add-Failure "$capabilityId has invalid detection method: $method"
        } else {
            Test-DetectionRule -Capability $capability -Rule $rule
        }
    }
}

$disallowedLive = @($capabilities | Where-Object {
    [string](Get-PropertyValue -Object (Get-PropertyValue -Object $_ -Name 'apply') -Name 'status') -eq 'live' -and
    $allowedLiveCapabilityIds -notcontains [string](Get-PropertyValue -Object $_ -Name 'capabilityId')
})
if ($disallowedLive.Count -eq 0) {
    Add-Pass 'No system optimization capability is marked live outside the proven timer/power list'
} else {
    Add-Failure "Disallowed live apply capability count: $($disallowedLive.Count)"
}

$standby = @($capabilities | Where-Object { [string](Get-PropertyValue -Object $_ -Name 'capabilityId') -eq 'system-optimizations.standby-memory' }) | Select-Object -First 1
if ($standby -and [string](Get-PropertyValue -Object (Get-PropertyValue -Object $standby -Name 'apply') -Name 'status') -eq 'helper-contract' -and [string](Get-PropertyValue -Object $standby -Name 'unavailableReason') -eq 'helper-packaging-pending') {
    Add-Pass 'Standby memory is helper-contract with helper-packaging-pending'
} else {
    Add-Failure 'Standby memory does not match required helper-contract status'
}

$shader = @($capabilities | Where-Object { [string](Get-PropertyValue -Object $_ -Name 'capabilityId') -eq 'system-optimizations.shader-cache' }) | Select-Object -First 1
if ($shader -and [string](Get-PropertyValue -Object (Get-PropertyValue -Object $shader -Name 'apply') -Name 'status') -eq 'fixture-proven') {
    Add-Pass 'Shader cache is fixture-proven'
} else {
    Add-Failure 'Shader cache is not fixture-proven'
}

$network = @($capabilities | Where-Object { [string](Get-PropertyValue -Object $_ -Name 'capabilityId') -eq 'system-optimizations.network-tweaks' }) | Select-Object -First 1
if ($network -and [string](Get-PropertyValue -Object $network -Name 'riskLevel') -eq 'high' -and [string](Get-PropertyValue -Object (Get-PropertyValue -Object $network -Name 'apply') -Name 'status') -in @('preview-only', 'not-implemented')) {
    Add-Pass 'Network tweaks are high risk and not live'
} else {
    Add-Failure 'Network tweaks do not preserve high-risk non-live status'
}

$features = @($capabilities | Where-Object { [string](Get-PropertyValue -Object $_ -Name 'capabilityId') -eq 'system-optimizations.windows-features-fixes' }) | Select-Object -First 1
if ($features -and [string](Get-PropertyValue -Object (Get-PropertyValue -Object $features -Name 'apply') -Name 'status') -eq 'not-implemented' -and [string](Get-PropertyValue -Object $features -Name 'technicalName') -match 'DISM') {
    Add-Pass 'Windows features/fixes are DISM-based and not implemented for apply'
} else {
    Add-Failure 'Windows features/fixes entry does not match required DISM not-implemented status'
}

$factsPath = Resolve-RepoPath -RelativePath 'backend\scripts\Get-SystemOptimizationFacts.ps1'
if (Test-Path -LiteralPath $factsPath -PathType Leaf) {
    try {
        $factsOutput = & $factsPath
        $facts = ($factsOutput -join [Environment]::NewLine) | ConvertFrom-Json
        if ($facts.actionId -eq 'systemOptimizations.facts' -and $facts.dryRun -eq $true -and $facts.status -eq 'completed' -and $facts.correlationId) {
            Add-Pass 'System optimization facts detector emits a dry-run action envelope'
        } else {
            Add-Failure 'System optimization facts detector did not emit expected dry-run action envelope'
        }
        if ($facts.summary.willChangeSystem -eq $false -and $facts.summary.willWriteRegistry -eq $false -and $facts.summary.willEditServices -eq $false -and $facts.summary.willLaunchExternalUtility -eq $false -and $facts.summary.willRunDism -eq $false) {
            Add-Pass 'System optimization facts detector declares no system mutation or utility launch'
        } else {
            Add-Failure 'System optimization facts detector summary claims a mutation or utility launch'
        }
    } catch {
        Add-Failure "System optimization facts detector failed: $($_.Exception.Message)"
    }
} else {
    Add-Failure 'System optimization facts detector script is missing'
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after system optimization capability validation'
} else {
    Add-Failure "backend/state is not empty or changed during validation: before=$stateBefore after=$stateAfter"
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS System optimization capability validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL System optimization capability validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
