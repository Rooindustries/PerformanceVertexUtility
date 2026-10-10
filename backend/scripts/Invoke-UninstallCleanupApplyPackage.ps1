param(
    [string]$OfficialPreviewPath = '',
    [string]$CleanupManifestPath = '',
    [string]$ApprovedAppId = '',
    [string]$OfficialPreviewSha256 = '',
    [string]$CleanupManifestSha256 = '',
    [switch]$ManualReviewApproved,
    [ValidateSet('Preview','Real')]
    [string]$ExecutorMode = 'Preview',
    [string]$AllowedOfficialExecutablePath = '',
    [string]$OfficialRunnerWorkingDirectory = '',
    [string[]]$ExactTargetAllowlist = @(),
    [string]$BackupRoot = '',
    [string]$DataRoot = '',
    [string]$RollbackManifestPath = '',
    [string]$OutputPath = '',
    [int]$TimeoutSeconds = 30,
    [switch]$ConfirmApply,
    [switch]$OfficialUninstallCommandApproved,
    [switch]$CleanupDeletionManifestApproved,
    [switch]$UserApproved,
    [switch]$AllowRealSystemExecution,
    [string]$FixtureRoot = '',
    [switch]$AllowFixtureClaims
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')
. (Join-Path $PSScriptRoot 'UninstallOutcome.Common.ps1')
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')

function Test-ApplyPackageTargetAllowlist {
    param(
        [object[]]$Items,
        [string[]]$Allowlist
    )
    if (@($Items).Count -eq 0) { return $false }
    $allowed = @{}
    foreach ($target in @(Get-RooIndustriesUninstallArray $Allowlist)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) { continue }
        $allowed[[System.IO.Path]::GetFullPath([string]$target).ToLowerInvariant()] = $true
    }
    foreach ($item in @($Items)) {
        $target = [string](Get-RooIndustriesUninstallPropertyValue $item 'target' '')
        if ([string]::IsNullOrWhiteSpace($target)) { return $false }
        $full = [System.IO.Path]::GetFullPath($target).ToLowerInvariant()
        if (-not $allowed.ContainsKey($full)) { return $false }
    }
    return $true
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
    $itemId = [string](Get-RooIndustriesUninstallPropertyValue $Item 'itemId' '')
    $source = [System.IO.Path]::GetFullPath([string](Get-RooIndustriesUninstallPropertyValue $Item 'target' ''))
    $type = [string](Get-RooIndustriesUninstallPropertyValue $Item 'type' '')
    $destination = Join-Path $BackupRoot ([guid]::NewGuid().ToString('N'))
    Ensure-RooIndustriesUninstallDirectory (Split-Path $destination -Parent)

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
        Ensure-RooIndustriesUninstallDirectory (Split-Path $destination -Parent)
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
        deleteAttempted = $false
        deleted = $false
        reason = 'Copied before cleanup.'
    }
}

function Remove-ApplyPackageTarget {
    param([object]$Item)
    $target = [System.IO.Path]::GetFullPath([string](Get-RooIndustriesUninstallPropertyValue $Item 'target' ''))
    Assert-RooIndustriesCleanupExclusions @($target) -DataRoot $DataRoot
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
        return $true
    }
    return $false
}

function Read-ApprovalInput {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-RooIndustriesUninstallPath $Path $Path))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ data = ([System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json); sha256 = $hash }
}

