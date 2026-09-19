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
    $result = Get-RooIndustriesResidentHostStatusModel `
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
        -Logs @((New-RooIndustriesLog 'Resident host status was read without system changes.'))
    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = Get-RooIndustriesResidentHostStatusModel `
        -ProcessId $ProcessId `
        -Status 'failed' `
        -Errors @((New-RooIndustriesIssue 'RESIDENT_HOST_STATUS_FAILED' $_.Exception.Message 'error' 'backend.residentHost' $ProcessId $true 'Check the process id and retry.' $null)) `
        -Logs @((New-RooIndustriesLog 'Resident host status check failed.' 'error'))
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
