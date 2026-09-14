Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$fragmentPath = Join-Path $repoRoot 'backend\capabilities\cleanup-uninstall.json'
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

function Test-HasProperty {
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
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function Get-RepoPath {
    param([string]$RelativePath)
    $normalized = $RelativePath -replace '/', '\'
    return Join-Path $repoRoot $normalized
}

function Test-ReferencedScript {
    param(
        [string]$CapabilityId,
        [string]$SectionName,
        [object]$Section
    )
    $script = [string](Get-PropertyValue $Section 'script' '')
    if ([string]::IsNullOrWhiteSpace($script)) { return }
    $path = Get-RepoPath $script
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Add-Pass "$CapabilityId $SectionName script exists: $script"
    } else {
        Add-Failure "$CapabilityId $SectionName script missing: $script"
    }
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Resolve-UtilitiesRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:ROO_UTILITIES_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:ROO_UTILITIES_ROOT)
    }
    return [System.IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Utilities'))
}

function Invoke-DetectionRule {
    param(
        [string]$CapabilityId,
        [object]$Rule,
        [string]$UtilitiesRoot
    )
    $method = [string](Get-PropertyValue $Rule 'method' '')
    $target = [string](Get-PropertyValue $Rule 'target' '')
    switch ($method) {
        'file-exists' {
            $resolved = $target.Replace('{utilitiesRoot}', $UtilitiesRoot)
            if (-not [System.IO.Path]::IsPathRooted($resolved)) {
                $resolved = Join-Path $repoRoot $resolved
            }
            $fullPath = [System.IO.Path]::GetFullPath($resolved)
            $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
            Write-Host "DETECT $CapabilityId file-exists $fullPath => $exists"
            Add-Pass "$CapabilityId file-exists detection resolved read-only"
        }
        'registry-key' {
            $exists = Test-Path -LiteralPath $target -PathType Container -ErrorAction SilentlyContinue
            Write-Host "DETECT $CapabilityId registry-key $target => $exists"
            Add-Pass "$CapabilityId registry-key detection ran read-only"
        }
        'registry-value' {
            Write-Host "DETECT $CapabilityId registry-value $target => not-evaluated"
            Add-Pass "$CapabilityId registry-value detection target accepted read-only"
        }
        'service-exists' {
            $exists = $false
            try {
                $exists = $null -ne (Get-Service -Name $target -ErrorAction SilentlyContinue)
            } catch {
                $exists = $false
            }
            Write-Host "DETECT $CapabilityId service-exists $target => $exists"
            Add-Pass "$CapabilityId service-exists detection ran read-only"
        }
        'command-on-path' {
            $exists = $null -ne (Get-Command $target -ErrorAction SilentlyContinue)
            Write-Host "DETECT $CapabilityId command-on-path $target => $exists"
            Add-Pass "$CapabilityId command-on-path detection ran read-only"
        }
        'hardware-gpu-vendor' {
            Write-Host "DETECT $CapabilityId hardware-gpu-vendor $target => aggregator-runtime"
            Add-Pass "$CapabilityId hardware GPU vendor detection target accepted"
        }
        'windows-feature' {
            Write-Host "DETECT $CapabilityId windows-feature $target => aggregator-runtime"
            Add-Pass "$CapabilityId Windows feature detection target accepted"
        }
        'builtin' {
            Write-Host "DETECT $CapabilityId builtin $target => assumed-present"
            Add-Pass "$CapabilityId builtin detection target accepted"
        }
        default {
            Add-Failure "$CapabilityId has unsupported detection method: $method"
        }
    }
}

$stateBefore = Get-StateEntryCount

$allowedFamilies = @('process-controls', 'cleanup-uninstall', 'drivers-gpu-tools', 'system-optimizations')
$allowedSources = @('process-lasso', 'revo', 'nvpi', 'fsosx-dash', 'winutil', 'utilities-folder', 'roo-native')
$allowedImplementedBy = @('roo-native', 'roo-script', 'external-tool', 'not-implemented')
$allowedRiskLevels = @('safe', 'low', 'medium', 'high', 'critical')
$allowedPreviewStatuses = @('implemented', 'not-implemented')
$allowedApplyStatuses = @('live', 'fixture-proven', 'allowlist-shim', 'helper-contract', 'preview-only', 'not-implemented')
$allowedRestoreStatuses = @('live', 'fixture-proven', 'manifest-ready', 'not-applicable', 'not-implemented')
$allowedDetectionMethods = @('builtin', 'file-exists', 'registry-key', 'registry-value', 'service-exists', 'command-on-path', 'hardware-gpu-vendor', 'windows-feature')
$allowedUnavailableReasons = @('tool-not-present', 'hardware-not-present', 'requires-admin-token', 'requires-helper-manifest', 'helper-packaging-pending', 'blocked-by-acl', 'cli-unsupported', 'not-safely-executable-yet')
$allowedFrontendTabs = @('Game Tune', 'Clean Junk', 'Drivers & Settings', 'Live Feel')
$allowedLiveCapabilityIds = @(
        'cleanup-uninstall.bulk-removal')

