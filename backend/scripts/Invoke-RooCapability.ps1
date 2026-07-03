param(
    [Parameter(Mandatory = $true)]
    [string]$CapabilityId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('preview', 'status', 'explain', 'apply', 'restore')]
    [string]$Action,

    [switch]$ConfirmApply,
    [string]$FixtureRoot = '',
    [int]$TargetProcessId = 0,
    [string]$UtilitiesRoot = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'CapabilityRouter.Common.ps1')

function New-RooRouterError {
    param(
        [string]$Code,
        [string]$Message,
        [bool]$Blocking = $true
    )

    return [pscustomobject]@{
        code = $Code
        message = $Message
        blocking = [bool]$Blocking
    }
}

function Add-RooRouterError {
    param(
        [object]$Envelope,
        [object]$ErrorRecord
    )

    $errors = @()
    if ($null -ne $Envelope.errors) {
        $errors = @($Envelope.errors)
    }
    $errors += $ErrorRecord
    $Envelope.errors = @($errors)
}

function Resolve-RooRepoPath {
    param(
        [string]$RepoRoot,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $candidate = $Path -replace '/', '\'
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $RepoRoot $candidate
    }
    $resolved = [System.IO.Path]::GetFullPath($candidate)
    $repoPrefix = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Route path escapes repository root: $Path"
    }
    return $resolved
}

function ConvertTo-RooRepoRelativePath {
    param(
        [string]$RepoRoot,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $resolved = Resolve-RooRepoPath $RepoRoot $Path
    $repoPrefix = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') + '\'
    return $resolved.Substring($repoPrefix.Length).Replace('\', '/')
}

function Read-RooCapabilityFragments {
    param([string]$RepoRoot)

    $capabilityRoot = Join-Path $RepoRoot 'backend\capabilities'
    $capabilities = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $capabilityRoot -Filter '*.json' -File | Sort-Object Name)) {
        $fragment = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        foreach ($capability in @($fragment.capabilities)) {
            $capabilities.Add($capability) | Out-Null
        }
    }
    return @($capabilities.ToArray())
}

