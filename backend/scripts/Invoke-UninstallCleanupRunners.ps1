param(
    [string]$OfficialPreviewPath = '',
    [string]$CleanupManifestPath = '',
    [ValidateSet('Preview','Mock','Real')]
    [string]$ExecutorMode = 'Preview',
    [string]$MockUninstallerShimPath = '',
    [string]$MockDeletionShimPath = '',
    [string]$AllowedOfficialExecutablePath = '',
    [string]$OfficialRunnerWorkingDirectory = '',
    [string]$CancellationSignalPath = '',
    [string[]]$ExactTargetAllowlist = @(),
    [string]$RollbackManifestPath = '',
    [int]$TimeoutSeconds = 30,
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$OfficialUninstallCommandApproved,
    [switch]$CleanupDeletionManifestApproved,
    [switch]$BackupsAndExportsCompleted,
    [switch]$UserApproved,
    [switch]$AllowRealSystemExecution
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')
. (Join-Path $PSScriptRoot 'BackendExecutor.Common.ps1')

function Resolve-RunnerJsonInput {
    param(
        [string]$Path,
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label path is required." }
    return Read-RooIndustriesUninstallJsonFile (Resolve-RooIndustriesUninstallPath $Path $Path)
}
function Test-ExactTargetAllowlist {
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

function Invoke-MockCleanupRunner {
    param(
        [string]$ShimPath,
        [string[]]$Arguments,
        [int]$Timeout
    )
    return Invoke-RooIndustriesBackendPowerShellShim -ShimPath $ShimPath -Arguments $Arguments -TimeoutSeconds $Timeout
}

function Get-OfficialRunnerArguments {
    param([object]$Command)
    $value = Get-RooIndustriesUninstallPropertyValue $Command 'arguments' $null
    if ($null -eq $value) { return @() }
    if ($value -is [System.Array]) { return @($value | ForEach-Object { [string]$_ }) }
    return @([string]$value)
}

function Test-RunnerPathInsideTemp {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Path).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

try {
    $officialPreview = Resolve-RunnerJsonInput $OfficialPreviewPath 'Official preview'
    $cleanupManifest = Resolve-RunnerJsonInput $CleanupManifestPath 'Cleanup manifest'
    $commands = @(Get-RooIndustriesUninstallPropertyArray $officialPreview 'commands')
    $command = if ($commands.Count -gt 0) { $commands[0] } else { $null }
    $items = @(Get-RooIndustriesUninstallPropertyArray $cleanupManifest 'items')
    $protectedItems = @($items | Where-Object { [bool](Get-RooIndustriesUninstallPropertyValue $_ 'protected' $false) })
    $unsupportedItems = @($items | Where-Object { [string](Get-RooIndustriesUninstallPropertyValue $_ 'type' '') -notin @('file','folder','registryKey','registryValue','service','scheduledTask','startupEntry') })
    $mockMode = ($ExecutorMode -eq 'Mock')
    $realMode = ($ExecutorMode -eq 'Real')
    $executeRequested = ($ExecutorMode -ne 'Preview')
    $mockUninstallerPresent = (-not [string]::IsNullOrWhiteSpace($MockUninstallerShimPath) -and (Test-Path -LiteralPath (Resolve-RooIndustriesPath $MockUninstallerShimPath $MockUninstallerShimPath)))
    $mockDeletionPresent = (-not [string]::IsNullOrWhiteSpace($MockDeletionShimPath) -and (Test-Path -LiteralPath (Resolve-RooIndustriesPath $MockDeletionShimPath $MockDeletionShimPath)))
    $commandExecutable = if ($command) { Resolve-RooIndustriesUninstallPath ([string](Get-RooIndustriesUninstallPropertyValue $command 'executable' '')) ([string](Get-RooIndustriesUninstallPropertyValue $command 'executable' '')) } else { '' }
    $allowedOfficialExecutable = if ([string]::IsNullOrWhiteSpace($AllowedOfficialExecutablePath)) { '' } else { Resolve-RooIndustriesUninstallPath $AllowedOfficialExecutablePath $AllowedOfficialExecutablePath }
    $officialRunnerWorkingDirectory = if ([string]::IsNullOrWhiteSpace($OfficialRunnerWorkingDirectory)) { '' } else { [System.IO.Path]::GetFullPath($OfficialRunnerWorkingDirectory) }
    $officialExecutableAllowlisted = (-not [string]::IsNullOrWhiteSpace($commandExecutable) -and -not [string]::IsNullOrWhiteSpace($allowedOfficialExecutable) -and [System.IO.Path]::GetFullPath($commandExecutable).Equals([System.IO.Path]::GetFullPath($allowedOfficialExecutable), [System.StringComparison]::OrdinalIgnoreCase))
    $cancellationRequested = (-not [string]::IsNullOrWhiteSpace($CancellationSignalPath) -and (Test-Path -LiteralPath (Resolve-RooIndustriesUninstallPath $CancellationSignalPath $CancellationSignalPath)))
    $workingDirectorySafe = Test-RunnerPathInsideTemp $officialRunnerWorkingDirectory
    $exactTargetsApproved = Test-ExactTargetAllowlist $items $ExactTargetAllowlist

    $gates = @(
        (New-RooIndustriesBackendExecutorGate 'confirm-apply' 'Confirmed execution requested' $true ([bool]$ConfirmApply) 'Runner execution remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooIndustriesBackendExecutorGate 'executor-mode-selected' 'Executor mode selected' $true $executeRequested 'ExecutorMode must be Mock or Real to run runner commands.' ([pscustomobject]@{ executorMode = $ExecutorMode })),
        (New-RooIndustriesBackendExecutorGate 'official-command-approved' 'Official uninstall command approved' $true ([bool]$OfficialUninstallCommandApproved) 'Official uninstall command must be reviewed and approved.' ([pscustomobject]@{ commandPreviewCount = $commands.Count })),
        (New-RooIndustriesBackendExecutorGate 'cleanup-manifest-approved' 'Cleanup deletion manifest approved' $true ([bool]$CleanupDeletionManifestApproved) 'Leftover deletion manifest must be reviewed and approved.' ([pscustomobject]@{ manifestId = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'manifestId' $null })),
        (New-RooIndustriesBackendExecutorGate 'backups-exports-complete' 'Backups and exports completed' $true ([bool]$BackupsAndExportsCompleted) 'All file backups, registry exports, service state exports, task exports, and startup exports must complete before deletion.' $null),
        (New-RooIndustriesBackendExecutorGate 'explicit-user-approval' 'Explicit user approval evidence captured' $true ([bool]$UserApproved) 'Execution requires user approval evidence for the exact app, command, manifest, and target allowlist.' $null),
        (New-RooIndustriesBackendExecutorGate 'exact-target-allowlist' 'Exact target allowlist covers all leftover items' $true $exactTargetsApproved 'Every leftover target must match the exact allowlist.' ([pscustomobject]@{ allowlistCount = @(Get-RooIndustriesUninstallArray $ExactTargetAllowlist).Count; itemCount = $items.Count })),
        (New-RooIndustriesBackendExecutorGate 'protected-items-excluded' 'Protected items excluded' $true ($protectedItems.Count -eq 0) 'Protected leftover items cannot be passed to runners.' ([pscustomobject]@{ protectedItemCount = $protectedItems.Count })),
        (New-RooIndustriesBackendExecutorGate 'supported-item-types' 'Runner item types supported' $true ($unsupportedItems.Count -eq 0) 'Unsupported leftover item types cannot be passed to runners.' ([pscustomobject]@{ unsupportedItemCount = $unsupportedItems.Count })),
        (New-RooIndustriesBackendExecutorGate 'mock-uninstaller-shim-present' 'Mock uninstaller shim present' $mockMode ((-not $mockMode) -or $mockUninstallerPresent) 'Mock official uninstaller validation requires a shim path.' ([pscustomobject]@{ mockUninstallerShimPath = $MockUninstallerShimPath })),
        (New-RooIndustriesBackendExecutorGate 'mock-deletion-shim-present' 'Mock leftover deletion shim present' $mockMode ((-not $mockMode) -or $mockDeletionPresent) 'Mock leftover deletion validation requires a shim path.' ([pscustomobject]@{ mockDeletionShimPath = $MockDeletionShimPath })),
        (New-RooIndustriesBackendExecutorGate 'real-system-explicit-flag' 'Real-system explicit flag supplied' $realMode ((-not $realMode) -or [bool]$AllowRealSystemExecution) 'Real uninstall and cleanup runners require -AllowRealSystemExecution beyond confirmation.' $null),
        (New-RooIndustriesBackendExecutorGate 'official-executable-allowlist' 'Official executable exactly allowlisted' $realMode ((-not $realMode) -or $officialExecutableAllowlisted) 'Real runner mode requires the preview command executable to match the exact allowlist path.' ([pscustomobject]@{ commandExecutable = $commandExecutable; allowedOfficialExecutablePath = $allowedOfficialExecutable })),
        (New-RooIndustriesBackendExecutorGate 'official-runner-working-directory-safe' 'Official runner working directory isolated' $realMode ((-not $realMode) -or $workingDirectorySafe) 'Official runner working directory must be empty or under temp during validation.' ([pscustomobject]@{ workingDirectory = $officialRunnerWorkingDirectory })),
        (New-RooIndustriesBackendExecutorGate 'cancellation-not-requested' 'Cancellation signal absent' $realMode ((-not $realMode) -or -not $cancellationRequested) 'Cancellation signal prevents official runner start.' ([pscustomobject]@{ cancellationSignalPath = $CancellationSignalPath })),
        (New-RooIndustriesBackendExecutorGate 'real-system-runner-implemented' 'Real-system runner implemented' $realMode $true 'Real runner path is implemented behind exact executable, approval, backup/export, timeout, cancellation, and log-capture gates.' $null)
    )
    $blockingGates = @($gates | Where-Object { $_.blocking })
    $canExecute = ($blockingGates.Count -eq 0)
    $sequence = New-Object System.Collections.Generic.List[object]
    $status = if ($canExecute) { 'success' } elseif ($ConfirmApply -or $executeRequested) { 'blocked' } else { 'preview' }
    $uninstallCompleted = $false

    if ($canExecute -and $mockMode) {
        $uninstallArgs = @(
            'official-uninstall',
            [string](Get-RooIndustriesUninstallPropertyValue $command 'appId' ''),
            [string](Get-RooIndustriesUninstallPropertyValue $command 'rawCommand' '')
        )
        $uninstallResult = Invoke-MockCleanupRunner -ShimPath $MockUninstallerShimPath -Arguments $uninstallArgs -Timeout $TimeoutSeconds
        $uninstallCompleted = ((-not [bool](Get-RooIndustriesPropertyValue $uninstallResult 'timedOut' $false)) -and [int](Get-RooIndustriesPropertyValue $uninstallResult 'exitCode' -1) -eq 0)
        $sequence.Add([pscustomobject]@{
            order = 1
            runner = 'official-uninstaller'
            appId = [string](Get-RooIndustriesUninstallPropertyValue $command 'appId' '')
            rawCommand = Get-RooIndustriesUninstallPropertyValue $command 'rawCommand' $null
            result = $uninstallResult
            completed = $uninstallCompleted
        }) | Out-Null
        if ($uninstallCompleted) {
            $order = 2
            foreach ($item in $items) {
                $deleteArgs = @(
                    'leftover-delete',
                    [string](Get-RooIndustriesUninstallPropertyValue $item 'itemId' ''),
                    [string](Get-RooIndustriesUninstallPropertyValue $item 'type' ''),
                    [string](Get-RooIndustriesUninstallPropertyValue $item 'target' '')
                )
                $deleteResult = Invoke-MockCleanupRunner -ShimPath $MockDeletionShimPath -Arguments $deleteArgs -Timeout $TimeoutSeconds
                $deleteCompleted = ((-not [bool](Get-RooIndustriesPropertyValue $deleteResult 'timedOut' $false)) -and [int](Get-RooIndustriesPropertyValue $deleteResult 'exitCode' -1) -eq 0)
                if (-not $deleteCompleted) { $status = 'failed' }
                $sequence.Add([pscustomobject]@{
                    order = $order
                    runner = 'leftover-deletion'
                    itemId = [string](Get-RooIndustriesUninstallPropertyValue $item 'itemId' '')
                    type = [string](Get-RooIndustriesUninstallPropertyValue $item 'type' '')
                    target = [string](Get-RooIndustriesUninstallPropertyValue $item 'target' '')
                    result = $deleteResult
                    completed = $deleteCompleted
                }) | Out-Null
                $order++
            }
        } else {
            $status = 'failed'
            $sequence.Add([pscustomobject]@{
                order = 2
                runner = 'leftover-deletion'
                skipped = $true
                reason = 'Official uninstall runner failed or timed out; leftover deletion runners were not attempted.'
            }) | Out-Null
        }
    } elseif ($canExecute -and $realMode) {
        $officialArgs = Get-OfficialRunnerArguments $command
        $officialResult = Invoke-RooIndustriesBackendHiddenProcess -FilePath $commandExecutable -Arguments $officialArgs -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $officialRunnerWorkingDirectory
        $uninstallCompleted = ((-not [bool](Get-RooIndustriesPropertyValue $officialResult 'timedOut' $false)) -and [int](Get-RooIndustriesPropertyValue $officialResult 'exitCode' -1) -eq 0)
        if (-not $uninstallCompleted) { $status = 'failed' }
        $sequence.Add([pscustomobject]@{
            order = 1
            runner = 'official-uninstaller'
            runnerMode = 'real-controlled-process'
            appId = [string](Get-RooIndustriesUninstallPropertyValue $command 'appId' '')
            rawCommand = Get-RooIndustriesUninstallPropertyValue $command 'rawCommand' $null
            executable = $commandExecutable
            arguments = @($officialArgs)
            result = $officialResult
            completed = $uninstallCompleted
        }) | Out-Null
    }

    $runs = @($sequence.ToArray())
    $rollbackManifest = [pscustomobject]@{
        manifestId = 'cleanup-runner-rollback-' + (ConvertTo-RooIndustriesStableId ([string](Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'appId' 'app'))) + '-' + (Get-RooIndustriesUninstallFileStamp)
        schemaVersion = 1
        productName = $script:RooIndustriesUninstallProductName
        actionId = 'apps.rollbackCleanup'
        appId = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'appId' $null
        sourceManifestId = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'manifestId' $null
        createdAtUtc = Get-RooIndustriesUninstallUtcStamp
        realSystemRollback = $false
        exactTargetAllowlist = @(Get-RooIndustriesUninstallArray $ExactTargetAllowlist)
        backupExportEvidence = [pscustomobject]@{
            backupsAndExportsCompleted = [bool]$BackupsAndExportsCompleted
            sourceRollback = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'rollback' $null
        }
        runnerResults = $runs
    }
    $resolvedRollbackManifestPath = $null
    if ($canExecute -and -not [string]::IsNullOrWhiteSpace($RollbackManifestPath)) {
        $resolvedRollbackManifestPath = Resolve-RooIndustriesUninstallPath $RollbackManifestPath $RollbackManifestPath
        Ensure-RooIndustriesUninstallDirectory (Split-Path $resolvedRollbackManifestPath -Parent)
        ($rollbackManifest | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $resolvedRollbackManifestPath -Encoding UTF8
    }

    $result = [pscustomobject]@{
        actionId = 'apps.invokeUninstallCleanupRunners'
        schemaVersion = 1
        productName = $script:RooIndustriesUninstallProductName
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = (-not $canExecute)
        status = $status
        executionMode = $ExecutorMode.ToLowerInvariant()
        appId = Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'appId' $null
        gates = @($gates)
        executionSequence = $runs
        rollbackManifest = $rollbackManifest
        rollbackManifestPath = $resolvedRollbackManifestPath
        capabilities = [pscustomobject]@{
            officialUninstallerRunnerImplemented = $true
            leftoverDeletionRunnerImplemented = $true
            mockRunnerImplemented = $true
            realSystemRunnerImplemented = $true
            realRunnerRequiresExactExecutableAllowlist = $true
            realAppUninstallPreventedByAllowlist = $true
            fixtureDeletionStillSupported = $true
        }
        summary = [pscustomobject]@{
            willRunMockRunner = ($canExecute -and $mockMode)
            willRunRealUninstaller = ($canExecute -and $realMode)
            willDeleteRealLeftovers = $false
            officialRunnerAttempted = @($runs | Where-Object { $_.runner -eq 'official-uninstaller' }).Count -gt 0
            officialRunnerCompleted = $uninstallCompleted
            leftoverRunnerAttemptedCount = @($runs | Where-Object { $_.runner -eq 'leftover-deletion' -and -not $_.skipped }).Count
            leftoverRunnerCompletedCount = @($runs | Where-Object { $_.runner -eq 'leftover-deletion' -and $_.completed -eq $true }).Count
            leftoverRunnerSkippedUntilOfficialUninstallSucceeded = @($runs | Where-Object { $_.runner -eq 'leftover-deletion' -and $_.skipped }).Count -gt 0
            cancellationRequested = $cancellationRequested
            timeoutCount = @($runs | Where-Object { $_.result.timedOut -eq $true }).Count
            nonZeroExitCount = @($runs | Where-Object { $null -ne $_.result.exitCode -and [int]$_.result.exitCode -ne 0 }).Count
            focusStealPrevented = (@($runs | Where-Object { $_.result.invocation.focusStealPrevented -eq $false }).Count -eq 0)
            blockingGateCount = $blockingGates.Count
        }
        warnings = @((New-RooIndustriesUninstallIssue 'CLEANUP_RUNNERS_CONTROLLED' 'Cleanup runner abstraction evaluated with mock runners or the real controlled official process runner.' 'info' 'apps.uninstallCleanupRunners' (Get-RooIndustriesUninstallPropertyValue $cleanupManifest 'appId' $null) $false 'Use exact executable allowlists and backup/export evidence before real runner mode.' $null))
        errors = @()
        logs = @((New-RooIndustriesUninstallLog 'Uninstall cleanup runner abstraction completed.'))
    }
    Write-RooIndustriesUninstallJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'apps.invokeUninstallCleanupRunners'
        schemaVersion = 1
        productName = $script:RooIndustriesUninstallProductName
        capturedAtUtc = Get-RooIndustriesUninstallUtcStamp
        dryRun = $true
        status = 'failed'
        executionMode = $ExecutorMode.ToLowerInvariant()
        executionSequence = @()
        summary = [pscustomobject]@{ willRunMockRunner = $false; willRunRealUninstaller = $false; willDeleteRealLeftovers = $false }
        warnings = @()
        errors = @((New-RooIndustriesUninstallIssue 'CLEANUP_RUNNERS_FAILED' $_.Exception.Message 'error' 'apps.uninstallCleanupRunners' $null $true 'Check runner inputs, mock shims, approval gates, and target allowlist.' $null))
        logs = @((New-RooIndustriesUninstallLog 'Uninstall cleanup runner abstraction failed.' 'error'))
    }
    Write-RooIndustriesUninstallJsonOutput $errorResult $OutputPath
    exit 1
}
