param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[int]$Probes=60,[string[]]$Cases=@('timeout','killed','closed','rebooted','other-program','stale-journal','race','full'))
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
Add-Type 'using System;using System.Runtime.InteropServices;public static class RooIndustriesInterruptedApply{[DllImport("ntdll.dll")]public static extern int NtSuspendProcess(IntPtr h);[DllImport("ntdll.dll")]public static extern int NtResumeProcess(IntPtr h);}'
Assert-NoUnownedAppProcess
$directory=Join-Path $OutRoot 'interrupted-apply';[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$owned=[Collections.Generic.List[object]]::new();$results=[ordered]@{}
$tag=[Guid]::NewGuid().ToString('N').Substring(0,6)
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
& $dotnet publish (Join-Path $Source 'tools\validation\ClientBoundary\ClientBoundary.csproj') -c Release -p:UseSharedCompilation=false -r win-x64 --self-contained false -o (Join-Path $directory 'probe') *> (Join-Path $directory 'probe-build.log')
if($LASTEXITCODE){throw 'Client probe build failed'}
$probe=Join-Path $directory 'probe\ClientBoundary.dll'
$root=Join-Path $directory 'repo';[IO.Directory]::CreateDirectory($root)|Out-Null;Copy-Item (Join-Path $Source 'backend') (Join-Path $root 'backend') -Recurse
$finishing='The last apply is still finishing. Try again in a moment.'

function Save($name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 45),$utf8)}
function Own($p){$r=New-OwnedProcess $p;if($r){$owned.Add($r)};$r}
function Fixtures($case){
 $folder=Join-Path $directory $case;[IO.Directory]::CreateDirectory($folder)|Out-Null
 @(for($i=0;$i -lt $Probes;$i++){
  $path=Join-Path $folder ('RooCut'+$tag+$case.Substring(0,2)+$i.ToString('00')+'.exe');Copy-Item "$env:SystemRoot\System32\PING.EXE" $path
  $p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$null=Own $p
  $p.PriorityClass='Normal';[RooIndustriesBackgroundOracle]::SetIo($p,2);[RooIndustriesBackgroundOracle]::SetMemory($p,5);$p
 })
}
function Profile($fixtures){$profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\game-session.profile.json')|ConvertFrom-Json;$profile.profileId='roo655-interrupted-apply';$profile.foregroundGame.processNames=@();$profile.targetGames=@();$profile.rules=@([pscustomobject]@{ruleId='fixture';enabled=$true;match=@{processNames=@($fixtures|ForEach-Object {$_.ProcessName+'.exe'})};action=@{actionType='setPriority';priorityClass='BelowNormal'}});$profile|ConvertTo-Json -Depth 30|Set-Content (Join-Path $root 'backend\profiles\game-session.profile.json') -Encoding UTF8}
function Read($p){$p.Refresh();[ordered]@{pid=$p.Id;priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64();ioPriority=[RooIndustriesBackgroundOracle]::Io($p);memoryPriority=[RooIndustriesBackgroundOracle]::Memory($p)}}
function Before($fixtures){$map=@{};foreach($p in $fixtures){$map[$p.Id]=Read $p};$map}
function Same($a,$b){foreach($field in 'priorityClass','affinityMask','ioPriority','memoryPriority'){if([string]$a.$field -cne [string]$b.$field){return $false}};$true}
function Changed($fixtures){@($fixtures|Where-Object {-not$_.HasExited -and $(try{$_.Refresh();[string]$_.PriorityClass -ne 'Normal'}catch{$false})})}
function Settings($case){$path=Join-Path (Join-Path $directory $case) 'settings';[IO.Directory]::CreateDirectory($path)|Out-Null;$path}
function State($settings){[ordered]@{journal=(Test-Path (Join-Path $settings 'process-profile-apply.json'));pointer=(Test-Path (Join-Path $settings 'process-profile-recovery.json'));archived=@(Get-ChildItem $settings -Filter 'process-profile-apply.json.invalid-*' -ErrorAction SilentlyContinue|ForEach-Object Name)}}
function Service($action,$settings,$name){$output=Join-Path $directory ($name+'.json');& $dotnet $probe --recovery-slot $action $output $root $settings *> (Join-Path $directory ($name+'.log'));if($LASTEXITCODE){throw ('Recovery service '+$name+' failed')};Get-Content -Raw $output|ConvertFrom-Json}
function Cut($fixtures,$settings,$name){$pids=Join-Path $directory ($name+'-pids.txt');[IO.File]::WriteAllLines($pids,[string[]]@($fixtures|ForEach-Object {$_.Id}));$output=Join-Path $directory ($name+'.json');& $dotnet $probe --recovery-cut $output $root $settings $pids *> (Join-Path $directory ($name+'.log'));if($LASTEXITCODE){throw ('Cut apply '+$name+' failed')};Get-Content -Raw $output|ConvertFrom-Json}
function StartApply($settings,$name){$arguments=@($probe,'--recovery-slot','apply',(Join-Path $directory ($name+'.json')),$root,$settings)|ForEach-Object {'"'+$_+'"'};Own (Start-Process $dotnet -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $directory ($name+'.log')))}
function ScriptOf($app){
 $deadline=[DateTime]::UtcNow.AddSeconds(90)
 while([DateTime]::UtcNow -lt $deadline){
  $child=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$app.process.Id)|Where-Object {$_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*Apply-ProcessProfile.ps1*'})
  if($child.Count -eq 1){$receipt=Own (Get-Process -Id $child[0].ProcessId);if($receipt){return $receipt}}
  if($app.process.HasExited){throw 'The app exited before its apply script started'}
  Start-Sleep -Milliseconds 20
 }
 throw 'The apply script did not start'
}
function WaitChange($fixtures,$script){$deadline=[DateTime]::UtcNow.AddSeconds(120);while([DateTime]::UtcNow -lt $deadline){if((Changed $fixtures).Count){return};if($script.process.HasExited){throw 'The apply script ended before changing a fixture'};Start-Sleep -Milliseconds 2};throw 'No fixture changed'}
function MidApply($fixtures,$name){$count=(Changed $fixtures).Count;$results[$name+'-changedAtCut']=$count;if($count -lt 1 -or $count -ge $fixtures.Count){throw ('The cut did not land mid-apply: '+$count+' of '+$fixtures.Count+' changed')}}
function KillApply($settings,$fixtures,$name){$app=StartApply $settings ($name+'-apply');$script=ScriptOf $app;WaitChange $fixtures $script;Stop-OwnedProcess $app;Stop-OwnedProcess $script;$null=$app.process.WaitForExit(15000);$null=$script.process.WaitForExit(15000);MidApply $fixtures $name}
function Offered($settings,$name){$inspect=Service 'inspect' $settings $name;if(-not$inspect.recovery -or -not$inspect.pending -or -not(Test-Path -LiteralPath $inspect.recovery.Path)){throw ('Restore was not offered after relaunch: '+$name)};$inspect}
function RestoreAll($fixtures,$before,$settings,$name,$keep=@{}){
 $restore=Service 'restore' $settings $name;$raw=$restore.result.Value|ConvertFrom-Json
 if($restore.result.Error -or $restore.pending -or $raw.status -ne 'success' -or $raw.result.restorePendingCount -ne 0){throw ('Restore did not finish: '+$name+' '+$restore.result.Error+' '+$raw.result.summary)}
 $after=@{};foreach($p in $fixtures){if($p.HasExited){continue};$now=Read $p;$after[[string]$p.Id]=$now;$expected=@{};foreach($field in $before[$p.Id].Keys){$expected[$field]=$before[$p.Id][$field]};if($keep.ContainsKey($p.Id)){$expected.priorityClass=$keep[$p.Id]};if(-not(Same $now $expected)){throw ('Restore left '+$p.ProcessName+' different from its original: '+($now|ConvertTo-Json -Compress))}}
 $state=State $settings;if($state.journal -or $state.pointer){throw ('Restore left a journal or pointer: '+$name)}
 Save ($name+'-after') $after;$raw
}
function StopFixtures($fixtures){foreach($p in $fixtures){Stop-OwnedProcess ($owned|Where-Object {$_.Identity.pid -eq $p.Id}|Select-Object -First 1)}}

