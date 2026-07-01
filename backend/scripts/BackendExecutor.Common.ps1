. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function ConvertTo-RooBackendExecutorQuotedArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ([string]$Value).Replace('"', '\"') + '"'
}

function Join-RooBackendExecutorCommandLine {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((ConvertTo-RooBackendExecutorQuotedArgument $FilePath)) | Out-Null
    foreach ($arg in @(Get-RooArray $Arguments)) {
        $parts.Add((ConvertTo-RooBackendExecutorQuotedArgument ([string]$arg))) | Out-Null
    }
    return ($parts.ToArray() -join ' ')
}

function Join-RooBackendExecutorArguments {
    param([string[]]$Arguments)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @(Get-RooArray $Arguments)) {
        $parts.Add((ConvertTo-RooBackendExecutorQuotedArgument ([string]$arg))) | Out-Null
    }
    return ($parts.ToArray() -join ' ')
}

function Resolve-RooPowerShellExePath {
    $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return 'powershell.exe'
}

function Invoke-RooBackendHiddenProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30,
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{}
    )

    if ($TimeoutSeconds -lt 1) { $TimeoutSeconds = 1 }
    $startedAt = Get-RooUtcStamp
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    if ($null -ne $startInfo.ArgumentList) {
        foreach ($arg in @(Get-RooArray $Arguments)) {
            [void]$startInfo.ArgumentList.Add([string]$arg)
        }
    } else {
        $startInfo.Arguments = Join-RooBackendExecutorArguments @(Get-RooArray $Arguments)
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($key in @($Environment.Keys)) {
        $startInfo.Environment[[string]$key] = [string]$Environment[$key]
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $timedOut = $false
    $started = $false
    $exitCode = $null
    $stdout = ''
    $stderr = ''
    try {
        $started = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
            $process.WaitForExit(5000) | Out-Null
        }
        try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch { $stdout = '' }
        try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch { $stderr = '' }
        if (-not $timedOut) {
            try { $exitCode = [int]$process.ExitCode } catch { $exitCode = $null }
        }
    } finally {
        $watch.Stop()
        $process.Dispose()
    }

    return [pscustomobject]@{
        startedAtUtc = $startedAt
        completedAtUtc = Get-RooUtcStamp
        durationMilliseconds = [int][math]::Round($watch.Elapsed.TotalMilliseconds)
        filePath = $FilePath
        arguments = @(Get-RooArray $Arguments)
        commandLine = Join-RooBackendExecutorCommandLine $FilePath @(Get-RooArray $Arguments)
        processStarted = $started
        exitCode = $exitCode
        timedOut = $timedOut
        timeoutSeconds = $TimeoutSeconds
        stdout = $stdout
        stderr = $stderr
        invocation = [pscustomobject]@{
            useShellExecute = $false
            createNoWindow = $true
            windowStyle = 'Hidden'
            focusStealPrevented = $true
            redirectedOutput = $true
        }
    }
}

function Invoke-RooBackendPowerShellShim {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShimPath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30,
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{}
    )
    $resolvedShim = Resolve-RooPath $ShimPath $ShimPath
    if (-not (Test-Path -LiteralPath $resolvedShim)) {
        throw "Mock shim not found: $resolvedShim"
    }
    $shimArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolvedShim) + @(Get-RooArray $Arguments)
    return Invoke-RooBackendHiddenProcess `
        -FilePath (Resolve-RooPowerShellExePath) `
        -Arguments $shimArgs `
        -TimeoutSeconds $TimeoutSeconds `
        -WorkingDirectory $WorkingDirectory `
        -Environment $Environment
}

function New-RooBackendExecutorGate {
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
