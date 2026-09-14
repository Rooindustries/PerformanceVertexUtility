Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$passes = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]

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
        Add-Pass "$Label parses as JSON"
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
    param([string]$RepoRoot)

    $stateRoot = Join-Path $RepoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function New-CountMap {
    param([object[]]$Items)

    $map = @{}
    foreach ($item in $Items) {
        $key = [string]$item
        if ($map.ContainsKey($key)) {
            $map[$key] = [int]$map[$key] + 1
        } else {
            $map[$key] = 1
        }
    }
    return $map
}

function Get-CountObjectValue {
    param(
        [object]$Object,
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return [int]$property.Value
}

function Test-CountObjectMatchesMap {
    param(
        [object]$CountObject,
        [hashtable]$Expected,
        [string]$Label
    )

    foreach ($key in @($Expected.Keys)) {
        $actual = Get-CountObjectValue $CountObject $key
        Add-Check ($actual -eq [int]$Expected[$key]) "$Label count matches for $key" "$Label count mismatch for $key expected=$($Expected[$key]) actual=$actual"
    }

    $actualKeys = @($CountObject.PSObject.Properties.Name)
    foreach ($key in $actualKeys) {
        Add-Check ($Expected.ContainsKey($key)) "$Label has expected key $key" "$Label has unexpected key $key"
    }
}

function Test-IdSetMatches {
    param(
        [string[]]$ExpectedIds,
        [string[]]$ActualIds,
        [string]$Label
    )

    $diff = @(Compare-Object -ReferenceObject @($ExpectedIds | Sort-Object) -DifferenceObject @($ActualIds | Sort-Object))
    Add-Check ($diff.Count -eq 0) "$Label capability IDs match" "$Label capability IDs differ: $((@($diff | ForEach-Object { $_.SideIndicator + ':' + $_.InputObject })) -join ', ')"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$capabilityRoot = Join-Path $repoRoot 'backend\capabilities'
$aggregatorPath = Join-Path $repoRoot 'backend\scripts\Get-RooCapabilityRegistry.ps1'
$labelMapPath = Join-Path $repoRoot 'backend\catalogs\frontend-label-map.json'
$samplePath = Join-Path $repoRoot 'backend\samples\capability-registry.sample.json'
$catalogPath = Join-Path $repoRoot 'backend\contracts\contract-catalog.json'
$schemaPath = Join-Path $repoRoot 'backend\contracts\roo-backend-contracts.schema.json'
$validTabs = @('Game Tune', 'Clean Junk', 'Drivers & Settings', 'Live Feel')
$requiredCatalogNames = @('capability entry', 'capability registry', 'frontend label map', 'utilities inventory detector')

$stateBefore = Get-StateEntryCount $repoRoot
Add-Check ($stateBefore -eq 0) 'backend/state is absent or empty before registry validation' "backend/state is not empty before registry validation: $stateBefore item(s)"

$fragmentFiles = @(Get-ChildItem -LiteralPath $capabilityRoot -Filter '*.json' -File | Sort-Object Name)
$fragments = New-Object System.Collections.Generic.List[object]
$fragmentCapabilities = New-Object System.Collections.Generic.List[object]

foreach ($file in $fragmentFiles) {
    $fragment = Read-JsonFile $file.FullName "Capability fragment $($file.Name)"
    if ($null -ne $fragment) {
        $fragments.Add($fragment) | Out-Null
        foreach ($capability in @($fragment.capabilities)) {
            $fragmentCapabilities.Add($capability) | Out-Null
        }
    }
}

$expectedCapabilities = @($fragmentCapabilities.ToArray())
$expectedCapabilityIds = @($expectedCapabilities | ForEach-Object { [string]$_.capabilityId })
$expectedFamilyMap = New-CountMap (@($expectedCapabilities | ForEach-Object { [string]$_.family }))
$expectedApplyStatusMap = New-CountMap (@($expectedCapabilities | ForEach-Object { [string]$_.apply.status }))
$expectedIdGroups = @($expectedCapabilityIds | Group-Object | Where-Object { $_.Count -gt 1 })

Add-Check ($fragments.Count -eq 4) 'Exactly 4 capability fragments were loaded' "Expected 4 capability fragments, found $($fragments.Count)"
Add-Check ($expectedFamilyMap.Count -eq 4) 'Exactly 4 families are represented in fragments' "Expected 4 represented families, found $($expectedFamilyMap.Count)"
Add-Check ($expectedCapabilities.Count -eq 56) 'Fragment capability total is exactly 56' "Fragment capability total expected 56, found $($expectedCapabilities.Count)"
Add-Check ($expectedIdGroups.Count -eq 0) 'Fragment capability IDs are unique' "Duplicate fragment capability IDs: $((@($expectedIdGroups | ForEach-Object { $_.Name })) -join ', ')"

$registry = $null
try {
    $registry = ConvertFrom-ScriptJson (& $aggregatorPath)
    Add-Pass 'Capability registry aggregator runs'
} catch {
    Add-Failure "Capability registry aggregator failed: $($_.Exception.Message)"
}

if ($null -ne $registry) {
    Add-Check ([string](Get-PropertyValue $registry 'actionId' '') -eq 'backend.capabilityRegistry.get') 'Registry actionId is valid' 'Registry actionId is invalid'
    Add-Check ((Get-PropertyValue $registry 'dryRun' $false) -eq $true) 'Registry dryRun is true' 'Registry dryRun is not true'
    Add-Check ([string](Get-PropertyValue $registry 'status' '') -eq 'completed') 'Registry status is completed' 'Registry status is not completed'
    Add-Check ([int](Get-PropertyValue $registry 'schemaVersion' 0) -eq 1) 'Registry schemaVersion is 1' 'Registry schemaVersion is not 1'
    Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $registry 'generatedAtUtc' ''))) 'Registry generatedAtUtc is present' 'Registry generatedAtUtc is missing'
    Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $registry 'utilitiesRoot' ''))) 'Registry utilitiesRoot is present' 'Registry utilitiesRoot is missing'

    $registryFamilies = @(Get-PropertyValue $registry 'families' @())
    $registryCapabilities = @(Get-PropertyValue $registry 'capabilities' @())
    Add-Check ($registryFamilies.Count -eq 4) 'Registry contains exactly 4 families' "Registry family count expected 4, found $($registryFamilies.Count)"
    Add-Check ($registryCapabilities.Count -eq $expectedCapabilities.Count) 'Registry capability count equals fragment sum' "Registry capability count $($registryCapabilities.Count) does not equal fragment sum $($expectedCapabilities.Count)"
    Add-Check ($registryCapabilities.Count -eq 53) 'Registry capability total is exactly 56' "Registry capability total expected 56, found $($registryCapabilities.Count)"

    Test-IdSetMatches $expectedCapabilityIds (@($registryCapabilities | ForEach-Object { [string]$_.capabilityId })) 'Live registry'

    $summary = Get-PropertyValue $registry 'summary' $null
    if ($null -ne $summary) {
        Add-Check ([int](Get-PropertyValue $summary 'totalCapabilities' 0) -eq $expectedCapabilities.Count) 'Registry summary totalCapabilities matches fragment sum' 'Registry summary totalCapabilities mismatch'
        Test-CountObjectMatchesMap (Get-PropertyValue $summary 'byFamily' $null) $expectedFamilyMap 'Registry summary byFamily'
        Test-CountObjectMatchesMap (Get-PropertyValue $summary 'byApplyStatus' $null) $expectedApplyStatusMap 'Registry summary byApplyStatus'
        $availableCount = @($registryCapabilities | Where-Object { $_.resolvedAvailability.available -eq $true }).Count
        $unavailableCount = $registryCapabilities.Count - $availableCount
        Add-Check ([int](Get-PropertyValue $summary 'availableCount' -1) -eq $availableCount) 'Registry summary availableCount matches recount' 'Registry summary availableCount mismatch'
        Add-Check ([int](Get-PropertyValue $summary 'unavailableCount' -1) -eq $unavailableCount) 'Registry summary unavailableCount matches recount' 'Registry summary unavailableCount mismatch'
    } else {
        Add-Failure 'Registry summary is missing'
    }

    foreach ($capability in $registryCapabilities) {
        $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '<missing>')
        $resolvedAvailability = Get-PropertyValue $capability 'resolvedAvailability' $null
        Add-Check ($null -ne $resolvedAvailability) "$capabilityId has resolvedAvailability" "$capabilityId missing resolvedAvailability"
        if ($null -eq $resolvedAvailability) { continue }

        $checkedRules = @(Get-PropertyValue $resolvedAvailability 'checkedRules' @())
        Add-Check ($checkedRules.Count -gt 0) "$capabilityId has checked availability rules" "$capabilityId has no checked availability rules"
        foreach ($rule in $checkedRules) {
            $method = [string](Get-PropertyValue $rule 'method' '')
            $target = [string](Get-PropertyValue $rule 'target' '')
            $resolvedTarget = [string](Get-PropertyValue $rule 'resolvedTarget' '')
            Add-Check (-not [string]::IsNullOrWhiteSpace($method)) "$capabilityId checked rule has method" "$capabilityId checked rule missing method"
            Add-Check (-not [string]::IsNullOrWhiteSpace($target)) "$capabilityId checked rule has target" "$capabilityId checked rule missing target"
            Add-Check (-not [string]::IsNullOrWhiteSpace($resolvedTarget)) "$capabilityId checked rule has resolvedTarget" "$capabilityId checked rule missing resolvedTarget"
            Add-Check ((Get-PropertyValue $rule 'passed' $null) -is [bool]) "$capabilityId checked rule passed flag is boolean" "$capabilityId checked rule passed flag is not boolean"
            Add-Check ($null -ne (Get-PropertyValue $rule 'evidence' $null)) "$capabilityId checked rule has evidence" "$capabilityId checked rule missing evidence"
        }

        $available = [bool](Get-PropertyValue $resolvedAvailability 'available' $false)
        if (-not $available) {
            $reason = [string](Get-PropertyValue $resolvedAvailability 'unavailableReason' '')
            Add-Check (-not [string]::IsNullOrWhiteSpace($reason)) "$capabilityId unavailableReason is present" "$capabilityId unavailableReason is missing"
            Add-Check (@('requires-elevation', 'requires elevation', 'elevation') -notcontains $reason) "$capabilityId unavailableReason is not a bare elevation phrase" "$capabilityId unavailableReason is imprecise: $reason"
        }
    }
}