function Get-RooCapabilityById {
    param(
        [object[]]$Capabilities,
        [string]$RequestedCapabilityId
    )

    $matches = @($Capabilities | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq $RequestedCapabilityId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-RooRouteSection {
    param(
        [object]$Route,
        [string]$SectionName
    )

    if ($null -eq $Route) { return $null }
    $property = $Route.PSObject.Properties[$SectionName]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-RooStatusOnlySection {
    param([object]$Section)

    return ([bool](Get-PropertyValue $Section 'statusOnly' $false))
}

function Read-RooRouteManifest {
    param(
        [string]$RepoRoot,
        [string]$Family,
        [string]$RequestedCapabilityId
    )

    $manifestRelativePath = "backend/capabilities/routing/$Family.routes.json"
    $manifestPath = Resolve-RooRepoPath $RepoRoot $manifestRelativePath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject]@{
            manifestPath = $manifestRelativePath
            manifestExists = $false
            routePresent = $false
            manifest = $null
            route = $null
        }
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $route = @($manifest.routes | Where-Object {
        [string](Get-PropertyValue $_ 'capabilityId' '') -eq $RequestedCapabilityId
    } | Select-Object -First 1)

    return [pscustomobject]@{
        manifestPath = $manifestRelativePath
        manifestExists = $true
        routePresent = ($route.Count -eq 1)
        manifest = $manifest
        route = if ($route.Count -eq 1) { $route[0] } else { $null }
    }
}

function New-RooRouteSectionSummary {
    param([object]$Section)

    if ($null -eq $Section) {
        return [pscustomobject]@{
            present = $false
            statusOnly = $false
            script = $null
            timeoutSeconds = $null
            reason = $null
            nextRequiredStep = $null
        }
    }

    return [pscustomobject]@{
        present = $true
        statusOnly = [bool](Get-PropertyValue $Section 'statusOnly' $false)
        script = Get-PropertyValue $Section 'script' $null
        timeoutSeconds = Get-PropertyValue $Section 'timeoutSeconds' $null
        reason = Get-PropertyValue $Section 'reason' $null
        nextRequiredStep = Get-PropertyValue $Section 'nextRequiredStep' $null
    }
}

function New-RooRoutingEvidence {
    param(
        [object]$Capability,
        [object]$Availability,
        [object]$RouteInfo,
        [string]$Action
    )

    $previewSection = if ($RouteInfo) { Get-RooRouteSection $RouteInfo.route 'preview' } else { $null }
    $applySection = if ($RouteInfo) { Get-RooRouteSection $RouteInfo.route 'apply' } else { $null }
    $restoreSection = if ($RouteInfo) { Get-RooRouteSection $RouteInfo.route 'restore' } else { $null }
    $apply = Get-PropertyValue $Capability 'apply' $null
    $restore = Get-PropertyValue $Capability 'restore' $null
    $preview = Get-PropertyValue $Capability 'preview' $null

    $evidence = [pscustomobject]@{
        capability = [pscustomobject]@{
            capabilityId = Get-PropertyValue $Capability 'capabilityId' $null
            previewStatus = Get-PropertyValue $preview 'status' $null
            applyStatus = Get-PropertyValue $apply 'status' $null
            restoreStatus = Get-PropertyValue $restore 'status' $null
            gates = @((Get-PropertyValue $apply 'gates' @()))
        }
        availability = $Availability
        routing = [pscustomobject]@{
            manifestPath = if ($RouteInfo) { $RouteInfo.manifestPath } else { $null }
            manifestExists = if ($RouteInfo) { [bool]$RouteInfo.manifestExists } else { $false }
            routePresent = if ($RouteInfo) { [bool]$RouteInfo.routePresent } else { $false }
            preview = New-RooRouteSectionSummary $previewSection
            apply = New-RooRouteSectionSummary $applySection
            restore = New-RooRouteSectionSummary $restoreSection
        }
    }

    if ($Action -eq 'explain') {
        $evidence | Add-Member -NotePropertyName explanation -NotePropertyValue ([pscustomobject]@{
            applyMode = Get-PropertyValue $apply 'mode' $null
            restoreMode = Get-PropertyValue $restore 'mode' $null
            applyNotes = Get-PropertyValue $apply 'notes' $null
            restoreNotes = Get-PropertyValue $restore 'notes' $null
            availabilityNotes = Get-PropertyValue (Get-PropertyValue $Capability 'availability' $null) 'notes' $null
        })
    }

    return $evidence
}

function New-RooCapabilityEnvelope {
    param(
        [string]$RequestedCapabilityId,
        [string]$Action,
        [string]$CorrelationId,
        [string]$StartedAtUtc,
        [object]$Capability = $null,
        [object]$Availability = $null
    )

    $apply = Get-PropertyValue $Capability 'apply' $null
    $restore = Get-PropertyValue $Capability 'restore' $null
    return [pscustomobject][ordered]@{
        actionId = 'backend.capability.invoke'
        schemaVersion = 1
        correlationId = $CorrelationId
        startedAtUtc = $StartedAtUtc
        completedAtUtc = $null
        capabilityId = $RequestedCapabilityId
        family = Get-PropertyValue $Capability 'family' $null
        displayName = Get-PropertyValue $Capability 'displayName' $null
        frontendLabel = Get-PropertyValue $Capability 'frontendLabel' $null
        frontendTab = Get-PropertyValue $Capability 'frontendTab' $null
        action = $Action
        dryRun = $true
        status = 'completed'
        requiresApproval = [bool](Get-PropertyValue $Capability 'approvalRequired' $false)
        approvalSatisfied = $false
        machineAvailable = if ($Availability) { [bool](Get-PropertyValue $Availability 'available' $false) } else { $false }
        unavailableReason = if ($Availability) { Get-PropertyValue $Availability 'unavailableReason' $null } else { $null }
        applyStatus = Get-PropertyValue $apply 'status' $null
        restoreStatus = Get-PropertyValue $restore 'status' $null
        routedScript = $null
        wouldChange = $false
        changed = $false
        restoreAvailable = $false
        evidence = [pscustomobject]@{}
        errors = @()
        nextRequiredStep = $null
    }
}

function Test-RooApplyStatusCanDispatch {
    param([string]$ApplyStatus)
    return ($ApplyStatus -in @('live', 'fixture-proven', 'allowlist-shim'))
}

function Test-RooRestoreStatusCanDispatch {
    param([string]$RestoreStatus)
    return ($RestoreStatus -in @('live', 'fixture-proven'))
}

function Test-RooActionCouldMutate {
    param(
        [object]$Capability,
        [string]$Action
    )

    if ($Action -eq 'apply') {
        $applyStatus = [string](Get-PropertyValue (Get-PropertyValue $Capability 'apply' $null) 'status' '')
        return (Test-RooApplyStatusCanDispatch $applyStatus)
    }
    if ($Action -eq 'restore') {
        $restoreStatus = [string](Get-PropertyValue (Get-PropertyValue $Capability 'restore' $null) 'status' '')
        return (Test-RooRestoreStatusCanDispatch $restoreStatus)
    }
    return $false
}

function Get-RooWouldChange {
    param(
        [object]$Capability,
        [object]$Availability
    )

    $available = [bool](Get-PropertyValue $Availability 'available' $false)
    $applyStatus = [string](Get-PropertyValue (Get-PropertyValue $Capability 'apply' $null) 'status' '')
    return ($available -and (Test-RooApplyStatusCanDispatch $applyStatus))
}

function Test-RooRestoreRouteAvailable {
    param(
        [object]$Capability,
        [object]$RouteInfo
    )

    if ($null -eq $RouteInfo -or -not [bool]$RouteInfo.routePresent) { return $false }
    $restoreStatus = [string](Get-PropertyValue (Get-PropertyValue $Capability 'restore' $null) 'status' '')
    if (-not (Test-RooRestoreStatusCanDispatch $restoreStatus)) { return $false }
    $restoreSection = Get-RooRouteSection $RouteInfo.route 'restore'
    if ($null -eq $restoreSection -or (Test-RooStatusOnlySection $restoreSection)) { return $false }
    return (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $restoreSection 'script' '')))
}

