param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\ShippedHarness.Common.ps1')
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$rows=[Collections.Generic.List[object]]::new()
function Rejected([string]$CaseName,[scriptblock]$Action,[scriptblock]$Unchanged){
 $message=$null
 try{& $Action}catch{$message=$_.Exception.Message}
 if(-not$message -or -not(& $Unchanged)){throw ($CaseName+' did not safely refuse.')}
 $rows.Add(@{check=$CaseName;status='pass';observed=$message})
}
$fixture=Join-Path $OutRoot 'present-data';[IO.Directory]::CreateDirectory($fixture)|Out-Null
$sentinel=Join-Path $fixture 'keep.txt';[IO.File]::WriteAllText($sentinel,'untouched')
Rejected 'active current data root present in preflight' {Move-ShippedFreshData $fixture @{dataRoots=@(@{path=$fixture;exists=$true;files=@()})} (Join-Path $OutRoot 'moved-data')} {Test-Path $sentinel}
$name='RooTest-ShippedOffline-'+[Guid]::NewGuid().ToString('N');$nonce='OtherOwner-'+[Guid]::NewGuid().ToString('N')
New-NetFirewallRule -Name $name -DisplayName $name -Description $nonce -Direction Outbound -Action Block -Program "$env:SystemRoot\System32\PING.EXE"|Out-Null
try{
 Rejected 'existing offline firewall rule retained' {try{New-ShippedFirewall $name 'different-owner' "$env:SystemRoot\System32\PING.EXE"}finally{Remove-ShippedFirewall $name 'different-owner' $false}} {(Get-NetFirewallRule -Name $name).Description -ceq $nonce}
}finally{Remove-ShippedFirewall $name $nonce $true}
$image=Join-Path $OutRoot 'RooHarnessGame.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $image
$p=Start-Process $image -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned=New-OwnedProcess $p
try{
 Rejected 'pre-running app instance retained' {Assert-ShippedNoApp $image} {-not$p.HasExited}
 $after=[DateTime]::UtcNow
 $second=Start-Process $image -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$secondOwned=New-OwnedProcess $second
 try{Rejected 'second fixture with an earlier instance retained' {Get-ShippedFixture $image $after} {-not$p.HasExited -and -not$second.HasExited}}finally{Stop-OwnedProcess $secondOwned}
 Rejected 'earlier fixture instance retained' {Get-ShippedFixture $image $after} {-not$p.HasExited}
 Rejected 'Current refuses an app before its check launch window' {Assert-ShippedFreshApp $p $after} {-not$p.HasExited}
}finally{Stop-OwnedProcess $owned}
$frame='C:\RooBuild\roo-industries-roo29-shipped-'+[Guid]::NewGuid().ToString('N')
[IO.Directory]::CreateDirectory($frame)|Out-Null
$script=Join-Path $frame 'stay.ps1';[IO.File]::WriteAllText($script,'Start-Sleep -Seconds 180')
$p=Start-Process powershell.exe -ArgumentList ('-NoProfile -File "'+$script+'"') -WindowStyle Hidden -PassThru;$owned=New-OwnedProcess $p
try{Rejected 'frame script in PowerShell command line retained' {& (Join-Path $Source 'tools\validation\Update\Clear-UpdateFrame.ps1') -Frame $frame -ExpectedMachine $env:COMPUTERNAME} {Test-Path $script}}finally{Stop-OwnedProcess $owned}
& (Join-Path $Source 'tools\validation\Update\Clear-UpdateFrame.ps1') -Frame $frame -ExpectedMachine $env:COMPUTERNAME|Out-Null
$target=Join-Path $OutRoot 'junction-target';[IO.Directory]::CreateDirectory($target)|Out-Null
$keep=Join-Path $target 'keep.txt';[IO.File]::WriteAllText($keep,'untouched')
$frame='C:\RooBuild\roo-industries-roo29-shipped-'+[Guid]::NewGuid().ToString('N')
New-Item -ItemType Junction -Path $frame -Target $target|Out-Null
try{Rejected 'junction frame retained without touching target' {& (Join-Path $Source 'tools\validation\Update\Clear-UpdateFrame.ps1') -Frame $frame -ExpectedMachine $env:COMPUTERNAME} {[IO.File]::ReadAllText($keep) -ceq 'untouched'}}finally{[IO.Directory]::Delete($frame,$false)}
$hosts=Join-Path $OutRoot 'hosts-fixture';$original=[byte[]]@(239,187,191,35,32,195,169,10)
[IO.File]::WriteAllBytes($hosts,$original);$marker='# RooShipped-fixture';$line='192.0.2.1 example.test '+$marker
[IO.File]::AppendAllText($hosts,"`r`n"+$line+"`r`n",[Text.UTF8Encoding]::new($false))
Remove-ShippedHostsLine $hosts $line $marker
if([Convert]::ToBase64String([IO.File]::ReadAllBytes($hosts)) -cne [Convert]::ToBase64String($original)){throw 'Hosts cleanup changed unrelated bytes.'}
$rows.Add(@{check='hosts cleanup preserves BOM, UTF-8 and original line endings';status='pass';observed='byte-identical after marked line removal'})
$log=Join-Path $OutRoot 'app.log';[IO.File]::WriteAllText($log,'before')
$cursor=Get-ShippedLogCursor $log
[IO.File]::AppendAllText($log,' old-tail');[IO.File]::Move($log,$log+'.old');[IO.File]::WriteAllText($log,'new-head')
$read=Read-ShippedLog $cursor
if($read -cne ' old-tailnew-head'){throw 'Rotated log tail was lost.'}
$rows.Add(@{check='app-log rotation retains old tail';status='pass';observed=$read})
$before=@{pid=100;creationTimeUtc='2026-10-01T00:00:00Z'}
if((Test-ShippedGovernorReplacement $before $before) -or (Test-ShippedGovernorReplacement $before @{pid=101;creationTimeUtc=$before.creationTimeUtc}) -or (Test-ShippedGovernorReplacement $before @{pid=100;creationTimeUtc='2026-10-02T00:00:00Z'}) -or -not(Test-ShippedGovernorReplacement $before @{pid=101;creationTimeUtc='2026-10-02T00:00:00Z'})){throw 'Governor identity checks do not discriminate.'}
$rows.Add(@{check='governor needs new PID and creation time';status='pass';observed='unchanged, PID-only and time-only refused; both changed accepted'})
if((Get-ShippedFinalStatus 'pass' @('Governor pause timeout')) -cne 'fail'){throw 'Cleanup failure was reported as pass.'}
$rows.Add(@{check='cleanup error changes a pass to fail';status='pass';observed='Governor pause timeout => fail'})
$rows|ConvertTo-Json -Depth 20|Set-Content (Join-Path $OutRoot 'receipt.json')
'PASS '+$rows.Count+' owned fixture checks'
