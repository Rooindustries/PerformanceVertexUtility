$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
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

function Read-CatalogJson {
    param([string]$RelativePath)
    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Failure "Catalog file missing: $RelativePath"
        return $null
    }

    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Add-Pass "Catalog JSON parsed: $RelativePath"
        return $json
    } catch {
        Add-Failure "Catalog JSON parse failed: $RelativePath :: $($_.Exception.Message)"
        return $null
    }
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
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

    $path = Join-Path $repoRoot $RelativePath
    if (Test-Path -LiteralPath $path) {
        Add-Pass "$Context path exists: $RelativePath"
    } else {
        Add-Failure "$Context path missing: $RelativePath"
    }
}

function Get-UniqueCapabilities {
    param([object[]]$Catalogs)
    $items = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($catalog in $Catalogs) {
        if ($null -eq $catalog) { continue }
        foreach ($capability in @($catalog.capabilities)) {
            if ($null -eq $capability) { continue }
            $key = "$([string]$capability.sourceKind)|$([string]$capability.capabilityId)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $items.Add($capability) | Out-Null
        }
        foreach ($capability in @($catalog.capabilityStatusMap)) {
            if ($null -eq $capability) { continue }
            $key = "$([string]$capability.sourceKind)|$([string]$capability.capabilityId)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $items.Add($capability) | Out-Null
        }
    }
    return @($items.ToArray())
}

$playbook = Read-CatalogJson 'backend\catalogs\fsosx-playbook-capabilities.json'
$dash = Read-CatalogJson 'backend\catalogs\fsosx-dash-capabilities.json'
$gap = Read-CatalogJson 'backend\catalogs\fsosx-gap-map.json'

