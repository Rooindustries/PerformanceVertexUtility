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

function Get-StateEntryCount {
    param([string]$RepoRoot)

    $stateRoot = Join-Path $RepoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Test-CompleteRouterEnvelope {
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

    if ($null -eq $Envelope) { return }

    Add-Check ([string](Get-PropertyValue $Envelope 'actionId' '') -eq 'backend.capability.invoke') "$Label actionId is valid" "$Label actionId is invalid"
    Add-Check ([int](Get-PropertyValue $Envelope 'schemaVersion' 0) -eq 1) "$Label schemaVersion is 1" "$Label schemaVersion is not 1"
    Add-Check ((Get-PropertyValue $Envelope 'dryRun' $null) -is [bool]) "$Label dryRun is boolean" "$Label dryRun is not boolean"
    Add-Check ((Get-PropertyValue $Envelope 'requiresApproval' $null) -is [bool]) "$Label requiresApproval is boolean" "$Label requiresApproval is not boolean"
    Add-Check ((Get-PropertyValue $Envelope 'approvalSatisfied' $null) -is [bool]) "$Label approvalSatisfied is boolean" "$Label approvalSatisfied is not boolean"
    Add-Check ((Get-PropertyValue $Envelope 'machineAvailable' $null) -is [bool]) "$Label machineAvailable is boolean" "$Label machineAvailable is not boolean"
    Add-Check ((Get-PropertyValue $Envelope 'wouldChange' $null) -is [bool]) "$Label wouldChange is boolean" "$Label wouldChange is not boolean"
    Add-Check ((Get-PropertyValue $Envelope 'changed' $null) -is [bool]) "$Label changed is boolean" "$Label changed is not boolean"
    Add-Check ((Get-PropertyValue $Envelope 'restoreAvailable' $null) -is [bool]) "$Label restoreAvailable is boolean" "$Label restoreAvailable is not boolean"
    Add-Check ($null -ne (Get-PropertyValue $Envelope 'evidence' $null)) "$Label evidence is present" "$Label evidence is missing"
    Add-Check (Has-Property $Envelope 'errors') "$Label errors field is present" "$Label errors field is missing"
}

function ConvertFrom-RouterOutput {
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
        return $null
    }
}

function Invoke-RouterStatus {
    param([string]$CapabilityId)

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:RouterPath -CapabilityId $CapabilityId -Action status 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        exitCode = [int]$exitCode
        json = ConvertFrom-RouterOutput $output "router status $CapabilityId"
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:RouterPath = Join-Path $repoRoot 'backend\scripts\Invoke-RooCapability.ps1'
$registryPath = Join-Path $repoRoot 'backend\scripts\Get-RooCapabilityRegistry.ps1'
$schemaPath = Join-Path $repoRoot 'backend\contracts\roo-backend-contracts.schema.json'
$catalogPath = Join-Path $repoRoot 'backend\contracts\contract-catalog.json'
$routingRoot = Join-Path $repoRoot 'backend\capabilities\routing'
$samplesRoot = Join-Path $repoRoot 'backend\samples'

$stateBefore = Get-StateEntryCount $repoRoot
Add-Check ($stateBefore -eq 0) 'backend/state is absent or empty before integration validation' "backend/state is not empty before integration validation: $stateBefore item(s)"

$sampleExpectations = @(
    [pscustomobject]@{ Kind = 'status'; File = 'capability-router-status.sample.json'; CapabilityId = 'process-controls.cpu-priority'; Action = 'explain'; CorrelationId = 'sample-capability-router-status-20260703-180000' },
    [pscustomobject]@{ Kind = 'preview'; File = 'capability-router-preview.sample.json'; CapabilityId = 'cleanup-uninstall.installed-app-inventory'; Action = 'preview'; CorrelationId = 'sample-capability-router-preview-20260703-180000' },
    [pscustomobject]@{ Kind = 'approval'; File = 'capability-router-approval.sample.json'; CapabilityId = 'system-optimizations.timer-resolution'; Action = 'apply'; CorrelationId = 'sample-capability-router-approval-20260703-180000' },
    [pscustomobject]@{ Kind = 'unavailable'; File = 'capability-router-unavailable.sample.json'; CapabilityId = 'drivers-gpu-tools.nvidia-nip-profile-preview'; Action = 'explain'; CorrelationId = 'sample-capability-router-unavailable-20260703-180000' }
)

foreach ($sample in $sampleExpectations) {
    $path = Join-Path $samplesRoot $sample.File
    $raw = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -LiteralPath $path -Raw } else { '' }
    Add-Check (-not ($raw -match 'C:[\\/]+Users|\.claude')) "$($sample.Kind) sample has no absolute local user path" "$($sample.Kind) sample contains an absolute local user path"

    $json = Read-JsonFile $path "$($sample.Kind) sample"
    Test-CompleteRouterEnvelope $json "$($sample.Kind) sample"
    if ($null -eq $json) { continue }

    Add-Check ([string](Get-PropertyValue $json 'capabilityId' '') -eq $sample.CapabilityId) "$($sample.Kind) sample capabilityId matches" "$($sample.Kind) sample capabilityId mismatch"
    Add-Check ([string](Get-PropertyValue $json 'action' '') -eq $sample.Action) "$($sample.Kind) sample action matches" "$($sample.Kind) sample action mismatch"
    Add-Check ([string](Get-PropertyValue $json 'correlationId' '') -eq $sample.CorrelationId) "$($sample.Kind) sample correlationId is normalized" "$($sample.Kind) sample correlationId is not normalized"
}

