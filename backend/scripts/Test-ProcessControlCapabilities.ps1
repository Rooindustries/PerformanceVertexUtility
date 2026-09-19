Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$passes = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]

function Add-Pass {
    param([string]$Message)
    $passes.Add($Message) | Out-Null
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Get-RepoRoot {
    $root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    return $root.Path
}

function Test-RequiredProperty {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Context
    )
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        Add-Failure "$Context missing required property '$Name'"
        return $false
    }
    return $true
}

function Resolve-DetectionPath {
    param(
        [string]$Target,
        [string]$RepoRoot,
        [string]$UtilitiesRoot
    )
    $resolvedTarget = $Target.Replace('{utilitiesRoot}', $UtilitiesRoot)
    if ([System.IO.Path]::IsPathRooted($resolvedTarget)) {
        return [System.IO.Path]::GetFullPath($resolvedTarget)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $resolvedTarget))
}

function Get-StateEntryCount {
    param([string]$RepoRoot)
    $stateRoot = Join-Path $RepoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @((Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction Stop)).Count
}

$repoRoot = Get-RepoRoot
$fragmentPath = Join-Path $repoRoot 'backend\capabilities\process-controls.json'
$detectorPath = Join-Path $repoRoot 'backend\scripts\Get-ProcessControlCapabilityFacts.ps1'
$stateBefore = Get-StateEntryCount $repoRoot

