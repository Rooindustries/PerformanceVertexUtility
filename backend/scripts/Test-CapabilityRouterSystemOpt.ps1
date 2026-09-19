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

function Get-PathValue {
    param(
        [object]$Object,
        [string]$Path
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
    $current = $Object
    foreach ($part in @($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    return $current
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
    $json = ConvertFrom-RouterJson $output "Invoke-RooIndustriesCapability $($Arguments -join ' ')"
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

function Get-RouteByCapabilityId {
    param(
        [object]$Manifest,
        [string]$CapabilityId
    )

    $matches = @($Manifest.routes | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq $CapabilityId })
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-RouteSection {
    param(
        [object]$Route,
        [string]$SectionName
    )

    return Get-PropertyValue $Route $SectionName $null
}

function Test-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rootWithSlash = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    return ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-ActivePowerSchemeGuid {
    $powerCfg = Get-Command -Name powercfg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $powerCfg) { return '' }
    try {
        $text = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { return '' }
        if ($text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            return $matches[1].ToLowerInvariant()
        }
    } catch {
        return ''
    }
    return ''
}

function Get-PowerSchemeListText {
    try {
        return (& powercfg.exe /list 2>&1 | Out-String)
    } catch {
        return ''
    }
}

function Test-TimerCapabilityFailureEvidence {
    param([object]$Timer)

    $failure = Get-PathValue $Timer 'capabilities.timerApiFailure'
    if ($null -eq $failure) { return $false }
    return (
        (Get-PropertyValue $failure 'timedOut' $false) -eq $true -or
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $failure 'startError' '')) -or
        ($null -ne (Get-PropertyValue $failure 'processExitCode' $null) -and [int](Get-PropertyValue $failure 'processExitCode' 0) -ne 0) -or
        ($null -ne (Get-PropertyValue $failure 'beginResult' $null) -and [uint32](Get-PropertyValue $failure 'beginResult' 0) -ne 0) -or
        ($null -ne (Get-PropertyValue $failure 'endResult' $null) -and [uint32](Get-PropertyValue $failure 'endResult' 0) -ne 0)
    )
}

function Test-PowerCapabilityFailureEvidence {
    param([object]$Power)

    $failure = Get-PathValue $Power 'capabilities.powerCommandFailure'
    if ($null -eq $failure -or [int](Get-PropertyValue $failure 'failedStepCount' 0) -lt 1) { return $false }
    foreach ($step in @((Get-PropertyValue $failure 'failedSteps' @()))) {
        if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $step 'error' ''))) { return $true }
        if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $step 'filePath' '')) -and (@((Get-PropertyValue $step 'arguments' @())).Count -gt 0 -or $null -ne (Get-PropertyValue $step 'exitCode' $null) -or (Get-PropertyValue $step 'timedOut' $false) -eq $true -or -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $step 'startError' '')))) { return $true }
    }
    return $false
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:RouterPath = Join-Path $repoRoot 'backend\scripts\Invoke-RooIndustriesCapability.ps1'
$fragmentPath = Join-Path $repoRoot 'backend\capabilities\system-optimizations.json'
$manifestPath = Join-Path $repoRoot 'backend\capabilities\routing\system-optimizations.routes.json'
$adminFeatureStep = 'Requires an administrators-group token: launch via an elevated helper before DISM feature queries can run'

$stateBefore = Get-StateEntryCount $repoRoot
Add-Check ($stateBefore -eq 0) 'backend/state is absent or empty before system optimization router validation' "backend/state is not empty before system optimization router validation: $stateBefore item(s)"

$fragment = $null
$manifest = $null
try {
    $fragment = Get-Content -LiteralPath $fragmentPath -Raw | ConvertFrom-Json
    Add-Pass 'System optimization capability fragment parses as JSON'
} catch {
    Add-Failure "System optimization capability fragment failed JSON parse: $($_.Exception.Message)"
}

try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Add-Pass 'System optimization route manifest parses as JSON'
} catch {
    Add-Failure "System optimization route manifest failed JSON parse: $($_.Exception.Message)"
}

$capabilities = if ($fragment) { @((Get-PropertyValue $fragment 'capabilities' @())) } else { @() }
$capabilityIds = @($capabilities | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })
$routes = if ($manifest) { @((Get-PropertyValue $manifest 'routes' @())) } else { @() }

