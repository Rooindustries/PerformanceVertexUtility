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
    $previous=[IO.File]::ReadAllBytes($path)
    $script:RooIndustriesSimulateReplaceFailure={param($Target,$Backup) [IO.File]::Move($Target,$Backup); throw 'Simulated replace failure'}
    $replaceFailed=$false
    try{Write-RooIndustriesOperationJson @{value='replacement'} $path}catch{$replaceFailed=$true}finally{$script:RooIndustriesSimulateReplaceFailure=$null}
    function Get-Leftovers{@(Get-ChildItem -LiteralPath $root -File -Force | Where-Object { $_.Name.StartsWith('state.json.') -and -not $_.Name.EndsWith('.replace.lock') })}
    Assert ($replaceFailed -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToBase64String($previous) -and (Get-Leftovers).Count -eq 0) 'A failed PowerShell replace keeps the exact previous file and leaves no backup behind'
    $orphan=$path+'.'+[Guid]::NewGuid().ToString('N')+'.bak'
    [IO.File]::Move($path,$orphan)
    $recovered=Read-RooIndustriesOperationJson $path
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToBase64String($previous) -and -not(Test-Path -LiteralPath $orphan)) 'A PowerShell read recovers the last saved version left only as a backup'
    [IO.File]::Move($path,$orphan)
    Assert ((Test-RooIndustriesOperationFile $path) -and -not(Test-Path -LiteralPath $orphan)) 'A PowerShell existence check recovers an orphaned saved file'
    [IO.File]::Move($path,$orphan)
    Write-RooIndustriesOperationJson @{value='after recovery'} $path
    Assert ((Read-RooIndustriesOperationJson $path).data.value -eq 'after recovery' -and (Get-Leftovers).Count -eq 0) 'A PowerShell write over an orphaned backup recovers it first and leaves no leftovers'
    [IO.File]::WriteAllText($path+'.'+[Guid]::NewGuid().ToString('N')+'.bak','{}')
    Write-RooIndustriesOperationJson @{value='cleaned'} $path
    Assert ((Get-Leftovers).Count -eq 0) 'A PowerShell write clears a leftover backup next to an existing file'
    $strict=Join-Path $root 'strict.json'
    $strictScript=Join-Path $root 'strict.ps1'
    [IO.File]::WriteAllText($strictScript,"Set-StrictMode -Version Latest`n`$ErrorActionPreference='Stop'`n. '"+(Join-Path $PSScriptRoot 'OperationState.Common.ps1')+"'`nWrite-RooIndustriesOperationJson @{value='strict'} '$strict'`nWrite-RooIndustriesOperationJson @{value='strict again'} '$strict'`nif((Read-RooIndustriesOperationJson '$strict').data.value -ne 'strict again'){exit 2}`nexit 0`n")
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $strictScript
    Assert ($LASTEXITCODE -eq 0) 'Operation-state helpers work under Set-StrictMode -Version Latest'
    $missing=$false
    try{Read-RooIndustriesOperationJson (Join-Path $root 'absent.json')|Out-Null}catch{$missing=$true}
    Assert $missing 'A missing operation file still fails after its bounded wait'
} finally {
    if($writer){Remove-Job -Job $writer -Force}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path -LiteralPath $root)) 'Operation-state validation removes its fixture'
