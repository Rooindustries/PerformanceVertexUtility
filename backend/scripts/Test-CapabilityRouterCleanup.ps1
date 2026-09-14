Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$previousFixtureRoot = $env:ROO_CLEANUP_FIXTURE_ROOT
$script:FixtureBase = Join-Path ([IO.Path]::GetTempPath()) ('roo-capability-router-cleanup-' + [guid]::NewGuid().ToString('N'))
$env:ROO_CLEANUP_FIXTURE_ROOT = $script:FixtureBase

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

function Get-RouteSection {
    param(
        [object]$Route,
        [string]$SectionName
    )

    if ($null -eq $Route) { return $null }
    return Get-PropertyValue $Route $SectionName $null
}

function Get-RouteArgValue {
    param(
        [object]$Section,
        [string]$Name
    )

    $args = @((Get-PropertyValue $Section 'args' @()))
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ([string]$args[$i] -eq $Name -and ($i + 1) -lt $args.Count) {
            return ([string]$args[$i + 1]).Replace('{cleanupFixtureRoot}', $script:FixtureBase)
        }
    }
    return ''
}

function Test-PathInsideRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rootPrefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    return ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-PathUnderTemp {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Path).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-TempTree {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-PathUnderTemp $Path)) {
        Add-Failure "Refused to remove non-temp path: $Path"
        return
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
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

function Write-OfficialPreviewFixture {
    param(
        [string]$Path,
        [string]$Executable,
        [object[]]$Arguments,
        [string]$AppId = 'fixture:router-cleanup'
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    ([pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = '2026-07-03T00:00:00Z'
        dryRun = $true
        status = 'preview'
        commands = @(
            [pscustomobject]@{
                appId = $AppId
                displayName = 'Router Cleanup Harmless Fixture'
                commandType = 'harmless-shim'
                rawCommand = 'router cleanup harmless shim'
                executable = $Executable
                arguments = @($Arguments)
                protected = $false
                blocked = $false
                executionAllowed = $false
            }
        )
        summary = [pscustomobject]@{
            requestedCount = 1
            commandPreviewCount = 1
            blockedCount = 0
            executionAllowedCount = 0
            willRunUninstallers = $false
        }
        warnings = @()
        errors = @()
        logs = @()
    } | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-CleanupManifestFixture {
    param(
        [string]$Path,
        [string]$FixtureRoot,
        [string]$FolderTarget,
        [string]$FileTarget
    )

    $backupRoot = Join-Path $FixtureRoot '_roo-cleanup-backup'
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    ([pscustomobject]@{
        manifestId = 'router-cleanup-fixture-manifest'
        productName = 'Roo Industries Optimization Suite'
        schemaVersion = 1
        appId = 'fixture:router-cleanup'
        displayName = 'Router Cleanup Fixture'
        createdAtUtc = '2026-07-03T00:00:00Z'
        dryRun = $true
        executionMode = 'preview-only'
        sourceScanId = 'router-cleanup-fixture-scan'
        items = @(
            [pscustomobject]@{
                itemId = 'folder:router-cache'
                type = 'folder'
                target = $FolderTarget
                matchedBy = @('fixture')
                confidence = 'high'
                risk = 'low'
                defaultSelected = $true
                protected = $false
                reason = 'Disposable router cleanup fixture folder.'
            },
            [pscustomobject]@{
                itemId = 'file:router-loose'
                type = 'file'
                target = $FileTarget
                matchedBy = @('fixture')
                confidence = 'high'
                risk = 'low'
                defaultSelected = $true
                protected = $false
                reason = 'Disposable router cleanup fixture file.'
            }
        )
        excludedItems = @()
        rollback = [pscustomobject]@{
            backupRoot = $backupRoot
            rollbackActionId = 'apps.rollbackCleanup'
            rollbackSupported = $true
            restorePoint = [pscustomobject]@{
                requiredBeforeFutureApply = $false
                created = $false
                previewOnly = $true
            }
            fileBackupRequirements = @()
            registryExportRequirements = @()
            serviceStateBackupRequirements = @()
            scheduledTaskBackupRequirements = @()
            startupEntryBackupRequirements = @()
            manifestExportRequired = $true
        }
        summary = [pscustomobject]@{
            itemCount = 2
            willDeleteOnApply = $false
            willEditRegistry = $false
            willEditServices = $false
            willEditScheduledTasks = $false
            dryRunWritesState = $false
        }
        warnings = @()
        errors = @()
    } | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-InitialRollbackManifest {
    param(
        [string]$Path,
        [string]$FixtureRoot
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    ([pscustomobject]@{
        manifestId = 'router-cleanup-preview-rollback'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        actionId = 'apps.rollbackCleanup'
        sourceManifestId = 'router-cleanup-fixture-manifest'
        fixtureRoot = $FixtureRoot
        backupRoot = $parent
        createdAtUtc = '2026-07-03T00:00:00Z'
        restoreSupported = $true
        realSystemRollback = $false
        fileBackups = @()
        deletedItems = @()
    } | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $Path -Encoding UTF8
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:RouterPath = Join-Path $repoRoot 'backend\scripts\Invoke-RooCapability.ps1'
$manifestPath = Join-Path $repoRoot 'backend\capabilities\routing\cleanup-uninstall.routes.json'
$capabilityPath = Join-Path $repoRoot 'backend\capabilities\cleanup-uninstall.json'
$statePath = Join-Path $repoRoot 'backend\state'
$tempBase = ''
$utilitiesRoot = ''
$outsideSentinel = ''

try {
    $stateBeforeCount = Get-StateEntryCount $repoRoot
    Add-Check (-not (Test-Path -LiteralPath $statePath)) 'backend/state is absent before cleanup router validation' 'backend/state exists before cleanup router validation'
    Add-Check ($stateBeforeCount -eq 0) 'backend/state has no entries before cleanup router validation' "backend/state has $stateBeforeCount item(s) before cleanup router validation"

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $capabilityFragment = Get-Content -LiteralPath $capabilityPath -Raw | ConvertFrom-Json
    Add-Check ([int](Get-PropertyValue $manifest 'schemaVersion' 0) -eq 1) 'Cleanup route manifest schemaVersion is 1' 'Cleanup route manifest schemaVersion mismatch'
    Add-Check ([string](Get-PropertyValue $manifest 'family' '') -eq 'cleanup-uninstall') 'Cleanup route manifest family is cleanup-uninstall' 'Cleanup route manifest family mismatch'

    $capabilityIds = @($capabilityFragment.capabilities | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })
    $routes = @($manifest.routes)
    $routeIds = @($routes | ForEach-Object { [string](Get-PropertyValue $_ 'capabilityId' '') })
    Add-Check ($capabilityIds.Count -eq 10) 'Cleanup registry contains 10 capabilities' "Cleanup registry capability count expected 10, got $($capabilityIds.Count)"
    Add-Check ($routes.Count -eq 10) 'Cleanup route manifest contains 10 routes' "Cleanup route count expected 10, got $($routes.Count)"
    Add-Check (@($routeIds | Select-Object -Unique).Count -eq $routeIds.Count) 'Cleanup route capabilityIds are unique' 'Cleanup route capabilityIds are not unique'

    foreach ($capabilityId in $capabilityIds) {
        $route = @($routes | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq $capabilityId })
        Add-Check ($route.Count -eq 1) "Route exists for $capabilityId" "Route count for $capabilityId expected 1, got $($route.Count)"
        if ($route.Count -ne 1) { continue }

        foreach ($sectionName in @('preview', 'apply', 'restore')) {
            $section = Get-RouteSection $route[0] $sectionName
            Add-Check ($null -ne $section) "$capabilityId has $sectionName section" "$capabilityId missing $sectionName section"
            if ($null -eq $section) { continue }

            if ([bool](Get-PropertyValue $section 'statusOnly' $false)) {
                Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $section 'reason' ''))) "$capabilityId $sectionName statusOnly reason is present" "$capabilityId $sectionName statusOnly reason missing"
                Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $section 'nextRequiredStep' ''))) "$capabilityId $sectionName statusOnly nextRequiredStep is present" "$capabilityId $sectionName statusOnly nextRequiredStep missing"
            } else {
                $scriptRelativePath = [string](Get-PropertyValue $section 'script' '')
                Add-Check (-not [string]::IsNullOrWhiteSpace($scriptRelativePath)) "$capabilityId $sectionName declares routed script" "$capabilityId $sectionName missing routed script"
                if (-not [string]::IsNullOrWhiteSpace($scriptRelativePath)) {
                    $scriptPath = Join-Path $repoRoot ($scriptRelativePath -replace '/', '\')
                    Add-Check (Test-Path -LiteralPath $scriptPath -PathType Leaf) "$capabilityId $sectionName routed script exists" "$capabilityId $sectionName routed script missing: $scriptRelativePath"
                }
            }
        }
    }

    $officialRoute = @($routes | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq 'cleanup-uninstall.official-uninstall' })[0]
    $officialApply = Get-RouteSection $officialRoute 'apply'
    $officialPreviewPath = [System.IO.Path]::GetFullPath((Get-RouteArgValue $officialApply '-OfficialPreviewPath'))
    $allowedExecutablePath = [System.IO.Path]::GetFullPath((Get-RouteArgValue $officialApply '-AllowedExecutablePath'))
    $runnerRoot = [System.IO.Path]::GetFullPath((Get-RouteArgValue $officialApply '-WorkingDirectory'))

    $cleanupRoute = @($routes | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq 'cleanup-uninstall.cleanup-deletion-plan' })[0]
    $cleanupApplySection = Get-RouteSection $cleanupRoute 'apply'
    $cleanupOfficialPath = [System.IO.Path]::GetFullPath((Get-RouteArgValue $cleanupApplySection '-OfficialPreviewPath'))
    $cleanupManifestPath = [System.IO.Path]::GetFullPath((Get-RouteArgValue $cleanupApplySection '-CleanupManifestPath'))
    $cleanupRoot = Split-Path -Parent $cleanupOfficialPath

    $rollbackRoute = @($routes | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq 'cleanup-uninstall.cleanup-rollback' })[0]
    $rollbackApplySection = Get-RouteSection $rollbackRoute 'apply'
    $rollbackManifestPath = [System.IO.Path]::GetFullPath((Get-RouteArgValue $rollbackApplySection '-RollbackManifestPath'))

    $tempBase = Split-Path -Parent $runnerRoot
    Add-Check (Test-PathUnderTemp $tempBase) 'Route fixture base is under the OS temp directory' "Route fixture base is not under temp: $tempBase"
    Add-Check ($cleanupRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) 'Cleanup fixture root shares the route temp base' 'Cleanup fixture root does not share the route temp base'
    Add-Check ($rollbackManifestPath.StartsWith($cleanupRoot, [System.StringComparison]::OrdinalIgnoreCase)) 'Rollback manifest path is inside cleanup fixture root' 'Rollback manifest path is not inside cleanup fixture root'
    Add-Check ((Get-PropertyValue $cleanupApplySection 'fixtureRootParam' '') -eq '-FixtureRoot') 'Cleanup apply declares fixtureRootParam -FixtureRoot' 'Cleanup apply fixtureRootParam mismatch'

    Remove-TempTree $tempBase
    New-Item -ItemType Directory -Path $runnerRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $cleanupRoot -Force | Out-Null

    $utilitiesRoot = Join-Path $tempBase 'utilities'
    New-Item -ItemType Directory -Path (Join-Path $utilitiesRoot 'Other') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $utilitiesRoot 'autoruns.exe') -Value 'router cleanup fake autoruns detector file' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $utilitiesRoot 'Other\DeviceCleanup.exe') -Value 'router cleanup fake device cleanup detector file' -Encoding UTF8

    $shimPath = Join-Path $runnerRoot 'harmless-shim.ps1'
    @'