if ($manifest) {
    Add-Check ([int](Get-PropertyValue $manifest 'schemaVersion' 0) -eq 1) 'Route manifest schemaVersion is 1' 'Route manifest schemaVersion is not 1'
    Add-Check ([string](Get-PropertyValue $manifest 'family' '') -eq 'system-optimizations') 'Route manifest family is system-optimizations' 'Route manifest family mismatch'
}
Add-Check ($capabilityIds.Count -eq 11) 'System optimization fragment has 11 capabilities' "System optimization fragment expected 11 capabilities, got $($capabilityIds.Count)"
Add-Check ($routes.Count -eq 11) 'System optimization route manifest has 11 routes' "System optimization route manifest expected 11 routes, got $($routes.Count)"

foreach ($capabilityId in $capabilityIds) {
    $route = Get-RouteByCapabilityId $manifest $capabilityId
    Add-Check ($null -ne $route) "$capabilityId has a route" "$capabilityId route missing"
    if ($null -eq $route) { continue }

    foreach ($sectionName in @('preview', 'apply', 'restore')) {
        $section = Get-RouteSection $route $sectionName
        Add-Check ($null -ne $section) "$capabilityId has $sectionName route section" "$capabilityId missing $sectionName route section"
        if ($null -eq $section) { continue }

        $statusOnly = [bool](Get-PropertyValue $section 'statusOnly' $false)
        if ($statusOnly) {
            Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $section 'reason' ''))) "$capabilityId $sectionName statusOnly has reason" "$capabilityId $sectionName statusOnly missing reason"
            Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $section 'nextRequiredStep' ''))) "$capabilityId $sectionName statusOnly has nextRequiredStep" "$capabilityId $sectionName statusOnly missing nextRequiredStep"
        } else {
            $script = [string](Get-PropertyValue $section 'script' '')
            Add-Check (-not [string]::IsNullOrWhiteSpace($script)) "$capabilityId $sectionName has routed script" "$capabilityId $sectionName missing routed script"
            if (-not [string]::IsNullOrWhiteSpace($script)) {
                $scriptPath = Join-Path $repoRoot ($script -replace '/', '\')
                Add-Check (Test-Path -LiteralPath $scriptPath -PathType Leaf) "$capabilityId $sectionName routed script exists" "$capabilityId $sectionName routed script missing: $script"
            }
        }
    }
}

$extraRoutes = @($routes | Where-Object { $capabilityIds -notcontains [string](Get-PropertyValue $_ 'capabilityId' '') })
Add-Check ($extraRoutes.Count -eq 0) 'Route manifest has no extra system optimization capabilityIds' "Route manifest has $($extraRoutes.Count) extra route(s)"

$statusOnlyExpected = @(
    'system-optimizations.network-tweaks',
    'system-optimizations.game-registry-tweaks',
    'system-optimizations.svchost-grouping-registry',
    'system-optimizations.windows-features-fixes',
    'system-optimizations.windows-toggle-library'
)
foreach ($capabilityId in $statusOnlyExpected) {
    $route = Get-RouteByCapabilityId $manifest $capabilityId
    foreach ($sectionName in @('apply', 'restore')) {
        $section = Get-RouteSection $route $sectionName
        Add-Check ([bool](Get-PropertyValue $section 'statusOnly' $false)) "$capabilityId $sectionName is statusOnly" "$capabilityId $sectionName is not statusOnly"
        Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $section 'nextRequiredStep' ''))) "$capabilityId $sectionName has precise next step" "$capabilityId $sectionName missing precise next step"
    }
}

foreach ($capabilityId in $capabilityIds) {
    foreach ($action in @('status', 'explain')) {
        $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', $action)
        $label = "$capabilityId $action"
        Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
        Test-CompleteEnvelope $result.json $label
        if ($null -eq $result.json) { continue }
        Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'completed') "$label status is completed" "$label status is not completed"
        Add-Check ([string](Get-PropertyValue $result.json 'family' '') -eq 'system-optimizations') "$label family is system-optimizations" "$label family mismatch"
        Add-Check ([string](Get-PropertyValue $result.json 'action' '') -eq $action) "$label action is echoed" "$label action mismatch"
        Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
        Add-Check ($null -ne (Get-PathValue $result.json 'evidence.availability')) "$label embeds availability evidence" "$label missing availability evidence"
        Add-Check ($null -ne (Get-PathValue $result.json 'evidence.routing')) "$label embeds routing evidence" "$label missing routing evidence"
    }
}