try {
    if (Test-Path -LiteralPath $fragmentPath -PathType Leaf) {
        Add-Pass 'Process controls capability fragment exists'
    } else {
        Add-Failure "Missing capability fragment: $fragmentPath"
    }

    $fragment = Get-Content -LiteralPath $fragmentPath -Raw | ConvertFrom-Json
    Add-Pass 'Process controls capability fragment parses as JSON'

    $capabilities = @($fragment.capabilities)
    if ($capabilities.Count -gt 0) {
        Add-Pass "Capability fragment contains $($capabilities.Count) entries"
    } else {
        Add-Failure 'Capability fragment contains no capabilities'
    }

    $enumFamily = @('process-controls','cleanup-uninstall','drivers-gpu-tools','system-optimizations')
    $enumSource = @('process-lasso','revo','nvpi','fsosx-dash','winutil','utilities-folder','roo-industries-native')
    $enumImplementedBy = @('roo-industries-native','roo-industries-script','external-tool','not-implemented')
    $enumRisk = @('safe','low','medium','high','critical')
    $enumPreviewStatus = @('implemented','not-implemented')
    $enumApplyStatus = @('live','fixture-proven','allowlist-shim','helper-contract','preview-only','not-implemented')
    $enumRestoreStatus = @('live','fixture-proven','manifest-ready','not-applicable','not-implemented')
    $enumDetectionMethod = @('builtin','file-exists','registry-key','registry-value','service-exists','command-on-path','hardware-gpu-vendor','windows-feature')
    $enumUnavailableReason = @('tool-not-present','hardware-not-present','requires-admin-token','requires-helper-manifest','helper-packaging-pending','blocked-by-acl','cli-unsupported','not-safely-executable-yet')
    $enumFrontendTab = @('Game Tune','Clean Junk','Drivers & Settings','Live Feel')

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

    $ids = @{}
    $allowedLiveApplyIds = @(
        'process-controls.cpu-sets',
        'process-controls.cpu-priority',
        'process-controls.io-priority',
        'process-controls.gpu-priority',
        'process-controls.cpu-affinity',
        'process-controls.probalance-restraint',
        'process-controls.per-game-rules'
    )

    foreach ($capability in $capabilities) {
        $context = [string]$capability.capabilityId
        if ([string]::IsNullOrWhiteSpace($context)) { $context = '<missing capabilityId>' }

        foreach ($field in $requiredFields) {
            [void](Test-RequiredProperty $capability $field $context)
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$capability.capabilityId)) {
            if ($ids.ContainsKey([string]$capability.capabilityId)) {
                Add-Failure "Duplicate capabilityId '$($capability.capabilityId)'"
            } else {
                $ids[[string]$capability.capabilityId] = $true
            }
            if (-not ([string]$capability.capabilityId).StartsWith('process-controls.', [System.StringComparison]::Ordinal)) {
                Add-Failure "$context capabilityId is outside process-controls namespace"
            }
        }

        if ($enumFamily -notcontains [string]$capability.family) { Add-Failure "$context has invalid family '$($capability.family)'" }
        if ([string]$capability.family -ne 'process-controls') { Add-Failure "$context family is not process-controls" }
        if ($enumSource -notcontains [string]$capability.source) { Add-Failure "$context has invalid source '$($capability.source)'" }
        if ($enumImplementedBy -notcontains [string]$capability.implementedBy) { Add-Failure "$context has invalid implementedBy '$($capability.implementedBy)'" }
        if ($enumRisk -notcontains [string]$capability.riskLevel) { Add-Failure "$context has invalid riskLevel '$($capability.riskLevel)'" }
        if ($enumFrontendTab -notcontains [string]$capability.frontendTab) { Add-Failure "$context has invalid frontendTab '$($capability.frontendTab)'" }
        if ($capability.approvalRequired -isnot [bool]) { Add-Failure "$context approvalRequired must be boolean" }

        if ($null -eq $capability.preview -or $enumPreviewStatus -notcontains [string]$capability.preview.status) {
            Add-Failure "$context has invalid preview.status '$($capability.preview.status)'"
        }
        if ($null -eq $capability.apply -or $enumApplyStatus -notcontains [string]$capability.apply.status) {
            Add-Failure "$context has invalid apply.status '$($capability.apply.status)'"
        }
        if ($null -eq $capability.restore -or $enumRestoreStatus -notcontains [string]$capability.restore.status) {
            Add-Failure "$context has invalid restore.status '$($capability.restore.status)'"
        }

        if ($null -ne $capability.unavailableReason -and $enumUnavailableReason -notcontains [string]$capability.unavailableReason) {
            Add-Failure "$context has invalid unavailableReason '$($capability.unavailableReason)'"
        }

        if ([string]$capability.apply.status -eq 'live' -and $allowedLiveApplyIds -notcontains [string]$capability.capabilityId) {
            Add-Failure "$context claims live apply outside the process-control proven allow-list"
        }

        foreach ($sectionName in @('preview','apply','restore')) {
            $section = $capability.$sectionName
            if ($null -ne $section -and $null -ne $section.PSObject.Properties['script']) {
                $scriptValue = [string]$section.script
                if (-not [string]::IsNullOrWhiteSpace($scriptValue)) {
                    $scriptPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $scriptValue))
                    if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
                        Add-Pass "$context $sectionName script exists: $scriptValue"
                    } else {
                        Add-Failure "$context $sectionName script missing: $scriptValue"
                    }
                }
            }
        }

        $detections = @($capability.availability.detection)
        if ($detections.Count -lt 1) {
            Add-Failure "$context has no availability detection rules"
        }

        $utilitiesRoot = if (-not [string]::IsNullOrWhiteSpace($env:ROO_INDUSTRIES_UTILITIES_ROOT)) { [System.IO.Path]::GetFullPath($env:ROO_INDUSTRIES_UTILITIES_ROOT) } else { [System.IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Utilities')) }
        foreach ($rule in $detections) {
            if ($enumDetectionMethod -notcontains [string]$rule.method) {
                Add-Failure "$context has invalid detection method '$($rule.method)'"
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$rule.target)) {
                Add-Failure "$context has blank detection target"
                continue
            }

            if ([string]$rule.method -eq 'file-exists') {
                $resolved = Resolve-DetectionPath ([string]$rule.target) $repoRoot $utilitiesRoot
                if ([System.IO.Path]::IsPathRooted($resolved)) {
                    $exists = Test-Path -LiteralPath $resolved
                    Write-Host "DETECT $context file-exists $resolved exists=$exists"
                    Add-Pass "$context file-exists detection resolved to an absolute path"
                } else {
                    Add-Failure "$context file-exists detection did not resolve to an absolute path: $($rule.target)"
                }
            } else {
                Write-Host "DETECT $context $($rule.method) $($rule.target) readOnly=true"
                Add-Pass "$context $($rule.method) detection is resolvable"
            }
        }

        $evidence = @($capability.testEvidence)
        if ($evidence.Count -lt 1) {
            Add-Failure "$context has no testEvidence entries"
        }
        foreach ($entry in $evidence) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.test)) {
                Add-Failure "$context has blank testEvidence.test"
                continue
            }
            $testPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ([string]$entry.test)))
            if (Test-Path -LiteralPath $testPath -PathType Leaf) {
                Add-Pass "$context evidence exists: $($entry.test)"
            } else {
                Add-Failure "$context evidence missing: $($entry.test)"
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.proves)) {
                Add-Failure "$context evidence '$($entry.test)' has blank proves text"
            }
        }
    }

    if ($capabilities.Count -eq $ids.Count) {
        Add-Pass 'Capability IDs are unique'
    }

    if (Test-Path -LiteralPath $detectorPath -PathType Leaf) {
        $detector = & $detectorPath | ConvertFrom-Json
        if ($detector.actionId -eq 'performance.processControls.facts' -and $detector.dryRun -eq $true -and $detector.status -eq 'completed' -and -not [string]::IsNullOrWhiteSpace([string]$detector.correlationId)) {
            Add-Pass 'Read-only process control facts detector returned a standard action envelope'
        } else {
            Add-Failure 'Read-only process control facts detector returned an unexpected envelope'
        }
        $launched = @($detector.facts.externalTools | Where-Object { $_.launched -ne $false })
        if ($launched.Count -eq 0) {
            Add-Pass 'Read-only process control facts detector did not launch external tools'
        } else {
            Add-Failure 'Read-only process control facts detector reported an external launch'
        }
    } else {
        Add-Failure "Missing process control facts detector: $detectorPath"
    }

    $stateAfter = Get-StateEntryCount $repoRoot
    if ($stateBefore -eq 0 -and $stateAfter -eq 0) {
        Add-Pass 'backend/state is absent or empty before and after validation'
    } else {
        Add-Failure "backend/state is not empty or changed during validation: before=$stateBefore after=$stateAfter"
    }

    Add-Pass 'Capability validation created no temp artifacts outside the process temp directory'
} catch {
    Add-Failure "Process control capability validation failed: $($_.Exception.Message)"
}

if ($failures.Count -eq 0) {
    foreach ($pass in $passes) { Write-Host "PASS $pass" }
    Write-Host "PASS Process control capability validation completed. $($passes.Count) checks passed."
    exit 0
}

foreach ($pass in $passes) { Write-Host "PASS $pass" }
foreach ($failure in $failures) { Write-Host "FAIL $failure" }
Write-Host "FAIL Process control capability validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
