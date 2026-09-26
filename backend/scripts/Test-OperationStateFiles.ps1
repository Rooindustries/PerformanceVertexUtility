$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-operation-state-'+[Guid]::NewGuid().ToString('N'))
$writer=$null
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $path=Join-Path $root 'state.json'
    Write-RooIndustriesOperationJson @{value=0} $path
    $ready=Join-Path $root 'writer.ready'
    $writer=Start-Job -ArgumentList (Join-Path $PSScriptRoot 'OperationState.Common.ps1'),$path,$ready -ScriptBlock {
        param($Common,$Target,$Ready)
        . $Common
        [IO.File]::WriteAllText($Ready,'ready')
        $end=(Get-Date).AddSeconds(4);$count=0
        while((Get-Date) -lt $end){$count++;Write-RooIndustriesOperationJson @{value=$count} $Target}
        $count
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not(Test-Path -LiteralPath $ready) -and $clock.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 50}
    Assert (Test-Path -LiteralPath $ready) 'The concurrent writer started'
    $reads=0;$failures=0;$failure=''
    while($writer.State -eq 'Running' -and $clock.Elapsed.TotalSeconds -lt 40){
        try{$null=Read-RooIndustriesOperationJson $path;$reads++}catch{$failures++;$failure=$_.Exception.Message}
    }
    $writes=[int](Receive-Job -Job $writer -Wait)
    Write-Output ('Operation-state race: writes='+$writes+' reads='+$reads+' failures='+$failures+' '+$failure)
    Assert ($writes -gt 50 -and $reads -gt 50 -and $failures -eq 0) 'PowerShell readers never fail while a writer atomically replaces the same file'
    $script:RooIndustriesSimulateReplaceFailure={param($Target,$Backup) [IO.File]::Move($Target,$Backup); throw 'Simulated replace failure'}
    $replaceFailed=$false
    try{Write-RooIndustriesOperationJson @{value='replacement'} $path}catch{$replaceFailed=$true}finally{$script:RooIndustriesSimulateReplaceFailure=$null}
    $kept=(Read-RooIndustriesOperationJson $path).data
    Assert ($replaceFailed -and $kept.value -ne 'replacement' -and @(Get-ChildItem -LiteralPath $root -File -Force | Where-Object { $_.Name.StartsWith('state.json.') }).Count -eq 0) 'A failed PowerShell replace keeps the previous file and leaves no backup behind'
    $missing=$false
    try{Read-RooIndustriesOperationJson (Join-Path $root 'absent.json')|Out-Null}catch{$missing=$true}
    Assert $missing 'A missing operation file still fails after its bounded wait'
} finally {
    if($writer){Remove-Job -Job $writer -Force}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path -LiteralPath $root)) 'Operation-state validation removes its fixture'