$timerPreview = Invoke-Router @('-CapabilityId', 'system-optimizations.timer-resolution', '-Action', 'preview')
Add-Check ($timerPreview.exitCode -eq 0) 'Timer preview exits 0' "Timer preview exit code expected 0, got $($timerPreview.exitCode)"
Test-CompleteEnvelope $timerPreview.json 'Timer preview'
if ($null -ne $timerPreview.json) {
    Add-Check ([string](Get-PropertyValue $timerPreview.json 'status' '') -eq 'completed') 'Timer preview status is completed' 'Timer preview status mismatch'
    Add-Check ([string](Get-PropertyValue $timerPreview.json 'routedScript' '') -eq 'backend/scripts/Preview-StutterOptimization.ps1') 'Timer preview routes to Preview-StutterOptimization.ps1' 'Timer preview routedScript mismatch'
    Add-Check ([string](Get-PathValue $timerPreview.json 'evidence.actionId') -eq 'performance.stutterOptimization.preview') 'Timer preview embeds stutter preview evidence' 'Timer preview evidence actionId mismatch'
    Add-Check ([string](Get-PathValue $timerPreview.json 'evidence.optimizationId') -eq 'timer-resolution') 'Timer preview uses timer-resolution optimization id' 'Timer preview optimization id mismatch'
}

$dispatchableApplyIds = @(
    'system-optimizations.timer-resolution',
    'system-optimizations.power-plan',
    'system-optimizations.shader-cache',
    'system-optimizations.service-trim'
)
foreach ($capabilityId in $capabilityIds) {
    $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', 'apply')
    $label = "$capabilityId apply without confirmation"
    Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
    Test-CompleteEnvelope $result.json $label
    if ($null -eq $result.json) { continue }
    Add-Check ((Get-PropertyValue $result.json 'dryRun' $false) -eq $true) "$label remains dryRun" "$label is not dryRun"
    Add-Check ((Get-PropertyValue $result.json 'changed' $true) -eq $false) "$label changed is false" "$label changed is not false"
    Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
    $status = [string](Get-PropertyValue $result.json 'status' '')
    if ($dispatchableApplyIds -contains $capabilityId -and (Get-PropertyValue $result.json 'machineAvailable' $false) -eq $true) {
        Add-Check ($status -eq 'approval-required') "$label returns approval-required" "$label expected approval-required, got $status"
    } else {
        Add-Check ($status -in @('approval-required', 'not-executable', 'unavailable')) "$label returns non-mutating status" "$label returned unexpected status $status"
    }
}

