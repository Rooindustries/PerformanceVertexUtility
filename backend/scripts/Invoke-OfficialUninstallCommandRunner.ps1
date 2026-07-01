param(
    [string]$OfficialPreviewPath = '',
    [int]$CommandIndex = 0,
    [string]$AllowedExecutablePath = '',
    [string]$WorkingDirectory = '',
    [string]$CancellationSignalPath = '',
    [int]$TimeoutSeconds = 15,
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowHarmlessShimExecution,
    [switch]$UserApproved
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')
. (Join-Path $PSScriptRoot 'BackendExecutor.Common.ps1')

function Get-OfficialRunnerArguments {
    param([object]$Command)
    $value = Get-RooUninstallPropertyValue $Command 'arguments' $null
    if ($null -eq $value) { return @() }
    if ($value -is [System.Array]) { return @($value | ForEach-Object { [string]$_ }) }
    return @([string]$value)
}

function Test-RunnerPathInsideTemp {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Path).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

try {
    if ([string]::IsNullOrWhiteSpace($OfficialPreviewPath)) { throw 'OfficialPreviewPath is required.' }
    $officialPreview = Read-RooUninstallJsonFile (Resolve-RooUninstallPath $OfficialPreviewPath $OfficialPreviewPath)
    $commands = @(Get-RooUninstallPropertyArray $officialPreview 'commands')
    if ($CommandIndex -lt 0 -or $CommandIndex -ge $commands.Count) { throw "CommandIndex $CommandIndex is outside command count $($commands.Count)." }
    $command = $commands[$CommandIndex]
    $commandExecutable = Resolve-RooUninstallPath ([string](Get-RooUninstallPropertyValue $command 'executable' '')) ([string](Get-RooUninstallPropertyValue $command 'executable' ''))
    $allowedExecutable = if ([string]::IsNullOrWhiteSpace($AllowedExecutablePath)) { '' } else { Resolve-RooUninstallPath $AllowedExecutablePath $AllowedExecutablePath }
    $arguments = Get-OfficialRunnerArguments $command
    $workingDirectoryResolved = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { '' } else { [System.IO.Path]::GetFullPath($WorkingDirectory) }
    $cancelRequested = (-not [string]::IsNullOrWhiteSpace($CancellationSignalPath) -and (Test-Path -LiteralPath (Resolve-RooUninstallPath $CancellationSignalPath $CancellationSignalPath)))
    $executableMatchesAllowlist = (-not [string]::IsNullOrWhiteSpace($allowedExecutable) -and [System.IO.Path]::GetFullPath($commandExecutable).Equals([System.IO.Path]::GetFullPath($allowedExecutable), [System.StringComparison]::OrdinalIgnoreCase))
    $workingDirectorySafe = ([string]::IsNullOrWhiteSpace($workingDirectoryResolved) -or (Test-RunnerPathInsideTemp $workingDirectoryResolved))

    $gates = @(
        (New-RooBackendExecutorGate 'confirm-apply' 'Confirmed harmless runner requested' $true ([bool]$ConfirmApply) 'The official command runner remains preview-only until -ConfirmApply is supplied.' $null),
        (New-RooBackendExecutorGate 'harmless-shim-flag' 'Harmless shim execution allowed' $true ([bool]$AllowHarmlessShimExecution) 'Validation may run only a harmless shim executable, never a real app uninstaller.' $null),
        (New-RooBackendExecutorGate 'explicit-user-approval' 'Explicit runner approval captured' $true ([bool]$UserApproved) 'The exact harmless command must be approved for validation.' $null),
        (New-RooBackendExecutorGate 'executable-allowlist-match' 'Command executable matches harmless allowlist' $true $executableMatchesAllowlist 'The preview command executable must exactly match the supplied harmless shim path.' ([pscustomobject]@{ commandExecutable = $commandExecutable; allowedExecutablePath = $allowedExecutable })),
        (New-RooBackendExecutorGate 'working-directory-temp' 'Working directory is empty or under temp' $true $workingDirectorySafe 'Harmless runner working directory must be omitted or isolated under temp.' ([pscustomobject]@{ workingDirectory = $workingDirectoryResolved })),
        (New-RooBackendExecutorGate 'cancellation-not-requested' 'Cancellation signal absent' $true (-not $cancelRequested) 'A cancellation signal prevents process start.' ([pscustomobject]@{ cancellationSignalPath = $CancellationSignalPath })),
        (New-RooBackendExecutorGate 'no-silent-real-app-uninstall' 'No silent real app uninstall path' $true $executableMatchesAllowlist 'Only the exact harmless shim executable can run.' $null)
    )
    $blockingGates = @($gates | Where-Object { $_.blocking })
    $canRun = ($blockingGates.Count -eq 0)
    $runnerResult = $null
    $status = if ($cancelRequested) { 'canceled' } elseif ($canRun) { 'success' } elseif ($ConfirmApply) { 'blocked' } else { 'preview' }

    if ($canRun) {
        $runnerResult = Invoke-RooBackendHiddenProcess -FilePath $commandExecutable -Arguments $arguments -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $workingDirectoryResolved
        if ([bool](Get-RooPropertyValue $runnerResult 'timedOut' $false) -or [int](Get-RooPropertyValue $runnerResult 'exitCode' -1) -ne 0) {
            $status = 'failed'
        }
    }

    $result = [pscustomobject]@{
        actionId = 'apps.officialUninstallCommandRunner'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        dryRun = (-not $canRun)
        status = $status
        executionMode = if ($canRun) { 'harmless-shim-real-process' } else { 'preview-or-blocked' }
        appId = Get-RooUninstallPropertyValue $command 'appId' $null
        command = [pscustomobject]@{
            executable = $commandExecutable
            arguments = @($arguments)
            rawCommand = Get-RooUninstallPropertyValue $command 'rawCommand' $null
            commandLine = Join-RooBackendExecutorCommandLine $commandExecutable @($arguments)
            workingDirectory = $workingDirectoryResolved
        }
        gates = @($gates)
        result = $runnerResult
        capabilities = [pscustomobject]@{
            realProcessRunnerImplemented = $true
            harmlessShimExecutionImplemented = $true
            quotingPreservedByArgumentList = $true
            timeoutCancellationImplemented = $true
            realAppUninstallBlocked = $true
        }
        summary = [pscustomobject]@{
            processStarted = [bool](Get-RooPropertyValue $runnerResult 'processStarted' $false)
            timedOut = [bool](Get-RooPropertyValue $runnerResult 'timedOut' $false)
            exitCode = Get-RooPropertyValue $runnerResult 'exitCode' $null
            stdoutCaptured = -not [string]::IsNullOrEmpty([string](Get-RooPropertyValue $runnerResult 'stdout' ''))
            stderrCaptured = -not [string]::IsNullOrEmpty([string](Get-RooPropertyValue $runnerResult 'stderr' ''))
            cancellationRequested = $cancelRequested
            focusStealPrevented = ([bool](Get-RooPropertyValue (Get-RooPropertyValue $runnerResult 'invocation' $null) 'focusStealPrevented' $true))
            willRunRealUninstaller = $false
            blockingGateCount = $blockingGates.Count
        }
        warnings = @((New-RooUninstallIssue 'OFFICIAL_RUNNER_HARMLESS_ONLY' 'Official uninstall command runner executed only when the command executable matches the harmless shim allowlist.' 'info' 'apps.officialUninstallCommandRunner' (Get-RooUninstallPropertyValue $command 'appId' $null) $false 'Use this runner proof before wiring real uninstall approval gates.' $null))
        errors = @()
        logs = @((New-RooUninstallLog 'Official uninstall harmless process runner evaluated.'))
    }
    Write-RooUninstallJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'apps.officialUninstallCommandRunner'
        schemaVersion = 1
        productName = $script:RooUninstallProductName
        capturedAtUtc = Get-RooUninstallUtcStamp
        dryRun = $true
        status = 'failed'
        executionMode = 'blocked'
        result = $null
        summary = [pscustomobject]@{ processStarted = $false; willRunRealUninstaller = $false; nextEngineeringStep = 'Check official preview command, harmless allowlist path, working directory, and timeout.' }
        warnings = @()
        errors = @((New-RooUninstallIssue 'OFFICIAL_RUNNER_FAILED' $_.Exception.Message 'error' 'apps.officialUninstallCommandRunner' $null $true 'Check official preview command, harmless allowlist path, working directory, and timeout.' $null))
        logs = @((New-RooUninstallLog 'Official uninstall harmless process runner failed.' 'error'))
    }
    Write-RooUninstallJsonOutput $errorResult $OutputPath
    exit 1
}
