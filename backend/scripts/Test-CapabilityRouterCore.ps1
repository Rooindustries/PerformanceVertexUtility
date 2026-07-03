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

function Get-StateEntryCount {
    param([string]$RepoRoot)

    $stateRoot = Join-Path $RepoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:RouterPath = Join-Path $repoRoot 'backend\scripts\Invoke-RooCapability.ps1'
$registryTestPath = Join-Path $repoRoot 'backend\scripts\Test-CapabilityRegistry.ps1'

$stateBefore = Get-StateEntryCount $repoRoot
Add-Check ($stateBefore -eq 0) 'backend/state is absent or empty before router validation' "backend/state is not empty before router validation: $stateBefore item(s)"

$unknown = Invoke-Router @('-CapabilityId', 'missing.capability', '-Action', 'status')
Add-Check ($unknown.exitCode -eq 1) 'Unknown capability exits 1' "Unknown capability exit code expected 1, got $($unknown.exitCode)"
Test-CompleteEnvelope $unknown.json 'Unknown capability'
if ($null -ne $unknown.json) {
    Add-Check ([string](Get-PropertyValue $unknown.json 'status' '') -eq 'failed') 'Unknown capability status is failed' 'Unknown capability status is not failed'
    $unknownErrors = @((Get-PropertyValue $unknown.json 'errors' @()))
    Add-Check ($unknownErrors.Count -eq 1) 'Unknown capability has one structured error' "Unknown capability error count expected 1, got $($unknownErrors.Count)"
    if ($unknownErrors.Count -gt 0) {
        Add-Check ([string](Get-PropertyValue $unknownErrors[0] 'code' '') -eq 'UNKNOWN_CAPABILITY') 'Unknown capability error code is UNKNOWN_CAPABILITY' 'Unknown capability error code mismatch'
        Add-Check ((Get-PropertyValue $unknownErrors[0] 'blocking' $null) -eq $true) 'Unknown capability error is blocking' 'Unknown capability error blocking flag mismatch'
    }
}

$familyExamples = [ordered]@{
    'process-controls' = 'process-controls.lightweight-governor-budget'
    'cleanup-uninstall' = 'cleanup-uninstall.installed-app-inventory'
    'drivers-gpu-tools' = 'drivers-gpu-tools.hwinfo-installed-sensor-monitoring'
    'system-optimizations' = 'system-optimizations.timer-resolution'
}

foreach ($family in $familyExamples.Keys) {
    $capabilityId = $familyExamples[$family]
    foreach ($action in @('status', 'explain')) {
        $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', $action)
        $label = "$family $action"
        Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
        Test-CompleteEnvelope $result.json $label
        if ($null -eq $result.json) { continue }
        Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'completed') "$label status is completed" "$label status is not completed"
        Add-Check ([string](Get-PropertyValue $result.json 'action' '') -eq $action) "$label action is echoed" "$label action mismatch"
        Add-Check ([string](Get-PropertyValue $result.json 'family' '') -eq $family) "$label family is echoed" "$label family mismatch"
        Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly routed a script"
        Add-Check ($null -ne (Get-PropertyValue (Get-PropertyValue $result.json 'evidence' $null) 'availability' $null)) "$label embeds availability evidence" "$label missing availability evidence"
    }
}

$preview = Invoke-Router @('-CapabilityId', 'process-controls.lightweight-governor-budget', '-Action', 'preview')
Add-Check ($preview.exitCode -eq 0) 'Worked example preview exits 0' "Worked example preview exit code expected 0, got $($preview.exitCode)"
Test-CompleteEnvelope $preview.json 'Worked example preview'
if ($null -ne $preview.json) {
    Add-Check ([string](Get-PropertyValue $preview.json 'status' '') -eq 'completed') 'Worked example preview status is completed' 'Worked example preview status mismatch'
    Add-Check ([string](Get-PropertyValue $preview.json 'routedScript' '') -eq 'backend/scripts/Measure-RooBackendFootprint.ps1') 'Worked example preview routed the footprint script' 'Worked example preview routedScript mismatch'
    $evidence = Get-PropertyValue $preview.json 'evidence' $null
    Add-Check ([string](Get-PropertyValue $evidence 'actionId' '') -eq 'backend.measureFootprint') 'Worked example preview embeds real footprint evidence' 'Worked example preview evidence actionId mismatch'
    Add-Check ([string](Get-PropertyValue $evidence 'status' '') -eq 'completed') 'Worked example footprint evidence completed' 'Worked example footprint evidence did not complete'
    Add-Check ([int](Get-PropertyValue $evidence 'sampleDurationSeconds' 0) -eq 1) 'Worked example footprint used manifest duration argument' 'Worked example footprint duration argument mismatch'
    $stateEvidence = Get-PropertyValue $evidence 'state' $null
    Add-Check ((Get-PropertyValue $stateEvidence 'wroteState' $true) -eq $false) 'Worked example footprint evidence reports no state write' 'Worked example footprint evidence reports state write'
}