try {
    $fragment = Get-Content -LiteralPath $fragmentPath -Raw | ConvertFrom-Json
    Add-Pass 'cleanup-uninstall capability fragment parses as JSON'
} catch {
    Add-Failure "cleanup-uninstall capability fragment failed to parse: $($_.Exception.Message)"
    $fragment = $null
}

if ($null -ne $fragment) {
    $capabilities = @(Get-PropertyValue $fragment 'capabilities' @())
    if ($capabilities.Count -gt 0) {
        Add-Pass "fragment contains $($capabilities.Count) capability entries"
    } else {
        Add-Failure 'fragment contains no capability entries'
    }

    $seenIds = @{}
    foreach ($capability in $capabilities) {
        $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
        if ([string]::IsNullOrWhiteSpace($capabilityId)) {
            Add-Failure 'capability entry missing capabilityId'
            $capabilityId = '<missing-capabilityId>'
        }
        if ($seenIds.ContainsKey($capabilityId)) {
            Add-Failure "duplicate capabilityId: $capabilityId"
        } else {
            $seenIds[$capabilityId] = $true
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
        foreach ($field in $requiredFields) {
            if (Test-HasProperty $capability $field) {
                Add-Pass "$capabilityId has required field: $field"
            } else {
                Add-Failure "$capabilityId missing required field: $field"
            }
        }

        $family = [string](Get-PropertyValue $capability 'family' '')
        $source = [string](Get-PropertyValue $capability 'source' '')
        $implementedBy = [string](Get-PropertyValue $capability 'implementedBy' '')
        $riskLevel = [string](Get-PropertyValue $capability 'riskLevel' '')
        $frontendTab = [string](Get-PropertyValue $capability 'frontendTab' '')
        $preview = Get-PropertyValue $capability 'preview' $null
        $apply = Get-PropertyValue $capability 'apply' $null
        $restore = Get-PropertyValue $capability 'restore' $null
        $previewStatus = [string](Get-PropertyValue $preview 'status' '')
        $applyStatus = [string](Get-PropertyValue $apply 'status' '')
        $restoreStatus = [string](Get-PropertyValue $restore 'status' '')
        $unavailableReason = Get-PropertyValue $capability 'unavailableReason' $null

        if ($allowedFamilies -contains $family) { Add-Pass "$capabilityId family enum is valid" } else { Add-Failure "$capabilityId invalid family: $family" }
        if ($family -eq 'cleanup-uninstall') { Add-Pass "$capabilityId belongs to cleanup-uninstall family" } else { Add-Failure "$capabilityId belongs to wrong family: $family" }
        if ($allowedSources -contains $source) { Add-Pass "$capabilityId source enum is valid" } else { Add-Failure "$capabilityId invalid source: $source" }
        if ($allowedImplementedBy -contains $implementedBy) { Add-Pass "$capabilityId implementedBy enum is valid" } else { Add-Failure "$capabilityId invalid implementedBy: $implementedBy" }
        if ($allowedRiskLevels -contains $riskLevel) { Add-Pass "$capabilityId riskLevel enum is valid" } else { Add-Failure "$capabilityId invalid riskLevel: $riskLevel" }
        if ($allowedFrontendTabs -contains $frontendTab) { Add-Pass "$capabilityId frontendTab is valid" } else { Add-Failure "$capabilityId invalid frontendTab: $frontendTab" }
        if ((Get-PropertyValue $capability 'approvalRequired' $null) -is [bool]) { Add-Pass "$capabilityId approvalRequired is boolean" } else { Add-Failure "$capabilityId approvalRequired is not boolean" }
        if ($allowedPreviewStatuses -contains $previewStatus) { Add-Pass "$capabilityId preview status enum is valid" } else { Add-Failure "$capabilityId invalid preview status: $previewStatus" }
        if ($allowedApplyStatuses -contains $applyStatus) { Add-Pass "$capabilityId apply status enum is valid" } else { Add-Failure "$capabilityId invalid apply status: $applyStatus" }
        if ($allowedRestoreStatuses -contains $restoreStatus) { Add-Pass "$capabilityId restore status enum is valid" } else { Add-Failure "$capabilityId invalid restore status: $restoreStatus" }
        if ($null -eq $unavailableReason -or $allowedUnavailableReasons -contains [string]$unavailableReason) {
            Add-Pass "$capabilityId unavailableReason enum is valid"
        } else {
            Add-Failure "$capabilityId invalid unavailableReason: $unavailableReason"
        }

        if ($applyStatus -eq 'live' -and -not ($allowedLiveCapabilityIds -contains $capabilityId)) {
            Add-Failure "$capabilityId claims live apply without being in the allowed proven live list"
        }

        Test-ReferencedScript $capabilityId 'preview' $preview
        Test-ReferencedScript $capabilityId 'apply' $apply
        Test-ReferencedScript $capabilityId 'restore' $restore

        $availability = Get-PropertyValue $capability 'availability' $null
        $detectionRules = @(Get-PropertyValue $availability 'detection' @())
        if ($detectionRules.Count -gt 0) {
            Add-Pass "$capabilityId has at least one detection rule"
        } else {
            Add-Failure "$capabilityId has no detection rules"
        }
        foreach ($rule in $detectionRules) {
            $method = [string](Get-PropertyValue $rule 'method' '')
            $target = [string](Get-PropertyValue $rule 'target' '')
            if ($allowedDetectionMethods -contains $method) {
                Add-Pass "$capabilityId detection method enum is valid: $method"
            } else {
                Add-Failure "$capabilityId detection method enum is invalid: $method"
            }
            if ([string]::IsNullOrWhiteSpace($target)) {
                Add-Failure "$capabilityId detection target is empty for method $method"
            }
        }

        $evidence = @(Get-PropertyValue $capability 'testEvidence' @())
        if ($evidence.Count -gt 0) {
            Add-Pass "$capabilityId has test evidence"
        } else {
            Add-Failure "$capabilityId has no test evidence"
        }
        foreach ($item in $evidence) {
            $testPath = [string](Get-PropertyValue $item 'test' '')
            $proves = [string](Get-PropertyValue $item 'proves' '')
            if ([string]::IsNullOrWhiteSpace($testPath)) {
                Add-Failure "$capabilityId has empty testEvidence.test"
                continue
            }
            $resolvedTestPath = Get-RepoPath $testPath
            if (Test-Path -LiteralPath $resolvedTestPath -PathType Leaf) {
                Add-Pass "$capabilityId testEvidence exists: $testPath"
            } else {
                Add-Failure "$capabilityId missing testEvidence file: $testPath"
            }
            if (-not [string]::IsNullOrWhiteSpace($proves)) {
                Add-Pass "$capabilityId testEvidence has proves text"
            } else {
                Add-Failure "$capabilityId has empty testEvidence.proves text"
            }
        }
    }

    if (@($capabilities | Where-Object { [string](Get-PropertyValue (Get-PropertyValue $_ 'apply' $null) 'status' '') -eq 'live' }).Count -eq 0) {
        Add-Pass 'cleanup-uninstall fragment contains no live apply entries'
    }

    $utilitiesRoot = Resolve-UtilitiesRoot
    foreach ($capability in $capabilities) {
        $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
        $availability = Get-PropertyValue $capability 'availability' $null
        foreach ($rule in @(Get-PropertyValue $availability 'detection' @())) {
            Invoke-DetectionRule $capabilityId $rule $utilitiesRoot
        }
    }

    $applyCounts = @($capabilities | Group-Object { [string](Get-PropertyValue (Get-PropertyValue $_ 'apply' $null) 'status' '') } | Sort-Object Name)
    foreach ($group in $applyCounts) {
        Write-Host "COUNT apply.status $($group.Name) = $($group.Count)"
    }
}

try {
    $detectorOutput = & (Join-Path $PSScriptRoot 'Get-CleanupToolFacts.ps1')
    $detector = ($detectorOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($detector.actionId -eq 'apps.cleanupToolFacts' -and $detector.dryRun -eq $true -and $detector.status -eq 'completed' -and -not [string]::IsNullOrWhiteSpace([string]$detector.correlationId)) {
        Add-Pass 'Get-CleanupToolFacts emits a dry-run action envelope'
    } else {
        Add-Failure 'Get-CleanupToolFacts did not emit the expected dry-run action envelope'
    }
    if ($detector.summary.willLaunchTools -eq $false -and $detector.summary.willChangeSystem -eq $false) {
        Add-Pass 'Get-CleanupToolFacts reports no tool launch and no system change'
    } else {
        Add-Failure 'Get-CleanupToolFacts reported a launch or system change'
    }
    foreach ($tool in @($detector.tools)) {
        Write-Host "TOOL $($tool.toolId) exists=$($tool.exists) productVersion=$($tool.productVersion) fileVersion=$($tool.fileVersion)"
        if ($tool.launchAttempted -eq $false) {
            Add-Pass "Get-CleanupToolFacts did not launch $($tool.toolId)"
        } else {
            Add-Failure "Get-CleanupToolFacts reported launchAttempted for $($tool.toolId)"
        }
    }
} catch {
    Add-Failure "Get-CleanupToolFacts invocation failed: $($_.Exception.Message)"
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains absent or empty after cleanup-uninstall capability validation'
} else {
    Add-Failure "backend/state is not empty or changed during validation: before=$stateBefore after=$stateAfter"
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Cleanup uninstall capability validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Cleanup uninstall capability validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
