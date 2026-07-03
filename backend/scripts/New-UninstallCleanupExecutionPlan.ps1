param(
    [string]$OfficialPreviewPath = '',
    [string]$CleanupManifestPath = '',
    [string]$AppId = '',
    [string]$InventoryPath = '',
    [string]$ScanPath = '',
    [string]$PolicyPath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')

function ConvertFrom-RooJsonOutput {
    param([object[]]$Output)
    return ($Output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-OfficialPreviewForPlan {
    param(
        [string]$OfficialPreviewPath,
        [string]$AppId,
        [string]$InventoryPath
    )

    if (-not [string]::IsNullOrWhiteSpace($OfficialPreviewPath)) {
        return Read-RooUninstallJsonFile (Resolve-RooUninstallPath $OfficialPreviewPath $OfficialPreviewPath)
    }
    if ([string]::IsNullOrWhiteSpace($AppId)) {
        throw 'Either -OfficialPreviewPath or -AppId is required for the execution plan.'
    }

    $args = @{ AppId = @($AppId) }
    if (-not [string]::IsNullOrWhiteSpace($InventoryPath)) { $args['InventoryPath'] = $InventoryPath }
    return ConvertFrom-RooJsonOutput (& (Join-Path $PSScriptRoot 'Preview-OfficialUninstall.ps1') @args)
}

function Get-CleanupManifestForPlan {
    param(
        [string]$CleanupManifestPath,
        [string]$ScanPath,
        [string]$AppId,
        [string]$InventoryPath
    )

    if (-not [string]::IsNullOrWhiteSpace($CleanupManifestPath)) {
        return Read-RooUninstallJsonFile (Resolve-RooUninstallPath $CleanupManifestPath $CleanupManifestPath)
    }
    if ([string]::IsNullOrWhiteSpace($ScanPath) -and [string]::IsNullOrWhiteSpace($AppId)) {
        throw 'Either -CleanupManifestPath, -ScanPath, or -AppId is required for the execution plan.'
    }

    $args = @{}
    if (-not [string]::IsNullOrWhiteSpace($ScanPath)) {
        $args['ScanPath'] = $ScanPath
    } else {
        $args['AppId'] = $AppId
        if (-not [string]::IsNullOrWhiteSpace($InventoryPath)) { $args['InventoryPath'] = $InventoryPath }
    }
    return ConvertFrom-RooJsonOutput (& (Join-Path $PSScriptRoot 'New-CleanupDeletionManifest.ps1') @args)
}

function New-RooExecutionGate {
    param(
        [string]$GateId,
        [string]$Name,
        [bool]$Required,
        [bool]$Satisfied,
        [bool]$Blocking,
        [string]$Reason,
        [object]$Evidence = $null
    )

    return [pscustomobject]@{
        gateId = $GateId
        name = $Name
        required = $Required
        satisfied = $Satisfied
        blocking = ($Blocking -and -not $Satisfied)
        reason = $Reason
        evidence = $Evidence
    }
}

function Get-BackupRequirementCount {
    param(
        [object]$Rollback,
        [string]$PropertyName
    )
    return @(Get-RooUninstallPropertyArray $Rollback $PropertyName).Count
}

function Test-ControlledUninstallRunnerImplemented {
    $requiredRunnerScripts = @(
        (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupRunners.ps1'),
        (Join-Path $PSScriptRoot 'Restore-UninstallCleanupExecution.ps1')
    )
    return (@($requiredRunnerScripts | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0)
}

try {
    $policy = Read-RooUninstallPolicy $PolicyPath
    $officialPreview = Get-OfficialPreviewForPlan $OfficialPreviewPath $AppId $InventoryPath
    $cleanupManifest = Get-CleanupManifestForPlan $CleanupManifestPath $ScanPath $AppId $InventoryPath

    $commands = @(Get-RooUninstallPropertyArray $officialPreview 'commands')
    $command = if ($commands.Count -gt 0) { $commands[0] } else { $null }
    $manifestItems = @(Get-RooUninstallPropertyArray $cleanupManifest 'items')
    $rollback = Get-RooUninstallPropertyValue $cleanupManifest 'rollback' $null
    $restorePoint = Get-RooUninstallPropertyValue $rollback 'restorePoint' $null
    $policyExecutionDesign = Get-RooUninstallPropertyValue $policy 'executionDesign' $null
    $confirmedExecutionEnabled = [bool](Get-RooUninstallPropertyValue $policy 'confirmedExecutionEnabled' $false)
    $executorImplemented = [bool](Get-RooUninstallPropertyValue $policyExecutionDesign 'executorImplemented' $false)
    $fixtureExecutorImplemented = [bool](Get-RooUninstallPropertyValue $policyExecutionDesign 'fixtureExecutorImplemented' $false)
    $controlledRunnerImplemented = Test-ControlledUninstallRunnerImplemented
    $realSystemExecutorImplemented = ([bool](Get-RooUninstallPropertyValue $policyExecutionDesign 'realSystemExecutorImplemented' $false) -or $controlledRunnerImplemented)
    $officialErrors = @(Get-RooUninstallPropertyArray $officialPreview 'errors')
    $manifestErrors = @(Get-RooUninstallPropertyArray $cleanupManifest 'errors')
    $protectedSelected = @($manifestItems | Where-Object { [bool](Get-RooUninstallPropertyValue $_ 'protected' $false) })
    $blockedCommands = @($commands | Where-Object { [bool](Get-RooUninstallPropertyValue $_ 'blocked' $false) })
    $executionAllowedCommands = @($commands | Where-Object { [bool](Get-RooUninstallPropertyValue $_ 'executionAllowed' $false) })

    $fileBackupCount = Get-BackupRequirementCount $rollback 'fileBackupRequirements'
    $registryExportCount = Get-BackupRequirementCount $rollback 'registryExportRequirements'
    $serviceBackupCount = Get-BackupRequirementCount $rollback 'serviceStateBackupRequirements'
    $taskBackupCount = Get-BackupRequirementCount $rollback 'scheduledTaskBackupRequirements'
    $startupBackupCount = Get-BackupRequirementCount $rollback 'startupEntryBackupRequirements'
    $backupRequirementCount = $fileBackupCount + $registryExportCount + $serviceBackupCount + $taskBackupCount + $startupBackupCount

    $gates = New-Object System.Collections.Generic.List[object]
    $gates.Add((New-RooExecutionGate 'policy-confirmed-execution-enabled' 'Confirmed real-system execution policy enabled' $true $confirmedExecutionEnabled $true 'Repository policy must explicitly enable confirmed real-system execution before real uninstall or cleanup can run.' ([pscustomobject]@{ confirmedExecutionEnabled = $confirmedExecutionEnabled }))) | Out-Null
    $gates.Add((New-RooExecutionGate 'fixture-executor-implemented' 'Disposable fixture executor implementation present' $true $fixtureExecutorImplemented $true 'The backend must expose a fixture-only executor before live validation can prove backup and deletion mechanics.' ([pscustomobject]@{ fixtureExecutorImplemented = $fixtureExecutorImplemented }))) | Out-Null
    $gates.Add((New-RooExecutionGate 'real-system-executor-implemented' 'Real-system executor implementation present' $true $realSystemExecutorImplemented $true 'Controlled official runner and rollback contracts must exist before real-system execution can be considered.' ([pscustomobject]@{ realSystemExecutorImplemented = $realSystemExecutorImplemented; controlledRunnerImplemented = $controlledRunnerImplemented }))) | Out-Null
    $gates.Add((New-RooExecutionGate 'official-preview-clean' 'Official uninstall preview has no blocking errors' $true ($officialErrors.Count -eq 0 -and $blockedCommands.Count -eq 0) $true 'Official uninstall metadata must resolve and the selected app must not be blocked.' ([pscustomobject]@{ errorCount = $officialErrors.Count; blockedCommandCount = $blockedCommands.Count }))) | Out-Null
    $gates.Add((New-RooExecutionGate 'manifest-clean' 'Cleanup manifest has no blocking errors' $true ($manifestErrors.Count -eq 0 -and $protectedSelected.Count -eq 0) $true 'Cleanup manifest must exclude protected items and contain no manifest errors.' ([pscustomobject]@{ errorCount = $manifestErrors.Count; protectedSelectedCount = $protectedSelected.Count }))) | Out-Null
    $gates.Add((New-RooExecutionGate 'restore-point-before-apply' 'Restore point required before future apply' $true $false $true 'A future executor must create a restore point before official uninstall or cleanup apply.' ([pscustomobject]@{ requiredBeforeFutureApply = [bool](Get-RooUninstallPropertyValue $restorePoint 'requiredBeforeFutureApply' $true); created = [bool](Get-RooUninstallPropertyValue $restorePoint 'created' $false) }))) | Out-Null
    $gates.Add((New-RooExecutionGate 'backup-exports-complete' 'Backups and exports completed' $true ($backupRequirementCount -eq 0) ($backupRequirementCount -gt 0) 'Every selected cleanup target must have its backup or export completed before deletion is allowed.' ([pscustomobject]@{ backupRequirementCount = $backupRequirementCount; fileBackupCount = $fileBackupCount; registryExportCount = $registryExportCount; serviceBackupCount = $serviceBackupCount; scheduledTaskBackupCount = $taskBackupCount; startupEntryBackupCount = $startupBackupCount }))) | Out-Null
    $gates.Add((New-RooExecutionGate 'explicit-user-confirmation' 'Explicit user confirmation captured' $true $false $true 'The future apply path must require a fresh user confirmation for the exact app and manifest.' ([pscustomobject]@{ confirmationCaptured = $false }))) | Out-Null

    $gateArray = @($gates.ToArray())
    $blockingGateCount = @($gateArray | Where-Object { [bool](Get-RooUninstallPropertyValue $_ 'blocking' $false) }).Count
    $effectiveAppId = [string](Get-RooUninstallPropertyValue $cleanupManifest 'appId' $AppId)
    if ([string]::IsNullOrWhiteSpace($effectiveAppId) -and $null -ne $command) {
        $effectiveAppId = [string](Get-RooUninstallPropertyValue $command 'appId' '')
    }

    $plan = [pscustomobject]@{
        actionId = 'apps.planUninstallCleanupExecution'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        planId = 'uninstall-cleanup-execution-plan-' + (ConvertTo-RooStableId $effectiveAppId) + '-' + (Get-RooUninstallFileStamp)
        appId = $effectiveAppId
        displayName = [string](Get-RooUninstallPropertyValue $cleanupManifest 'displayName' (Get-RooUninstallPropertyValue $command 'displayName' ''))
        createdAtUtc = Get-RooUninstallUtcStamp
        dryRun = $true
        executionMode = 'guarded-fixture-ready'
        status = if ($blockingGateCount -gt 0) { 'blocked' } else { 'review-ready' }
        policyPath = Get-RooUninstallPolicyPath $PolicyPath
        sourceArtifacts = [pscustomobject]@{
            officialPreviewPath = if ([string]::IsNullOrWhiteSpace($OfficialPreviewPath)) { $null } else { Resolve-RooUninstallPath $OfficialPreviewPath $OfficialPreviewPath }
            cleanupManifestPath = if ([string]::IsNullOrWhiteSpace($CleanupManifestPath)) { $null } else { Resolve-RooUninstallPath $CleanupManifestPath $CleanupManifestPath }
            officialActionId = [string](Get-RooUninstallPropertyValue $officialPreview 'actionId' '')
            cleanupManifestId = [string](Get-RooUninstallPropertyValue $cleanupManifest 'manifestId' '')
            sourceScanId = [string](Get-RooUninstallPropertyValue $cleanupManifest 'sourceScanId' '')
        }
        capabilities = [pscustomobject]@{
            currentCapability = 'preview-plan-disposable-fixture-and-controlled-runner'
            executorImplemented = $executorImplemented
            fixtureExecutorImplemented = $fixtureExecutorImplemented
            realSystemExecutorImplemented = $realSystemExecutorImplemented
            confirmedExecutionEnabled = $confirmedExecutionEnabled
            canRunAllowlistedOfficialCommand = $realSystemExecutorImplemented
            canRunUninstallers = $false
            canDeleteLeftovers = $false
            canApplyDisposableFixture = $fixtureExecutorImplemented
            canEditRegistry = $false
            canEditServices = $false
            canEditScheduledTasks = $false
            canWriteState = $false
        }
        gates = $gateArray
        phases = @(
            [pscustomobject]@{
                phaseId = 'preflight-review'
                order = 1
                mode = 'current'
                status = 'available'
                purpose = 'Review official uninstall and cleanup manifest artifacts without changing the system.'
                requiredGateIds = @('official-preview-clean', 'manifest-clean')
                allowedNow = $true
                actionsNow = @('read-preview-artifacts', 'validate-policy-gates')
                systemChangesNow = @()
            },
            [pscustomobject]@{
                phaseId = 'official-uninstall'
                order = 2
                mode = 'approval-gated-controlled-runner'
                status = 'blocked'
                purpose = 'Run an allowlisted vendor or package-manager uninstall command before leftover cleanup.'
                requiredGateIds = @('policy-confirmed-execution-enabled', 'real-system-executor-implemented', 'restore-point-before-apply', 'explicit-user-confirmation')
                allowedNow = $false
                commandPreviews = @($commands | ForEach-Object {
                    [pscustomobject]@{
                        appId = [string](Get-RooUninstallPropertyValue $_ 'appId' '')
                        commandType = [string](Get-RooUninstallPropertyValue $_ 'commandType' '')
                        rawCommand = Get-RooUninstallPropertyValue $_ 'rawCommand' $null
                        quietRawCommand = Get-RooUninstallPropertyValue $_ 'quietRawCommand' $null
                        requiresElevation = [bool](Get-RooUninstallPropertyValue $_ 'requiresElevation' $true)
                        protected = [bool](Get-RooUninstallPropertyValue $_ 'protected' $false)
                        blocked = [bool](Get-RooUninstallPropertyValue $_ 'blocked' $false)
                        executionAllowedNow = $false
                    }
                })
                systemChangesNow = @()
            },
            [pscustomobject]@{
                phaseId = 'post-uninstall-leftover-rescan'
                order = 3
                mode = 'future-executor'
                status = 'blocked'
                purpose = 'Rescan leftovers after official uninstall so stale preview candidates are not blindly applied.'
                requiredGateIds = @('policy-confirmed-execution-enabled', 'real-system-executor-implemented')
                allowedNow = $false
                actionsNow = @()
                systemChangesNow = @()
            },
            [pscustomobject]@{
                phaseId = 'backup-and-export'
                order = 4
                mode = 'future-executor'
                status = 'blocked'
                purpose = 'Capture file backups, registry exports, service state, scheduled task exports, and startup entry exports.'
                requiredGateIds = @('restore-point-before-apply')
                allowedNow = $false
                requirements = [pscustomobject]@{
                    fileBackupCount = $fileBackupCount
                    registryExportCount = $registryExportCount
                    serviceStateBackupCount = $serviceBackupCount
                    scheduledTaskBackupCount = $taskBackupCount
                    startupEntryBackupCount = $startupBackupCount
                }
                systemChangesNow = @()
            },
            [pscustomobject]@{
                phaseId = 'cleanup-apply'
                order = 5
                mode = 'future-executor'
                status = 'blocked'
                purpose = 'Apply selected leftover removals only after backups, exports, protected-item checks, and confirmation pass.'
                requiredGateIds = @('backup-exports-complete', 'manifest-clean', 'explicit-user-confirmation')
                allowedNow = $false
                itemCount = $manifestItems.Count
                items = @($manifestItems | ForEach-Object {
                    [pscustomobject]@{
                        itemId = [string](Get-RooUninstallPropertyValue $_ 'itemId' '')
                        type = [string](Get-RooUninstallPropertyValue $_ 'type' '')
                        target = [string](Get-RooUninstallPropertyValue $_ 'target' '')
                        risk = [string](Get-RooUninstallPropertyValue $_ 'risk' '')
                        protected = [bool](Get-RooUninstallPropertyValue $_ 'protected' $false)
                    }
                })
                systemChangesNow = @()
            },
            [pscustomobject]@{
                phaseId = 'verify-and-rollback-ready'
                order = 6
                mode = 'approval-gated-controlled-runner'
                status = 'blocked'
                purpose = 'Verify removal results and keep rollback metadata ready for restore.'
                requiredGateIds = @('backup-exports-complete')
                allowedNow = $false
                rollbackSupported = [bool](Get-RooUninstallPropertyValue $rollback 'rollbackSupported' $true)
                systemChangesNow = @()
            }
        )
        summary = [pscustomobject]@{
            commandPreviewCount = $commands.Count
            executionAllowedCommandCount = $executionAllowedCommands.Count
            cleanupItemCount = $manifestItems.Count
            protectedSelectedCount = $protectedSelected.Count
            blockingGateCount = $blockingGateCount
            willRunUninstallers = $false
            willDeleteLeftovers = $false
            willEditRegistry = $false
            willEditServices = $false
            willEditScheduledTasks = $false
            dryRunWritesState = $false
            executionReady = $false
            disposableFixtureExecutionReady = $fixtureExecutorImplemented
            allowlistedOfficialRunnerReady = $realSystemExecutorImplemented
        }
        policySummary = [pscustomobject]@{
            previewOnly = [bool](Get-RooUninstallPropertyValue $policy 'previewOnly' $true)
            confirmedExecutionEnabled = $confirmedExecutionEnabled
            executorImplemented = $executorImplemented
            fixtureExecutorImplemented = $fixtureExecutorImplemented
            realSystemExecutorImplemented = $realSystemExecutorImplemented
            backupRoot = [string](Get-RooUninstallPropertyValue (Get-RooUninstallPropertyValue $policy 'cleanupDeletion' $null) 'backupRoot' '')
        }
        warnings = @(
            (New-RooUninstallIssue 'EXECUTION_PLAN_CONTROLLED_RUNNER_GATED' 'Execution plan was produced without running uninstallers, deleting real leftovers, editing registry, editing services, editing tasks, or writing repo state. Controlled runner and disposable fixture execution are available separately.' 'info' 'apps.uninstallCleanupExecutionPlan' $effectiveAppId $false 'Use Invoke-UninstallCleanupRunners.ps1 only with exact executable allowlists and approval evidence; use Invoke-UninstallCleanupExecution.ps1 only with temp fixture roots for deletion validation.' $null),
            (New-RooUninstallIssue 'CONFIRMED_REAL_EXECUTION_DISABLED' 'Confirmed real uninstall and cleanup execution remains disabled by policy.' 'warning' 'apps.uninstallCleanupExecutionPlan' $effectiveAppId $true 'Keep real execution disabled until policy, backups, restore point, executable allowlist, and confirmation gates are satisfied.' $null)
        )
        errors = @($officialErrors + $manifestErrors)
        logs = @((New-RooUninstallLog 'Uninstall cleanup execution plan generated without system changes.'))
    }

    Write-RooUninstallJsonOutput $plan $OutputPath
} catch {
    $plan = [pscustomobject]@{
        actionId = 'apps.planUninstallCleanupExecution'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        planId = 'uninstall-cleanup-execution-plan-' + (Get-RooUninstallFileStamp)
        appId = $AppId
        createdAtUtc = Get-RooUninstallUtcStamp
        dryRun = $true
        executionMode = 'blocked'
        status = 'failed'
        capabilities = [pscustomobject]@{
            currentCapability = 'preview-plan-disposable-fixture-and-controlled-runner'
            executorImplemented = $false
            fixtureExecutorImplemented = $false
            realSystemExecutorImplemented = (Test-ControlledUninstallRunnerImplemented)
            confirmedExecutionEnabled = $false
            canRunAllowlistedOfficialCommand = (Test-ControlledUninstallRunnerImplemented)
            canRunUninstallers = $false
            canDeleteLeftovers = $false
            canApplyDisposableFixture = $false
            canEditRegistry = $false
            canEditServices = $false
            canEditScheduledTasks = $false
            canWriteState = $false
        }
        summary = [pscustomobject]@{
            commandPreviewCount = 0
            cleanupItemCount = 0
            willRunUninstallers = $false
            willDeleteLeftovers = $false
            dryRunWritesState = $false
            executionReady = $false
        }
        warnings = @()
        errors = @((New-RooUninstallIssue 'EXECUTION_PLAN_FAILED' $_.Exception.Message 'error' 'apps.uninstallCleanupExecutionPlan' $AppId $true 'Check official uninstall preview and cleanup manifest inputs.' $null))
        logs = @((New-RooUninstallLog 'Uninstall cleanup execution plan failed.' 'error'))
    }
    Write-RooUninstallJsonOutput $plan $OutputPath
    exit 1
}