function Get-RooRouteMissingStep {
    param([string]$Family)
    return "Add a route for this capability in backend/capabilities/routing/$Family.routes.json"
}

function Get-RooUnavailableStep {
    param(
        [string]$Reason,
        [object]$Capability
    )

    if ($Reason -match '^requires-admin-token') {
        return 'Requires an administrators-group token: launch via an elevated helper before DISM feature queries can run'
    }
    if ($Reason -eq 'helper-packaging-pending') {
        return 'Run Build-StandbyMemoryHelper.ps1, then package the helper with an elevated launch manifest'
    }
    if ($Reason -eq 'hardware-not-present') {
        return 'Run this capability on matching hardware before routing its script.'
    }
    if ($Reason -eq 'tool-not-present') {
        return 'Install the required tool at the detected path before routing this capability.'
    }
    if ($Reason -eq 'not-safely-executable-yet') {
        $apply = Get-PropertyValue $Capability 'apply' $null
        $notes = Convert-ToCleanString (Get-PropertyValue $apply 'notes' $null)
        if ($notes) { return $notes }
    }
    return "Resolve availability requirement '$Reason' before routing this capability."
}

function Get-RooApprovalStep {
    param(
        [object]$RouteInfo,
        [string]$Family,
        [string]$Action
    )

    $section = if ($RouteInfo -and $RouteInfo.routePresent) { Get-RooRouteSection $RouteInfo.route $Action } else { $null }
    $script = Convert-ToCleanString (Get-PropertyValue $section 'script' $null)
    if ($script) {
        return "Re-run with -ConfirmApply to route to $([System.IO.Path]::GetFileName($script)) (its own confirmation gates still apply)"
    }
    return "Re-run with -ConfirmApply after adding a route for this capability in backend/capabilities/routing/$Family.routes.json"
}

function Get-RooStatusOnlyStep {
    param(
        [object]$Section,
        [string]$Family
    )

    $step = Convert-ToCleanString (Get-PropertyValue $Section 'nextRequiredStep' $null)
    if ($step) { return $step }
    $reason = Convert-ToCleanString (Get-PropertyValue $Section 'reason' $null)
    if ($reason) { return "Add an executable route for this capability after resolving $reason in backend/capabilities/routing/$Family.routes.json" }
    return (Get-RooRouteMissingStep $Family)
}

