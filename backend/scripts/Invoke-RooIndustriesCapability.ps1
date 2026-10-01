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
    [string]$RequestPath = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'CapabilityRouter.Common.ps1')

function New-RooIndustriesRouterError {
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

function Add-RooIndustriesRouterError {
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

function Resolve-RooIndustriesRepoPath {
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

function ConvertTo-RooIndustriesRepoRelativePath {
    param(
        [string]$RepoRoot,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $resolved = Resolve-RooIndustriesRepoPath $RepoRoot $Path
    $repoPrefix = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') + '\'
    return $resolved.Substring($repoPrefix.Length).Replace('\', '/')
}

function Read-RooIndustriesCapabilityFragments {
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

function Get-RooIndustriesCapabilityById {
    param(
        [object[]]$Capabilities,
        [string]$RequestedCapabilityId
    )

    $matches = @($Capabilities | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq $RequestedCapabilityId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-RooIndustriesRouteSection {
    param(
        [object]$Route,
        [string]$SectionName
    )

    if ($null -eq $Route) { return $null }
    $property = $Route.PSObject.Properties[$SectionName]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-RooIndustriesStatusOnlySection {
    param([object]$Section)

    return ([bool](Get-PropertyValue $Section 'statusOnly' $false))
}

function Read-RooIndustriesRouteManifest {
    param(
        [string]$RepoRoot,
        [string]$Family,
        [string]$RequestedCapabilityId
    )

    $manifestRelativePath = "backend/capabilities/routing/$Family.routes.json"
    $manifestPath = Resolve-RooIndustriesRepoPath $RepoRoot $manifestRelativePath
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

function New-RooIndustriesRouteSectionSummary {
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

function New-RooIndustriesRoutingEvidence {
    param(
        [object]$Capability,
        [object]$Availability,
        [object]$RouteInfo,
        [string]$Action
    )

    $previewSection = if ($RouteInfo) { Get-RooIndustriesRouteSection $RouteInfo.route 'preview' } else { $null }
    $applySection = if ($RouteInfo) { Get-RooIndustriesRouteSection $RouteInfo.route 'apply' } else { $null }
    $restoreSection = if ($RouteInfo) { Get-RooIndustriesRouteSection $RouteInfo.route 'restore' } else { $null }
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
            preview = New-RooIndustriesRouteSectionSummary $previewSection
            apply = New-RooIndustriesRouteSectionSummary $applySection
            restore = New-RooIndustriesRouteSectionSummary $restoreSection
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

function New-RooIndustriesCapabilityEnvelope {
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

function Test-RooIndustriesApplyStatusCanDispatch {
    param([string]$ApplyStatus)
    return ($ApplyStatus -in @('live', 'fixture-proven', 'allowlist-shim'))
}

function Test-RooIndustriesRestoreStatusCanDispatch {
    param([string]$RestoreStatus)
    return ($RestoreStatus -in @('live', 'fixture-proven'))
}

function Test-RooIndustriesActionCouldMutate {
    param(
        [object]$Capability,
        [string]$Action
    )

    if ($Action -eq 'apply') {
        $applyStatus = [string](Get-PropertyValue (Get-PropertyValue $Capability 'apply' $null) 'status' '')
        return (Test-RooIndustriesApplyStatusCanDispatch $applyStatus)
    }
    if ($Action -eq 'restore') {
        $restoreStatus = [string](Get-PropertyValue (Get-PropertyValue $Capability 'restore' $null) 'status' '')
        return (Test-RooIndustriesRestoreStatusCanDispatch $restoreStatus)
    }
    return $false
}

function Get-RooIndustriesWouldChange {
    param(
        [object]$Capability,
        [object]$Availability
    )

    $available = [bool](Get-PropertyValue $Availability 'available' $false)
    $applyStatus = [string](Get-PropertyValue (Get-PropertyValue $Capability 'apply' $null) 'status' '')
    return ($available -and (Test-RooIndustriesApplyStatusCanDispatch $applyStatus))
}

function Test-RooIndustriesRestoreRouteAvailable {
    param(
        [object]$Capability,
        [object]$RouteInfo
    )

    if ($null -eq $RouteInfo -or -not [bool]$RouteInfo.routePresent) { return $false }
    $restoreStatus = [string](Get-PropertyValue (Get-PropertyValue $Capability 'restore' $null) 'status' '')
    if (-not (Test-RooIndustriesRestoreStatusCanDispatch $restoreStatus)) { return $false }
    $restoreSection = Get-RooIndustriesRouteSection $RouteInfo.route 'restore'
    if ($null -eq $restoreSection -or (Test-RooIndustriesStatusOnlySection $restoreSection)) { return $false }
    return (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $restoreSection 'script' '')))
}

function Get-RooIndustriesRouteMissingStep {
    param([string]$Family)
    return "Add a route for this capability in backend/capabilities/routing/$Family.routes.json"
}

function Get-RooIndustriesUnavailableStep {
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

function Get-RooIndustriesApprovalStep {
    param(
        [object]$RouteInfo,
        [string]$Family,
        [string]$Action
    )

    $section = if ($RouteInfo -and $RouteInfo.routePresent) { Get-RooIndustriesRouteSection $RouteInfo.route $Action } else { $null }
    $script = Convert-ToCleanString (Get-PropertyValue $section 'script' $null)
    if ($script) {
        return "Re-run with -ConfirmApply to route to $([System.IO.Path]::GetFileName($script)) (its own confirmation gates still apply)"
    }
    return "Re-run with -ConfirmApply after adding a route for this capability in backend/capabilities/routing/$Family.routes.json"
}

function Get-RooIndustriesStatusOnlyStep {
    param(
        [object]$Section,
        [string]$Family
    )

    $step = Convert-ToCleanString (Get-PropertyValue $Section 'nextRequiredStep' $null)
    if ($step) { return $step }
    $reason = Convert-ToCleanString (Get-PropertyValue $Section 'reason' $null)
    if ($reason) { return "Add an executable route for this capability after resolving $reason in backend/capabilities/routing/$Family.routes.json" }
    return (Get-RooIndustriesRouteMissingStep $Family)
}

function Get-RooIndustriesPathValue {
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

function ConvertTo-RooIndustriesBoolean {
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

function Join-RooIndustriesCommandLine {
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

function Test-RooIndustriesPathUnderTemp {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    return $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RooIndustriesRouteArgumentList {
    param(
        [object]$Section,
        [bool]$FixtureRootProvided,
        [string]$FixtureRoot,
        [bool]$TargetProcessIdProvided,
        [int]$TargetProcessId,
        [string]$RequestPath
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @((Get-PropertyValue $Section 'args' @()))) {
        $fixtureBase = $env:ROO_INDUSTRIES_CLEANUP_FIXTURE_ROOT
        if ([string]::IsNullOrWhiteSpace($fixtureBase)) { $fixtureBase = Join-Path ([IO.Path]::GetTempPath()) 'roo-industries-capability-router-cleanup-fixture' }
        if (-not (Test-RooIndustriesPathUnderTemp $fixtureBase)) { throw 'Cleanup fixture storage must stay under the current user temp directory.' }
        $arguments.Add(([string]$arg).Replace('{cleanupFixtureRoot}', $fixtureBase)) | Out-Null
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

    $requestPathParam = Convert-ToCleanString (Get-PropertyValue $Section 'requestPathParam' $null)
    if ($RequestPath -and $requestPathParam) {
        $arguments.Add($requestPathParam) | Out-Null
        $arguments.Add([IO.Path]::GetFullPath($RequestPath)) | Out-Null
    }

    return @($arguments.ToArray())
}

function Invoke-RooIndustriesRoutedScript {
    param(
        [string]$RepoRoot,
        [string]$ScriptRelativePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds
    )

    $scriptPath = Resolve-RooIndustriesRepoPath $RepoRoot $ScriptRelativePath
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Routed script missing: $ScriptRelativePath"
    }
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = 60 }

    $processArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + @($Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = Join-RooIndustriesCommandLine $processArgs
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

function Write-RooIndustriesRouterOutput {
    param(
        [object]$Envelope,
        [string]$OutputPath
    )

    $Envelope.completedAtUtc = Get-RooIndustriesUtcStamp
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

$startedAtUtc = Get-RooIndustriesUtcStamp
$correlationId = [guid]::NewGuid().ToString('N')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exitCode = 0
$envelope = $null

try {
    $capabilities = @(Read-RooIndustriesCapabilityFragments $repoRoot)
    $capability = Get-RooIndustriesCapabilityById $capabilities $CapabilityId

    if ($null -eq $capability) {
        $envelope = New-RooIndustriesCapabilityEnvelope $CapabilityId $Action $correlationId $startedAtUtc
        $envelope.status = 'failed'
        Add-RooIndustriesRouterError $envelope (New-RooIndustriesRouterError 'UNKNOWN_CAPABILITY' "Unknown capabilityId: $CapabilityId" $true)
        $exitCode = 1
    } else {
        $family = [string](Get-PropertyValue $capability 'family' '')
        $resolvedUtilitiesRoot = Resolve-RooIndustriesUtilitiesRoot $UtilitiesRoot
        $gpuInventory = Get-RooIndustriesGpuInventory
        $availability = Resolve-RooIndustriesCapabilityAvailability $capability $repoRoot $resolvedUtilitiesRoot $gpuInventory
        $routeInfo = Read-RooIndustriesRouteManifest $repoRoot $family $CapabilityId
        $envelope = New-RooIndustriesCapabilityEnvelope $CapabilityId $Action $correlationId $startedAtUtc $capability $availability
        $envelope.restoreAvailable = Test-RooIndustriesRestoreRouteAvailable $capability $routeInfo
        $envelope.evidence = New-RooIndustriesRoutingEvidence $capability $availability $routeInfo $Action

        if ($Action -eq 'status') {
            $envelope.status = 'completed'
        } elseif ($Action -eq 'explain') {
            $envelope.status = 'completed'
            $envelope.wouldChange = Get-RooIndustriesWouldChange $capability $availability
            if (-not [bool](Get-PropertyValue $availability 'available' $false)) {
                $envelope.nextRequiredStep = Get-RooIndustriesUnavailableStep ([string](Get-PropertyValue $availability 'unavailableReason' '')) $capability
            } elseif (-not [bool]$routeInfo.manifestExists -or -not [bool]$routeInfo.routePresent) {
                $envelope.nextRequiredStep = Get-RooIndustriesRouteMissingStep $family
            }
        } else {
            if (-not [bool]$routeInfo.manifestExists) {
                $envelope.status = 'not-executable'
                $envelope.nextRequiredStep = Get-RooIndustriesRouteMissingStep $family
            } elseif (-not [bool](Get-PropertyValue $availability 'available' $false)) {
                $envelope.status = 'unavailable'
                $envelope.nextRequiredStep = Get-RooIndustriesUnavailableStep ([string](Get-PropertyValue $availability 'unavailableReason' '')) $capability
            } elseif ((Test-RooIndustriesActionCouldMutate $capability $Action) -and -not $ConfirmApply.IsPresent) {
                $envelope.status = 'approval-required'
                $envelope.nextRequiredStep = Get-RooIndustriesApprovalStep $routeInfo $family $Action
            } elseif (-not [bool]$routeInfo.routePresent) {
                $envelope.status = 'not-executable'
                $envelope.nextRequiredStep = Get-RooIndustriesRouteMissingStep $family
            } else {
                $section = Get-RooIndustriesRouteSection $routeInfo.route $Action
                if ($null -eq $section) {
                    $envelope.status = 'not-executable'
                    $envelope.nextRequiredStep = Get-RooIndustriesRouteMissingStep $family
                } elseif (Test-RooIndustriesStatusOnlySection $section) {
                    $envelope.status = 'not-executable'
                    $envelope.nextRequiredStep = Get-RooIndustriesStatusOnlyStep $section $family
                    $envelope.evidence | Add-Member -NotePropertyName statusOnlyReason -NotePropertyValue (Get-PropertyValue $section 'reason' $null) -Force
                } else {
                    $registryActionStatus = ''
                    if ($Action -eq 'preview') {
                        $registryActionStatus = [string](Get-PropertyValue (Get-PropertyValue $capability 'preview' $null) 'status' '')
                        if ($registryActionStatus -ne 'implemented') {
                            $envelope.status = 'not-executable'
                            $envelope.nextRequiredStep = Get-RooIndustriesRouteMissingStep $family
                        }
                    } elseif ($Action -eq 'apply') {
                        $registryActionStatus = [string](Get-PropertyValue (Get-PropertyValue $capability 'apply' $null) 'status' '')
                        if (-not (Test-RooIndustriesApplyStatusCanDispatch $registryActionStatus)) {
                            $envelope.status = 'not-executable'
                            $envelope.nextRequiredStep = Get-RooIndustriesStatusOnlyStep $section $family
                        }
                    } elseif ($Action -eq 'restore') {
                        $registryActionStatus = [string](Get-PropertyValue (Get-PropertyValue $capability 'restore' $null) 'status' '')
                        if (-not (Test-RooIndustriesRestoreStatusCanDispatch $registryActionStatus)) {
                            $envelope.status = 'not-executable'
                            $envelope.nextRequiredStep = Get-RooIndustriesStatusOnlyStep $section $family
                        }
                    }

                    if ($envelope.status -eq 'completed') {
                        $scriptRelativePath = [string](Get-PropertyValue $section 'script' '')
                        $scriptPath = Resolve-RooIndustriesRepoPath $repoRoot $scriptRelativePath
                        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
                            $envelope.status = 'failed'
                            Add-RooIndustriesRouterError $envelope (New-RooIndustriesRouterError 'ROUTED_SCRIPT_MISSING' "Routed script missing: $scriptRelativePath" $true)
                            $exitCode = 1
                        } else {
                            if (($Action -in @('apply', 'restore')) -and (Test-RooIndustriesActionCouldMutate $capability $Action)) {
                                $envelope.approvalSatisfied = $ConfirmApply.IsPresent
                                $envelope.dryRun = $false
                                $envelope.wouldChange = $true
                            }

                            $fixtureProvided = $PSBoundParameters.ContainsKey('FixtureRoot') -and -not [string]::IsNullOrWhiteSpace($FixtureRoot)
                            if ($fixtureProvided -and ($Action -in @('apply', 'restore')) -and -not (Test-RooIndustriesPathUnderTemp $FixtureRoot)) {
                                $envelope.status = 'not-executable'
                                $envelope.dryRun = $true
                                $envelope.approvalSatisfied = $false
                                $envelope.nextRequiredStep = 'Re-run with -FixtureRoot under the OS temp directory before executing this fixture route.'
                            } else {
                                $targetProvided = $PSBoundParameters.ContainsKey('TargetProcessId')
                                $routeArgs = Get-RooIndustriesRouteArgumentList $section $fixtureProvided $FixtureRoot $targetProvided $TargetProcessId $RequestPath
                                $timeoutSeconds = [int](Get-PropertyValue $section 'timeoutSeconds' 60)
                                $dispatch = Invoke-RooIndustriesRoutedScript $repoRoot $scriptRelativePath $routeArgs $timeoutSeconds
                                $envelope.routedScript = ConvertTo-RooIndustriesRepoRelativePath $repoRoot $scriptRelativePath
                                if ($null -ne $dispatch.evidence) {
                                    $envelope.evidence = $dispatch.evidence
                                    if ($scriptRelativePath -eq 'backend/scripts/Invoke-OptimizerRequest.ps1') {
                                        $envelope.dryRun = [bool](Get-PropertyValue $dispatch.evidence 'dryRun' $true)
                                    }
                                }

                                if ([bool]$dispatch.timedOut) {
                                    $envelope.status = 'failed'
                                    Add-RooIndustriesRouterError $envelope (New-RooIndustriesRouterError 'ROUTED_SCRIPT_TIMEOUT' "Timed out after $timeoutSeconds seconds: $scriptRelativePath" $true)
                                    $exitCode = 1
                                } elseif ([int]$dispatch.exitCode -ne 0) {
                                    $envelope.status = 'failed'
                                    $message = Convert-ToCleanString $dispatch.stderr
                                    if (-not $message) { $message = "Routed script exited with code $($dispatch.exitCode): $scriptRelativePath" }
                                    Add-RooIndustriesRouterError $envelope (New-RooIndustriesRouterError 'ROUTED_SCRIPT_FAILED' $message $true)
                                    $exitCode = 1
                                } elseif ($null -ne $dispatch.parseError -or $null -eq $dispatch.evidence) {
                                    $envelope.status = 'failed'
                                    $parseMessage = Convert-ToCleanString $dispatch.parseError
                                    if (-not $parseMessage) { $parseMessage = "Routed script did not emit JSON: $scriptRelativePath" }
                                    Add-RooIndustriesRouterError $envelope (New-RooIndustriesRouterError 'ROUTED_SCRIPT_OUTPUT_INVALID' $parseMessage $true)
                                    $exitCode = 1
                                } else {
                                    $envelope.evidence = $dispatch.evidence
                                    if ($Action -eq 'preview') {
                                        $envelope.wouldChange = Get-RooIndustriesWouldChange $capability $availability
                                    }
                                    if ($Action -in @('apply', 'restore')) {
                                        $changedPath = Convert-ToCleanString (Get-PropertyValue $section 'changedEvidencePath' $null)
                                        if ($changedPath) {
                                            $envelope.changed = ConvertTo-RooIndustriesBoolean (Get-RooIndustriesPathValue $dispatch.evidence $changedPath)
                                        }
                                        $restorablePath = Convert-ToCleanString (Get-PropertyValue $section 'restorableEvidencePath' $null)
                                        if ($restorablePath) {
                                            $envelope.restoreAvailable = ConvertTo-RooIndustriesBoolean (Get-RooIndustriesPathValue $dispatch.evidence $restorablePath)
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
        $envelope = New-RooIndustriesCapabilityEnvelope $CapabilityId $Action $correlationId $startedAtUtc
    }
    $envelope.status = 'failed'
    Add-RooIndustriesRouterError $envelope (New-RooIndustriesRouterError 'CAPABILITY_ROUTER_FAILED' $_.Exception.Message $true)
    $exitCode = 1
}

Write-RooIndustriesRouterOutput $envelope $OutputPath
exit $exitCode