$journal = $null
$lock = $null
$executionStarted = $false
$resolvedRollbackManifestPath = $null
$backupRecords = New-Object System.Collections.Generic.List[object]
$sequence = New-Object System.Collections.Generic.List[object]
$gates = @()
$errors = @()
$reused = $false
$canApply = $false
$appId = ''
$status = 'preview'
$officialInput = $null
$cleanupInput = $null
$items = @()
$reviewRequired = $true
$hasOfficialCommand = $false
try {
    $officialInput = Read-ApprovalInput $OfficialPreviewPath
    $cleanupInput = Read-ApprovalInput $CleanupManifestPath
    $officialPreview = $officialInput.data
    $cleanupManifest = $cleanupInput.data
    $appId = [string](Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'appId' '')
    $commands = @(Get-RooIndustriesUninstallPropertyArray $officialPreview 'commands')
    $command = if ($commands.Count -eq 1) { $commands[0] } else { $null }
    $items = @(Get-RooIndustriesUninstallPropertyArray $cleanupManifest 'items')
    $fileFolderItems = @($items | Where-Object { [string](Get-RooIndustriesUninstallPropertyValue $_ 'type' '') -in @('file','folder') })
    Assert-RooIndustriesCleanupExclusions @($fileFolderItems | ForEach-Object { [string]$_.target }) -DataRoot $DataRoot
    $unsupportedItems = @($items | Where-Object { [string](Get-RooIndustriesUninstallPropertyValue $_ 'type' '') -notin @('file','folder') })
    $reviewItems = @($items | Where-Object { [bool](Get-RooIndustriesUninstallPropertyValue $_ 'protected' $false) })
    $reviewRequired = [bool](Get-RooIndustriesUninstallPropertyValue $command 'reviewRequired' $true)
    $commandExecutable = [string](Get-RooIndustriesUninstallPropertyValue $command 'executable' '')
    $hasOfficialCommand = -not [string]::IsNullOrWhiteSpace($commandExecutable)
    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot) -and -not $AllowFixtureClaims) { throw 'A fixture claim root is accepted only by validation runs that pass AllowFixtureClaims.' }
    $claimRoot = if ([string]::IsNullOrWhiteSpace($FixtureRoot)) { '' } else { Assert-RooIndustriesBulkFixtureRoot $FixtureRoot }
    $argumentText = ''
    $commandLineReviewed = -not $hasOfficialCommand
    $executableReviewed = -not $hasOfficialCommand
    if ($hasOfficialCommand) {
        $commandExecutable = Resolve-RooIndustriesUninstallPath $commandExecutable $commandExecutable
        $argumentProperty = $command.PSObject.Properties['arguments']
        $argumentText = if ($null -ne $argumentProperty -and $argumentProperty.Value -is [System.Array]) { Join-RooIndustriesWindowsArguments ([string[]]@($argumentProperty.Value)) } elseif ($null -eq $argumentProperty) { '' } else { [string]$argumentProperty.Value }
        $reviewedCommandLine = [string](Get-RooIndustriesUninstallPropertyValue $command 'commandLine' '')
        $commandLineReviewed = -not [string]::IsNullOrWhiteSpace($reviewedCommandLine) -and (Get-RooIndustriesUninstallCommandLine $commandExecutable $argumentText) -ceq $reviewedCommandLine
        $reviewedExecutableSha256 = [string](Get-RooIndustriesUninstallPropertyValue $command 'executableSha256' '')
        $executableReviewed = -not [string]::IsNullOrWhiteSpace($reviewedExecutableSha256) -and -not (Test-RooIndustriesCleanupReparsePath $commandExecutable) -and (Get-RooIndustriesReviewedUninstallExecutableHash $commandExecutable) -ceq $reviewedExecutableSha256
    }
    if ($AllowFixtureClaims -and ([string]::IsNullOrWhiteSpace($claimRoot) -or ($hasOfficialCommand -and -not (Test-RooIndustriesCleanupPathWithin $commandExecutable $claimRoot)))) { throw 'Fixture claims apply only to removers inside the fixture root.' }
    $officialExecutableAllowlisted = (-not $hasOfficialCommand) -or (-not [string]::IsNullOrWhiteSpace($AllowedOfficialExecutablePath) -and $commandExecutable.Equals([System.IO.Path]::GetFullPath($AllowedOfficialExecutablePath), [System.StringComparison]::OrdinalIgnoreCase))
    $exactTargetsApproved = Test-ApplyPackageTargetAllowlist $fileFolderItems $ExactTargetAllowlist
    $resolvedBackupRoot = if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        Join-Path $(if ($DataRoot) { $DataRoot } else { Get-RooIndustriesLocalDataRoot -Protected }) ('cleanup-backups\' + [guid]::NewGuid().ToString('N'))
    } else { [System.IO.Path]::GetFullPath($BackupRoot) }
    $resolvedRollbackManifestPath = if ([string]::IsNullOrWhiteSpace($RollbackManifestPath)) { Join-Path $resolvedBackupRoot 'rollback-manifest.json' } else { [System.IO.Path]::GetFullPath($RollbackManifestPath) }
    $replayingSavedRun = $false
    if ($hasOfficialCommand -and (Test-Path -LiteralPath $resolvedRollbackManifestPath)) {
        try {
            $saved = Read-RooIndustriesUninstallJsonFile $resolvedRollbackManifestPath
            $replayingSavedRun = $saved.appId -ceq $appId -and $saved.officialPreviewSha256 -eq $officialInput.sha256 -and $saved.cleanupManifestSha256 -eq $cleanupInput.sha256
        } catch { $replayingSavedRun = $false }
    }

    $safeTargets = $true
    $ids = @{}
    $targets = @()
    foreach ($item in $fileFolderItems) {
        $id = [string](Get-RooIndustriesUninstallPropertyValue $item 'itemId' '')
        $target = [System.IO.Path]::GetFullPath([string](Get-RooIndustriesUninstallPropertyValue $item 'target' ''))
        if ([string]::IsNullOrWhiteSpace($id) -or $ids.ContainsKey($id)) { $safeTargets = $false }
        $ids[$id] = $true
        if ($target.TrimEnd('\','/') -eq [System.IO.Path]::GetPathRoot($target).TrimEnd('\','/')) { $safeTargets = $false }
        if (Test-RooIndustriesCleanupReparsePath $target -Recurse) { $safeTargets = $false }
        if ((Test-RooIndustriesCleanupPathWithin $resolvedBackupRoot $target) -or (Test-RooIndustriesCleanupPathWithin $resolvedRollbackManifestPath $target)) { $safeTargets = $false }
        foreach ($previous in $targets) {
            if ((Test-RooIndustriesCleanupPathWithin $target $previous) -or (Test-RooIndustriesCleanupPathWithin $previous $target)) { $safeTargets = $false }
        }
        if (Test-Path -LiteralPath $target) {
            $isFolder = (Get-Item -LiteralPath $target -Force).PSIsContainer
            if ($isFolder -ne ([string]$item.type -eq 'folder')) { $safeTargets = $false }
        }
        $targets += $target
    }
    if ((Test-RooIndustriesCleanupReparsePath $resolvedBackupRoot) -or (Test-RooIndustriesCleanupReparsePath $resolvedRollbackManifestPath)) { $safeTargets = $false }
    $inputErrors = @(Get-RooIndustriesUninstallPropertyArray $officialPreview 'errors') + @(Get-RooIndustriesUninstallPropertyArray $cleanupManifest 'errors')
    $sameApp = (-not [string]::IsNullOrWhiteSpace($appId)) -and $commands.Count -eq 1 -and ([string](Get-RooIndustriesUninstallPropertyValue $command 'appId' '') -ceq $appId) -and ($ApprovedAppId -ceq $appId)
    $gates = @(
        (New-ApplyPackageGate 'confirm-apply' 'Confirmed apply requested' $true ([bool]$ConfirmApply) 'Apply remains a dry run until confirmed.' $null),
        (New-ApplyPackageGate 'real-mode-selected' 'Real cleanup mode selected' $true ($ExecutorMode -eq 'Real') 'Preview mode removes nothing.' $null),
        (New-ApplyPackageGate 'official-route-reviewed' 'Removal route reviewed' $true ([bool]$OfficialUninstallCommandApproved) 'Review the exact removal route.' $null),
        (New-ApplyPackageGate 'cleanup-list-reviewed' 'Cleanup list reviewed' $true ([bool]$CleanupDeletionManifestApproved) 'Review the exact cleanup list.' $null),
        (New-ApplyPackageGate 'explicit-user-approval' 'Final approval captured' $true ([bool]$UserApproved) 'Approve this specific app and operation.' $null),
        (New-ApplyPackageGate 'real-system-flag' 'Real execution requested' $true ([bool]$AllowRealSystemExecution) 'Real execution requires its explicit flag.' $null),
        (New-ApplyPackageGate 'same-approved-app' 'App identity matches throughout' $true $sameApp 'Supply exactly one removal route belonging to ApprovedAppId and the cleanup manifest.' $null),
        (New-ApplyPackageGate 'reviewed-inputs-unchanged' 'Reviewed inputs are unchanged' $true ($OfficialPreviewSha256 -eq $officialInput.sha256 -and $CleanupManifestSha256 -eq $cleanupInput.sha256) 'Apply requires the SHA-256 hashes returned for the reviewed inputs.' $null),
        (New-ApplyPackageGate 'manual-review-approved' 'Dependency review completed' $true ((-not $reviewRequired) -or $ManualReviewApproved) 'Apps marked for review require explicit dependency review approval.' $null),
        (New-ApplyPackageGate 'valid-preview' 'Preview completed without errors' $true ($inputErrors.Count -eq 0 -and -not [bool](Get-RooIndustriesUninstallPropertyValue $command 'blocked' $true) -and -not [bool](Get-RooIndustriesUninstallPropertyValue $command 'protected' $true)) 'Failed, incomplete or protected routes cannot run.' $null),
        (New-ApplyPackageGate 'official-executable-allowlisted' 'Official executable approved' $true $officialExecutableAllowlisted 'The executable must match the allowlist exactly.' $null),
        (New-ApplyPackageGate 'reviewed-command-line' 'Reviewed remover command unchanged' $true $commandLineReviewed 'The remover runs only when the command it will start matches the reviewed command exactly.' $null),
        (New-ApplyPackageGate 'reviewed-executable-unchanged' 'Reviewed remover file unchanged' $true ($executableReviewed -or $replayingSavedRun) 'The remover runs only when its file still has the SHA-256 recorded at review.' $null),
        (New-ApplyPackageGate 'exact-target-allowlist' 'Exact cleanup targets approved' $true $exactTargetsApproved 'Every cleanup target must be on the exact allowlist.' $null),
        (New-ApplyPackageGate 'manual-review-items-excluded' 'Protected leftovers excluded' $true ($reviewItems.Count -eq 0) 'Protected leftovers require a separate workflow.' $null),
        (New-ApplyPackageGate 'supported-cleanup-types' 'Only files and folders selected' $true ($unsupportedItems.Count -eq 0) 'Registry, services and tasks remain outside this executor.' $null),
        (New-ApplyPackageGate 'safe-target-layout' 'Targets and recovery storage are separate' $true $safeTargets 'Reject duplicate IDs, overlapping targets, roots, reparse paths and backups inside deletion targets.' $null)
    )
    $canApply = @($gates | Where-Object { $_.blocking }).Count -eq 0
    $status = if ($canApply) { 'success' } elseif ($ConfirmApply -or $ExecutorMode -eq 'Real') { 'blocked' } else { 'preview' }
    if ($canApply) {
        Ensure-RooIndustriesUninstallDirectory (Split-Path $resolvedRollbackManifestPath -Parent)
        $lock = [System.IO.FileStream]::new($resolvedRollbackManifestPath + '.lock', [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::DeleteOnClose)
        if (Test-Path -LiteralPath $resolvedRollbackManifestPath) {
            $existing = Read-RooIndustriesUninstallJsonFile $resolvedRollbackManifestPath
            if ($existing.appId -cne $appId -or $existing.officialPreviewSha256 -ne $officialInput.sha256 -or $existing.cleanupManifestSha256 -ne $cleanupInput.sha256) { throw 'Recovery path already belongs to another operation.' }
            $journal = $existing
            $reused = $true
            $status = if ($journal.status -in @('success','cleanup-review-required','needs-reconciliation')) { $journal.status } else { 'partial' }
            $executionStarted = [bool]$journal.executionStarted
        } else {
            $journal = [pscustomobject]@{
                manifestId = 'cleanup-rollback-' + [guid]::NewGuid().ToString('N')
                schemaVersion = 1; productName = $script:RooIndustriesUninstallProductName; actionId = 'apps.rollbackCleanup'
                sourceManifestId = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'manifestId' $null
                appId = $appId; displayName = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'displayName' $null
                createdAtUtc = Get-RooIndustriesUninstallUtcStamp; fixtureRoot = ''; backupRoot = $resolvedBackupRoot
                restoreSupported = $true; realSystemRollback = $true; exactTargetAllowlist = @($targets)
                officialPreviewSha256 = $officialInput.sha256; cleanupManifestSha256 = $cleanupInput.sha256
                status = 'preparing'; executionStarted = $false; fileBackups = @(); deletedItems = @()
                officialRunnerAttempted = $false; officialRunnerCompleted = (-not $hasOfficialCommand); postUninstallReview = $null; officialOutcome = $null
            }
            Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath
            foreach ($item in @(if (-not $hasOfficialCommand) { $fileFolderItems })) {
                if (Test-RooIndustriesCleanupReparsePath ([string]$item.target) -Recurse) { throw 'A cleanup target changed to a reparse path.' }
                $backup = Copy-ApplyPackageBackup $item $resolvedBackupRoot
                if ($backup.copied) { $backupRecords.Add($backup) | Out-Null }
                $journal.fileBackups = @($backupRecords.ToArray())
                Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath
            }
            $journal.status = 'prepared'
            Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath
            if ($hasOfficialCommand) {
                $claimPath = Get-RooIndustriesBulkClaimPath ([pscustomobject]@{ appId = $appId }) $claimRoot
                try { $claimLease = Lock-RooIndustriesOperation $claimPath } catch [IO.IOException] { throw 'Another removal of this app is running right now. Let it finish, then try again.' }
                try {
                    if (Test-Path -LiteralPath $claimPath) {
                        $claim = (Read-RooIndustriesOperationJson $claimPath).data
                        if ([string](Get-RooIndustriesUninstallPropertyValue $claim 'kind' '') -ne 'cleanup-apply' -or (Test-RooIndustriesBulkClaimLive $claim)) {
                            throw 'An earlier removal of this app is still running or unresolved. Let it finish, then try again.'
                        }
                        Remove-Item -LiteralPath $claimPath -Force
                    }
                    $journal.officialRunnerAttempted = $true
                    $journal.executionStarted = $true
                    Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath
                    $executionStarted = $true
                    Write-RooIndustriesOperationJson ([pscustomobject]@{ kind = 'cleanup-apply'; appId = $appId; rollbackManifestPath = $resolvedRollbackManifestPath; launchConfirmed = $false; invocation = $null }) $claimPath
                    $executableLease = $null
                    try {
                        $executableLease = [IO.File]::Open($commandExecutable, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                        $sha = [Security.Cryptography.SHA256]::Create()
                        try { $digest = ([BitConverter]::ToString($sha.ComputeHash($executableLease))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
                        if ($digest -cne $reviewedExecutableSha256) { throw 'The remover file changed after review. Check the removal path again.' }
                        if (Test-RooIndustriesCleanupReparsePath $commandExecutable) { throw 'The remover is now reached through a link. Check the removal path again.' }
                        $officialResult = Invoke-RooIndustriesObservedRemover $commandExecutable $argumentText $OfficialRunnerWorkingDirectory $TimeoutSeconds {
                            param($invocation)
                            Write-RooIndustriesOperationJson ([pscustomobject]@{ kind = 'cleanup-apply'; appId = $appId; rollbackManifestPath = $resolvedRollbackManifestPath; launchConfirmed = [bool]$invocation.resumed; invocation = $invocation }) $claimPath
                            $journal | Add-Member -NotePropertyName officialInvocation -NotePropertyValue $invocation -Force
                            Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath
                        } $reviewedCommandLine $executableLease
                    } catch {
                        if ($null -eq (Get-RooIndustriesUninstallPropertyValue $journal 'officialInvocation' $null)) { Remove-Item -LiteralPath $claimPath -Force -ErrorAction SilentlyContinue }
                        throw
                    } finally {
                        if ($null -ne $executableLease) { $executableLease.Dispose() }
                    }
                    if (-not $officialResult.timedOut -and -not $officialResult.outputIncomplete -and (Test-Path -LiteralPath $claimPath)) { Remove-Item -LiteralPath $claimPath -Force }
                } finally { $claimLease.Dispose() }
                $sequence.Add([pscustomobject]@{ runner = 'official-uninstaller'; result = $officialResult }) | Out-Null
                $policy = if ([string](Get-RooIndustriesUninstallPropertyValue $command 'commandType' '') -eq 'msi-uninstall-string' -and [IO.Path]::GetFileName($commandExecutable) -ieq 'msiexec.exe') { 'windows-installer' } else { 'generic' }
                if ($officialResult.processStarted -and -not $officialResult.timedOut -and $null -ne $officialResult.exitCode) {
                    $journal.officialOutcome = Get-RooIndustriesUninstallOutcome $policy ([int]$officialResult.exitCode)
                }
                $journal.officialRunnerCompleted = ($null -ne $journal.officialOutcome -and $journal.officialOutcome.success -and -not $officialResult.outputIncomplete)
                Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath
                if ($officialResult.timedOut) {
                    $status = 'needs-reconciliation'
                    $errors = @((New-RooIndustriesUninstallIssue 'OFFICIAL_REMOVER_STILL_RUNNING' ([string]$officialResult.error) 'warning' 'apps.uninstallCleanupApplyPackage' $appId $true 'Let the app remover finish, then scan for leftovers again before cleaning up.' $null))
                } elseif ($officialResult.outputIncomplete) {
                    $status = 'needs-reconciliation'
                    $errors = @((New-RooIndustriesUninstallIssue 'OFFICIAL_REMOVER_STILL_RUNNING' 'The remover exited but its output did not finish. A process it started may still be running.' 'warning' 'apps.uninstallCleanupApplyPackage' $appId $true 'Let the app remover finish, then scan for leftovers again before cleaning up.' $null))
                } elseif (-not $officialResult.processStarted) { throw ('The remover could not be started: ' + [string]$(if ($officialResult.startError) { $officialResult.startError } else { $officialResult.error })) }
                elseif (-not $journal.officialRunnerCompleted) { throw 'The vendor remover failed; leftover cleanup was not started.' }
                else {
                    $journal.postUninstallReview = Get-RooIndustriesPostUninstallReview $fileFolderItems
                    $status = 'cleanup-review-required'
                }
            }
            foreach ($backup in $backupRecords) {
                if ((Test-RooIndustriesCleanupReparsePath $backup.source -Recurse) -or (Test-RooIndustriesCleanupReparsePath $backup.backupPath -Recurse)) { throw 'A cleanup or backup path changed to a reparse path.' }
                $backup.deleteAttempted = $true
                $journal.executionStarted = $true
                Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath
                $executionStarted = $true
                $backup.deleted = Remove-ApplyPackageTarget ([pscustomobject]@{ target = $backup.source })
                $journal.deletedItems = @($backupRecords.ToArray() | Where-Object { $_.deleted } | ForEach-Object { [pscustomobject]@{ itemId = $_.itemId; type = $_.type; target = $_.source; deleted = $true } })
                Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath
                $sequence.Add([pscustomobject]@{ runner = 'leftover-cleanup'; target = $backup.source; completed = $backup.deleted }) | Out-Null
            }
            $journal.status = $status
            Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath
        }
    }
} catch {
    $status = if ($executionStarted) { 'partial' } else { 'failed' }
    $errors = @((New-RooIndustriesUninstallIssue 'CLEANUP_APPLY_PACKAGE_FAILED' $_.Exception.Message 'error' 'apps.uninstallCleanupApplyPackage' $appId $true 'Inspect the recovery journal before retrying or restoring.' $null))
    if ($null -ne $journal -and -not $reused) {
        $journal.status = $status
        try { Write-RooIndustriesCleanupJournal $journal $resolvedRollbackManifestPath } catch { }
    }
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
$records = @(if ($null -ne $journal) { Get-RooIndustriesUninstallPropertyArray $journal 'fileBackups' })
$restoreReady = $executionStarted -and $null -ne $journal -and (Test-Path -LiteralPath $resolvedRollbackManifestPath) -and $records.Count -gt 0
$result = [pscustomobject]@{
    actionId = 'apps.invokeUninstallCleanupApplyPackage'; schemaVersion = 1; productName = $script:RooIndustriesUninstallProductName
    capturedAtUtc = Get-RooIndustriesUninstallUtcStamp; dryRun = (-not $executionStarted -and -not ($canApply -and $status -eq 'success')); status = $status; executionMode = $ExecutorMode.ToLowerInvariant()
    appId = $appId; gates = @($gates); executionSequence = @($sequence.ToArray()); executionReused = $reused
    approval = [pscustomobject]@{ appId = $appId; officialPreviewSha256 = Get-RooIndustriesUninstallPropertyValue $officialInput 'sha256' ''; cleanupManifestSha256 = Get-RooIndustriesUninstallPropertyValue $cleanupInput 'sha256' ''; reviewRequired = $reviewRequired }
    postUninstallReview = Get-RooIndustriesUninstallPropertyValue $journal 'postUninstallReview' $null
    rollback = [pscustomobject]@{ rollbackManifestPath = if ($null -ne $journal) { $resolvedRollbackManifestPath } else { $null }; rollbackSupported = $restoreReady; fileBackups = @($records) }
    summary = [pscustomobject]@{
        hasOfficialCommand = $hasOfficialCommand; rooIndustriesRouteUsed = (-not $hasOfficialCommand)
        officialRunnerAttempted = [bool](Get-RooIndustriesUninstallPropertyValue $journal 'officialRunnerAttempted' $false)
        officialRunnerCompleted = [bool](Get-RooIndustriesUninstallPropertyValue $journal 'officialRunnerCompleted' $false)
        cleanupItemCount = $items.Count; backupCount = $records.Count
        deletedCount = @($records | Where-Object { $_.deleted }).Count
        attemptedCleanupCount = @($records | Where-Object { $_.deleteAttempted }).Count
        blockingGateCount = @($gates | Where-Object { $_.blocking }).Count; restoreReady = $restoreReady
        approvalReady = @($gates | Where-Object { $_.blocking -and $_.gateId -notin @('confirm-apply','real-mode-selected','explicit-user-approval','real-system-flag') }).Count -eq 0
        willDeleteLeftovers = $canApply -and -not $reused -and -not $hasOfficialCommand; willChangeRegistry = $false; willChangeServices = $false; willChangeScheduledTasks = $false
    }
    warnings = @(); errors = @($errors); logs = @((New-RooIndustriesUninstallLog 'Cleanup operation evaluated.'))
}
Write-RooIndustriesUninstallJsonOutput $result $OutputPath
if ($status -in @('failed','partial')) { exit 1 }
