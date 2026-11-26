param(
    [string]$OfficialPreviewPath = '',
    [string]$CleanupManifestPath = '',
    [string]$PolicyPath = '',
    [string]$FixtureRoot = '',
    [string]$BackupRoot = '',
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowDisposableFixtureApply,
    [switch]$OfficialUninstallCommandApproved,
    [switch]$CleanupDeletionManifestApproved
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')

function ConvertFrom-RooIndustriesExecutionJsonOutput {
    param([object[]]$Output)
    return ($Output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Resolve-RooIndustriesExecutionInput {
    param(
        [string]$Path,
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label path is required." }
    return Read-RooIndustriesUninstallJsonFile (Resolve-RooIndustriesUninstallPath $Path $Path)
}

function Test-RooIndustriesPathInsideRoot {
    param(
        [string]$Path,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootWithSlash = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    return ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-RooIndustriesPathInsideTemp {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-ControlledUninstallRunnerImplemented {
    $requiredRunnerScripts = @(
        (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupRunners.ps1'),
        (Join-Path $PSScriptRoot 'Restore-UninstallCleanupExecution.ps1')
    )
    return (@($requiredRunnerScripts | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0)
}

function New-RooIndustriesCleanupExecutionGate {
    param(
        [string]$GateId,
        [string]$Name,
        [bool]$Required,
        [bool]$Satisfied,
        [string]$Reason,
        [object]$Evidence = $null
    )
    return [pscustomobject]@{
        gateId = $GateId
        name = $Name
        required = $Required
        satisfied = $Satisfied
        blocking = ($Required -and -not $Satisfied)
        reason = $Reason
        evidence = $Evidence
    }
}

function Copy-RooIndustriesFixtureBackup {
    param(
        [object]$Item,
        [string]$BackupRoot
    )
    $itemId = [string](Get-RooIndustriesUninstallPropertyValue $Item 'itemId' '')
    $source = [System.IO.Path]::GetFullPath([string](Get-RooIndustriesUninstallPropertyValue $Item 'target' ''))
    $safeId = ConvertTo-RooIndustriesStableId $itemId
    $destination = Join-Path $BackupRoot $safeId
    Ensure-RooIndustriesUninstallDirectory (Split-Path $destination -Parent)
    $itemType = [string](Get-RooIndustriesUninstallPropertyValue $Item 'type' '')
    if (-not (Test-Path -LiteralPath $source)) {
        return [pscustomobject]@{
            itemId = $itemId
            type = $itemType
            source = $source
            backupPath = $destination
            copied = $false
            reason = 'Target did not exist in disposable fixture.'
        }
    }
    if ($itemType -eq 'folder') {
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    } elseif ($itemType -eq 'file') {
        Ensure-RooIndustriesUninstallDirectory (Split-Path $destination -Parent)
        Copy-Item -LiteralPath $source -Destination $destination -Force
    } else {
        throw "Fixture executor only supports file and folder items. Unsupported type: $itemType"
    }
    return [pscustomobject]@{
        itemId = $itemId
        type = $itemType
        source = $source
        backupPath = $destination
        copied = $true
        reason = 'Copied before disposable fixture deletion.'
    }
}

function Remove-RooIndustriesFixtureTarget {
    param([object]$Item)
    $target = [System.IO.Path]::GetFullPath([string](Get-RooIndustriesUninstallPropertyValue $Item 'target' ''))
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
        return $true
    }
    return $false
}

try {
    $realSystemExecutorImplemented = Test-ControlledUninstallRunnerImplemented
    $policy = Read-RooIndustriesUninstallPolicy $PolicyPath
    $officialPreview = Resolve-RooIndustriesExecutionInput $OfficialPreviewPath 'Official preview'
    $cleanupManifest = Resolve-RooIndustriesExecutionInput $CleanupManifestPath 'Cleanup manifest'
    $plan = ConvertFrom-RooIndustriesExecutionJsonOutput (& (Join-Path $PSScriptRoot 'New-UninstallCleanupExecutionPlan.ps1') -OfficialPreviewPath $OfficialPreviewPath -CleanupManifestPath $CleanupManifestPath -PolicyPath $PolicyPath)

    $items = @(Get-RooIndustriesUninstallPropertyArray $cleanupManifest 'items')
    $commands = @(Get-RooIndustriesUninstallPropertyArray $officialPreview 'commands')
    $protectedItems = @($items | Where-Object { [bool](Get-RooIndustriesUninstallPropertyValue $_ 'protected' $false) })
    $unsupportedItems = @($items | Where-Object { [string](Get-RooIndustriesUninstallPropertyValue $_ 'type' '') -notin @('file','folder') })
    $resolvedFixtureRoot = if ([string]::IsNullOrWhiteSpace($FixtureRoot)) { $null } else { [System.IO.Path]::GetFullPath($FixtureRoot) }
    $resolvedBackupRoot = if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        if ([string]::IsNullOrWhiteSpace($resolvedFixtureRoot)) { $null } else { Join-Path $resolvedFixtureRoot '_roo-cleanup-backup' }
    } else {
        [System.IO.Path]::GetFullPath($BackupRoot)
    }

    $targetsInsideFixture = $false
    if (-not [string]::IsNullOrWhiteSpace($resolvedFixtureRoot) -and $items.Count -gt 0) {
        $outside = @($items | Where-Object { -not (Test-RooIndustriesPathInsideRoot ([string](Get-RooIndustriesUninstallPropertyValue $_ 'target' '')) $resolvedFixtureRoot) })
        $targetsInsideFixture = ($outside.Count -eq 0)
    }
    $linkedItems = @($items | Where-Object {
        $target = [string](Get-RooIndustriesUninstallPropertyValue $_ 'target' '')
        $target -and (Test-RooIndustriesCleanupReparsePath $target -Recurse)
    })

    $gates = @(
        (New-RooIndustriesCleanupExecutionGate 'confirm-apply' 'Confirmed apply requested' $true ([bool]$ConfirmApply) 'Execution remains a dry-run until -ConfirmApply is supplied.' $null),
        (New-RooIndustriesCleanupExecutionGate 'disposable-fixture-flag' 'Disposable fixture apply allowed' $true ([bool]$AllowDisposableFixtureApply) 'Live cleanup is allowed only for disposable temp fixtures.' $null),
        (New-RooIndustriesCleanupExecutionGate 'fixture-root-temp' 'Fixture root is inside temp' $true ((-not [string]::IsNullOrWhiteSpace($resolvedFixtureRoot)) -and (Test-RooIndustriesPathInsideTemp $resolvedFixtureRoot)) 'Fixture apply must be isolated under the OS temp path.' ([pscustomobject]@{ fixtureRoot = $resolvedFixtureRoot })),
        (New-RooIndustriesCleanupExecutionGate 'targets-inside-fixture' 'All cleanup targets are inside fixture root' $true $targetsInsideFixture 'Every live deletion target must resolve inside the disposable fixture root.' ([pscustomobject]@{ itemCount = $items.Count })),
        (New-RooIndustriesCleanupExecutionGate 'official-command-approved' 'Official uninstall command approved' $true ([bool]$OfficialUninstallCommandApproved) 'The official command must be reviewed and approved before the cleanup sequence is considered executable.' ([pscustomobject]@{ commandPreviewCount = $commands.Count; willRunUninstallers = $false })),
        (New-RooIndustriesCleanupExecutionGate 'cleanup-manifest-approved' 'Cleanup deletion manifest approved' $true ([bool]$CleanupDeletionManifestApproved) 'The selected leftover manifest must be approved before fixture deletion.' ([pscustomobject]@{ cleanupManifestId = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'manifestId' $null })),
        (New-RooIndustriesCleanupExecutionGate 'targets-without-links' 'No cleanup target is or holds a link' $true ($linkedItems.Count -eq 0) 'A target reached through or holding a junction, mount point or symbolic link is never copied or deleted.' ([pscustomobject]@{ linkedSelectedCount = $linkedItems.Count })),
        (New-RooIndustriesCleanupExecutionGate 'protected-items-excluded' 'Protected cleanup items excluded' $true ($protectedItems.Count -eq 0) 'Protected leftover items cannot be selected for deletion.' ([pscustomobject]@{ protectedSelectedCount = $protectedItems.Count })),
        (New-RooIndustriesCleanupExecutionGate 'fixture-supported-types' 'Fixture executor supports selected item types' $true ($unsupportedItems.Count -eq 0) 'Disposable fixture execution supports file and folder targets only; registry, service, task, and startup changes remain preview-only.' ([pscustomobject]@{ unsupportedItemCount = $unsupportedItems.Count })),
        (New-RooIndustriesCleanupExecutionGate 'real-uninstaller-disabled' 'Real official uninstaller execution disabled' $false $true 'This executor never launches official uninstall commands; fixture validation starts after approved metadata review.' ([pscustomobject]@{ willRunUninstallers = $false }))
    )
    $blockingGates = @($gates | Where-Object { $_.blocking })
    $canApplyFixture = ($ConfirmApply -and $AllowDisposableFixtureApply -and $blockingGates.Count -eq 0)

    $backupRecords = New-Object System.Collections.Generic.List[object]
    $deletedRecords = New-Object System.Collections.Generic.List[object]
    $rollbackManifestPath = $null

    if ($canApplyFixture) {
        Ensure-RooIndustriesUninstallDirectory $resolvedBackupRoot
        foreach ($item in $items) {
            $backup = Copy-RooIndustriesFixtureBackup $item $resolvedBackupRoot
            $backupRecords.Add($backup) | Out-Null
            $deleted = Remove-RooIndustriesFixtureTarget $item
            $deletedRecords.Add([pscustomobject]@{
                itemId = [string](Get-RooIndustriesUninstallPropertyValue $item 'itemId' '')
                type = [string](Get-RooIndustriesUninstallPropertyValue $item 'type' '')
                target = [System.IO.Path]::GetFullPath([string](Get-RooIndustriesUninstallPropertyValue $item 'target' ''))
                deleted = $deleted
            }) | Out-Null
        }
        $rollbackManifestPath = Join-Path $resolvedBackupRoot 'rollback-manifest.json'
        $rollbackManifest = [pscustomobject]@{
            manifestId = 'cleanup-fixture-rollback-' + (ConvertTo-RooIndustriesStableId ([string](Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'appId' 'fixture'))) + '-' + (Get-RooIndustriesUninstallFileStamp)
            schemaVersion = 1
            productName = $script:RooIndustriesUninstallProductName
            actionId = 'apps.rollbackCleanup'
            sourceManifestId = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'manifestId' $null
            fixtureRoot = $resolvedFixtureRoot
            backupRoot = $resolvedBackupRoot
            createdAtUtc = Get-RooIndustriesUninstallUtcStamp
            restoreSupported = $true
            realSystemRollback = $false
            fileBackups = @($backupRecords.ToArray())
            deletedItems = @($deletedRecords.ToArray())
        }
        ($rollbackManifest | ConvertTo-Json -Depth 24) | Set-Content -LiteralPath $rollbackManifestPath -Encoding UTF8
    }

    $result = [pscustomobject]@{
        actionId = 'apps.invokeUninstallCleanupExecution'
        schemaVersion = 1
        productName = $script:RooIndustriesUninstallProductName
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = (-not $canApplyFixture)
        status = if ($canApplyFixture) { 'success' } elseif ($ConfirmApply) { 'blocked' } else { 'preview' }
        executionMode = if ($canApplyFixture) { 'disposable-fixture-apply' } else { 'preview-or-blocked' }
        appId = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'appId' $null
        displayName = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'displayName' $null
        fixtureRoot = $resolvedFixtureRoot
        backupRoot = $resolvedBackupRoot
        sourceArtifacts = [pscustomobject]@{
            officialPreviewPath = Resolve-RooIndustriesUninstallPath $OfficialPreviewPath $OfficialPreviewPath
            cleanupManifestPath = Resolve-RooIndustriesUninstallPath $CleanupManifestPath $CleanupManifestPath
            planId = Get-RooIndustriesUninstallPropertyValue $plan 'planId' $null
        }
        gates = @($gates)
        plan = $plan
        rollback = [pscustomobject]@{
            rollbackManifestPath = $rollbackManifestPath
            rollbackSupported = $true
            backupRecords = @($backupRecords.ToArray())
        }
        changedItems = @($deletedRecords.ToArray())
        capabilities = [pscustomobject]@{
            fixtureExecutorImplemented = $true
            realSystemExecutorImplemented = $realSystemExecutorImplemented
            canRunAllowlistedOfficialCommand = $realSystemExecutorImplemented
            canRunUninstallers = $false
            canDeleteFixtureFiles = $canApplyFixture
            canDeleteRealFiles = $false
            canEditRegistry = $false
            canEditServices = $false
            canEditScheduledTasks = $false
        }
        summary = [pscustomobject]@{
            commandPreviewCount = $commands.Count
            cleanupItemCount = $items.Count
            backupCount = $backupRecords.Count
            deletedCount = @($deletedRecords.ToArray() | Where-Object { $_.deleted }).Count
            blockingGateCount = @($gates | Where-Object { $_.blocking }).Count
            willRunUninstallers = $false
            willDeleteLeftovers = $canApplyFixture
            willDeleteRealFiles = $false
            willEditRegistry = $false
            willEditServices = $false
            willEditScheduledTasks = $false
            dryRunWritesState = $false
        }
        warnings = @((New-RooIndustriesUninstallIssue 'CLEANUP_EXECUTION_FIXTURE_ONLY' 'Cleanup execution deletes only disposable temp fixtures. Official uninstall commands are handled by the separate controlled runner behind exact allowlist and approval gates; real leftover deletion is not performed by this fixture executor.' 'warning' 'apps.uninstallCleanupExecution' (Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'appId' $null) $true 'Use fixture execution for backend validation only; use controlled runners only with exact allowlists and approval evidence.' $null))
        errors = @()
        logs = @((New-RooIndustriesUninstallLog 'Uninstall cleanup execution contract evaluated without launching uninstallers.'))
    }

    Write-RooIndustriesUninstallJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'apps.invokeUninstallCleanupExecution'
        schemaVersion = 1
        productName = $script:RooIndustriesUninstallProductName
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        status = 'failed'
        executionMode = 'blocked'
        capabilities = [pscustomobject]@{ fixtureExecutorImplemented = $true; realSystemExecutorImplemented = (Test-ControlledUninstallRunnerImplemented); canRunAllowlistedOfficialCommand = (Test-ControlledUninstallRunnerImplemented); canRunUninstallers = $false; canDeleteRealFiles = $false }
        summary = [pscustomobject]@{ willRunUninstallers = $false; willDeleteLeftovers = $false; dryRunWritesState = $false }
        warnings = @()
        errors = @((New-RooIndustriesUninstallIssue 'CLEANUP_EXECUTION_FAILED' $_.Exception.Message 'error' 'apps.uninstallCleanupExecution' $null $true 'Check official preview, cleanup manifest, and fixture root inputs.' $null))
        logs = @((New-RooIndustriesUninstallLog 'Uninstall cleanup execution failed.' 'error'))
    }
    Write-RooIndustriesUninstallJsonOutput $errorResult $OutputPath
    exit 1
}