param([string]$Marker)
[pscustomobject]@{
  marker = $Marker
  cwd = (Get-Location).Path
  harmless = $true
} | ConvertTo-Json -Compress
exit 0
'@ | Set-Content -LiteralPath $shimPath -Encoding UTF8
    Write-OfficialPreviewFixture -Path $officialPreviewPath -Executable $allowedExecutablePath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $shimPath, 'router-cleanup-harmless-shim')

    $folderTarget = Join-Path $cleanupRoot 'FakeAppCache'
    $folderFile = Join-Path $folderTarget 'cache.txt'
    $fileTarget = Join-Path $cleanupRoot 'loose-cache.txt'
    New-Item -ItemType Directory -Path $folderTarget -Force | Out-Null
    Set-Content -LiteralPath $folderFile -Value 'folder payload' -Encoding UTF8
    Set-Content -LiteralPath $fileTarget -Value 'file payload' -Encoding UTF8
    $outsideSentinel = Join-Path $tempBase 'outside-cleanup-sentinel.txt'
    Set-Content -LiteralPath $outsideSentinel -Value 'outside payload' -Encoding UTF8

    Write-OfficialPreviewFixture -Path $cleanupOfficialPath -Executable $allowedExecutablePath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $shimPath, 'unused-cleanup-command') -AppId 'fixture:router-cleanup'
    Write-CleanupManifestFixture -Path $cleanupManifestPath -FixtureRoot $cleanupRoot -FolderTarget $folderTarget -FileTarget $fileTarget
    Write-InitialRollbackManifest -Path $rollbackManifestPath -FixtureRoot $cleanupRoot

    foreach ($capabilityId in $capabilityIds) {
        foreach ($action in @('status', 'explain')) {
            $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', $action, '-UtilitiesRoot', $utilitiesRoot)
            $label = "$capabilityId $action"
            Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
            Test-CompleteEnvelope $result.json $label
            if ($null -eq $result.json) { continue }
            Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'completed') "$label status is completed" "$label status mismatch"
            Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
            Add-Check ([string](Get-PropertyValue $result.json 'family' '') -eq 'cleanup-uninstall') "$label family is cleanup-uninstall" "$label family mismatch"
        }
    }

    $previewScripts = [ordered]@{
        'cleanup-uninstall.installed-app-inventory' = 'backend/scripts/Get-InstalledAppInventory.ps1'
        'cleanup-uninstall.app-classification' = 'backend/scripts/Get-AppClassification.ps1'
        'cleanup-uninstall.uninstall-queue' = 'backend/scripts/Preview-UninstallQueue.ps1'
        'cleanup-uninstall.official-uninstall' = 'backend/scripts/Preview-OfficialUninstall.ps1'
        'cleanup-uninstall.leftover-scan' = 'backend/scripts/Preview-LeftoverScan.ps1'
        'cleanup-uninstall.cleanup-deletion-plan' = 'backend/scripts/New-CleanupDeletionManifest.ps1'
        'cleanup-uninstall.cleanup-rollback' = 'backend/scripts/Restore-UninstallCleanupExecution.ps1'
    }

    foreach ($capabilityId in $previewScripts.Keys) {
        $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', 'preview', '-UtilitiesRoot', $utilitiesRoot)
        $label = "$capabilityId preview"
        Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
        Test-CompleteEnvelope $result.json $label
        if ($null -eq $result.json) { continue }
        Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'completed') "$label status is completed" "$label status mismatch"
        Add-Check ([string](Get-PropertyValue $result.json 'routedScript' '') -eq $previewScripts[$capabilityId]) "$label routed expected script" "$label routedScript mismatch"
        $evidence = Get-PropertyValue $result.json 'evidence' $null
        Add-Check ($null -ne $evidence) "$label embeds real script evidence" "$label missing real script evidence"

        switch ($capabilityId) {
            'cleanup-uninstall.installed-app-inventory' {
                Add-Check ([int](Get-PropertyValue $evidence 'schemaVersion' 0) -eq 1) "$label inventory evidence schemaVersion is 1" "$label inventory evidence schemaVersion mismatch"
            }
            'cleanup-uninstall.app-classification' {
                $summary = Get-PropertyValue $evidence 'summary' $null
                Add-Check ([int](Get-PropertyValue $summary 'appCount' 0) -gt 0) "$label classified sample apps" "$label did not classify sample apps"
            }
            'cleanup-uninstall.uninstall-queue' {
                $summary = Get-PropertyValue $evidence 'summary' $null
                Add-Check ([bool](Get-PropertyValue $evidence 'dryRun' $false) -eq $true) "$label is dryRun" "$label is not dryRun"
                Add-Check ([bool](Get-PropertyValue $summary 'willRunUninstallers' $true) -eq $false) "$label will not run uninstallers" "$label reports uninstaller execution"
                Add-Check ([int](Get-PropertyValue $summary 'selectedCount' 0) -eq 1) "$label selects one safe sample app" "$label selected sample count mismatch"
                Add-Check ([int](Get-PropertyValue $summary 'blockedCount' -1) -eq 0) "$label has no blocked app for the single safe sample" "$label blocked sample count mismatch"
            }
            'cleanup-uninstall.official-uninstall' {
                $summary = Get-PropertyValue $evidence 'summary' $null
                Add-Check ([string](Get-PropertyValue $evidence 'actionId' '') -eq 'apps.previewOfficialUninstall') "$label evidence actionId matches" "$label evidence actionId mismatch"
                Add-Check ([bool](Get-PropertyValue $summary 'willRunUninstallers' $true) -eq $false) "$label will not run uninstallers" "$label reports uninstaller execution"
            }
            'cleanup-uninstall.leftover-scan' {
                $summary = Get-PropertyValue $evidence 'summary' $null
                Add-Check ([string](Get-PropertyValue $summary 'deletionMode' '') -eq 'preview-only') "$label deletionMode is preview-only" "$label deletionMode mismatch"
                Add-Check ([bool](Get-PropertyValue $summary 'willDeleteLeftovers' $true) -eq $false) "$label will not delete leftovers" "$label reports leftover deletion"
            }
            'cleanup-uninstall.cleanup-deletion-plan' {
                $summary = Get-PropertyValue $evidence 'summary' $null
                Add-Check ([bool](Get-PropertyValue $evidence 'dryRun' $false) -eq $true) "$label is dryRun" "$label is not dryRun"
                Add-Check ([bool](Get-PropertyValue $summary 'willDeleteOnApply' $true) -eq $false) "$label preview will not delete on apply" "$label preview reports delete on apply"
            }
            'cleanup-uninstall.cleanup-rollback' {
                Add-Check ([string](Get-PropertyValue $evidence 'actionId' '') -eq 'apps.restoreUninstallCleanupExecution') "$label evidence actionId matches" "$label evidence actionId mismatch"
                Add-Check ([string](Get-PropertyValue $evidence 'status' '') -eq 'preview') "$label restore preview status is preview" "$label restore preview status mismatch"
            }
        }
    }

    foreach ($capabilityId in @('cleanup-uninstall.startup-entries-autoruns', 'cleanup-uninstall.device-cleanup')) {
        $route = @($routes | Where-Object { [string](Get-PropertyValue $_ 'capabilityId' '') -eq $capabilityId })[0]
        foreach ($action in @('preview', 'apply', 'restore')) {
            $section = Get-RouteSection $route $action
            Add-Check ([bool](Get-PropertyValue $section 'statusOnly' $false)) "$capabilityId $action route is statusOnly" "$capabilityId $action route is not statusOnly"
            $resultArgs = @('-CapabilityId', $capabilityId, '-Action', $action, '-UtilitiesRoot', $utilitiesRoot)
            if ($action -ne 'preview') { $resultArgs += '-ConfirmApply' }
            $result = Invoke-Router $resultArgs
            $label = "$capabilityId $action statusOnly"
            Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
            Test-CompleteEnvelope $result.json $label
            if ($null -eq $result.json) { continue }
            Add-Check ([string](Get-PropertyValue $result.json 'status' '') -eq 'not-executable') "$label returns not-executable" "$label status mismatch"
            Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
            Add-Check ([string](Get-PropertyValue $result.json 'nextRequiredStep' '') -eq [string](Get-PropertyValue $section 'nextRequiredStep' '')) "$label nextRequiredStep matches manifest" "$label nextRequiredStep mismatch"
        }
    }

    $mutatingApplyIds = @(
        'cleanup-uninstall.bulk-removal',
        'cleanup-uninstall.official-uninstall',
        'cleanup-uninstall.cleanup-deletion-plan',
        'cleanup-uninstall.cleanup-rollback'
    )
    foreach ($capabilityId in $capabilityIds) {
        $result = Invoke-Router @('-CapabilityId', $capabilityId, '-Action', 'apply', '-UtilitiesRoot', $utilitiesRoot)
        $label = "$capabilityId apply without confirmation"
        Add-Check ($result.exitCode -eq 0) "$label exits 0" "$label exit code expected 0, got $($result.exitCode)"
        Test-CompleteEnvelope $result.json $label
        if ($null -eq $result.json) { continue }
        $status = [string](Get-PropertyValue $result.json 'status' '')
        if ($mutatingApplyIds -contains $capabilityId) {
            Add-Check ($status -eq 'approval-required') "$label returns approval-required" "$label expected approval-required, got $status"
        } else {
            Add-Check ($status -eq 'not-executable') "$label returns not-executable for non-mutating route" "$label expected not-executable, got $status"
        }
        Add-Check ([bool](Get-PropertyValue $result.json 'dryRun' $false) -eq $true) "$label remains dryRun" "$label is not dryRun"
        Add-Check ([bool](Get-PropertyValue $result.json 'changed' $true) -eq $false) "$label changed is false" "$label changed is not false"
        Add-Check ($null -eq (Get-PropertyValue $result.json 'routedScript' $null)) "$label did not dispatch" "$label unexpectedly dispatched"
    }

    $officialApplyResult = Invoke-Router @('-CapabilityId', 'cleanup-uninstall.official-uninstall', '-Action', 'apply', '-ConfirmApply', '-UtilitiesRoot', $utilitiesRoot)
    Add-Check ($officialApplyResult.exitCode -eq 0) 'Official uninstall harmless apply exits 0' "Official uninstall harmless apply exit code expected 0, got $($officialApplyResult.exitCode)"
    Test-CompleteEnvelope $officialApplyResult.json 'Official uninstall harmless apply'
    if ($null -ne $officialApplyResult.json) {
        $evidence = Get-PropertyValue $officialApplyResult.json 'evidence' $null
        $summary = Get-PropertyValue $evidence 'summary' $null
        $command = Get-PropertyValue $evidence 'command' $null
        $capabilities = Get-PropertyValue $evidence 'capabilities' $null
        Add-Check ([string](Get-PropertyValue $officialApplyResult.json 'status' '') -eq 'completed') 'Official uninstall harmless apply completed' 'Official uninstall harmless apply status mismatch'
        Add-Check ([string](Get-PropertyValue $officialApplyResult.json 'routedScript' '') -eq 'backend/scripts/Invoke-OfficialUninstallCommandRunner.ps1') 'Official uninstall harmless apply routed runner script' 'Official uninstall harmless apply routedScript mismatch'
        Add-Check ([bool](Get-PropertyValue $summary 'processStarted' $false) -eq $true) 'Official uninstall harmless apply started the shim process' 'Official uninstall harmless apply did not start process'
        Add-Check ([bool](Get-PropertyValue $summary 'willRunRealUninstaller' $true) -eq $false) 'Official uninstall harmless apply will not run a real uninstaller' 'Official uninstall harmless apply reports real uninstaller execution'
        Add-Check ([bool](Get-PropertyValue $capabilities 'realAppUninstallBlocked' $false) -eq $true) 'Official uninstall harmless apply blocks real app uninstall' 'Official uninstall harmless apply does not report real app uninstall blocked'
        Add-Check ([System.IO.Path]::GetFullPath([string](Get-PropertyValue $command 'executable' '')).Equals($allowedExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) 'Official uninstall command executable matches exact allowlist' 'Official uninstall command executable does not match allowlist'
        $arguments = @((Get-PropertyValue $command 'arguments' @()))
        Add-Check ($arguments -contains $shimPath) 'Official uninstall command arguments reference only the temp harmless shim script' 'Official uninstall command arguments do not reference the temp harmless shim script'
        Add-Check (Test-PathInsideRoot $shimPath $runnerRoot) 'Official uninstall shim path is inside the temp runner root' 'Official uninstall shim path is outside the temp runner root'
        Add-Check ([bool](Get-PropertyValue $officialApplyResult.json 'changed' $false) -eq $true) 'Official uninstall harmless apply marks process proof as changed' 'Official uninstall harmless apply changed flag mismatch'
    }

    Add-Check ((Get-Content -LiteralPath $outsideSentinel -Raw).Trim() -eq 'outside payload') 'Outside sentinel is intact before cleanup fixture apply' 'Outside sentinel changed before cleanup fixture apply'

    $cleanupApplyResult = Invoke-Router @('-CapabilityId', 'cleanup-uninstall.cleanup-deletion-plan', '-Action', 'apply', '-ConfirmApply', '-FixtureRoot', $cleanupRoot, '-UtilitiesRoot', $utilitiesRoot)
    Add-Check ($cleanupApplyResult.exitCode -eq 0) 'Cleanup deletion fixture apply exits 0' "Cleanup deletion fixture apply exit code expected 0, got $($cleanupApplyResult.exitCode)"
    Test-CompleteEnvelope $cleanupApplyResult.json 'Cleanup deletion fixture apply'
    if ($null -ne $cleanupApplyResult.json) {
        $evidence = Get-PropertyValue $cleanupApplyResult.json 'evidence' $null
        $summary = Get-PropertyValue $evidence 'summary' $null
        $rollback = Get-PropertyValue $evidence 'rollback' $null
        Add-Check ([string](Get-PropertyValue $cleanupApplyResult.json 'status' '') -eq 'completed') 'Cleanup deletion fixture apply completed' 'Cleanup deletion fixture apply status mismatch'
        Add-Check ([string](Get-PropertyValue $cleanupApplyResult.json 'routedScript' '') -eq 'backend/scripts/Invoke-UninstallCleanupExecution.ps1') 'Cleanup deletion fixture apply routed executor script' 'Cleanup deletion fixture apply routedScript mismatch'
        Add-Check ([bool](Get-PropertyValue $cleanupApplyResult.json 'dryRun' $true) -eq $false) 'Cleanup deletion fixture apply is not dryRun' 'Cleanup deletion fixture apply is dryRun'
        Add-Check ([bool](Get-PropertyValue $cleanupApplyResult.json 'approvalSatisfied' $false) -eq $true) 'Cleanup deletion fixture apply approval is satisfied' 'Cleanup deletion fixture apply approval not satisfied'
        Add-Check ([bool](Get-PropertyValue $cleanupApplyResult.json 'changed' $false) -eq $true) 'Cleanup deletion fixture apply changed is true' 'Cleanup deletion fixture apply changed is not true'
        Add-Check ([int](Get-PropertyValue $summary 'deletedCount' 0) -eq 2) 'Cleanup deletion fixture apply deleted two fixture targets' 'Cleanup deletion fixture apply deleted count mismatch'
        Add-Check ([bool](Get-PropertyValue $summary 'willRunUninstallers' $true) -eq $false) 'Cleanup deletion fixture apply will not run uninstallers' 'Cleanup deletion fixture apply reports uninstaller execution'
        Add-Check ([bool](Get-PropertyValue $summary 'willDeleteRealFiles' $true) -eq $false) 'Cleanup deletion fixture apply will not delete real files' 'Cleanup deletion fixture apply reports real file deletion'
        Add-Check (-not (Test-Path -LiteralPath $folderTarget)) 'Cleanup deletion fixture apply removed fixture folder target' 'Cleanup deletion fixture folder target still exists'
        Add-Check (-not (Test-Path -LiteralPath $fileTarget)) 'Cleanup deletion fixture apply removed fixture file target' 'Cleanup deletion fixture file target still exists'
        $writtenRollbackPath = [string](Get-PropertyValue $rollback 'rollbackManifestPath' '')
        Add-Check (Test-Path -LiteralPath $writtenRollbackPath -PathType Leaf) 'Cleanup deletion fixture apply wrote rollback manifest' 'Cleanup deletion fixture apply did not write rollback manifest'
        Add-Check ([System.IO.Path]::GetFullPath($writtenRollbackPath).Equals($rollbackManifestPath, [System.StringComparison]::OrdinalIgnoreCase)) 'Cleanup deletion fixture apply wrote the routed rollback manifest path' 'Cleanup deletion fixture apply rollback manifest path mismatch'
        Add-Check (Test-PathInsideRoot $writtenRollbackPath $cleanupRoot) 'Cleanup rollback manifest is inside fixture root' 'Cleanup rollback manifest is outside fixture root'
    }
    Add-Check ((Get-Content -LiteralPath $outsideSentinel -Raw).Trim() -eq 'outside payload') 'Outside sentinel is intact after cleanup fixture apply' 'Outside sentinel changed after cleanup fixture apply'

    $rollbackApplyResult = Invoke-Router @('-CapabilityId', 'cleanup-uninstall.cleanup-rollback', '-Action', 'apply', '-ConfirmApply', '-UtilitiesRoot', $utilitiesRoot)
    Add-Check ($rollbackApplyResult.exitCode -eq 0) 'Cleanup rollback fixture apply exits 0' "Cleanup rollback fixture apply exit code expected 0, got $($rollbackApplyResult.exitCode)"
    Test-CompleteEnvelope $rollbackApplyResult.json 'Cleanup rollback fixture apply'
    if ($null -ne $rollbackApplyResult.json) {
        $evidence = Get-PropertyValue $rollbackApplyResult.json 'evidence' $null
        $summary = Get-PropertyValue $evidence 'summary' $null
        Add-Check ([string](Get-PropertyValue $rollbackApplyResult.json 'status' '') -eq 'completed') 'Cleanup rollback fixture apply completed' 'Cleanup rollback fixture apply status mismatch'
        Add-Check ([string](Get-PropertyValue $rollbackApplyResult.json 'routedScript' '') -eq 'backend/scripts/Restore-UninstallCleanupExecution.ps1') 'Cleanup rollback fixture apply routed restore script' 'Cleanup rollback fixture apply routedScript mismatch'
        Add-Check ([bool](Get-PropertyValue $rollbackApplyResult.json 'changed' $false) -eq $true) 'Cleanup rollback fixture apply changed is true' 'Cleanup rollback fixture apply changed is not true'
        Add-Check ([int](Get-PropertyValue $summary 'restoredCount' 0) -eq 2) 'Cleanup rollback fixture apply restored two targets' 'Cleanup rollback fixture apply restored count mismatch'
        Add-Check ([bool](Get-PropertyValue $summary 'willChangeRealSystem' $true) -eq $false) 'Cleanup rollback fixture apply will not change the real system' 'Cleanup rollback fixture apply reports real system change'
        Add-Check (Test-Path -LiteralPath $folderFile -PathType Leaf) 'Cleanup rollback restored folder payload file' 'Cleanup rollback did not restore folder payload file'
        Add-Check (Test-Path -LiteralPath $fileTarget -PathType Leaf) 'Cleanup rollback restored loose file payload' 'Cleanup rollback did not restore loose file payload'
        if ((Test-Path -LiteralPath $folderFile -PathType Leaf) -and (Test-Path -LiteralPath $fileTarget -PathType Leaf)) {
            Add-Check ((Get-Content -LiteralPath $folderFile -Raw).Trim() -eq 'folder payload') 'Cleanup rollback preserved folder payload content' 'Cleanup rollback folder payload content mismatch'
            Add-Check ((Get-Content -LiteralPath $fileTarget -Raw).Trim() -eq 'file payload') 'Cleanup rollback preserved loose file payload content' 'Cleanup rollback loose file payload content mismatch'
        }
    }
    Add-Check ((Get-Content -LiteralPath $outsideSentinel -Raw).Trim() -eq 'outside payload') 'Outside sentinel is intact after cleanup rollback' 'Outside sentinel changed after cleanup rollback'

} catch {
    Add-Failure "Cleanup router validation threw: $($_.Exception.Message)"
} finally {
    $env:ROO_CLEANUP_FIXTURE_ROOT = $previousFixtureRoot
    if (-not [string]::IsNullOrWhiteSpace($tempBase)) {
        try {
            Remove-TempTree $tempBase
        } catch {
            Add-Failure "Failed to clean temp fixture base $tempBase :: $($_.Exception.Message)"
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($tempBase)) {
    Add-Check (-not (Test-Path -LiteralPath $tempBase)) 'Cleanup router temp fixture base was removed' "Cleanup router temp fixture base remains: $tempBase"
}

$stateAfterCount = Get-StateEntryCount $repoRoot
Add-Check (-not (Test-Path -LiteralPath $statePath)) 'backend/state remains absent after cleanup router validation' 'backend/state exists after cleanup router validation'
Add-Check ($stateAfterCount -eq 0) 'backend/state has no entries after cleanup router validation' "backend/state has $stateAfterCount item(s) after cleanup router validation"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Capability router cleanup validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Capability router cleanup validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