function Get-RooPathValue {
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

function ConvertTo-RooBoolean {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([double]$Value -gt 0)
    }
    $text = Convert-ToCleanString $Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -match '^(true|yes)$') { return $true }
    if ($text -match '^(false|no)$') { return $false }
    $number = 0.0
    if ([double]::TryParse($text, [ref]$number)) { return ($number -gt 0) }
    return $true
}

function Join-RooCommandLine {
    param([string[]]$Arguments)

    return (@($Arguments | ForEach-Object {
        $arg = [string]$_
        if ($arg.Length -eq 0) { return '""' }
        if ($arg -match '[\s"]') {
            return '"' + ($arg -replace '"', '\"') + '"'
        }
        return $arg
    }) -join ' ')
}

function Test-RooPathUnderTemp {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    return $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RooRouteArgumentList {
    param(
        [object]$Section,
        [bool]$FixtureRootProvided,
        [string]$FixtureRoot,
        [bool]$TargetProcessIdProvided,
        [int]$TargetProcessId
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @((Get-PropertyValue $Section 'args' @()))) {
        $arguments.Add([string]$arg) | Out-Null
    }

    $fixtureRootParam = Convert-ToCleanString (Get-PropertyValue $Section 'fixtureRootParam' $null)
    if ($FixtureRootProvided -and $fixtureRootParam) {
        $arguments.Add($fixtureRootParam) | Out-Null
        $arguments.Add($FixtureRoot) | Out-Null
    }

    $disposableProbeParam = Convert-ToCleanString (Get-PropertyValue $Section 'disposableProbeParam' $null)
    if ($TargetProcessIdProvided -and $disposableProbeParam) {
        $arguments.Add($disposableProbeParam) | Out-Null
        $arguments.Add([string]$TargetProcessId) | Out-Null
    }

    return @($arguments.ToArray())
}

function Invoke-RooRoutedScript {
    param(
        [string]$RepoRoot,
        [string]$ScriptRelativePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds
    )

    $scriptPath = Resolve-RooRepoPath $RepoRoot $ScriptRelativePath
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Routed script missing: $ScriptRelativePath"
    }
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = 60 }

    $processArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + @($Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $psi.Arguments = Join-RooCommandLine $processArgs
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try { $process.Kill() } catch { }
        try { $process.WaitForExit() } catch { }
        return [pscustomobject]@{
            timedOut = $true
            exitCode = $null
            stdout = $stdoutTask.Result
            stderr = $stderrTask.Result
            evidence = $null
            parseError = $null
        }
    }

    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $evidence = $null
    $parseError = $null
    $trimmed = if ($null -eq $stdout) { '' } else { $stdout.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        try {
            $evidence = $trimmed | ConvertFrom-Json
        } catch {
            $parseError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        timedOut = $false
        exitCode = [int]$process.ExitCode
        stdout = $stdout
        stderr = $stderr
        evidence = $evidence
        parseError = $parseError
    }
}

function Write-RooRouterOutput {
    param(
        [object]$Envelope,
        [string]$OutputPath
    )

    $Envelope.completedAtUtc = Get-RooUtcStamp
    $json = $Envelope | ConvertTo-Json -Depth 64
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
        $parent = Split-Path -Parent $resolvedOutputPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "OutputPath parent does not exist: $parent"
        }
        Set-Content -LiteralPath $resolvedOutputPath -Value $json -Encoding UTF8
    }
    $json
}

$startedAtUtc = Get-RooUtcStamp
$correlationId = [guid]::NewGuid().ToString('N')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exitCode = 0
$envelope = $null

