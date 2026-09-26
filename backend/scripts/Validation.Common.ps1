. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Wait-RooIndustriesValidationProcess {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds = 5)
    if ($null -eq $Process) { return }
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) { throw "Validation process $($Process.Id) did not exit within $TimeoutSeconds seconds." }
}

function Stop-RooIndustriesValidationProcess {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    $Process.Refresh()
    if (-not $Process.HasExited) { $Process.Kill() }
    Wait-RooIndustriesValidationProcess $Process 5
}

function Set-RooIndustriesValidationNormalPriority {
    $current = [System.Diagnostics.Process]::GetCurrentProcess()
    $current.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    Set-RooIndustriesProcessIoPriority $current 'Normal'
    $current.Dispose()
}
