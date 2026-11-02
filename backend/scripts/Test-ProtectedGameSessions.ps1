param([string]$DotNetPath='', [switch]$HardwareGpu, [switch]$RetainedGpu, [switch]$HighIo, [ValidateRange(0,300)][int]$InspectSeconds=0, [switch]$StartFileSharing)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
& (Join-Path $PSScriptRoot 'Build-OptimizerHost.ps1') -DotNetPath $DotNetPath
if($LASTEXITCODE -ne 0){throw 'Native session package build failed'}
$bin=Join-Path $root 'tools\validation\ProtectedSessions\bin\publish'
& $DotNetPath publish (Join-Path $root 'tools\validation\ProtectedSessions\ProtectedSessions.csproj') -c Release -o $bin -p:UseSharedCompilation=false
if($LASTEXITCODE -ne 0){throw 'Protected-session validation build failed'}
$arguments=@((Join-Path $bin 'RooIndustriesLaunchPolicyProbe.dll'),$root,$DotNetPath)
if($HighIo -and $RetainedGpu){$arguments+='--retained-gpu-high-io'}elseif($HighIo){$arguments+=@('--high-io',[string]$InspectSeconds)}elseif($RetainedGpu){$arguments+='--retained-gpu'}elseif($HardwareGpu){$arguments+='--hardware-gpu'}
# The mapped-drive checks need file sharing (the Server service). -StartFileSharing turns it on for this run only and puts back its exact start type and state.
$server=$null
if($StartFileSharing){
 $key='HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer'
 $config=Get-ItemProperty -LiteralPath $key
 $server=[pscustomobject]@{Start=[int]$config.Start;Delayed=[int]$(if($null -ne $config.DelayedAutostart){$config.DelayedAutostart}else{0});Running=(Get-Service LanmanServer).Status -eq 'Running'}
 $startNames=@{2='auto';3='demand';4='disabled'}
 if(-not $startNames.ContainsKey($server.Start)){throw ('File sharing has a start type this test does not restore ('+$server.Start+').')}
}
try{
 if($server -and -not $server.Running){
  if($server.Start -eq 4){& sc.exe config LanmanServer start= demand|Out-Null;if($LASTEXITCODE -ne 0){throw 'File sharing could not be allowed to start.'}}
  Start-Service LanmanServer
 }
 & $DotNetPath @arguments
 if($LASTEXITCODE -ne 0){throw 'Protected-session validation failed'}
}finally{
 if($server){
  $type=if($server.Start -eq 2 -and $server.Delayed -eq 1){'delayed-auto'}else{$startNames[$server.Start]}
  & sc.exe config LanmanServer start= $type|Out-Null
  if(-not $server.Running -and (Get-Service LanmanServer).Status -ne 'Stopped'){Stop-Service LanmanServer -Force}
  $after=Get-ItemProperty -LiteralPath $key
  $afterDelayed=[int]$(if($null -ne $after.DelayedAutostart){$after.DelayedAutostart}else{0})
  if([int]$after.Start -ne $server.Start -or ($server.Start -eq 2 -and $afterDelayed -ne $server.Delayed) -or ((Get-Service LanmanServer).Status -eq 'Running') -ne $server.Running){throw 'File sharing was not put back to its start type and state.'}
  Write-Host ('File sharing put back: start type '+$type+', '+$(if($server.Running){'running'}else{'stopped'}))
 }
}