try {
    $capabilities = @(Read-RooCapabilityFragments $repoRoot)
    $capability = Get-RooCapabilityById $capabilities $CapabilityId

    if ($null -eq $capability) {
        $envelope = New-RooCapabilityEnvelope $CapabilityId $Action $correlationId $startedAtUtc
        $envelope.status = 'failed'
        Add-RooRouterError $envelope (New-RooRouterError 'UNKNOWN_CAPABILITY' "Unknown capabilityId: $CapabilityId" $true)
        $exitCode = 1
    } else {
        $family = [string](Get-PropertyValue $capability 'family' '')
        $resolvedUtilitiesRoot = Resolve-RooUtilitiesRoot $UtilitiesRoot
        $gpuInventory = Get-RooGpuInventory
        $availability = Resolve-RooCapabilityAvailability $capability $repoRoot $resolvedUtilitiesRoot $gpuInventory
        $routeInfo = Read-RooRouteManifest $repoRoot $family $CapabilityId
        $envelope = New-RooCapabilityEnvelope $CapabilityId $Action $correlationId $startedAtUtc $capability $availability
        $envelope.restoreAvailable = Test-RooRestoreRouteAvailable $capability $routeInfo
        $envelope.evidence = New-RooRoutingEvidence $capability $availability $routeInfo $Action

        if ($Action -eq 'status') {
            $envelope.status = 'completed'
        } elseif ($Action -eq 'explain') {
            $envelope.status = 'completed'
            $envelope.wouldChange = Get-RooWouldChange $capability $availability
            if (-not [bool](Get-PropertyValue $availability 'available' $false)) {
                $envelope.nextRequiredStep = Get-RooUnavailableStep ([string](Get-PropertyValue $availability 'unavailableReason' '')) $capability
            } elseif (-not [bool]$routeInfo.manifestExists -or -not [bool]$routeInfo.routePresent) {
                $envelope.nextRequiredStep = Get-RooRouteMissingStep $family
            }
        } else {
            if (-not [bool]$routeInfo.manifestExists) {
                $envelope.status = 'not-executable'
                $envelope.nextRequiredStep = Get-RooRouteMissingStep $family
            } elseif (-not [bool](Get-PropertyValue $availability 'available' $false)) {
                $envelope.status = 'unavailable'
                $envelope.nextRequiredStep = Get-RooUnavailableStep ([string](Get-PropertyValue $availability 'unavailableReason' '')) $capability
            } elseif ((Test-RooActionCouldMutate $capability $Action) -and -not $ConfirmApply.IsPresent) {
                $envelope.status = 'approval-required'
                $envelope.nextRequiredStep = Get-RooApprovalStep $routeInfo $family $Action
            } elseif (-not [bool]$routeInfo.routePresent) {
                $envelope.status = 'not-executable'
                $envelope.nextRequiredStep = Get-RooRouteMissingStep $family
            } else {
                $section = Get-RooRouteSection $routeInfo.route $Action
                if ($null -eq $section) {
                    $envelope.status = 'not-executable'
                    $envelope.nextRequiredStep = Get-RooRouteMissingStep $family
                } elseif (Test-RooStatusOnlySection $section) {
                    $envelope.status = 'not-executable'
                    $envelope.nextRequiredStep = Get-RooStatusOnlyStep $section $family
                    $envelope.evidence | Add-Member -NotePropertyName statusOnlyReason -NotePropertyValue (Get-PropertyValue $section 'reason' $null) -Force
                } else {
                    $registryActionStatus = ''
                    if ($Action -eq 'preview') {
                        $registryActionStatus = [string](Get-PropertyValue (Get-PropertyValue $capability 'preview' $null) 'status' '')
                        if ($registryActionStatus -ne 'implemented') {
                            $envelope.status = 'not-executable'
                            $envelope.nextRequiredStep = Get-RooRouteMissingStep $family
                        }
                    } elseif ($Action -eq 'apply') {
                        $registryActionStatus = [string](Get-PropertyValue (Get-PropertyValue $capability 'apply' $null) 'status' '')
                        if (-not (Test-RooApplyStatusCanDispatch $registryActionStatus)) {
                            $envelope.status = 'not-executable'
                            $envelope.nextRequiredStep = Get-RooStatusOnlyStep $section $family
                        }
                    } elseif ($Action -eq 'restore') {
                        $registryActionStatus = [string](Get-PropertyValue (Get-PropertyValue $capability 'restore' $null) 'status' '')
                        if (-not (Test-RooRestoreStatusCanDispatch $registryActionStatus)) {
                            $envelope.status = 'not-executable'
                            $envelope.nextRequiredStep = Get-RooStatusOnlyStep $section $family
                        }
                    }

                    if ($envelope.status -eq 'completed') {
                        $scriptRelativePath = [string](Get-PropertyValue $section 'script' '')
                        $scriptPath = Resolve-RooRepoPath $repoRoot $scriptRelativePath
                        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
                            $envelope.status = 'failed'
                            Add-RooRouterError $envelope (New-RooRouterError 'ROUTED_SCRIPT_MISSING' "Routed script missing: $scriptRelativePath" $true)
                            $exitCode = 1
                        } else {
                            if (($Action -in @('apply', 'restore')) -and (Test-RooActionCouldMutate $capability $Action)) {
                                $envelope.approvalSatisfied = $ConfirmApply.IsPresent
                                $envelope.dryRun = $false
                                $envelope.wouldChange = $true
                            }

                            $fixtureProvided = $PSBoundParameters.ContainsKey('FixtureRoot') -and -not [string]::IsNullOrWhiteSpace($FixtureRoot)
                            if ($fixtureProvided -and ($Action -in @('apply', 'restore')) -and -not (Test-RooPathUnderTemp $FixtureRoot)) {
                                $envelope.status = 'not-executable'
                                $envelope.dryRun = $true
                                $envelope.approvalSatisfied = $false
                                $envelope.nextRequiredStep = 'Re-run with -FixtureRoot under the OS temp directory before executing this fixture route.'
                            } else {
                                $targetProvided = $PSBoundParameters.ContainsKey('TargetProcessId')
                                $routeArgs = Get-RooRouteArgumentList $section $fixtureProvided $FixtureRoot $targetProvided $TargetProcessId
                                $timeoutSeconds = [int](Get-PropertyValue $section 'timeoutSeconds' 60)
                                $dispatch = Invoke-RooRoutedScript $repoRoot $scriptRelativePath $routeArgs $timeoutSeconds
                                $envelope.routedScript = ConvertTo-RooRepoRelativePath $repoRoot $scriptRelativePath

                                if ([bool]$dispatch.timedOut) {
                                    $envelope.status = 'failed'
                                    Add-RooRouterError $envelope (New-RooRouterError 'ROUTED_SCRIPT_TIMEOUT' "Timed out after $timeoutSeconds seconds: $scriptRelativePath" $true)
                                    $exitCode = 1
                                } elseif ([int]$dispatch.exitCode -ne 0) {
                                    $envelope.status = 'failed'
                                    $message = Convert-ToCleanString $dispatch.stderr
                                    if (-not $message) { $message = "Routed script exited with code $($dispatch.exitCode): $scriptRelativePath" }
                                    Add-RooRouterError $envelope (New-RooRouterError 'ROUTED_SCRIPT_FAILED' $message $true)
                                    $exitCode = 1
                                } elseif ($null -ne $dispatch.parseError -or $null -eq $dispatch.evidence) {
                                    $envelope.status = 'failed'
                                    $parseMessage = Convert-ToCleanString $dispatch.parseError
                                    if (-not $parseMessage) { $parseMessage = "Routed script did not emit JSON: $scriptRelativePath" }
                                    Add-RooRouterError $envelope (New-RooRouterError 'ROUTED_SCRIPT_OUTPUT_INVALID' $parseMessage $true)
                                    $exitCode = 1
                                } else {
                                    $envelope.evidence = $dispatch.evidence
                                    if ($Action -eq 'preview') {
                                        $envelope.wouldChange = Get-RooWouldChange $capability $availability
                                    }
                                    if ($Action -in @('apply', 'restore')) {
                                        $changedPath = Convert-ToCleanString (Get-PropertyValue $section 'changedEvidencePath' $null)
                                        if ($changedPath) {
                                            $envelope.changed = ConvertTo-RooBoolean (Get-RooPathValue $dispatch.evidence $changedPath)
                                        }
                                        $restorablePath = Convert-ToCleanString (Get-PropertyValue $section 'restorableEvidencePath' $null)
                                        if ($restorablePath) {
                                            $envelope.restoreAvailable = ConvertTo-RooBoolean (Get-RooPathValue $dispatch.evidence $restorablePath)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
} catch {
    if ($null -eq $envelope) {
        $envelope = New-RooCapabilityEnvelope $CapabilityId $Action $correlationId $startedAtUtc
    }
    $envelope.status = 'failed'
    Add-RooRouterError $envelope (New-RooRouterError 'CAPABILITY_ROUTER_FAILED' $_.Exception.Message $true)
    $exitCode = 1
}

Write-RooRouterOutput $envelope $OutputPath
exit $exitCode
