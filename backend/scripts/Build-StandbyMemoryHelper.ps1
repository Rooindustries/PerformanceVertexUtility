param(
    [string]$SourcePath = '',
    [string]$HelperOutputPath = '',
    [string]$OutputPath = '',
    [int]$TimeoutSeconds = 30,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')
. (Join-Path $PSScriptRoot 'BackendExecutor.Common.ps1')

function Get-CscCompilerPath {
    foreach ($cmd in @(Get-Command csc.exe -All -ErrorAction SilentlyContinue)) {
        if ($cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) { return $cmd.Source }
    }
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Test-PathInsideTemp {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Path).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

try {
    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        $SourcePath = Join-Path $PSScriptRoot '..\native\StandbyMemoryHelper\RooIndustriesStandbyMemoryHelper.cs'
    }
    $resolvedSource = Resolve-RooIndustriesPath $SourcePath $SourcePath
    $resolvedOutput = if ([string]::IsNullOrWhiteSpace($HelperOutputPath)) { '' } else { [System.IO.Path]::GetFullPath($HelperOutputPath) }
    $buildScriptPath = Resolve-RooIndustriesPath $PSCommandPath $PSCommandPath
    $sourceExists = Test-Path -LiteralPath $resolvedSource -PathType Leaf
    $cscPath = Get-CscCompilerPath
    $toolchainDetected = -not [string]::IsNullOrWhiteSpace($cscPath)
    $outputUnderTemp = (-not [string]::IsNullOrWhiteSpace($resolvedOutput) -and (Test-PathInsideTemp $resolvedOutput))
    $buildGateSatisfied = ((-not [bool]$Build) -or ($sourceExists -and $toolchainDetected -and $outputUnderTemp))
    $buildResult = $null
    $buildSucceeded = $false
    $status = if ($Build) {
        if (-not $sourceExists) { 'source-missing' }
        elseif (-not $toolchainDetected) { 'toolchain-missing' }
        elseif (-not $outputUnderTemp) { 'blocked' }
        else { 'ready-to-build' }
    } else {
        'preview'
    }

    if ($Build -and $buildGateSatisfied) {
        Ensure-RooIndustriesDirectory (Split-Path $resolvedOutput -Parent)
        $buildResult = Invoke-RooIndustriesBackendHiddenProcess -FilePath $cscPath -Arguments @('/nologo', '/target:exe', "/out:$resolvedOutput", $resolvedSource) -TimeoutSeconds $TimeoutSeconds
        $buildSucceeded = ((-not [bool](Get-RooIndustriesPropertyValue $buildResult 'timedOut' $false)) -and [int](Get-RooIndustriesPropertyValue $buildResult 'exitCode' -1) -eq 0 -and (Test-Path -LiteralPath $resolvedOutput -PathType Leaf))
        $status = if ($buildSucceeded) { 'success' } else { 'failed' }
    }

    $commandLine = if ([string]::IsNullOrWhiteSpace($resolvedOutput)) {
        'Build first, then run elevated: RooIndustriesStandbyMemoryHelper.exe --purge-standby-list'
    } else {
        "Start-Process -Verb RunAs -FilePath `"$resolvedOutput`" -ArgumentList '--purge-standby-list'"
    }
    $result = [pscustomobject]@{
        actionId = 'performance.standbyMemoryHelper.build'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        dryRun = (-not [bool]$Build)
        status = $status
        buildScriptPath = $buildScriptPath
        buildScriptExists = $true
        sourcePath = $resolvedSource
        outputPath = $resolvedOutput
        gates = @(
            [pscustomobject]@{ gateId = 'source-exists'; required = $true; satisfied = $sourceExists; blocking = (-not $sourceExists) },
            [pscustomobject]@{ gateId = 'csc-toolchain-detected'; required = [bool]$Build; satisfied = ((-not [bool]$Build) -or $toolchainDetected); blocking = ([bool]$Build -and -not $toolchainDetected) },
            [pscustomobject]@{ gateId = 'output-path-under-temp'; required = [bool]$Build; satisfied = ((-not [bool]$Build) -or $outputUnderTemp); blocking = ([bool]$Build -and -not $outputUnderTemp) }
        )
        capabilities = [pscustomobject]@{
            sourceExists = $sourceExists
            cscCompilerPath = $cscPath
            toolchainDetected = $toolchainDetected
            buildAttempted = [bool]$Build
            buildSucceeded = $buildSucceeded
            outputUnderTemp = $outputUnderTemp
            helperLaunchAttempted = $false
        }
        buildResult = $buildResult
        elevation = [pscustomobject]@{
            requiresAdministrator = $true
            commandLine = $commandLine
            launchAttempted = $false
        }
        summary = [pscustomobject]@{
            willPurgeStandbyList = $false
            willLaunchElevatedHelper = $false
            willWriteOutsideOutputPath = $false
            nextEngineeringStep = if ($buildSucceeded) { 'Sign the helper binary and launch it only through the controlled elevated approval path with before/after memory counters.' } elseif ($toolchainDetected) { 'Run with -Build and an output path under temp to validate compilation; do not launch the helper without elevation approval.' } else { 'Install or expose csc.exe, then build the helper to a temp output path before signing/elevation validation.' }
        }
        warnings = @()
        errors = @()
        logs = @((New-RooIndustriesLog 'Standby memory helper build contract evaluated without running the helper.'))
    }
    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.standbyMemoryHelper.build'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        dryRun = $true
        status = 'failed'
        summary = [pscustomobject]@{ willPurgeStandbyList = $false; willLaunchElevatedHelper = $false; nextEngineeringStep = 'Check helper source path, compiler availability, and temp output path.' }
        errors = @((New-RooIndustriesIssue 'STANDBY_HELPER_BUILD_FAILED' $_.Exception.Message 'error' 'performance.standbyMemoryHelper' $SourcePath $true 'Check helper source path, compiler availability, and temp output path.' $null))
        logs = @((New-RooIndustriesLog 'Standby memory helper build contract failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