if ($playbook -and $dash -and $gap) {
    if ($playbook.sourceKind -eq 'fsosx-playbook' -and $dash.sourceKind -eq 'fsosx-dash') {
        Add-Pass 'FSOS-X playbook and FSOS-X Dash catalogs use separate sourceKind values'
    } else {
        Add-Failure "Unexpected sourceKind values: playbook=$($playbook.sourceKind) dash=$($dash.sourceKind)"
    }

    if ($playbook.catalogId -ne $dash.catalogId -and $playbook.sourceProduct -ne $dash.sourceProduct) {
        Add-Pass 'FSOS-X playbook and FSOS-X Dash catalogs are not the same bucket'
    } else {
        Add-Failure 'FSOS-X playbook and FSOS-X Dash catalogs appear merged'
    }

    $playbookWrongKind = @($playbook.capabilities | Where-Object { $_.sourceKind -ne 'fsosx-playbook' })
    $dashWrongKind = @($dash.capabilities | Where-Object { $_.sourceKind -ne 'fsosx-dash' })
    if ($playbookWrongKind.Count -eq 0 -and $dashWrongKind.Count -eq 0) {
        Add-Pass 'Every catalog capability stays inside its source product boundary'
    } else {
        Add-Failure "Capability source boundary mismatch: playbook=$($playbookWrongKind.Count) dash=$($dashWrongKind.Count)"
    }

    $playbookBadPrefix = @($playbook.capabilities | Where-Object { $_.capabilityId -notlike 'playbook-*' })
    $dashBadPrefix = @($dash.capabilities | Where-Object { $_.capabilityId -notlike 'dash-*' })
    if ($playbookBadPrefix.Count -eq 0 -and $dashBadPrefix.Count -eq 0) {
        Add-Pass 'Capability IDs preserve playbook-* and dash-* prefixes'
    } else {
        Add-Failure "Capability prefix mismatch: playbook=$($playbookBadPrefix.Count) dash=$($dashBadPrefix.Count)"
    }

    $gapProducts = @($gap.sourceSeparation.products)
    $gapKinds = @($gapProducts | ForEach-Object { $_.sourceKind } | Sort-Object -Unique)
    if ($gap.sourceSeparation.requiredSeparateProducts -eq $true -and $gap.sourceSeparation.mergedBucketAllowed -eq $false -and $gapProducts.Count -eq 2 -and $gapKinds.Count -eq 2) {
        Add-Pass 'Gap map explicitly forbids merging FSOS-X playbook and FSOS-X Dash'
    } else {
        Add-Failure 'Gap map does not explicitly preserve separate FSOS-X playbook and Dash products'
    }

    $phaseTotal = 0
    foreach ($phase in @($playbook.phaseInventory)) {
        $phaseTotal += [int]$phase.actionCount
    }
    $actionCount = @($playbook.actionsByPhase).Count
    if ($phaseTotal -eq $actionCount -and $actionCount -eq 1319) {
        Add-Pass 'Playbook action inventory count matches phase totals and extracted R7 source count'
    } else {
        Add-Failure "Playbook action inventory mismatch: phaseTotal=$phaseTotal actionsByPhase=$actionCount expected=1319"
    }

    if ($playbook.bundledAssetSummary.nvidiaProfileInspectorAssetsFound -eq $false) {
        Add-Pass 'NIP/profile asset absence is recorded explicitly instead of inferred'
    } else {
        Add-Failure 'NIP/profile asset flag unexpectedly reports present assets'
    }

    $allowedStatuses = @('implemented-live', 'preview-only', 'catalog-only', 'missing', 'unsafe', 'blocked')
    $allCapabilities = Get-UniqueCapabilities @($playbook, $dash, $gap)
    $badStatus = @($allCapabilities | Where-Object { $allowedStatuses -notcontains $_.backendStatus })
    if ($badStatus.Count -eq 0) {
        Add-Pass 'Every capability uses an allowed backend status'
    } else {
        Add-Failure "Capability status typo count: $($badStatus.Count)"
    }

    $implemented = @($gap.capabilityStatusMap | Where-Object { [string]$_.backendStatus -eq 'implemented-live' })
    $expectedImplemented = [int]$gap.statusCounts.'implemented-live'
    if ($implemented.Count -eq $expectedImplemented -and $implemented.Count -gt 0) {
        Add-Pass "Implemented-live capability count matches gap statusCounts: $($implemented.Count)"
    } elseif ($implemented.Count -eq 0) {
        Add-Failure 'No implemented-live capability exists to exercise guardrail coverage'
    } else {
        Add-Failure "Implemented-live capability count mismatch: capabilityStatusMap=$($implemented.Count) statusCounts=$expectedImplemented"
    }

    foreach ($capability in $implemented) {
        $context = "Implemented capability $($capability.capabilityId)"
        $scripts = @($capability.backendEvidence.executableScripts)
        $rollback = @($capability.backendEvidence.rollbackOrBackupRules)
        $validation = @($capability.backendEvidence.validationEvidence)

        if ($scripts.Count -gt 0) {
            Add-Pass "$context has executable backend script evidence"
            foreach ($script in $scripts) {
                Test-RelativePathExists $script "$context executable script"
            }
        } else {
            Add-Failure "$context is missing executable backend script evidence"
        }

        if ($rollback.Count -gt 0) {
            Add-Pass "$context has rollback or backup rules"
        } else {
            Add-Failure "$context is missing rollback or backup rules"
        }

        if ($validation.Count -gt 0) {
            Add-Pass "$context has validation evidence"
            foreach ($path in $validation) {
                Test-RelativePathExists $path "$context validation evidence"
            }
        } else {
            Add-Failure "$context is missing validation evidence"
        }
    }

    $catalogText = @(
        (Get-Content -LiteralPath (Join-Path $repoRoot 'backend\catalogs\fsosx-playbook-capabilities.json') -Raw),
        (Get-Content -LiteralPath (Join-Path $repoRoot 'backend\catalogs\fsosx-dash-capabilities.json') -Raw),
        (Get-Content -LiteralPath (Join-Path $repoRoot 'backend\catalogs\fsosx-gap-map.json') -Raw),
        (Get-Content -LiteralPath (Join-Path $repoRoot 'backend\catalogs\stutter-optimization-ranking.json') -Raw)
    ) -join [Environment]::NewLine
    $staleExecutorText = @(
        ('real standby-list clearing ' + 'remains ' + 'blocked'),
        ('import/selection ' + 'remains ' + 'blocked'),
        ('Timer resolution apply ' + 'remains ' + 'blocked'),
        ('Real shader cache deletion ' + 'remains ' + 'blocked'),
        ('real cache deletion ' + 'remains ' + 'blocked')
    )
    $staleHits = @($staleExecutorText | Where-Object { $catalogText -match [regex]::Escape($_) })
    if ($staleHits.Count -eq 0) {
        Add-Pass 'FSOS-X catalogs contain no stale blocked metadata for implemented executor paths'
    } else {
        Add-Failure "FSOS-X catalogs still contain stale executor text: $($staleHits -join '; ')"
    }
}

$stateEntries = Get-StateEntryCount
if ($stateEntries -eq 0) {
    Add-Pass 'backend/state remains empty after FSOS-X catalog validation'
} else {
    Add-Failure "backend/state is not empty after FSOS-X catalog validation: $stateEntries item(s)"
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "PASS FSOS-X catalog validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL FSOS-X catalog validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
