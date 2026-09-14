param(
    [string]$OfficialPreviewPath = '',
    [string]$CleanupManifestPath = '',
    [ValidateSet('Preview','Real')]
    [string]$ExecutorMode = 'Preview',
    [string]$AllowedOfficialExecutablePath = '',
    [string]$OfficialRunnerWorkingDirectory = '',
    [string[]]$ExactTargetAllowlist = @(),
    [string]$BackupRoot = '',
    [string]$RollbackManifestPath = '',
    [string]$OutputPath = '',
    [int]$TimeoutSeconds = 30,
    [switch]$ConfirmApply,
    [switch]$OfficialUninstallCommandApproved,
    [switch]$CleanupDeletionManifestApproved,
    [switch]$UserApproved,
    [switch]$AllowRealSystemExecution
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')
. (Join-Path $PSScriptRoot 'BackendExecutor.Common.ps1')

function Resolve-ApplyPackageJsonInput {
    param(
        [string]$Path,
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label path is required." }
    return Read-RooUninstallJsonFile (Resolve-RooUninstallPath $Path $Path)
}

function Test-ApplyPackageTargetAllowlist {
    param(
        [object[]]$Items,
        [string[]]$Allowlist
    )
    if (@($Items).Count -eq 0) { return $false }
    $allowed = @{}
    foreach ($target in @(Get-RooUninstallArray $Allowlist)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) { continue }
        $allowed[[System.IO.Path]::GetFullPath([string]$target).ToLowerInvariant()] = $true
    }
    foreach ($item in @($Items)) {
        $target = [string](Get-RooUninstallPropertyValue $item 'target' '')
        if ([string]::IsNullOrWhiteSpace($target)) { return $false }
        $full = [System.IO.Path]::GetFullPath($target).ToLowerInvariant()
        if (-not $allowed.ContainsKey($full)) { return $false }
    }
    return $true
}

function Get-ApplyPackageOfficialArguments {
    param([object]$Command)
    $value = Get-RooUninstallPropertyValue $Command 'arguments' $null
    if ($null -eq $value) { return @() }
    if ($value -is [System.Array]) { return @($value | ForEach-Object { [string]$_ }) }
    return @([string]$value)
}

function New-ApplyPackageGate {
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

function Copy-ApplyPackageBackup {
    param(
        [object]$Item,
        [string]$BackupRoot
    )
    $itemId = [string](Get-RooUninstallPropertyValue $Item 'itemId' '')
    $source = [System.IO.Path]::GetFullPath([string](Get-RooUninstallPropertyValue $Item 'target' ''))
    $type = [string](Get-RooUninstallPropertyValue $Item 'type' '')
    $destination = Join-Path $BackupRoot (ConvertTo-RooStableId $itemId)
    Ensure-RooUninstallDirectory (Split-Path $destination -Parent)

    if (-not (Test-Path -LiteralPath $source)) {
        return [pscustomobject]@{
            itemId = $itemId
            type = $type
            source = $source
            backupPath = $destination
            copied = $false
            reason = 'Target did not exist when the run started.'
        }
    }

    if ($type -eq 'folder') {
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    } elseif ($type -eq 'file') {
        Ensure-RooUninstallDirectory (Split-Path $destination -Parent)
        Copy-Item -LiteralPath $source -Destination $destination -Force
    } else {
        throw "Apply package supports file and folder cleanup only. Unsupported type: $type"
    }

    return [pscustomobject]@{
        itemId = $itemId
        type = $type
        source = $source
        backupPath = $destination
        copied = $true
        reason = 'Copied before cleanup.'
    }
}

function Remove-ApplyPackageTarget {
    param([object]$Item)
    $target = [System.IO.Path]::GetFullPath([string](Get-RooUninstallPropertyValue $Item 'target' ''))
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
        return $true
    }
    return $false
}

try {
    $officialPreview = Resolve-ApplyPackageJsonInput $OfficialPreviewPath 'Official preview'
    $cleanupManifest = Resolve-ApplyPackageJsonInput $CleanupManifestPath 'Cleanup manifest'
    $commands = @(Get-RooUninstallPropertyArray $officialPreview 'commands')
    $command = if ($commands.Count -gt 0) { $commands[0] } else { $null }
    $items = @(Get-RooUninstallPropertyArray $cleanupManifest 'items')
    $fileFolderItems = @($items | Where-Object { [string](Get-RooUninstallPropertyValue $_ 'type' '') -in @('file','folder') })
    $unsupportedItems = @($items | Where-Object { [string](Get-RooUninstallPropertyValue $_ 'type' '') -notin @('file','folder') })
    $reviewItems = @($items | Where-Object { [bool](Get-RooUninstallPropertyValue $_ 'protected' $false) })
    $realMode = ($ExecutorMode -eq 'Real')
    $commandExecutable = if ($command) { Resolve-RooUninstallPath ([string](Get-RooUninstallPropertyValue $command 'executable' '')) ([string](Get-RooUninstallPropertyValue $command 'executable' '')) } else { '' }
    $allowedOfficialExecutable = if ([string]::IsNullOrWhiteSpace($AllowedOfficialExecutablePath)) { '' } else { Resolve-RooUninstallPath $AllowedOfficialExecutablePath $AllowedOfficialExecutablePath }
    $hasOfficialCommand = (-not [string]::IsNullOrWhiteSpace($commandExecutable))
    $officialExecutableAllowlisted = (-not $hasOfficialCommand) -or (-not [string]::IsNullOrWhiteSpace($allowedOfficialExecutable) -and [System.IO.Path]::GetFullPath($commandExecutable).Equals([System.IO.Path]::GetFullPath($allowedOfficialExecutable), [System.StringComparison]::OrdinalIgnoreCase))
    $exactTargetsApproved = Test-ApplyPackageTargetAllowlist $fileFolderItems $ExactTargetAllowlist
    $resolvedBackupRoot = if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        Join-Path ([System.IO.Path]::GetTempPath()) ('RooOptimizationSuite\cleanup-backups\' + (ConvertTo-RooStableId ([string](Get-RooUninstallPropertyValue $cleanupManifest 'appId' 'app'))) + '-' + (Get-RooUninstallFileStamp))
    } else {
        [System.IO.Path]::GetFullPath($BackupRoot)
    }
    $resolvedRollbackManifestPath = if ([string]::IsNullOrWhiteSpace($RollbackManifestPath)) {
        Join-Path $resolvedBackupRoot 'rollback-manifest.json'
    } else {
        Resolve-RooUninstallPath $RollbackManifestPath $RollbackManifestPath
    }

    $gates = @(
        (New-ApplyPackageGate 'confirm-apply' 'Confirmed apply requested' $true ([bool]$ConfirmApply) 'Apply remains a dry run until confirmed.' $null),
        (New-ApplyPackageGate 'real-mode-selected' 'Real cleanup mode selected' $true $realMode 'Preview mode prepares the run without removing anything.' ([pscustomobject]@{ executorMode = $ExecutorMode })),
        (New-ApplyPackageGate 'official-route-reviewed' 'Removal route reviewed' $true ([bool]$OfficialUninstallCommandApproved) 'The app route must be reviewed first.' ([pscustomobject]@{ commandCount = $commands.Count })),
        (New-ApplyPackageGate 'cleanup-list-reviewed' 'Cleanup list reviewed' $true ([bool]$CleanupDeletionManifestApproved) 'The exact cleanup list must be reviewed first.' ([pscustomobject]@{ itemCount = $items.Count })),
        (New-ApplyPackageGate 'explicit-user-approval' 'Final approval captured' $true ([bool]$UserApproved) 'The final apply action requires explicit approval for this app.' $null),
        (New-ApplyPackageGate 'real-system-flag' 'Real-system execution flag supplied' $true ([bool]$AllowRealSystemExecution) 'Real cleanup requires the real-system execution flag.' $null),
        (New-ApplyPackageGate 'official-executable-allowlisted' 'Official executable allowlisted or not needed' $true $officialExecutableAllowlisted 'If the app has a vendor remover, the executable must match the allowlist exactly.' ([pscustomobject]@{ hasOfficialCommand = $hasOfficialCommand; commandExecutable = $commandExecutable; allowedOfficialExecutablePath = $allowedOfficialExecutable })),
        (New-ApplyPackageGate 'exact-target-allowlist' 'Exact cleanup targets approved' $true $exactTargetsApproved 'Every file and folder target must match the exact allowlist.' ([pscustomobject]@{ allowlistCount = @(Get-RooUninstallArray $ExactTargetAllowlist).Count; itemCount = $fileFolderItems.Count })),
        (New-ApplyPackageGate 'manual-review-items-excluded' 'Manual-review items not selected' $true ($reviewItems.Count -eq 0) 'Manual-review items cannot be included in the apply package.' ([pscustomobject]@{ reviewItemCount = $reviewItems.Count })),
        (New-ApplyPackageGate 'supported-cleanup-types' 'Cleanup item types supported' $true ($unsupportedItems.Count -eq 0) 'This apply package only removes files and folders; registry, service, task, and startup changes stay in review.' ([pscustomobject]@{ unsupportedItemCount = $unsupportedItems.Count }))
    )
    $blockingGates = @($gates | Where-Object { $_.blocking })
    $canApply = ($blockingGates.Count -eq 0)
    $status = if ($canApply) { 'success' } elseif ($ConfirmApply -or $realMode) { 'blocked' } else { 'preview' }

    $sequence = New-Object System.Collections.Generic.List[object]
    $backupRecords = New-Object System.Collections.Generic.List[object]
    $deletedRecords = New-Object System.Collections.Generic.List[object]
    $officialCompleted = (-not $hasOfficialCommand)
    $officialAttempted = $false

    if ($canApply) {
        Ensure-RooUninstallDirectory $resolvedBackupRoot
        if ($hasOfficialCommand) {
            $officialAttempted = $true
            $officialArgs = Get-ApplyPackageOfficialArguments $command
            $officialResult = Invoke-RooBackendHiddenProcess -FilePath $commandExecutable -Arguments $officialArgs -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $OfficialRunnerWorkingDirectory
            $officialCompleted = ((-not [bool](Get-RooPropertyValue $officialResult 'timedOut' $false)) -and [int](Get-RooPropertyValue $officialResult 'exitCode' -1) -eq 0)
            if (-not $officialCompleted) { $status = 'failed' }
            $sequence.Add([pscustomobject]@{
                order = 1
                runner = 'official-uninstaller'
                executable = $commandExecutable
                arguments = @($officialArgs)
                result = $officialResult
                completed = $officialCompleted
            }) | Out-Null
        } else {
            $sequence.Add([pscustomobject]@{
                order = 1
                runner = 'roo-industries-route'
                completed = $true
                reason = 'The app did not publish a vendor remover; cleanup starts from exact leftovers.'
            }) | Out-Null
        }

        if ($officialCompleted) {
            $order = 2
            foreach ($item in $fileFolderItems) {
                $backup = Copy-ApplyPackageBackup $item $resolvedBackupRoot
                $deleted = Remove-ApplyPackageTarget $item
                $backupRecords.Add($backup) | Out-Null
                $deletedRecords.Add([pscustomobject]@{
                    itemId = [string](Get-RooUninstallPropertyValue $item 'itemId' '')
                    type = [string](Get-RooUninstallPropertyValue $item 'type' '')
                    target = [System.IO.Path]::GetFullPath([string](Get-RooUninstallPropertyValue $item 'target' ''))
                    deleted = $deleted
                }) | Out-Null
                $sequence.Add([pscustomobject]@{
                    order = $order
                    runner = 'leftover-cleanup'
                    itemId = [string](Get-RooUninstallPropertyValue $item 'itemId' '')
                    target = [System.IO.Path]::GetFullPath([string](Get-RooUninstallPropertyValue $item 'target' ''))
                    backupPath = [string](Get-RooUninstallPropertyValue $backup 'backupPath' '')
                    completed = $deleted
                }) | Out-Null
                $order++
            }
        } else {
            $sequence.Add([pscustomobject]@{
                order = 2
                runner = 'leftover-cleanup'
                skipped = $true
                reason = 'The vendor remover failed or timed out, so leftover cleanup did not run.'
            }) | Out-Null
        }
    }

    if ($canApply -and $status -eq 'success') {
        $rollbackManifest = [pscustomobject]@{
            manifestId = 'cleanup-rollback-' + (ConvertTo-RooStableId ([string](Get-RooUninstallPropertyValue $cleanupManifest 'appId' 'app'))) + '-' + (Get-RooUninstallFileStamp)
            schemaVersion = 1
            productName = $script:RooUninstallProductName
            actionId = 'apps.rollbackCleanup'
            sourceManifestId = Get-RooUninstallPropertyValue $cleanupManifest 'manifestId' $null
            appId = Get-RooUninstallPropertyValue $cleanupManifest 'appId' $null
            displayName = Get-RooUninstallPropertyValue $cleanupManifest 'displayName' $null
            createdAtUtc = Get-RooUninstallUtcStamp
            fixtureRoot = ''
            backupRoot = $resolvedBackupRoot
            restoreSupported = $true
            realSystemRollback = $true
            exactTargetAllowlist = @(Get-RooUninstallArray $ExactTargetAllowlist)
            fileBackups = @($backupRecords.ToArray())
            deletedItems = @($deletedRecords.ToArray())
            officialRunnerAttempted = $officialAttempted
            officialRunnerCompleted = $officialCompleted
        }
        Ensure-RooUninstallDirectory (Split-Path $resolvedRollbackManifestPath -Parent)
        ($rollbackManifest | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $resolvedRollbackManifestPath -Encoding UTF8
    }

    $result = [pscustomobject]@{
        actionId = 'apps.invokeUninstallCleanupApplyPackage'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        dryRun = (-not $canApply)
        status = $status
        executionMode = $ExecutorMode.ToLowerInvariant()
        appId = Get-RooUninstallPropertyValue $cleanupManifest 'appId' $null
        displayName = Get-RooUninstallPropertyValue $cleanupManifest 'displayName' $null
        gates = @($gates)
        executionSequence = @($sequence.ToArray())
        rollback = [pscustomobject]@{
            rollbackManifestPath = if ($canApply -and $status -eq 'success') { $resolvedRollbackManifestPath } else { $null }
            rollbackSupported = $true
            backupRoot = $resolvedBackupRoot
            fileBackups = @($backupRecords.ToArray())
        }
        capabilities = [pscustomobject]@{
            rooIndustriesRouteWithoutVendorUninstaller = $true
            officialUninstallerRunnerImplemented = $true
            fileFolderCleanupImplemented = $true
            rollbackRestoreImplemented = $true
            registryCleanupReviewOnly = $true
            serviceTaskCleanupReviewOnly = $true
        }
        summary = [pscustomobject]@{
            hasOfficialCommand = $hasOfficialCommand
            rooIndustriesRouteUsed = (-not $hasOfficialCommand)
            officialRunnerAttempted = $officialAttempted
            officialRunnerCompleted = $officialCompleted
            cleanupItemCount = $fileFolderItems.Count
            backupCount = $backupRecords.Count
            deletedCount = @($deletedRecords.ToArray() | Where-Object { $_.deleted }).Count
            blockingGateCount = $blockingGates.Count
            restoreReady = ($canApply -and $status -eq 'success' -and (Test-Path -LiteralPath $resolvedRollbackManifestPath))
            willDeleteLeftovers = $canApply
            willChangeRegistry = $false
            willChangeServices = $false
            willChangeScheduledTasks = $false
            focusStealPrevented = (@($sequence.ToArray() | Where-Object { $_.result.invocation.focusStealPrevented -eq $false }).Count -eq 0)
        }
        warnings = @((New-RooUninstallIssue 'CLEANUP_APPLY_PACKAGE_CONTROLLED' 'Cleanup apply package evaluated through exact route, exact target allowlist, backup, and rollback gates.' 'info' 'apps.uninstallCleanupApplyPackage' (Get-RooUninstallPropertyValue $cleanupManifest 'appId' $null) $false 'Review registry, service, task, and startup cleanup separately before those item types are allowed.' $null))
        errors = @()
        logs = @((New-RooUninstallLog 'Uninstall cleanup apply package completed.'))
    }
    Write-RooUninstallJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'apps.invokeUninstallCleanupApplyPackage'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        dryRun = $true
        status = 'failed'
        executionMode = $ExecutorMode.ToLowerInvariant()
        executionSequence = @()
        summary = [pscustomobject]@{ willDeleteLeftovers = $false; deletedCount = 0; restoreReady = $false }
        warnings = @()
        errors = @((New-RooUninstallIssue 'CLEANUP_APPLY_PACKAGE_FAILED' $_.Exception.Message 'error' 'apps.uninstallCleanupApplyPackage' $null $true 'Check official preview, cleanup manifest, allowlist, backup root, and approval gates.' $null))
        logs = @((New-RooUninstallLog 'Uninstall cleanup apply package failed.' 'error'))
    }
    Write-RooUninstallJsonOutput $errorResult $OutputPath
    exit 1
}