$applyWithoutConfirm = Invoke-Router @('-CapabilityId', 'process-controls.cpu-priority', '-Action', 'apply')
Add-Check ($applyWithoutConfirm.exitCode -eq 0) 'Apply without confirmation exits 0' "Apply without confirmation exit code expected 0, got $($applyWithoutConfirm.exitCode)"
Test-CompleteEnvelope $applyWithoutConfirm.json 'Apply without confirmation'
if ($null -ne $applyWithoutConfirm.json) {
    $status = [string](Get-PropertyValue $applyWithoutConfirm.json 'status' '')
    Add-Check ($status -in @('approval-required', 'not-executable')) 'Apply without confirmation returns approval-required or not-executable' "Apply without confirmation returned $status"
    Add-Check ((Get-PropertyValue $applyWithoutConfirm.json 'dryRun' $false) -eq $true) 'Apply without confirmation is dryRun' 'Apply without confirmation is not dryRun'
    Add-Check ((Get-PropertyValue $applyWithoutConfirm.json 'changed' $true) -eq $false) 'Apply without confirmation changed is false' 'Apply without confirmation changed is not false'
    Add-Check ($null -eq (Get-PropertyValue $applyWithoutConfirm.json 'routedScript' $null)) 'Apply without confirmation did not dispatch' 'Apply without confirmation unexpectedly dispatched'
}

$applyStatusOnly = Invoke-Router @('-CapabilityId', 'process-controls.lightweight-governor-budget', '-Action', 'apply', '-ConfirmApply')
Add-Check ($applyStatusOnly.exitCode -eq 0) 'Status-only apply exits 0' "Status-only apply exit code expected 0, got $($applyStatusOnly.exitCode)"
Test-CompleteEnvelope $applyStatusOnly.json 'Status-only apply'
if ($null -ne $applyStatusOnly.json) {
    Add-Check ([string](Get-PropertyValue $applyStatusOnly.json 'status' '') -eq 'not-executable') 'Status-only apply returns not-executable' 'Status-only apply status mismatch'
    Add-Check ((Get-PropertyValue $applyStatusOnly.json 'dryRun' $false) -eq $true) 'Status-only apply remains dryRun' 'Status-only apply is not dryRun'
    Add-Check ((Get-PropertyValue $applyStatusOnly.json 'changed' $true) -eq $false) 'Status-only apply changed is false' 'Status-only apply changed is not false'
    Add-Check ($null -eq (Get-PropertyValue $applyStatusOnly.json 'routedScript' $null)) 'Status-only apply did not dispatch' 'Status-only apply unexpectedly dispatched'
    Add-Check ([string](Get-PropertyValue (Get-PropertyValue $applyStatusOnly.json 'evidence' $null) 'statusOnlyReason' '') -eq 'read-only budget measurement') 'Status-only apply exposes read-only budget reason' 'Status-only apply reason mismatch'
}

if ($null -ne $preview.json) {
    try {
        $roundTrip = ($preview.json | ConvertTo-Json -Depth 64) | ConvertFrom-Json
        Add-Check ([string](Get-PropertyValue $roundTrip 'capabilityId' '') -eq 'process-controls.lightweight-governor-budget') 'Envelope JSON round-trips capabilityId' 'Envelope JSON round-trip capabilityId mismatch'
        Add-Check ([string](Get-PropertyValue (Get-PropertyValue $roundTrip 'evidence' $null) 'actionId' '') -eq 'backend.measureFootprint') 'Envelope JSON round-trips nested evidence' 'Envelope JSON round-trip evidence mismatch'
    } catch {
        Add-Failure "Envelope JSON round-trip failed: $($_.Exception.Message)"
    }
}

$registryOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $registryTestPath 2>&1
$registryExitCode = $LASTEXITCODE
Add-Check ($registryExitCode -eq 0) 'Test-CapabilityRegistry.ps1 exits 0 after shared resolver refactor' "Test-CapabilityRegistry.ps1 exit code expected 0, got $registryExitCode"
if ($registryExitCode -ne 0) {
    Write-Host ($registryOutput | Out-String)
}

$stateAfter = Get-StateEntryCount $repoRoot
Add-Check ($stateAfter -eq 0) 'backend/state is absent or empty after router validation' "backend/state is not empty after router validation: $stateAfter item(s)"
Add-Check ($stateBefore -eq $stateAfter) "backend/state item count unchanged at $stateAfter" "backend/state item count changed: before=$stateBefore after=$stateAfter"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Capability router core validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Capability router core validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