$timerApply = Invoke-Router @('-CapabilityId', 'system-optimizations.timer-resolution', '-Action', 'apply', '-ConfirmApply')
Add-Check ($timerApply.exitCode -eq 0) 'Timer confirmed apply exits 0' "Timer confirmed apply exit code expected 0, got $($timerApply.exitCode)"
Test-CompleteEnvelope $timerApply.json 'Timer confirmed apply'
if ($null -ne $timerApply.json) {
    Add-Check ([string](Get-PropertyValue $timerApply.json 'status' '') -eq 'completed') 'Timer confirmed apply status is completed' 'Timer confirmed apply status mismatch'
    Add-Check ([string](Get-PropertyValue $timerApply.json 'routedScript' '') -eq 'backend/scripts/Invoke-StutterOptimizationRealExecutor.ps1') 'Timer confirmed apply routes to real executor' 'Timer confirmed apply routedScript mismatch'
    Add-Check ((Get-PropertyValue $timerApply.json 'dryRun' $true) -eq $false) 'Timer confirmed apply is not dryRun' 'Timer confirmed apply stayed dryRun'
    Add-Check ((Get-PropertyValue $timerApply.json 'approvalSatisfied' $false) -eq $true) 'Timer confirmed apply approval is satisfied' 'Timer confirmed apply approval was not satisfied'
    Add-Check ([string](Get-PathValue $timerApply.json 'evidence.optimizationId') -eq 'timer-resolution') 'Timer real executor used timer-resolution id' 'Timer real executor optimization id mismatch'
    Add-Check ([string](Get-PathValue $timerApply.json 'evidence.executionMode') -eq 'real-reversible-timer-session') 'Timer real executor used bounded session mode' 'Timer real executor mode mismatch'
    Add-Check ((Get-PathValue $timerApply.json 'evidence.summary.willPersist') -eq $false) 'Timer real executor will not persist timer resolution' 'Timer real executor reports persistence'
    Add-Check ((Get-PathValue $timerApply.json 'evidence.summary.willLaunchForbiddenUtility') -eq $false) 'Timer real executor did not launch forbidden utilities' 'Timer real executor reports forbidden utility launch'
    $timerStatus = [string](Get-PathValue $timerApply.json 'evidence.status')
    if ($timerStatus -eq 'success') {
        Add-Check ((Get-PropertyValue $timerApply.json 'changed' $false) -eq $true) 'Timer confirmed apply marks changed only after restore proof' 'Timer confirmed apply did not mark changed after success'
        Add-Check ((Get-PropertyValue $timerApply.json 'restoreAvailable' $false) -eq $true) 'Timer confirmed apply marks restore evidence available' 'Timer confirmed apply did not mark restore evidence available'
        Add-Check ((Get-PathValue $timerApply.json 'evidence.capabilities.timerRestoreProved') -eq $true) 'Timer real executor proved timeEndPeriod on exit' 'Timer real executor did not prove timer restore'
    } else {
        Add-Check ((Get-PropertyValue $timerApply.json 'changed' $true) -eq $false) 'Timer capability-limited result does not claim changed' 'Timer capability-limited result incorrectly claims changed'
        Add-Check (Test-TimerCapabilityFailureEvidence $timerApply.json.evidence) 'Timer capability-limited result has exact failure evidence' "Timer confirmed apply returned $timerStatus without exact failure evidence"
    }
}

