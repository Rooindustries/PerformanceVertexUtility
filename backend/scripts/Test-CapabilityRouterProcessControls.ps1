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
        $start = $text.IndexOf('{')
        $end = $text.LastIndexOf('}')
        if ($start -ge 0 -and $end -gt $start) {
            try {
                return $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
            } catch { }
        }
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

    if ($null -eq $Envelope) { return }

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

function Get-RouteSection {
    param(
        [object]$Route,
        [string]$SectionName
    )

    return Get-PropertyValue $Route $SectionName $null
}

function Test-StatusOnlySection {
    param([object]$Section)
    return [bool](Get-PropertyValue $Section 'statusOnly' $false)
}

function Test-ControlValueEquals {
    param(
        [object]$Left,
        [object]$Right
    )

    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    return ([string]$Left -eq [string]$Right)
}

function Test-ControlStateRestored {
    param(
        [object]$Before,
        [object]$After
    )

    if ($null -eq $Before -or $null -eq $After) { return $false }
    if (-not (Test-ControlValueEquals (Get-PropertyValue $Before 'priorityClass' $null) (Get-PropertyValue $After 'priorityClass' $null))) { return $false }
    if (-not (Test-ControlValueEquals (Get-PropertyValue $Before 'affinityMask' $null) (Get-PropertyValue $After 'affinityMask' $null))) { return $false }
    if (-not (Test-ControlValueEquals (Get-PropertyValue $Before 'ioPriority' $null) (Get-PropertyValue $After 'ioPriority' $null))) { return $false }
    if (-not (Test-ControlValueEquals (Get-PropertyValue $Before 'gpuPriority' $null) (Get-PropertyValue $After 'gpuPriority' $null))) { return $false }
    return $true
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:RouterPath = Join-Path $repoRoot 'backend\scripts\Invoke-RooCapability.ps1'
$manifestPath = Join-Path $repoRoot 'backend\capabilities\routing\process-controls.routes.json'
$capabilityPath = Join-Path $repoRoot 'backend\capabilities\process-controls.json'

. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$stateBefore = Get-StateEntryCount $repoRoot
Add-Check ($stateBefore -eq 0) 'backend/state is absent or empty before process-controls router validation' "backend/state is not empty before process-controls router validation: $stateBefore item(s)"

$manifest = $null
$capabilityFragment = $null
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Add-Pass 'process-controls route manifest parses as JSON'
} catch {
    Add-Failure "process-controls route manifest failed to parse: $($_.Exception.Message)"
}

try {
    $capabilityFragment = Get-Content -LiteralPath $capabilityPath -Raw | ConvertFrom-Json
    Add-Pass 'process-controls capability fragment parses as JSON'
} catch {
    Add-Failure "process-controls capability fragment failed to parse: $($_.Exception.Message)"
}

if ($null -ne $manifest) {
    Add-Check ([int](Get-PropertyValue $manifest 'schemaVersion' 0) -eq 1) 'Manifest schemaVersion is 1' 'Manifest schemaVersion is not 1'
    Add-Check ([string](Get-PropertyValue $manifest 'family' '') -eq 'process-controls') 'Manifest family is process-controls' 'Manifest family mismatch'
}

$capabilities = @()
if ($null -ne $capabilityFragment) {
    $capabilities = @($capabilityFragment.capabilities)
    Add-Check ($capabilities.Count -eq 9) 'Registry exposes 9 process-controls capabilities' "Registry process-controls capability count expected 9, got $($capabilities.Count)"
}

$routes = if ($null -ne $manifest) { @($manifest.routes) } else { @() }
Add-Check ($routes.Count -eq $capabilities.Count) "Manifest route count matches registry count at $($routes.Count)" "Manifest route count $($routes.Count) did not match registry count $($capabilities.Count)"

