param(
    [int]$ProcessId = 0,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ResidentSessionHost.Common.ps1')

try {
    if ($ProcessId -le 0) { $ProcessId = $PID }
    $live = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    $status = if ($live) { 'active' } else { 'notFound' }
    $result = Get-RooResidentHostStatusModel `
        -ProcessId $ProcessId `
        -Status $status `
        -Bounds ([pscustomobject]@{
            boundedForegroundSession = $true
            serviceReady = $true
            serviceInstalled = $false
        }) `
        -State ([pscustomobject]@{
            wroteState = $false
            unboundedStateGrowthAllowed = $false
        }) `
        -DependencyProof ([pscustomobject]@{
            frontendProcessRequired = $false
            persistentUiProcessRequired = $false
            externalProcessGovernorDependencyRequired = $false
            processLassoProcessStartedByHost = $false
        }) `
        -Logs @((New-RooLog 'Resident host status was read without system changes.'))
    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = Get-RooResidentHostStatusModel `
        -ProcessId $ProcessId `
        -Status 'failed' `
        -Errors @((New-RooIssue 'RESIDENT_HOST_STATUS_FAILED' $_.Exception.Message 'error' 'backend.residentHost' $ProcessId $true 'Check the process id and retry.' $null)) `
        -Logs @((New-RooLog 'Resident host status check failed.' 'error'))
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