$schema = Read-JsonFile $schemaPath 'backend contract schema'
if ($null -ne $schema) {
    $defs = Get-PropertyValue $schema '$defs' $null
    foreach ($defName in @('capabilityRouterResponse', 'capabilityRouteManifest')) {
        Add-Check (Has-Property $defs $defName) "Schema contains `$defs.$defName" "Schema missing `$defs.$defName"
    }
}

$catalog = Read-JsonFile $catalogPath 'contract catalog'
if ($null -ne $catalog) {
    $requiredEntries = @{
        'capability router response' = 'roo-backend-contracts.schema.json#/$defs/capabilityRouterResponse'
        'capability route manifest' = 'roo-backend-contracts.schema.json#/$defs/capabilityRouteManifest'
    }

    foreach ($name in @($requiredEntries.Keys)) {
        $matches = @((Get-PropertyValue $catalog 'contracts' @()) | Where-Object { [string](Get-PropertyValue $_ 'name' '') -eq $name })
        Add-Check ($matches.Count -eq 1) "contract catalog contains $name entry" "contract catalog missing or duplicates $name entry"
        if ($matches.Count -ne 1) { continue }
        Add-Check ([string](Get-PropertyValue $matches[0] 'definitionRef' '') -eq $requiredEntries[$name]) "contract catalog $name definitionRef matches" "contract catalog $name definitionRef mismatch"
        Add-Check ([string](Get-PropertyValue $matches[0] 'workflow' '') -eq 'unified control plane') "contract catalog $name workflow is unified control plane" "contract catalog $name workflow mismatch"
        Add-Check ([string](Get-PropertyValue $matches[0] 'status' '') -eq 'draft') "contract catalog $name status is draft" "contract catalog $name status mismatch"
    }
}

$registry = $null
try {
    $registry = (& powershell -NoProfile -ExecutionPolicy Bypass -File $registryPath 2>&1 | Out-String).Trim() | ConvertFrom-Json
    Add-Pass 'capability registry command emits parseable JSON'
} catch {
    Add-Failure "capability registry command failed: $($_.Exception.Message)"
}

$registryCapabilities = @()
$registryIds = @()
if ($null -ne $registry) {
    $registryCapabilities = @(Get-PropertyValue $registry 'capabilities' @())
    $registryIds = @($registryCapabilities | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })
    Add-Check ($registryIds.Count -eq 53) "capability registry exposes exactly 53 capabilityIds" "capability registry exposed $($registryIds.Count) capabilityIds"
}