$routesById = @{}
foreach ($route in $routes) {
    $capabilityId = [string](Get-PropertyValue $route 'capabilityId' '')
    if ([string]::IsNullOrWhiteSpace($capabilityId)) {
        Add-Failure 'Manifest route has an empty capabilityId'
        continue
    }
    if ($routesById.ContainsKey($capabilityId)) {
        Add-Failure "Duplicate route found for $capabilityId"
    } else {
        $routesById[$capabilityId] = $route
        Add-Pass "Manifest route is unique for $capabilityId"
    }

    foreach ($sectionName in @('preview','apply','restore')) {
        $section = Get-RouteSection $route $sectionName
        Add-Check ($null -ne $section) "$capabilityId has $sectionName route section" "$capabilityId missing $sectionName route section"
        if ($null -eq $section) { continue }

        if (Test-StatusOnlySection $section) {
            Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $section 'reason' ''))) "$capabilityId $sectionName statusOnly has a reason" "$capabilityId $sectionName statusOnly missing reason"
            Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $section 'nextRequiredStep' ''))) "$capabilityId $sectionName statusOnly has nextRequiredStep" "$capabilityId $sectionName statusOnly missing nextRequiredStep"
        } else {
            $script = [string](Get-PropertyValue $section 'script' '')
            $scriptPath = Join-Path $repoRoot ($script -replace '/', '\')
            Add-Check (-not [string]::IsNullOrWhiteSpace($script)) "$capabilityId $sectionName declares a script" "$capabilityId $sectionName missing script"
            Add-Check (Test-Path -LiteralPath $scriptPath -PathType Leaf) "$capabilityId $sectionName referenced script exists: $script" "$capabilityId $sectionName referenced script missing: $script"
        }
    }
}

foreach ($capability in $capabilities) {
    $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
    Add-Check ($routesById.ContainsKey($capabilityId)) "Manifest contains route for $capabilityId" "Manifest missing route for $capabilityId"
}

$affToolRoute = if ($routesById.ContainsKey('process-controls.afftool-affinity-policy')) { $routesById['process-controls.afftool-affinity-policy'] } else { $null }
foreach ($sectionName in @('preview','apply','restore')) {
    $section = Get-RouteSection $affToolRoute $sectionName
    Add-Check (Test-StatusOnlySection $section) "AffTool $sectionName is statusOnly" "AffTool $sectionName is not statusOnly"
}

$governorRoute = if ($routesById.ContainsKey('process-controls.probalance-restraint')) { $routesById['process-controls.probalance-restraint'] } else { $null }
$governorApply = Get-RouteSection $governorRoute 'apply'
Add-Check ([string](Get-PropertyValue $governorApply 'disposableProbeParam' '') -eq '-ForegroundProcessId') 'Governor apply declares the actual disposable probe parameter -ForegroundProcessId' 'Governor apply disposableProbeParam mismatch'

foreach ($capability in $capabilities) {
    $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
    foreach ($action in @('status','explain')) {
        $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', $action)
        $label = "$capabilityId $action"
        Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
        Test-CompleteEnvelope $result.json $label
        if ($null -eq $result.json) { continue }
        Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'completed') "$label status is completed" "$label status is not completed"
        Add-Check ([string](Get-PropertyValue $result.json 'action' '') -eq $action) "$label action is echoed" "$label action mismatch"
        Add-Check ([string](Get-PropertyValue $result.json 'family' '') -eq 'process-controls') "$label family is process-controls" "$label family mismatch"
        Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
    }
}

$previewExpectations = [ordered]@{
    'process-controls.cpu-priority' = 'backend/scripts/Preview-ProcessProfile.ps1'
    'process-controls.io-priority' = 'backend/scripts/Preview-ProcessPolicy.ps1'
    'process-controls.probalance-restraint' = 'backend/scripts/Preview-ProcessGovernor.ps1'
    'process-controls.session-restore' = 'backend/scripts/Get-GameTuneSessionStatus.ps1'
    'process-controls.lightweight-governor-budget' = 'backend/scripts/Measure-RooBackendFootprint.ps1'
}

foreach ($capabilityId in $previewExpectations.Keys) {
    $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', 'preview')
    $label = "$capabilityId preview"
    Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
    Test-CompleteEnvelope $result.json $label
    if ($null -eq $result.json) { continue }
    Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'completed') "$label status is completed" "$label status is not completed"
    Add-Check ([string](Get-PropertyValue $result.json 'routedScript' '') -eq $previewExpectations[$capabilityId]) "$label routed expected script" "$label routedScript mismatch: $([string](Get-PropertyValue $result.json 'routedScript' ''))"
    Add-Check ($null -ne (Get-PropertyValue (Get-PropertyValue $result.json 'evidence' $null) 'actionId' $null)) "$label embeds real script evidence" "$label missing script actionId evidence"
}

