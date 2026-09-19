param(
    [uint32]$PeriodMilliseconds = 1,
    [int]$DurationMilliseconds = 250,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$typeDefinition = @"
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesTimerResolutionNative {
    [DllImport("ntdll.dll")]
    public static extern int NtQueryTimerResolution(out uint minimumResolution, out uint maximumResolution, out uint currentResolution);
    [DllImport("winmm.dll")]
    public static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")]
    public static extern uint timeEndPeriod(uint period);
}
"@

function Get-TimerResolutionSnapshot {
    $min = 0
    $max = 0
    $current = 0
    $status = [RooIndustriesTimerResolutionNative]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$current)
    return [pscustomobject]@{
        ntStatus = $status
        minimum100ns = [uint32]$min
        maximum100ns = [uint32]$max
        current100ns = [uint32]$current
    }
}

try {
    if ($DurationMilliseconds -lt 1) { $DurationMilliseconds = 1 }
    if ($PeriodMilliseconds -lt 1) { $PeriodMilliseconds = 1 }
    Add-Type -TypeDefinition $typeDefinition -ErrorAction Stop
    $before = Get-TimerResolutionSnapshot
    $beginResult = [RooIndustriesTimerResolutionNative]::timeBeginPeriod($PeriodMilliseconds)
    $during = $null
    $endResult = $null
    try {
        Start-Sleep -Milliseconds $DurationMilliseconds
        $during = Get-TimerResolutionSnapshot
    } finally {
        $endResult = [RooIndustriesTimerResolutionNative]::timeEndPeriod($PeriodMilliseconds)
    }
    $after = Get-TimerResolutionSnapshot
    $result = [pscustomobject]@{
        actionId = 'performance.timerResolution.session'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = Get-RooIndustriesUtcStamp
        dryRun = $false
        status = if ($beginResult -eq 0 -and $endResult -eq 0) { 'success' } else { 'capability-limited' }
        requestedPeriodMilliseconds = $PeriodMilliseconds
        durationMilliseconds = $DurationMilliseconds
        before = $before
        during = $during
        after = $after
        summary = [pscustomobject]@{
            beginCalled = $true
            beginResult = $beginResult
            endCalled = $true
            endResult = $endResult
            restoreCalledOnExit = ($null -ne $endResult)
            willPersist = $false
        }
        warnings = @()
        errors = @()
        logs = @((New-RooIndustriesLog 'Bounded timer resolution session completed.'))
    }
    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.timerResolution.session'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = Get-RooIndustriesUtcStamp
        dryRun = $true
        status = 'failed'
        summary = [pscustomobject]@{ beginCalled = $false; endCalled = $false; restoreCalledOnExit = $false; willPersist = $false; nextEngineeringStep = 'Check WinMM/NtQueryTimerResolution API availability and run on Windows.' }
        warnings = @()
        errors = @([pscustomobject]@{ code = 'TIMER_RESOLUTION_SESSION_FAILED'; message = $_.Exception.Message; severity = 'error'; source = 'performance.timerResolution'; blocking = $true })
        logs = @((New-RooIndustriesLog 'Bounded timer resolution session failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
