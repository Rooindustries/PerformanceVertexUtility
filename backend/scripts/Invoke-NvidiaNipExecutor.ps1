param(
    [ValidateSet('Apply','Restore')]
    [string]$Operation = 'Apply',
    [string]$ProfileId = 'framesync',
    [string]$CatalogPath = '',
    [string]$HardwareInventoryPath = '',
    [string]$NvpiExecutablePath = '',
    [string]$NipSourcePath = '',
    [string]$ExportPath = '',
    [string]$RollbackManifestPath = '',
    [ValidateSet('Preview','Mock','Real')]
    [string]$ExecutorMode = 'Preview',
    [string]$MockNvpiShimPath = '',
    [int]$TimeoutSeconds = 15,
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowRealNvpiExecution,
    [switch]$UserApproved,
    [switch]$BenchmarkEvidenceAttached
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NvidiaNip.Common.ps1')
. (Join-Path $PSScriptRoot 'BackendExecutor.Common.ps1')

function Invoke-NvidiaExecutorCommand {
    param(
        [object]$Command,
        [string]$Mode,
        [string]$MockShim,
        [int]$Timeout
    )
    $arguments = @(Get-RooIndustriesPropertyArray $Command 'arguments')
    if ($Mode -eq 'Mock') {
        return Invoke-RooIndustriesBackendPowerShellShim -ShimPath $MockShim -Arguments $arguments -TimeoutSeconds $Timeout
    }
    if ($Mode -eq 'Real') {
        return Invoke-RooIndustriesBackendHiddenProcess -FilePath ([string](Get-RooIndustriesPropertyValue $Command 'executablePath' '')) -Arguments $arguments -TimeoutSeconds $Timeout
    }
    return [pscustomobject]@{
        processStarted = $false
        exitCode = $null
        timedOut = $false
        timeoutSeconds = $Timeout
        arguments = $arguments
        commandLine = Get-RooIndustriesPropertyValue $Command 'commandLine' $null
        invocation = [pscustomobject]@{
            useShellExecute = $false
            createNoWindow = $true
            windowStyle = 'Hidden'
            focusStealPrevented = $true
            redirectedOutput = $true
        }
    }
}

function Write-NvidiaRollbackManifest {
    param(
        [object]$Manifest,
        [string]$Path,
        [bool]$ExportCompleted,
        [bool]$ImportAttempted,
        [bool]$ImportCompleted,
        [bool]$RealExecution
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $resolved = Resolve-RooIndustriesPath $Path $Path
    Ensure-RooIndustriesDirectory (Split-Path $resolved -Parent)
    $Manifest.exportCompleted = $ExportCompleted
    $Manifest.importAttempted = $ImportAttempted
    $Manifest.importCompleted = $ImportCompleted
    $Manifest.nvpiExecutionAllowedNow = $RealExecution
    $temporary = $resolved + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        ($Manifest | ConvertTo-Json -Depth 24) | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $resolved -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

try {
    $persistedRollbackManifest = $null
    $resolvedRequestedRollbackManifestPath = $null
    $rollbackManifestBound = $false
    $rollbackExportPresent = $false
    if ($Operation -eq 'Restore' -and -not [string]::IsNullOrWhiteSpace($RollbackManifestPath)) {
        $resolvedRequestedRollbackManifestPath = Resolve-RooIndustriesPath $RollbackManifestPath $RollbackManifestPath
        if (Test-Path -LiteralPath $resolvedRequestedRollbackManifestPath) {
            $persistedRollbackManifest = Read-RooIndustriesJsonFile $resolvedRequestedRollbackManifestPath
            $manifestExportPath = [string](Get-RooIndustriesPropertyValue $persistedRollbackManifest 'exportPath' '')
            $rollbackManifestBound = (
                [string](Get-RooIndustriesPropertyValue $persistedRollbackManifest 'actionId' '') -ceq 'drivers.nvidiaNip.rollbackManifest' -and
                [string](Get-RooIndustriesPropertyValue $persistedRollbackManifest 'restoreActionId' '') -ceq 'drivers.nvidiaNip.restoreProfile' -and
                [string](Get-RooIndustriesPropertyValue $persistedRollbackManifest 'profileId' '') -ceq $ProfileId -and
                [bool](Get-RooIndustriesPropertyValue $persistedRollbackManifest 'rollbackSupported' $false) -and
                [bool](Get-RooIndustriesPropertyValue $persistedRollbackManifest 'exportCompleted' $false) -and
                -not [string]::IsNullOrWhiteSpace($manifestExportPath) -and
                ([string]::IsNullOrWhiteSpace($ExportPath) -or (Resolve-RooIndustriesPath $ExportPath $ExportPath) -ceq (Resolve-RooIndustriesPath $manifestExportPath $manifestExportPath))
            )
            if ([string]::IsNullOrWhiteSpace($ExportPath)) { $ExportPath = $manifestExportPath }
            $rollbackExportPresent = $rollbackManifestBound -and (Test-Path -LiteralPath (Resolve-RooIndustriesPath $manifestExportPath $manifestExportPath))
        }
    }

    $preview = (& (Join-Path $PSScriptRoot 'Preview-NvidiaNipProfile.ps1') `
        -ProfileId $ProfileId `
        -CatalogPath $CatalogPath `
        -HardwareInventoryPath $HardwareInventoryPath `
        -NvpiExecutablePath $NvpiExecutablePath `
        -NipSourcePath $NipSourcePath `
        -ExportPath $ExportPath) | ConvertFrom-Json

    $commands = Get-RooIndustriesPropertyValue $preview 'commands' $null
    $rollbackManifest = if ($Operation -eq 'Restore' -and $null -ne $persistedRollbackManifest) { $persistedRollbackManifest } else { Get-RooIndustriesPropertyValue $preview 'rollbackManifest' $null }
    if ($Operation -eq 'Restore') {
        $effectiveRestoreExportPath = if ([string]::IsNullOrWhiteSpace($ExportPath)) { [string](Get-RooIndustriesPropertyValue $rollbackManifest 'exportPath' '') } else { $ExportPath }
        $restorePreview = (& (Join-Path $PSScriptRoot 'Restore-NvidiaNipProfile.ps1') `
            -ProfileId $ProfileId `
            -CatalogPath $CatalogPath `
            -HardwareInventoryPath $HardwareInventoryPath `
            -NvpiExecutablePath $NvpiExecutablePath `
            -RollbackManifestPath $resolvedRequestedRollbackManifestPath `
            -ExportPath $effectiveRestoreExportPath) | ConvertFrom-Json
    }

    $hardwareSatisfied = [bool](Get-RooIndustriesPropertyValue (Get-RooIndustriesPropertyValue $preview 'hardwareGate' $null) 'nvidiaGpuPresent' $false)
    $mockShimPresent = (-not [string]::IsNullOrWhiteSpace($MockNvpiShimPath) -and (Test-Path -LiteralPath (Resolve-RooIndustriesPath $MockNvpiShimPath $MockNvpiShimPath)))
    $realMode = ($ExecutorMode -eq 'Real')
    $mockMode = ($ExecutorMode -eq 'Mock')
    $executeRequested = ($ExecutorMode -ne 'Preview')
    $gates = @(
        (New-RooIndustriesBackendExecutorGate 'confirm-apply' 'Confirmed execution requested' $true ([bool]$ConfirmApply) 'Executor will not run from preview-only calls.' $null),
        (New-RooIndustriesBackendExecutorGate 'executor-mode-selected' 'Executor mode selected' $true $executeRequested 'ExecutorMode must be Mock or Real to run commands.' ([pscustomobject]@{ executorMode = $ExecutorMode })),
        (New-RooIndustriesBackendExecutorGate 'nvidia-hardware-present' 'NVIDIA hardware detected' $true $hardwareSatisfied 'NIP execution is NVIDIA-only.' (Get-RooIndustriesPropertyValue $preview 'hardwareGate' $null)),
        (New-RooIndustriesBackendExecutorGate 'explicit-user-approval' 'Explicit approval evidence captured' $true ([bool]$UserApproved) 'Execution requires user approval evidence for the exact profile.' $null),
        (New-RooIndustriesBackendExecutorGate 'no-auto-apply' 'No auto-apply path used' $true ($ConfirmApply -and $executeRequested) 'Default invocation remains preview-only.' ([pscustomobject]@{ confirmApply = [bool]$ConfirmApply; executorMode = $ExecutorMode })),
        (New-RooIndustriesBackendExecutorGate 'mock-shim-present' 'Mock NVPI shim present' $mockMode ((-not $mockMode) -or $mockShimPresent) 'Mock validation requires a shim path.' ([pscustomobject]@{ mockNvpiShimPath = $MockNvpiShimPath })),
        (New-RooIndustriesBackendExecutorGate 'real-nvpi-explicit-flag' 'Real NVPI explicit flag supplied' $realMode ((-not $realMode) -or [bool]$AllowRealNvpiExecution) 'Real NVIDIA Profile Inspector execution requires -AllowRealNvpiExecution in addition to confirmation.' $null),
        (New-RooIndustriesBackendExecutorGate 'benchmark-evidence' 'Benchmark evidence attached' ($Operation -eq 'Apply') (($Operation -ne 'Apply') -or [bool]$BenchmarkEvidenceAttached) 'Profile apply requires benchmark evidence before recommendation.' $null),
        (New-RooIndustriesBackendExecutorGate 'rollback-manifest-bound' 'Rollback manifest matches this profile' ($Operation -eq 'Restore') (($Operation -ne 'Restore') -or $rollbackManifestBound) 'Restore requires the exact rollback manifest written by the selected profile apply.' ([pscustomobject]@{ rollbackManifestPath = $resolvedRequestedRollbackManifestPath })),
        (New-RooIndustriesBackendExecutorGate 'rollback-export-present' 'Rollback export is present' ($Operation -eq 'Restore') (($Operation -ne 'Restore') -or $rollbackExportPresent) 'Restore requires the exported profile named by the rollback manifest.' ([pscustomobject]@{ exportPath = $ExportPath }))
    )
    $blockingGates = @($gates | Where-Object { $_.blocking })
    $canExecute = ($blockingGates.Count -eq 0)
    $sequence = New-Object System.Collections.Generic.List[object]
    $status = if ($canExecute) { 'success' } elseif ($ConfirmApply -or $executeRequested) { 'blocked' } else { 'preview' }
    $exportCompleted = $false
    $importCompleted = $false

    if ($canExecute -and $Operation -eq 'Apply') {
        $exportCommand = Get-RooIndustriesPropertyValue $commands 'exportCurrentProfile' $null
        $exportTarget = [string]@(Get-RooIndustriesPropertyArray $exportCommand 'arguments')[2]
        $resolvedExportTarget = if ([string]::IsNullOrWhiteSpace($exportTarget)) { '' } else { Resolve-RooIndustriesPath $exportTarget $exportTarget }
        if ([string]::IsNullOrWhiteSpace($exportTarget) -or (Test-Path -LiteralPath $resolvedExportTarget)) {
            $status = 'failed'
            $sequence.Add([pscustomobject]@{
                order = 1
                operation = 'import'
                skipped = $true
                reason = 'The rollback export path already exists, so an older file cannot stand in for this export. Choose a new export path; import was not attempted.'
            }) | Out-Null
        } else {
            $exportResult = Invoke-NvidiaExecutorCommand -Command $exportCommand -Mode $ExecutorMode -MockShim $MockNvpiShimPath -Timeout $TimeoutSeconds
            $exportFileReady = (Test-Path -LiteralPath $resolvedExportTarget -PathType Leaf) -and (Get-Item -LiteralPath $resolvedExportTarget -Force).Length -gt 0
            $exportProcessSucceeded = ((-not [bool](Get-RooIndustriesPropertyValue $exportResult 'timedOut' $false)) -and [int](Get-RooIndustriesPropertyValue $exportResult 'exitCode' -1) -eq 0)
            $exportCompleted = $exportProcessSucceeded -and $exportFileReady
            $sequence.Add([pscustomobject]@{
                order = 1
                operation = 'export'
                command = $exportCommand
                result = $exportResult
                completed = $exportCompleted
                exportFileVerified = $exportFileReady
            }) | Out-Null
            if ($exportCompleted) {
                Write-NvidiaRollbackManifest -Manifest $rollbackManifest -Path $RollbackManifestPath -ExportCompleted $true -ImportAttempted $true -ImportCompleted $false -RealExecution ($ExecutorMode -eq 'Real')
                $importCommand = Get-RooIndustriesPropertyValue $commands 'importCandidateProfile' $null
                $importResult = Invoke-NvidiaExecutorCommand -Command $importCommand -Mode $ExecutorMode -MockShim $MockNvpiShimPath -Timeout $TimeoutSeconds
                $importCompleted = ((-not [bool](Get-RooIndustriesPropertyValue $importResult 'timedOut' $false)) -and [int](Get-RooIndustriesPropertyValue $importResult 'exitCode' -1) -eq 0)
                $sequence.Add([pscustomobject]@{
                    order = 2
                    operation = 'import'
                    command = $importCommand
                    result = $importResult
                    completed = $importCompleted
                }) | Out-Null
                if (-not $importCompleted) { $status = 'failed' }
            } else {
                $status = 'failed'
                $sequence.Add([pscustomobject]@{
                    order = 2
                    operation = 'import'
                    skipped = $true
                    reason = if ($exportProcessSucceeded) { 'Export finished without writing a usable rollback file; import was not attempted.' } else { 'Export failed or timed out; import was not attempted.' }
                }) | Out-Null
            }
        }
    } elseif ($canExecute -and $Operation -eq 'Restore') {
        $restoreCommand = Get-RooIndustriesPropertyValue $restorePreview 'command' $null
        $restoreResult = Invoke-NvidiaExecutorCommand -Command $restoreCommand -Mode $ExecutorMode -MockShim $MockNvpiShimPath -Timeout $TimeoutSeconds
        $importCompleted = ((-not [bool](Get-RooIndustriesPropertyValue $restoreResult 'timedOut' $false)) -and [int](Get-RooIndustriesPropertyValue $restoreResult 'exitCode' -1) -eq 0)
        $sequence.Add([pscustomobject]@{
            order = 1
            operation = 'restore-import'
            command = $restoreCommand
            result = $restoreResult
            completed = $importCompleted
        }) | Out-Null
        if (-not $importCompleted) { $status = 'failed' }
    }

    if ($Operation -eq 'Apply' -and $canExecute -and -not [string]::IsNullOrWhiteSpace($RollbackManifestPath)) {
        $resolvedRollbackManifestPath = Resolve-RooIndustriesPath $RollbackManifestPath $RollbackManifestPath
        Write-NvidiaRollbackManifest -Manifest $rollbackManifest -Path $resolvedRollbackManifestPath -ExportCompleted $exportCompleted -ImportAttempted (@($sequence | Where-Object { $_.operation -eq 'import' -and -not $_.skipped }).Count -gt 0) -ImportCompleted $importCompleted -RealExecution ($ExecutorMode -eq 'Real')
    } elseif ($Operation -eq 'Restore' -and $rollbackManifestBound) {
        $resolvedRollbackManifestPath = $resolvedRequestedRollbackManifestPath
    } else {
        $resolvedRollbackManifestPath = $null
    }

    $runs = @($sequence.ToArray())
    $result = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.executor'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        operation = $Operation
        profileId = $ProfileId
        dryRun = (-not $canExecute)
        status = $status
        executionMode = $ExecutorMode.ToLowerInvariant()
        preview = $preview
        gates = @($gates)
        executionSequence = $runs
        rollbackManifest = $rollbackManifest
        rollbackManifestPath = $resolvedRollbackManifestPath
        summary = [pscustomobject]@{
            willRunNvpi = ($canExecute -and $ExecutorMode -eq 'Real')
            willRunMockShim = ($canExecute -and $ExecutorMode -eq 'Mock')
            realNvpiInvoked = ($canExecute -and $ExecutorMode -eq 'Real')
            exportAttempted = @($runs | Where-Object { $_.operation -eq 'export' }).Count -gt 0
            exportCompleted = $exportCompleted
            importAttempted = @($runs | Where-Object { $_.operation -in @('import','restore-import') -and -not $_.skipped }).Count -gt 0
            importCompleted = $importCompleted
            importSkippedUntilExportSucceeded = @($runs | Where-Object { $_.operation -eq 'import' -and $_.skipped }).Count -gt 0
            noAutoApply = ($ConfirmApply -and $executeRequested)
            focusStealPrevented = (@($runs | Where-Object { $_.result.invocation.focusStealPrevented -eq $false }).Count -eq 0)
            timeoutCount = @($runs | Where-Object { $_.result.timedOut -eq $true }).Count
            nonZeroExitCount = @($runs | Where-Object { $null -ne $_.result.exitCode -and [int]$_.result.exitCode -ne 0 }).Count
            blockingGateCount = $blockingGates.Count
        }
        warnings = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_EXECUTOR_CONTROLLED' 'NVIDIA NIP executor abstraction evaluated with explicit mock or real execution gates.' 'info' $ProfileId $false 'Use mock mode for validation; real NVPI remains behind explicit flags.' $null))
        errors = @()
        logs = @((New-RooIndustriesLog 'NVIDIA NIP executor abstraction completed.'))
    }
    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.executor'
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        operation = $Operation
        profileId = $ProfileId
        dryRun = $true
        status = 'failed'
        executionMode = $ExecutorMode.ToLowerInvariant()
        executionSequence = @()
        summary = [pscustomobject]@{ willRunNvpi = $false; willRunMockShim = $false; realNvpiInvoked = $false }
        warnings = @()
        errors = @((New-RooIndustriesNvidiaNipIssue 'NVIDIA_NIP_EXECUTOR_FAILED' $_.Exception.Message 'error' $ProfileId $true 'Check executor mode, mock shim, timeout, and profile inputs.' $null))
        logs = @((New-RooIndustriesLog 'NVIDIA NIP executor abstraction failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