try {
 if($Cases -contains 'timeout'){
  $fixtures=Fixtures 'timeout';Profile $fixtures;$before=Before $fixtures;$settings=Settings 'timeout'
  try {
   $cut=Cut $fixtures $settings 'timeout-apply';Save 'timeout-state' (State $settings)
   if($null -eq $cut.cutAtMs){throw 'The apply finished before the cut'};MidApply $fixtures 'timeout'
   if([string]$cut.result.Error -notlike 'This took too long and was stopped.*'){throw ('The cut apply did not report the time limit: '+$cut.result.Error)}
   if(-not$cut.recovery -or -not$cut.pending -or -not$cut.result.RecoveryPath){throw 'The timed-out apply offered no Restore'}
   $inspect=Offered $settings 'timeout-relaunch';if($inspect.recovery.Path -ne $cut.recovery.Path){throw 'Relaunch offered a different Restore'}
   $results.timeout=RestoreAll $fixtures $before $settings 'timeout-restore'
  } finally {StopFixtures $fixtures}
 }
 if($Cases -contains 'killed'){
  $fixtures=Fixtures 'killed';Profile $fixtures;$before=Before $fixtures;$settings=Settings 'killed'
  try {KillApply $settings $fixtures 'killed';Save 'killed-state' (State $settings);$null=Offered $settings 'killed-relaunch';$results.killed=RestoreAll $fixtures $before $settings 'killed-restore'}
  finally {StopFixtures $fixtures}
 }
 if($Cases -contains 'closed'){
  $fixtures=Fixtures 'closed';Profile $fixtures;$before=Before $fixtures;$settings=Settings 'closed';$script=$null;$suspended=$false
  try {
   $app=StartApply $settings 'closed-apply';$script=ScriptOf $app;WaitChange $fixtures $script
   if([RooIndustriesInterruptedApply]::NtSuspendProcess($script.handle) -ne 0){throw 'The apply script could not be paused'};$suspended=$true
   Stop-OwnedProcess $app;$null=$app.process.WaitForExit(15000);MidApply $fixtures 'closed'
   $journal=Join-Path $settings 'process-profile-apply.json';$generation=Join-Path $settings 'process-profile-operation-generation.json'
   $during=Service 'inspect' $settings 'closed-relaunch-running';Save 'closed-state-running' (State $settings)
   if($during.recovery -or -not$during.pending){throw 'A still-running apply was not kept pending after relaunch'}
   $hashes=@((Get-FileHash $journal).Hash,(Get-FileHash $generation).Hash)
   $second=Service 'apply' $settings 'closed-second-apply'
   if($second.result.Value -or $second.result.Error -ne $finishing){throw ('A second apply was not refused while the first still runs: '+$second.result.Error)}
   if((Get-FileHash $journal).Hash -ne $hashes[0] -or (Get-FileHash $generation).Hash -ne $hashes[1]){throw 'The refused apply changed the running apply records'}
   if([RooIndustriesInterruptedApply]::NtResumeProcess($script.handle) -ne 0){throw 'The apply script could not be resumed'};$suspended=$false
   if(-not$script.process.WaitForExit(300000)){throw 'The resumed apply did not finish'}
   $results['closed-changedAtEnd']=(Changed $fixtures).Count
   $null=Offered $settings 'closed-relaunch-finished';$results.closed=RestoreAll $fixtures $before $settings 'closed-restore'
  } finally {if($script -and $suspended){Stop-OwnedProcess $script};StopFixtures $fixtures}
 }
 if($Cases -contains 'rebooted'){
  $fixtures=Fixtures 'rebooted';Profile $fixtures;$before=Before $fixtures;$settings=Settings 'rebooted'
  try {
   KillApply $settings $fixtures 'rebooted';StopFixtures $fixtures;foreach($p in $fixtures){$null=$p.WaitForExit(15000)}
   $inspect=Offered $settings 'rebooted-relaunch';$snapshots=@((Get-Content -Raw -LiteralPath $inspect.recovery.Path|ConvertFrom-Json).snapshots).Count
   $raw=RestoreAll $fixtures $before $settings 'rebooted-restore'
   if(@($raw.result.alreadyClosedItems).Count -ne $snapshots -or $raw.result.summary -notmatch 'Already closed or restarted:'){throw 'Restore after the apps closed did not say so'}
   $results.rebooted=$raw
  } finally {StopFixtures $fixtures}
 }
 if($Cases -contains 'other-program'){
  $fixtures=Fixtures 'other';Profile $fixtures;$before=Before $fixtures;$settings=Settings 'other-program'
  try {
   $cut=Cut $fixtures $settings 'other-program-apply';MidApply $fixtures 'other-program'
   $target=@(Changed $fixtures)[0];$target.PriorityClass='Idle';Save 'other-program-target' (Read $target)
   $null=Offered $settings 'other-program-relaunch'
   $results['other-program']=RestoreAll $fixtures $before $settings 'other-program-restore' @{$target.Id='Idle'}
  } finally {StopFixtures $fixtures}
 }
 if($Cases -contains 'stale-journal'){
  $settings=Settings 'stale-journal';$journal=Join-Path $settings 'process-profile-apply.json'
  [IO.File]::WriteAllText($journal,'{"path":',$utf8);$hash=(Get-FileHash $journal).Hash
  $broken=Service 'inspect' $settings 'stale-journal-broken';$state=State $settings;Save 'stale-journal-broken-state' $state
  if($broken.pending -or $state.journal -or $state.archived.Count -ne 1 -or (Get-FileHash (Join-Path $settings $state.archived[0])).Hash -ne $hash){throw 'A broken journal was not set aside with its bytes kept'}
  $generationId=[Guid]::NewGuid().ToString('N');$folder=Join-Path $settings ('process-profile-backups\'+$generationId);[IO.Directory]::CreateDirectory($folder)|Out-Null
  [IO.File]::WriteAllText($journal,(@{path=(Join-Path $folder 'backup.json');generation=$generationId}|ConvertTo-Json),$utf8)
  $empty=Service 'inspect' $settings 'stale-journal-unstarted';$state=State $settings;Save 'stale-journal-unstarted-state' $state
  if($empty.pending -or $state.journal -or (Test-Path $folder) -or $state.archived.Count -ne 1){throw 'A journal whose apply changed nothing was not cleared'}
  $outside=Join-Path $directory 'stale-journal-outside.json';[IO.File]::WriteAllText($outside,'{"actionId":"performance.applyProfile"}',$utf8);$outsideHash=(Get-FileHash $outside).Hash
  [IO.File]::WriteAllText($journal,(@{path=$outside;generation=$generationId}|ConvertTo-Json),$utf8)
  $foreign=Service 'inspect' $settings 'stale-journal-outside';$state=State $settings;Save 'stale-journal-outside-state' $state
  if($foreign.pending -or $state.journal -or $state.archived.Count -ne 2 -or (Get-FileHash $outside).Hash -ne $outsideHash){throw 'A journal naming a file outside its folder was not set aside'}
  $results['stale-journal']='passed'
 }
 if($Cases -contains 'race'){
  $fixtures=Fixtures 'race';Profile $fixtures;$before=Before $fixtures;$settings=Settings 'race'
  try {
   $first=StartApply $settings 'race-a';$second=StartApply $settings 'race-b'
   if(-not$first.process.WaitForExit(300000) -or -not$second.process.WaitForExit(300000)){throw 'Racing applies did not finish'}
   $outcomes=@('race-a','race-b'|ForEach-Object {Get-Content -Raw (Join-Path $directory ($_+'.json'))|ConvertFrom-Json})
   $winners=@($outcomes|Where-Object {$_.result.RecoveryPath});$losers=@($outcomes|Where-Object {-not$_.result.RecoveryPath})
   if($winners.Count -ne 1 -or $losers[0].result.Error -notin 'Another process profile action is already in progress.','Restore the last change first'){throw 'Two applies at once did not leave exactly one restore point'}
   if(@(Get-ChildItem (Join-Path $settings 'process-profile-backups') -Directory).Count -ne 1){throw 'Two applies at once wrote more than one backup'}
   $results.race=RestoreAll $fixtures $before $settings 'race-restore'
  } finally {StopFixtures $fixtures}
 }
 if($Cases -contains 'full'){
  $fixtures=Fixtures 'full';Profile $fixtures;$before=Before $fixtures;$settings=Settings 'full'
  try {
   $clock=[Diagnostics.Stopwatch]::StartNew();$apply=Service 'apply' $settings 'full-apply';$results['full-applySeconds']=$clock.Elapsed.TotalSeconds
   if($apply.result.Error -or -not$apply.result.RecoveryPath){throw ('A full apply did not finish with a restore point: '+$apply.result.Error)}
   $outcomes=@((Get-Content -Raw -LiteralPath $apply.result.RecoveryPath|ConvertFrom-Json).snapshots|ForEach-Object {$_.controlChanges}|ForEach-Object {$_.outcome})
   $results['full-outcomes']=@($outcomes|Group-Object|ForEach-Object {@{outcome=$_.Name;count=$_.Count}})
   if(@($outcomes|Where-Object {$_ -ne 'applied'}).Count -or @(Changed $fixtures).Count -ne $fixtures.Count){throw 'A full apply did not record every change it made'}
   $results.full=RestoreAll $fixtures $before $settings 'full-restore'
  } finally {StopFixtures $fixtures}
 }
 $state=@(Get-ChildItem (Join-Path $root 'backend\state') -Recurse -File -ErrorAction SilentlyContinue|ForEach-Object FullName)
 if($state.Count){Save 'backend-state' $state;throw 'App applies left files in backend\state'}
 $results.status='passed';Save 'done' $results
}catch{$results.error=$_.Exception.Message;$results.stack=$_.ScriptStackTrace;Save 'failure' $results;throw}
finally{for($i=$owned.Count-1;$i -ge 0;$i--){try{Stop-OwnedProcess $owned[$i]}catch{}};Save 'cleanup' @($owned|ForEach-Object {@{pid=$_.Identity.pid;image=$_.Identity.imagePath;exited=$_.process.HasExited}})}
