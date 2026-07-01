param(
    [ValidateSet('Apply','Restore')]
    [string]$Operation = 'Apply',
    [string]$ProfileId = 'base-profile',
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
    $arguments = @(Get-RooPropertyArray $Command 'arguments')
    if ($Mode -eq 'Mock') {
        return Invoke-RooBackendPowerShellShim -ShimPath $MockShim -Arguments $arguments -TimeoutSeconds $Timeout
    }
    if ($Mode -eq 'Real') {
        return Invoke-RooBackendHiddenProcess -FilePath ([string](Get-RooPropertyValue $Command 'executablePath' '')) -Arguments $arguments -TimeoutSeconds $Timeout
    }
    return [pscustomobject]@{
        processStarted = $false
        exitCode = $null
        timedOut = $false
        timeoutSeconds = $Timeout
        arguments = $arguments
        commandLine = Get-RooPropertyValue $Command 'commandLine' $null
        invocation = [pscustomobject]@{
            useShellExecute = $false
            createNoWindow = $true
            windowStyle = 'Hidden'
            focusStealPrevented = $true
            redirectedOutput = $true
        }
    }
}

try {
    $preview = (& (Join-Path $PSScriptRoot 'Preview-NvidiaNipProfile.ps1') `
        -ProfileId $ProfileId `
        -CatalogPath $CatalogPath `
        -HardwareInventoryPath $HardwareInventoryPath `
        -NvpiExecutablePath $NvpiExecutablePath `
        -NipSourcePath $NipSourcePath `
        -ExportPath $ExportPath) | ConvertFrom-Json

    $commands = Get-RooPropertyValue $preview 'commands' $null
    $rollbackManifest = Get-RooPropertyValue $preview 'rollbackManifest' $null
    if ($Operation -eq 'Restore') {
        $effectiveRestoreExportPath = if ([string]::IsNullOrWhiteSpace($ExportPath)) { [string](Get-RooPropertyValue $rollbackManifest 'exportPath' '') } else { $ExportPath }
        $restorePreview = (& (Join-Path $PSScriptRoot 'Restore-NvidiaNipProfile.ps1') `
            -ProfileId $ProfileId `
            -CatalogPath $CatalogPath `
            -HardwareInventoryPath $HardwareInventoryPath `
            -NvpiExecutablePath $NvpiExecutablePath `
            -ExportPath $effectiveRestoreExportPath) | ConvertFrom-Json
    }

    $hardwareSatisfied = [bool](Get-RooPropertyValue (Get-RooPropertyValue $preview 'hardwareGate' $null) 'nvidiaGpuPresent' $false)
    $mockShimPresent = (-not [string]::IsNullOrWhiteSpace($MockNvpiShimPath) -and (Test-Path -LiteralPath (Resolve-RooPath $MockNvpiShimPath $MockNvpiShimPath)))
    $realMode = ($ExecutorMode -eq 'Real')
    $mockMode = ($ExecutorMode -eq 'Mock')
    $executeRequested = ($ExecutorMode -ne 'Preview')
    $gates = @(
        (New-RooBackendExecutorGate 'confirm-apply' 'Confirmed execution requested' $true ([bool]$ConfirmApply) 'Executor will not run from preview-only calls.' $null),
        (New-RooBackendExecutorGate 'executor-mode-selected' 'Executor mode selected' $true $executeRequested 'ExecutorMode must be Mock or Real to run commands.' ([pscustomobject]@{ executorMode = $ExecutorMode })),
        (New-RooBackendExecutorGate 'nvidia-hardware-present' 'NVIDIA hardware detected' $true $hardwareSatisfied 'NIP execution is NVIDIA-only.' (Get-RooPropertyValue $preview 'hardwareGate' $null)),
        (New-RooBackendExecutorGate 'explicit-user-approval' 'Explicit approval evidence captured' $true ([bool]$UserApproved) 'Execution requires user approval evidence for the exact profile.' $null),
        (New-RooBackendExecutorGate 'no-auto-apply' 'No auto-apply path used' $true ($ConfirmApply -and $executeRequested) 'Default invocation remains preview-only.' ([pscustomobject]@{ confirmApply = [bool]$ConfirmApply; executorMode = $ExecutorMode })),
        (New-RooBackendExecutorGate 'mock-shim-present' 'Mock NVPI shim present' $mockMode ((-not $mockMode) -or $mockShimPresent) 'Mock validation requires a shim path.' ([pscustomobject]@{ mockNvpiShimPath = $MockNvpiShimPath })),
        (New-RooBackendExecutorGate 'real-nvpi-explicit-flag' 'Real NVPI explicit flag supplied' $realMode ((-not $realMode) -or [bool]$AllowRealNvpiExecution) 'Real NVIDIA Profile Inspector execution requires -AllowRealNvpiExecution in addition to confirmation.' $null),
        (New-RooBackendExecutorGate 'benchmark-evidence' 'Benchmark evidence attached' ($Operation -eq 'Apply') (($Operation -ne 'Apply') -or [bool]$BenchmarkEvidenceAttached) 'Profile apply requires benchmark evidence before recommendation.' $null)
    )
    $blockingGates = @($gates | Where-Object { $_.blocking })
    $canExecute = ($blockingGates.Count -eq 0)
    $sequence = New-Object System.Collections.Generic.List[object]
    $status = if ($canExecute) { 'success' } elseif ($ConfirmApply -or $executeRequested) { 'blocked' } else { 'preview' }
    $exportCompleted = $false
    $importCompleted = $false

    if ($canExecute -and $Operation -eq 'Apply') {
        $exportCommand = Get-RooPropertyValue $commands 'exportCurrentProfile' $null
        $exportResult = Invoke-NvidiaExecutorCommand -Command $exportCommand -Mode $ExecutorMode -MockShim $MockNvpiShimPath -Timeout $TimeoutSeconds
        $exportCompleted = ((-not [bool](Get-RooPropertyValue $exportResult 'timedOut' $false)) -and [int](Get-RooPropertyValue $exportResult 'exitCode' -1) -eq 0)
        $sequence.Add([pscustomobject]@{
            order = 1
            operation = 'export'
            command = $exportCommand
            result = $exportResult
            completed = $exportCompleted
        }) | Out-Null
        if ($exportCompleted) {
            $importCommand = Get-RooPropertyValue $commands 'importCandidateProfile' $null
            $importResult = Invoke-NvidiaExecutorCommand -Command $importCommand -Mode $ExecutorMode -MockShim $MockNvpiShimPath -Timeout $TimeoutSeconds
            $importCompleted = ((-not [bool](Get-RooPropertyValue $importResult 'timedOut' $false)) -and [int](Get-RooPropertyValue $importResult 'exitCode' -1) -eq 0)
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
                reason = 'Export failed or timed out; import was not attempted.'
            }) | Out-Null
        }
    } elseif ($canExecute -and $Operation -eq 'Restore') {
        $restoreCommand = Get-RooPropertyValue $restorePreview 'command' $null
        $restoreResult = Invoke-NvidiaExecutorCommand -Command $restoreCommand -Mode $ExecutorMode -MockShim $MockNvpiShimPath -Timeout $TimeoutSeconds
        $importCompleted = ((-not [bool](Get-RooPropertyValue $restoreResult 'timedOut' $false)) -and [int](Get-RooPropertyValue $restoreResult 'exitCode' -1) -eq 0)
        $sequence.Add([pscustomobject]@{
            order = 1
            operation = 'restore-import'
            command = $restoreCommand
            result = $restoreResult
            completed = $importCompleted
        }) | Out-Null
        if (-not $importCompleted) { $status = 'failed' }
    }

    if ($canExecute -and -not [string]::IsNullOrWhiteSpace($RollbackManifestPath)) {
        $resolvedRollbackManifestPath = Resolve-RooPath $RollbackManifestPath $RollbackManifestPath
        Ensure-RooDirectory (Split-Path $resolvedRollbackManifestPath -Parent)
        $rollbackManifest.exportCompleted = $exportCompleted
        $rollbackManifest.nvpiExecutionAllowedNow = ($ExecutorMode -eq 'Real')
        ($rollbackManifest | ConvertTo-Json -Depth 24) | Set-Content -LiteralPath $resolvedRollbackManifestPath -Encoding UTF8
    } else {
        $resolvedRollbackManifestPath = $null
    }

    $runs = @($sequence.ToArray())
    $result = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.executor'
        schemaVersion = 1
        productName = $script:RooNvidiaNipProductName
        capturedAtUtc = Get-RooUtcStamp
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
        warnings = @((New-RooNvidiaNipIssue 'NVIDIA_NIP_EXECUTOR_CONTROLLED' 'NVIDIA NIP executor abstraction evaluated with explicit mock or real execution gates.' 'info' $ProfileId $false 'Use mock mode for validation; real NVPI remains behind explicit flags.' $null))
        errors = @()
        logs = @((New-RooLog 'NVIDIA NIP executor abstraction completed.'))
    }
    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'drivers.nvidiaNip.executor'
        schemaVersion = 1
        productName = $script:RooNvidiaNipProductName
        capturedAtUtc = Get-RooUtcStamp
        operation = $Operation
        profileId = $ProfileId
        dryRun = $true
        status = 'failed'
        executionMode = $ExecutorMode.ToLowerInvariant()
        executionSequence = @()
        summary = [pscustomobject]@{ willRunNvpi = $false; willRunMockShim = $false; realNvpiInvoked = $false }
        warnings = @()
        errors = @((New-RooNvidiaNipIssue 'NVIDIA_NIP_EXECUTOR_FAILED' $_.Exception.Message 'error' $ProfileId $true 'Check executor mode, mock shim, timeout, and profile inputs.' $null))
        logs = @((New-RooLog 'NVIDIA NIP executor abstraction failed.' 'error'))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