$originalPowerGuid = Get-ActivePowerSchemeGuid
$powerApply = Invoke-Router @('-CapabilityId', 'system-optimizations.power-plan', '-Action', 'apply', '-ConfirmApply')
$afterPowerGuid = Get-ActivePowerSchemeGuid
Add-Check ($powerApply.exitCode -eq 0) 'Power plan confirmed apply exits 0' "Power plan confirmed apply exit code expected 0, got $($powerApply.exitCode)"
Test-CompleteEnvelope $powerApply.json 'Power plan confirmed apply'
if ($null -ne $powerApply.json) {
    Add-Check ([string](Get-PropertyValue $powerApply.json 'status' '') -eq 'completed') 'Power plan confirmed apply status is completed' 'Power plan confirmed apply status mismatch'
    Add-Check ([string](Get-PropertyValue $powerApply.json 'routedScript' '') -eq 'backend/scripts/Invoke-StutterOptimizationRealExecutor.ps1') 'Power plan confirmed apply routes to real executor' 'Power plan confirmed apply routedScript mismatch'
    Add-Check ((Get-PropertyValue $powerApply.json 'dryRun' $true) -eq $false) 'Power plan confirmed apply is not dryRun' 'Power plan confirmed apply stayed dryRun'
    Add-Check ((Get-PropertyValue $powerApply.json 'approvalSatisfied' $false) -eq $true) 'Power plan confirmed apply approval is satisfied' 'Power plan confirmed apply approval was not satisfied'
    Add-Check ([string](Get-PathValue $powerApply.json 'evidence.optimizationId') -eq 'power-plan') 'Power real executor used power-plan id' 'Power real executor optimization id mismatch'
    Add-Check ([string](Get-PathValue $powerApply.json 'evidence.executionMode') -eq 'real-reversible-power-plan-session') 'Power real executor used reversible session mode' 'Power real executor mode mismatch'
    Add-Check ((Get-PathValue $powerApply.json 'evidence.summary.willPersist') -eq $false) 'Power real executor will not persist plan selection' 'Power real executor reports persistence'
    Add-Check ((Get-PathValue $powerApply.json 'evidence.summary.willLaunchForbiddenUtility') -eq $false) 'Power real executor did not launch forbidden utilities' 'Power real executor reports forbidden utility launch'
    $powerStatus = [string](Get-PathValue $powerApply.json 'evidence.status')
    if ($powerStatus -eq 'success') {
        Add-Check ((Get-PropertyValue $powerApply.json 'changed' $false) -eq $true) 'Power plan confirmed apply marks changed after restore attempt' 'Power plan confirmed apply did not mark changed after success'
        Add-Check ((Get-PropertyValue $powerApply.json 'restoreAvailable' $false) -eq $true) 'Power plan confirmed apply marks restore evidence available' 'Power plan confirmed apply did not mark restore evidence available'
        Add-Check ((Get-PathValue $powerApply.json 'evidence.capabilities.restoreAttempted') -eq $true) 'Power executor attempted original scheme restore' 'Power executor did not attempt original scheme restore'
        Add-Check ((Get-PathValue $powerApply.json 'evidence.capabilities.cleanupAttempted') -eq $true) 'Power executor attempted temp scheme cleanup' 'Power executor did not attempt temp scheme cleanup'
    } else {
        $powerCleanupAttempted = ((Get-PathValue $powerApply.json 'evidence.capabilities.cleanupAttempted') -eq $true)
        if ($powerCleanupAttempted) {
            Add-Check ((Get-PropertyValue $powerApply.json 'changed' $false) -eq $true) 'Power capability-limited result marks changed only when temp cleanup was attempted' 'Power capability-limited result did not mark changed despite temp cleanup attempt'
        } else {
            Add-Check ((Get-PropertyValue $powerApply.json 'changed' $true) -eq $false) 'Power capability-limited result does not claim changed before temp scheme creation' 'Power capability-limited result incorrectly claims changed before temp scheme creation'
        }
        Add-Check (Test-PowerCapabilityFailureEvidence $powerApply.json.evidence) 'Power capability-limited result has exact powercfg failure evidence' "Power confirmed apply returned $powerStatus without exact failure evidence"
    }

    if (-not [string]::IsNullOrWhiteSpace($originalPowerGuid) -and -not [string]::IsNullOrWhiteSpace($afterPowerGuid)) {
        Add-Check ($afterPowerGuid -eq $originalPowerGuid) 'Power plan active scheme restored to original GUID' "Power plan active scheme was not restored: before=$originalPowerGuid after=$afterPowerGuid"
    } else {
        Add-Pass 'Power plan active scheme comparison skipped because powercfg did not return a parsable GUID'
    }

    $temporarySchemeGuid = [string](Get-PathValue $powerApply.json 'evidence.capabilities.temporarySchemeGuid')
    if (-not [string]::IsNullOrWhiteSpace($temporarySchemeGuid)) {
        $schemeList = Get-PowerSchemeListText
        Add-Check ($schemeList -notmatch [regex]::Escape($temporarySchemeGuid)) 'Power executor deleted temporary scheme' "Power executor left temporary scheme behind: $temporarySchemeGuid"
    } else {
        Add-Pass 'Power executor did not report a temporary scheme GUID to clean'
    }

    $temporaryPowFilePath = [string](Get-PathValue $powerApply.json 'evidence.capabilities.temporaryPowFilePath')
    if (-not [string]::IsNullOrWhiteSpace($temporaryPowFilePath)) {
        Add-Check (-not (Test-Path -LiteralPath $temporaryPowFilePath)) 'Power executor removed temporary .pow export file' "Power executor left temporary .pow file behind: $temporaryPowFilePath"
    }
}

$standbyApply = Invoke-Router @('-CapabilityId', 'system-optimizations.standby-memory', '-Action', 'apply', '-ConfirmApply')
Add-Check ($standbyApply.exitCode -eq 0) 'Standby memory confirmed apply exits 0' "Standby memory confirmed apply exit code expected 0, got $($standbyApply.exitCode)"
Test-CompleteEnvelope $standbyApply.json 'Standby memory confirmed apply'
if ($null -ne $standbyApply.json) {
    Add-Check ([string](Get-PropertyValue $standbyApply.json 'status' '') -eq 'not-executable') 'Standby memory confirmed apply returns not-executable' 'Standby memory confirmed apply did not return not-executable'
    Add-Check ($null -eq (Get-PropertyValue $standbyApply.json 'routedScript' $null)) 'Standby memory confirmed apply did not dispatch helper' 'Standby memory confirmed apply unexpectedly dispatched'
    Add-Check ((Get-PropertyValue $standbyApply.json 'dryRun' $false) -eq $true) 'Standby memory confirmed apply remains dryRun' 'Standby memory confirmed apply is not dryRun'
    Add-Check ([string](Get-PropertyValue $standbyApply.json 'nextRequiredStep' '') -eq 'Run Build-StandbyMemoryHelper.ps1, then package the helper with an elevated launch manifest.') 'Standby memory apply names helper packaging next step' 'Standby memory apply nextRequiredStep mismatch'
}

$shaderTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-router-shader-$([guid]::NewGuid().ToString('N'))"
$serviceTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-router-service-$([guid]::NewGuid().ToString('N'))"
$cleanupPaths = New-Object System.Collections.Generic.List[string]
$cleanupPaths.Add($shaderTempRoot) | Out-Null
$cleanupPaths.Add($serviceTempRoot) | Out-Null

try {
    $shaderCacheRoot = Join-Path $shaderTempRoot 'shader-cache-root'
    $shaderCacheDir = Join-Path $shaderCacheRoot 'NVIDIA\DXCache'
    New-Item -ItemType Directory -Path $shaderCacheDir -Force | Out-Null
    $shaderFile = Join-Path $shaderCacheDir 'fixture.bin'
    Set-Content -LiteralPath $shaderFile -Value 'shader cache fixture' -Encoding UTF8

    $shaderApply = Invoke-Router @('-CapabilityId', 'system-optimizations.shader-cache', '-Action', 'apply', '-ConfirmApply', '-FixtureRoot', $shaderCacheRoot)
    Add-Check ($shaderApply.exitCode -eq 0) 'Shader cache fixture apply exits 0' "Shader cache fixture apply exit code expected 0, got $($shaderApply.exitCode)"
    Test-CompleteEnvelope $shaderApply.json 'Shader cache fixture apply'
    if ($null -ne $shaderApply.json) {
        Add-Check ([string](Get-PropertyValue $shaderApply.json 'status' '') -eq 'completed') 'Shader cache fixture apply status is completed' 'Shader cache fixture apply status mismatch'
        Add-Check ([string](Get-PropertyValue $shaderApply.json 'routedScript' '') -eq 'backend/scripts/Invoke-StutterOptimization.ps1') 'Shader cache fixture apply routes to fixture executor' 'Shader cache fixture apply routedScript mismatch'
        Add-Check ((Get-PropertyValue $shaderApply.json 'changed' $false) -eq $true) 'Shader cache fixture apply marks changed after deletion' 'Shader cache fixture apply did not mark changed'
        Add-Check ((Get-PropertyValue $shaderApply.json 'restoreAvailable' $false) -eq $true) 'Shader cache fixture apply exposes restore availability' 'Shader cache fixture apply did not expose restore availability'
        Add-Check (-not (Test-Path -LiteralPath $shaderFile)) 'Shader cache fixture file was deleted under temp root' 'Shader cache fixture file still exists after apply'
        Add-Check (Test-PathUnderRoot ([string](Get-PathValue $shaderApply.json 'evidence.shaderCacheRoot')) $shaderTempRoot) 'Shader cache evidence root is under temp fixture root' 'Shader cache evidence root escaped temp fixture root'
        foreach ($deleted in @((Get-PathValue $shaderApply.json 'evidence.changedItems'))) {
            Add-Check (Test-PathUnderRoot ([string](Get-PropertyValue $deleted 'path' '')) $shaderCacheRoot) 'Shader cache deleted item stayed under fixture root' "Shader cache deleted item escaped fixture root: $([string](Get-PropertyValue $deleted 'path' ''))"
        }
        foreach ($backup in @((Get-PathValue $shaderApply.json 'evidence.rollback.backupRecords'))) {
            Add-Check (Test-PathUnderRoot ([string](Get-PropertyValue $backup 'backupPath' '')) $shaderCacheRoot) 'Shader cache backup stayed under fixture root' "Shader cache backup escaped fixture root: $([string](Get-PropertyValue $backup 'backupPath' ''))"
        }

        $rollbackManifestPath = [string](Get-PathValue $shaderApply.json 'evidence.rollback.rollbackManifestPath')
        Add-Check (-not [string]::IsNullOrWhiteSpace($rollbackManifestPath)) 'Shader cache fixture apply emitted rollback manifest path' 'Shader cache fixture apply did not emit rollback manifest path'
        Add-Check (Test-PathUnderRoot $rollbackManifestPath $shaderCacheRoot) 'Shader cache rollback manifest stayed under fixture root' "Shader cache rollback manifest escaped fixture root: $rollbackManifestPath"
        Add-Check (Test-Path -LiteralPath $rollbackManifestPath -PathType Leaf) 'Shader cache rollback manifest exists' 'Shader cache rollback manifest missing'

        if (-not [string]::IsNullOrWhiteSpace($rollbackManifestPath)) {
            $shaderRestore = Invoke-Router @('-CapabilityId', 'system-optimizations.shader-cache', '-Action', 'restore', '-ConfirmApply', '-FixtureRoot', $rollbackManifestPath)
            Add-Check ($shaderRestore.exitCode -eq 0) 'Shader cache fixture restore exits 0' "Shader cache fixture restore exit code expected 0, got $($shaderRestore.exitCode)"
            Test-CompleteEnvelope $shaderRestore.json 'Shader cache fixture restore'
            if ($null -ne $shaderRestore.json) {
                Add-Check ([string](Get-PropertyValue $shaderRestore.json 'status' '') -eq 'completed') 'Shader cache fixture restore status is completed' 'Shader cache fixture restore status mismatch'
                Add-Check ([string](Get-PropertyValue $shaderRestore.json 'routedScript' '') -eq 'backend/scripts/Restore-StutterOptimization.ps1') 'Shader cache fixture restore routes to restore script' 'Shader cache fixture restore routedScript mismatch'
                Add-Check ((Get-PropertyValue $shaderRestore.json 'changed' $false) -eq $true) 'Shader cache fixture restore marks changed after restore' 'Shader cache fixture restore did not mark changed'
                Add-Check (Test-Path -LiteralPath $shaderFile -PathType Leaf) 'Shader cache fixture file restored' 'Shader cache fixture file was not restored'
            }
        }
    }

    New-Item -ItemType Directory -Path $serviceTempRoot -Force | Out-Null
    $serviceShimPath = Join-Path $serviceTempRoot 'service-shim.ps1'
    $serviceLogPath = Join-Path $serviceTempRoot 'service-shim.log'
    $serviceShim = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
($Rest -join '|') | Add-Content -LiteralPath '__LOG_PATH__'
exit 0
'@
    $serviceShim = $serviceShim.Replace('__LOG_PATH__', $serviceLogPath.Replace("'", "''"))
    Set-Content -LiteralPath $serviceShimPath -Value $serviceShim -Encoding UTF8

    $serviceApply = Invoke-Router @('-CapabilityId', 'system-optimizations.service-trim', '-Action', 'apply', '-ConfirmApply', '-FixtureRoot', $serviceShimPath)
    Add-Check ($serviceApply.exitCode -eq 0) 'Service trim confirmed apply exits 0' "Service trim confirmed apply exit code expected 0, got $($serviceApply.exitCode)"
    Test-CompleteEnvelope $serviceApply.json 'Service trim confirmed apply'
    if ($null -ne $serviceApply.json) {
        Add-Check ([string](Get-PropertyValue $serviceApply.json 'status' '') -eq 'completed') 'Service trim confirmed apply status is completed' 'Service trim confirmed apply status mismatch'
        Add-Check ([string](Get-PropertyValue $serviceApply.json 'routedScript' '') -eq 'backend/scripts/Invoke-StutterOptimizationRealExecutor.ps1') 'Service trim routes to real executor analysis/shim path' 'Service trim routedScript mismatch'
        Add-Check ([string](Get-PathValue $serviceApply.json 'evidence.optimizationId') -eq 'service-pause-preview') 'Service trim uses service-pause-preview optimization id' 'Service trim optimization id mismatch'
        Add-Check ([string](Get-PathValue $serviceApply.json 'evidence.executionMode') -eq 'real-readonly-service-analysis') 'Service trim uses read-only service analysis mode' 'Service trim execution mode mismatch'
        Add-Check ((Get-PathValue $serviceApply.json 'evidence.capabilities.serviceShimRunnerExecuted') -eq $true) 'Service trim executed temp shim runner' 'Service trim did not execute temp shim runner'
        Add-Check ((Get-PathValue $serviceApply.json 'evidence.capabilities.realPauseAttempted') -eq $false) 'Service trim did not pause real services' 'Service trim reported real service pause'
        Add-Check ((Get-PathValue $serviceApply.json 'evidence.summary.willEditServices') -eq $false) 'Service trim reports no service edits' 'Service trim reports service edits'
        $shimLog = if (Test-Path -LiteralPath $serviceLogPath) { @(Get-Content -LiteralPath $serviceLogPath) } else { @() }
        Add-Check ($shimLog.Count -eq 3) 'Service trim shim logged backup, pause, and restore calls' "Service trim shim log expected 3 entries, got $($shimLog.Count)"
        if ($shimLog.Count -ge 3) {
            Add-Check ($shimLog[0] -match 'service-backup') 'Service trim shim first call is backup' 'Service trim shim first call mismatch'
            Add-Check ($shimLog[1] -match 'service-pause') 'Service trim shim second call is pause' 'Service trim shim second call mismatch'
            Add-Check ($shimLog[2] -match 'service-restore') 'Service trim shim third call is restore' 'Service trim shim third call mismatch'
        }
    }
} catch {
    Add-Failure "System optimization fixture validation failed: $($_.Exception.Message)"
} finally {
    foreach ($path in @($cleanupPaths.ToArray())) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

foreach ($path in @($cleanupPaths.ToArray())) {
    Add-Check (-not (Test-Path -LiteralPath $path)) "Temporary fixture path cleaned: $path" "Temporary fixture path remains: $path"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$windowsFeaturesStatus = Invoke-Router @('-CapabilityId', 'system-optimizations.windows-features-fixes', '-Action', 'status')
Add-Check ($windowsFeaturesStatus.exitCode -eq 0) 'Windows features status exits 0' "Windows features status exit code expected 0, got $($windowsFeaturesStatus.exitCode)"
Test-CompleteEnvelope $windowsFeaturesStatus.json 'Windows features status'
if ($null -ne $windowsFeaturesStatus.json) {
    Add-Check ([bool](Get-PropertyValue $windowsFeaturesStatus.json 'machineAvailable' $false) -eq $isAdmin) 'Windows features availability matches the measured process token' 'Windows features availability disagrees with process token'
    if (-not $isAdmin) { Add-Check ([string](Get-PropertyValue $windowsFeaturesStatus.json 'unavailableReason' '') -like 'requires-admin-token*') 'Windows features status reports requires-admin-token reason' "Windows features status unavailableReason mismatch: $([string](Get-PropertyValue $windowsFeaturesStatus.json 'unavailableReason' ''))" }
    Add-Check ([string](Get-PathValue $windowsFeaturesStatus.json 'evidence.routing.apply.nextRequiredStep') -eq $adminFeatureStep) 'Windows features status routing evidence names exact admin-token next step' 'Windows features status routing evidence next step mismatch'
}

$windowsFeaturesExplain = Invoke-Router @('-CapabilityId', 'system-optimizations.windows-features-fixes', '-Action', 'explain')
Add-Check ($windowsFeaturesExplain.exitCode -eq 0) 'Windows features explain exits 0' "Windows features explain exit code expected 0, got $($windowsFeaturesExplain.exitCode)"
Test-CompleteEnvelope $windowsFeaturesExplain.json 'Windows features explain'
if ($null -ne $windowsFeaturesExplain.json) {
    if (-not $isAdmin) { Add-Check ([string](Get-PropertyValue $windowsFeaturesExplain.json 'nextRequiredStep' '') -eq $adminFeatureStep) 'Windows features explain names the missing admin token' 'Windows features explain nextRequiredStep mismatch' }
    else { Add-Check ([string](Get-PropertyValue $windowsFeaturesExplain.json 'status' '') -eq 'completed') 'Admin Windows features explanation completes without suggesting elevation' 'Admin explanation did not complete' }
}

$stateAfter = Get-StateEntryCount $repoRoot
Add-Check ($stateAfter -eq 0) 'backend/state is absent or empty after system optimization router validation' "backend/state is not empty after system optimization router validation: $stateAfter item(s)"
Add-Check ($stateBefore -eq $stateAfter) "backend/state item count unchanged at $stateAfter" "backend/state item count changed: before=$stateBefore after=$stateAfter"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Capability router system optimization validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Capability router system optimization validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