$labelMap = Read-JsonFile $labelMapPath 'frontend-label-map'
if ($null -ne $labelMap) {
    Add-Check ([int](Get-PropertyValue $labelMap 'schemaVersion' 0) -eq 1) 'frontend-label-map schemaVersion is 1' 'frontend-label-map schemaVersion is not 1'
    Add-Check ([string](Get-PropertyValue $labelMap 'generatedFrom' '') -eq 'backend/capabilities') 'frontend-label-map generatedFrom is backend/capabilities' 'frontend-label-map generatedFrom is invalid'
    $labelEntries = New-Object System.Collections.Generic.List[object]
    foreach ($tabEntry in @(Get-PropertyValue $labelMap 'tabs' @())) {
        $tab = [string](Get-PropertyValue $tabEntry 'tab' '')
        Add-Check ($validTabs -contains $tab) "frontend-label-map tab is valid: $tab" "frontend-label-map tab is invalid: $tab"
        foreach ($entry in @(Get-PropertyValue $tabEntry 'capabilities' @())) {
            $entry | Add-Member -NotePropertyName '_tab' -NotePropertyValue $tab -Force
            $labelEntries.Add($entry) | Out-Null
        }
    }

    $labelIds = @($labelEntries.ToArray() | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })
    Add-Check ($labelIds.Count -eq $expectedCapabilities.Count) 'frontend-label-map capability entry count matches fragments' "frontend-label-map count expected $($expectedCapabilities.Count), found $($labelIds.Count)"
    Test-IdSetMatches $expectedCapabilityIds $labelIds 'frontend-label-map'
    $duplicateLabelIds = @($labelIds | Group-Object | Where-Object { $_.Count -gt 1 })
    Add-Check ($duplicateLabelIds.Count -eq 0) 'frontend-label-map covers each capabilityId exactly once' "frontend-label-map duplicate capabilityIds: $((@($duplicateLabelIds | ForEach-Object { $_.Name })) -join ', ')"

    $capabilityById = @{}
    foreach ($capability in $expectedCapabilities) {
        $capabilityById[[string]$capability.capabilityId] = $capability
    }
    foreach ($entry in $labelEntries) {
        $capabilityId = [string](Get-PropertyValue $entry 'capabilityId' '')
        if (-not $capabilityById.ContainsKey($capabilityId)) { continue }
        $source = $capabilityById[$capabilityId]
        Add-Check ([string](Get-PropertyValue $entry 'frontendLabel' '') -eq [string]$source.frontendLabel) "$capabilityId frontendLabel matches fragment" "$capabilityId frontendLabel mismatch"
        Add-Check ([string](Get-PropertyValue $entry 'displayName' '') -eq [string]$source.displayName) "$capabilityId displayName matches fragment" "$capabilityId displayName mismatch"
        Add-Check ([string](Get-PropertyValue $entry 'riskLevel' '') -eq [string]$source.riskLevel) "$capabilityId riskLevel matches fragment" "$capabilityId riskLevel mismatch"
        Add-Check ([string](Get-PropertyValue $entry 'applyStatus' '') -eq [string]$source.apply.status) "$capabilityId applyStatus matches fragment" "$capabilityId applyStatus mismatch"
        Add-Check ((Get-PropertyValue $entry 'approvalRequired' $null) -eq [bool]$source.approvalRequired) "$capabilityId approvalRequired matches fragment" "$capabilityId approvalRequired mismatch"
        Add-Check ($validTabs -contains [string](Get-PropertyValue $entry '_tab' '')) "$capabilityId mapped tab is valid" "$capabilityId mapped tab is invalid"
    }
}

