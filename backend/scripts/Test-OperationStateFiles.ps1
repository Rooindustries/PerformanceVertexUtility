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
    $killed=Join-Path $root 'killed.json'
    Write-RooIndustriesOperationJson @{generation=0;check=0} $killed
    $common=(Join-Path $PSScriptRoot 'OperationState.Common.ps1').Replace("'","''")
    $target=$killed.Replace("'","''")
    $write="Write-RooIndustriesOperationJson @{generation=`$n;check=`$n} '$target'"
    $loop=". '$common'; for(`$n=1;;`$n++){$write; if(`$n -eq 1){[Console]::Out.WriteLine('ready')}}"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loop))
    $samples=0;$absent=0;$kills=0;$unreadable=0;$lost=''
    for($attempt=0;$attempt -lt 60;$attempt++){
        $shell="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $start=[Diagnostics.ProcessStartInfo]::new($shell,"-NoProfile -NonInteractive -EncodedCommand $encoded")
        $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.CreateNoWindow=$true
        $child=[Diagnostics.Process]::Start($start)
        try {
            if($child.StandardOutput.ReadLine() -ne 'ready'){throw 'The killed writer never reached its loop'}
            $until=[DateTime]::UtcNow.AddMilliseconds((Get-Random -Minimum 1 -Maximum 200))
            while([DateTime]::UtcNow -lt $until){$samples++;if(-not [IO.File]::Exists($killed)){$absent++}}
        } finally {if(-not $child.HasExited){$child.Kill()};$child.WaitForExit();$child.Dispose()}
        $kills++
        try {
            $saved=[IO.File]::ReadAllText($killed)|ConvertFrom-Json
            if([int]$saved.check -ne [int]$saved.generation){throw 'The saved generation is mixed'}
        } catch {$unreadable++;$lost=$_.Exception.Message}
    }
    Write-Output ('Killed writer: samples='+$samples+' absent='+$absent+' kills='+$kills+' unreadable='+$unreadable+' '+$lost)
    Assert ($samples -gt 1000 -and $absent -eq 0) 'A file being replaced by another process is never missing, even for an instant'
    Assert ($kills -eq 60 -and $unreadable -eq 0) 'A writer killed at any point of a replace leaves a whole readable generation'
    $missing=$false
    try{Read-RooIndustriesOperationJson (Join-Path $root 'absent.json')|Out-Null}catch{$missing=$true}
    Assert $missing 'A missing operation file still fails after its bounded wait'
} finally {
    if($writer){Remove-Job -Job $writer -Force}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path -LiteralPath $root)) 'Operation-state validation removes its fixture'