foreach ($capability in $capabilities) {
    $capabilityId = [string](Get-PropertyValue $capability 'capabilityId' '')
    $applyStatus = [string](Get-PropertyValue (Get-PropertyValue $capability 'apply' $null) 'status' '')
    $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', 'apply')
    $label = "$capabilityId apply without confirmation"
    Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
    Test-CompleteEnvelope $result.json $label
    if ($null -eq $result.json) { continue }
    $status = [string](Get-PropertyValue $result.json 'status' '')
    if ($applyStatus -eq 'live') {
        Add-Check ($status -eq 'approval-required') "$label returns approval-required" "$label expected approval-required, got $status"
    } else {
        Add-Check ($status -in @('not-executable','unavailable')) "$label returns not-executable or unavailable" "$label expected not-executable or unavailable, got $status"
    }
    Add-Check ((Get-PropertyValue $result.json 'dryRun' $false) -eq $true) "$label is dryRun" "$label is not dryRun"
    Add-Check ((Get-PropertyValue $result.json 'changed' $true) -eq $false) "$label changed is false" "$label changed is not false"
    Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
}

$liveRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-router-process-controls-$([guid]::NewGuid().ToString('N'))"
$busyProbe = $null
$protectedProbe = $null
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $liveRoot -Force | Out-Null
    $busyExe = Join-Path $liveRoot 'RooRouterWebHelperProbe.exe'
    $protectedExe = Join-Path $liveRoot 'RooRouterProtectedProbe.exe'
    Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $busyExe -Force
    Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $protectedExe -Force

    $busyCommand = "Add-Type -TypeDefinition 'using System; using System.Threading; public static class RooRouterBurn { public static void Run() { while (true) { Thread.SpinWait(1000000); } } }'; `$method = [RooRouterBurn].GetMethod('Run'); `$starter = [System.Delegate]::CreateDelegate([System.Threading.ThreadStart], `$method); `$threads = @(); for (`$i = 0; `$i -lt [Environment]::ProcessorCount; `$i++) { `$thread = [System.Threading.Thread]::new(`$starter); `$thread.IsBackground = `$true; `$thread.Start(); `$threads += `$thread }; Start-Sleep -Seconds 120"

    $busyProbe = Start-Process -FilePath $busyExe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command',$busyCommand -WindowStyle Hidden -PassThru
    $protectedProbe = Start-Process -FilePath $protectedExe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 3500

    try {
        (Get-Process -Id $busyProbe.Id -ErrorAction Stop).PriorityClass = 'Normal'
    } catch { }
    Start-Sleep -Milliseconds 500

    $before = Get-RooProcessControlState $busyProbe.Id $null
    Add-Check ([bool](Get-PropertyValue $before 'exists' $false)) 'Disposable governor busy probe is running before routed apply' 'Disposable governor busy probe was not running before routed apply'
    $protectedBefore = Get-RooProcessControlState $protectedProbe.Id $null
    Add-Check ([bool](Get-PropertyValue $protectedBefore 'exists' $false)) 'Disposable governor foreground probe is running before routed apply' 'Disposable governor foreground probe was not running before routed apply'

    $previewBefore = Get-RooProcessControlState $busyProbe.Id $null
    $directPreview = & (Join-Path $PSScriptRoot 'Preview-ProcessGovernor.ps1') -SampleIntervalMilliseconds 800 -ForegroundProcessId $protectedProbe.Id | ConvertFrom-Json
    $previewAfter = Get-RooProcessControlState $busyProbe.Id $null
    Add-Check (Test-ControlStateRestored $previewBefore $previewAfter) 'Direct governor preview left the disposable busy probe unchanged' "Direct governor preview changed the disposable busy probe: priority $([string](Get-PropertyValue $previewAfter 'priorityClass' ''))/$([string](Get-PropertyValue $previewBefore 'priorityClass' ''))"
    $directBusyPreview = @($directPreview.preview | Where-Object { [int](Get-PropertyValue $_ 'processId' 0) -eq [int]$busyProbe.Id })
    if ($directBusyPreview.Count -ge 1) {
        Add-Check ((Get-PropertyValue $directBusyPreview[0] 'requiresConfirmation' $false) -eq $true) 'Direct governor preview requires confirmation for the disposable busy probe' 'Direct governor preview did not require confirmation for the disposable busy probe'
    }

    $stateRoot = Join-Path $liveRoot 'state'
    $apply = Invoke-Router @(
        '-CapabilityId',
        'process-controls.probalance-restraint',
        '-Action',
        'apply',
        '-ConfirmApply',
        '-FixtureRoot',
        $stateRoot,
        '-TargetProcessId',
        ([string]$protectedProbe.Id)
    )
    Add-Check ($apply.exitCode -eq 0) "Confirmed governor apply exits 0" "Confirmed governor apply exit code expected 0, got $($apply.exitCode)"
    Test-CompleteEnvelope $apply.json 'Confirmed governor apply'
    if ($null -ne $apply.json) {
        Add-Check ([string](Get-PropertyValue $apply.json 'status' '') -eq 'completed') 'Confirmed governor apply status is completed' "Confirmed governor apply status mismatch: $([string](Get-PropertyValue $apply.json 'status' ''))"
        Add-Check ([string](Get-PropertyValue $apply.json 'routedScript' '') -eq 'backend/scripts/Start-ProcessGovernorSession.ps1') 'Confirmed governor apply routed Start-ProcessGovernorSession.ps1' 'Confirmed governor apply routedScript mismatch'
        Add-Check ((Get-PropertyValue $apply.json 'dryRun' $true) -eq $false) 'Confirmed governor apply is not dryRun' 'Confirmed governor apply unexpectedly stayed dryRun'
        Add-Check ((Get-PropertyValue $apply.json 'approvalSatisfied' $false) -eq $true) 'Confirmed governor apply approvalSatisfied is true' 'Confirmed governor apply approvalSatisfied is not true'
        Add-Check ((Get-PropertyValue $apply.json 'changed' $false) -eq $true) 'Confirmed governor apply reports changed:true' 'Confirmed governor apply did not report changed:true'
        Add-Check ((Get-PropertyValue $apply.json 'restoreAvailable' $false) -eq $true) 'Confirmed governor apply reports restoreAvailable:true' 'Confirmed governor apply did not report restoreAvailable:true'
        $applyEvidence = Get-PropertyValue $apply.json 'evidence' $null
        $changedProbe = @((Get-PropertyValue $applyEvidence 'changedItems' @()) | Where-Object { [int](Get-PropertyValue $_ 'processId' 0) -eq [int]$busyProbe.Id })
        Add-Check ($changedProbe.Count -ge 1) 'Confirmed governor apply evidence includes the disposable busy probe' 'Confirmed governor apply evidence did not include the disposable busy probe'
        Add-Check ([string](Get-PropertyValue $applyEvidence 'stateRoot' '') -like "$stateRoot*") 'Confirmed governor apply state stayed under temp fixture root' 'Confirmed governor apply stateRoot was not under the temp fixture root'
    }

    $afterApply = Get-RooProcessControlState $busyProbe.Id $null
    Add-Check ([string](Get-PropertyValue $afterApply 'priorityClass' '') -eq 'BelowNormal') 'Disposable governor busy probe priority changed to BelowNormal after routed apply' "Disposable governor busy probe priority after apply was $([string](Get-PropertyValue $afterApply 'priorityClass' ''))"

    $restore = Invoke-Router @(
        '-CapabilityId',
        'process-controls.probalance-restraint',
        '-Action',
        'restore',
        '-ConfirmApply',
        '-FixtureRoot',
        $stateRoot
    )
    Add-Check ($restore.exitCode -eq 0) "Confirmed governor restore exits 0" "Confirmed governor restore exit code expected 0, got $($restore.exitCode)"
    Test-CompleteEnvelope $restore.json 'Confirmed governor restore'
    if ($null -ne $restore.json) {
        Add-Check ([string](Get-PropertyValue $restore.json 'status' '') -eq 'completed') 'Confirmed governor restore status is completed' "Confirmed governor restore status mismatch: $([string](Get-PropertyValue $restore.json 'status' ''))"
        Add-Check ([string](Get-PropertyValue $restore.json 'routedScript' '') -eq 'backend/scripts/Stop-ProcessGovernorSession.ps1') 'Confirmed governor restore routed Stop-ProcessGovernorSession.ps1' 'Confirmed governor restore routedScript mismatch'
        Add-Check ((Get-PropertyValue $restore.json 'dryRun' $true) -eq $false) 'Confirmed governor restore is not dryRun' 'Confirmed governor restore unexpectedly stayed dryRun'
        Add-Check ((Get-PropertyValue $restore.json 'changed' $false) -eq $true) 'Confirmed governor restore reports changed:true' 'Confirmed governor restore did not report changed:true'
        $restoreEvidence = Get-PropertyValue $restore.json 'evidence' $null
        $restoredProbe = @((Get-PropertyValue $restoreEvidence 'restoredItems' @()) | Where-Object { [int](Get-PropertyValue $_ 'processId' 0) -eq [int]$busyProbe.Id })
        Add-Check ($restoredProbe.Count -ge 1) 'Confirmed governor restore evidence includes the disposable busy probe' 'Confirmed governor restore evidence did not include the disposable busy probe'
    }

    $afterRestore = Get-RooProcessControlState $busyProbe.Id $null
    Add-Check (Test-ControlStateRestored $before $afterRestore) 'Disposable governor busy probe returned to its original process-control state' "Disposable governor busy probe restore mismatch: priority $([string](Get-PropertyValue $afterRestore 'priorityClass' ''))/$([string](Get-PropertyValue $before 'priorityClass' '')), affinity $([string](Get-PropertyValue $afterRestore 'affinityMask' ''))/$([string](Get-PropertyValue $before 'affinityMask' '')), I/O $([string](Get-PropertyValue $afterRestore 'ioPriority' ''))/$([string](Get-PropertyValue $before 'ioPriority' '')), GPU $([string](Get-PropertyValue $afterRestore 'gpuPriority' ''))/$([string](Get-PropertyValue $before 'gpuPriority' ''))"
} catch {
    Add-Failure "Disposable governor router proof failed: $($_.Exception.Message)"
} finally {
    foreach ($liveProbe in @($busyProbe, $protectedProbe)) {
        if ($liveProbe -and -not $liveProbe.HasExited) {
            foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($liveProbe.Id)" -ErrorAction SilentlyContinue)) {
                Stop-Process -Id ([int]$child.ProcessId) -Force -ErrorAction SilentlyContinue
            }
            Stop-Process -Id $liveProbe.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $liveProbe.Id -Timeout 5 -ErrorAction SilentlyContinue
        }
    }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $fullLiveRoot = [System.IO.Path]::GetFullPath($liveRoot)
    if ($fullLiveRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullLiveRoot)) {
        Remove-Item -LiteralPath $fullLiveRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $cleanupDone = $true
}

Add-Check $cleanupDone 'Disposable router proof cleanup ran' 'Disposable router proof cleanup did not run'

$leftovers = @()
foreach ($item in @(Get-Process -Name 'RooRouterWebHelperProbe','RooRouterProtectedProbe' -ErrorAction SilentlyContinue)) {
    $path = $null
    try { $path = $item.Path } catch { $path = $null }
    if (-not [string]::IsNullOrWhiteSpace([string]$path) -and [string]$path -like "$liveRoot*") {
        $leftovers += $item
    }
}
Add-Check ($leftovers.Count -eq 0) 'No disposable process-controls router probe processes remained' "Disposable probe process(es) remained: $(@($leftovers | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', ')"

$stateAfter = Get-StateEntryCount $repoRoot
Add-Check ($stateAfter -eq 0) 'backend/state is absent or empty after process-controls router validation' "backend/state is not empty after process-controls router validation: $stateAfter item(s)"
Add-Check ($stateBefore -eq $stateAfter) "backend/state item count unchanged at $stateAfter" "backend/state item count changed: before=$stateBefore after=$stateAfter"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Capability router process-controls validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Capability router process-controls validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