$sample = Read-JsonFile $samplePath 'capability-registry.sample'
if ($null -ne $sample -and $null -ne $registry) {
    Add-Check ([string](Get-PropertyValue $sample 'correlationId' '') -eq 'sample-capability-registry-20260703-160000') 'Sample correlationId is normalized' 'Sample correlationId is not normalized'
    $sampleIds = @((Get-PropertyValue $sample 'capabilities' @()) | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })
    $liveIds = @((Get-PropertyValue $registry 'capabilities' @()) | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })
    Test-IdSetMatches $liveIds $sampleIds 'capability-registry.sample'
}

$catalog = Read-JsonFile $catalogPath 'contract-catalog'
if ($null -ne $catalog) {
    foreach ($name in $requiredCatalogNames) {
        $matches = @((Get-PropertyValue $catalog 'contracts' @()) | Where-Object { [string](Get-PropertyValue $_ 'name' '') -eq $name })
        Add-Check ($matches.Count -eq 1) "contract-catalog contains $name entry" "contract-catalog missing or duplicates $name entry"
        if ($matches.Count -eq 1) {
            Add-Check ([string](Get-PropertyValue $matches[0] 'workflow' '') -eq 'unified control plane') "contract-catalog $name workflow is unified control plane" "contract-catalog $name workflow is invalid"
            Add-Check ([string](Get-PropertyValue $matches[0] 'status' '') -eq 'draft') "contract-catalog $name status is draft" "contract-catalog $name status is not draft"
            Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $matches[0] 'definitionRef' ''))) "contract-catalog $name definitionRef is present" "contract-catalog $name definitionRef is missing"
        }
    }
}

$schema = Read-JsonFile $schemaPath 'roo-backend-contracts.schema'
if ($null -ne $schema) {
    $defs = Get-PropertyValue $schema '$defs' $null
    foreach ($defName in @('capabilityEntry', 'capabilityRegistry', 'frontendLabelMap')) {
        Add-Check (Has-Property $defs $defName) "Schema contains `$defs.$defName" "Schema missing `$defs.$defName"
    }
}

$stateAfter = Get-StateEntryCount $repoRoot
Add-Check ($stateAfter -eq 0) 'backend/state is absent or empty after registry validation' "backend/state is not empty after registry validation: $stateAfter item(s)"
Add-Check ($stateBefore -eq $stateAfter) "backend/state item count unchanged at $stateAfter" "backend/state item count changed: before=$stateBefore after=$stateAfter"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Capability registry validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Capability registry validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