$routeRecords = New-Object System.Collections.Generic.List[object]
foreach ($manifestPath in @(Get-ChildItem -LiteralPath $routingRoot -Filter '*.routes.json' -File | Sort-Object Name)) {
    $manifest = Read-JsonFile $manifestPath.FullName "route manifest $($manifestPath.Name)"
    if ($null -eq $manifest) { continue }

    Add-Check ([int](Get-PropertyValue $manifest 'schemaVersion' 0) -eq 1) "$($manifestPath.Name) schemaVersion is 1" "$($manifestPath.Name) schemaVersion is not 1"
    $family = [string](Get-PropertyValue $manifest 'family' '')
    Add-Check (-not [string]::IsNullOrWhiteSpace($family)) "$($manifestPath.Name) family is present" "$($manifestPath.Name) family is missing"

    foreach ($route in @(Get-PropertyValue $manifest 'routes' @())) {
        $capabilityId = [string](Get-PropertyValue $route 'capabilityId' '')
        $routeRecords.Add([pscustomobject]@{
            capabilityId = $capabilityId
            family = $family
            manifest = $manifestPath.Name
        }) | Out-Null

        Add-Check (-not [string]::IsNullOrWhiteSpace($capabilityId)) "$($manifestPath.Name) route has capabilityId" "$($manifestPath.Name) route missing capabilityId"
        foreach ($section in @('preview', 'apply', 'restore')) {
            $sectionValue = Get-PropertyValue $route $section $null
            Add-Check ($null -ne $sectionValue) "$capabilityId has $section route section" "$capabilityId missing $section route section"
            if ($null -eq $sectionValue) { continue }

            $statusOnly = [bool](Get-PropertyValue $sectionValue 'statusOnly' $false)
            $script = [string](Get-PropertyValue $sectionValue 'script' '')
            Add-Check ($statusOnly -or -not [string]::IsNullOrWhiteSpace($script)) "$capabilityId $section is dispatch or statusOnly" "$capabilityId $section is neither dispatch nor statusOnly"
        }
    }
}

$routeIds = @($routeRecords.ToArray() | ForEach-Object { [string]$_.capabilityId })
Add-Check ($routeIds.Count -eq 53) "route manifests contain exactly 53 route records" "route manifests contain $($routeIds.Count) route records"

if ($registryIds.Count -gt 0) {
    $registryDiff = @(Compare-Object -ReferenceObject @($registryIds | Sort-Object) -DifferenceObject @($routeIds | Sort-Object))
    Add-Check ($registryDiff.Count -eq 0) 'route manifests cover exactly the registry capabilityIds' "route manifest capabilityId diff: $((@($registryDiff | ForEach-Object { $_.SideIndicator + ':' + $_.InputObject })) -join ', ')"

    foreach ($group in @($routeRecords.ToArray() | Group-Object capabilityId)) {
        Add-Check ($group.Count -eq 1) "$($group.Name) appears in exactly one route manifest" "$($group.Name) appears in $($group.Count) route manifest records"
    }
}

$statusExamples = [ordered]@{
    'process-controls' = 'process-controls.cpu-priority'
    'cleanup-uninstall' = 'cleanup-uninstall.installed-app-inventory'
    'drivers-gpu-tools' = 'drivers-gpu-tools.nvidia-nip-profile-preview'
    'system-optimizations' = 'system-optimizations.timer-resolution'
}

foreach ($family in $statusExamples.Keys) {
    $capabilityId = $statusExamples[$family]
    $result = Invoke-RouterStatus $capabilityId
    $label = "$family status"

    Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
    Test-CompleteRouterEnvelope $result.json $label
    if ($null -eq $result.json) { continue }

    Add-Check ([string](Get-PropertyValue $result.json 'capabilityId' '') -eq $capabilityId) "$label capabilityId matches" "$label capabilityId mismatch"
    Add-Check ([string](Get-PropertyValue $result.json 'family' '') -eq $family) "$label family matches" "$label family mismatch"
    Add-Check ([string](Get-PropertyValue $result.json 'action' '') -eq 'status') "$label action is status" "$label action mismatch"
    Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'completed') "$label status is completed" "$label status mismatch"
    Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
}

$stateAfter = Get-StateEntryCount $repoRoot
Add-Check ($stateAfter -eq 0) 'backend/state is absent or empty after integration validation' "backend/state is not empty after integration validation: $stateAfter item(s)"
Add-Check ($stateBefore -eq $stateAfter) "backend/state item count unchanged at $stateAfter" "backend/state item count changed: before=$stateBefore after=$stateAfter"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Capability router integration validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Capability router integration validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
