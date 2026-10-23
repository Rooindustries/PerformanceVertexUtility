param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[string]$BackendSource='',[int]$Probes=60,[string[]]$Cases=@('startup-race','journal-path','boundaries','timeout','killed','closed','rebooted','other-program','stale-journal','race','full'))
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
Add-Type 'using System;using System.Runtime.InteropServices;public static class RooIndustriesInterruptedApply{[DllImport("ntdll.dll")]public static extern int NtSuspendProcess(IntPtr h);[DllImport("ntdll.dll")]public static extern int NtResumeProcess(IntPtr h);}'
Assert-NoUnownedAppProcess
$directory=Join-Path $OutRoot 'interrupted-apply';[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$owned=[Collections.Generic.List[object]]::new();$results=[ordered]@{}
$tag=[Guid]::NewGuid().ToString('N').Substring(0,6)
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
if(-not$BackendSource){$BackendSource=$Source}
& $dotnet publish (Join-Path $BackendSource 'tools\validation\ClientBoundary\ClientBoundary.csproj') -c Release -p:UseSharedCompilation=false -r win-x64 --self-contained false --artifacts-path (Join-Path $directory 'build') -o (Join-Path $directory 'probe') *> (Join-Path $directory 'probe-build.log')
if($LASTEXITCODE){throw 'Client probe build failed'}
$probe=Join-Path $directory 'probe\ClientBoundary.dll'
$root=Join-Path $directory 'repo';[IO.Directory]::CreateDirectory($root)|Out-Null;Copy-Item (Join-Path $BackendSource 'backend') (Join-Path $root 'backend') -Recurse
$finishing='The last apply is still finishing. Try again in a moment.'

function Save($name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 45),$utf8)}
function Own($p){$r=New-OwnedProcess $p;if($r){$owned.Add($r)};$r}
function Fixtures($case,[int]$count=$Probes,[switch]$Gpu){
 $folder=Join-Path $directory $case;[IO.Directory]::CreateDirectory($folder)|Out-Null
 $image="$env:SystemRoot\System32\PING.EXE"
 if($Gpu){
  $image=Join-Path $directory 'gpu-fixture.exe'
  if(-not(Test-Path -LiteralPath $image)){
   & "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /out:$image (Join-Path $Source 'tools\validation\Background\LauncherFixture.cs') *> (Join-Path $directory 'gpu-fixture-build.log')
   if($LASTEXITCODE){throw 'GPU fixture compile failed'}
  }
 }
 @(for($i=0;$i -lt $count;$i++){
  $path=Join-Path $folder ('RooIndustriesCut'+$tag+$case.Substring(0,2)+$i.ToString('00')+'.exe');Copy-Item $image $path
  $signal=$path+'.signal';$arguments=if($Gpu){'"'+$signal+'" "'+$env:SystemRoot+'\System32\PING.EXE" --gpu'}else{'-t 127.0.0.1'}
  $p=Start-Process $path -ArgumentList $arguments -WindowStyle Hidden -PassThru;$null=Own $p
  if($Gpu){$deadline=[DateTime]::UtcNow.AddSeconds(30);while(-not(Test-Path -LiteralPath ($signal+'.gpu-ready'))){if($p.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'The fixture did not create its Direct3D device'};Start-Sleep -Milliseconds 50};$null=[RooIndustriesBackgroundOracle]::Gpu($p)}
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
 if($Cases -contains 'startup-race'){
  $fixtures=Fixtures 'startup-race' 1;Profile $fixtures;$before=Before $fixtures;$settings=Settings 'startup-race'
  $applyPath=Join-Path $root 'backend\scripts\Apply-ProcessProfile.ps1';$applyText=[IO.File]::ReadAllText($applyPath)
  $apps=@();$scripts=@()
  try {
   foreach($label in 'old','new'){
    $marker=Join-Path $settings ($label+'-started.txt');$release=$marker+'.release'
    $pause="[IO.File]::WriteAllText('$($marker.Replace("'","''"))','started'); while(-not [IO.File]::Exists('$($release.Replace("'","''"))')){Start-Sleep -Milliseconds 20}"
    [IO.File]::WriteAllText($applyPath,$applyText.Replace(". (Join-Path `$PSScriptRoot 'ProcessProfile.Common.ps1')",". (Join-Path `$PSScriptRoot 'ProcessProfile.Common.ps1')`r`n"+$pause),$utf8)
    $app=StartApply $settings ('startup-'+$label+'-apply');$apps+=,$app;$script=ScriptOf $app;$scripts+=,$script;$deadline=[DateTime]::UtcNow.AddSeconds(90)
    while(-not(Test-Path -LiteralPath $marker)){if($script.process.HasExited -or [DateTime]::UtcNow -gt $deadline){throw ('The '+$label+' apply never reached startup')};Start-Sleep -Milliseconds 20}
    $journal=Join-Path $settings 'process-profile-apply.json'
    if(-not(Test-Path -LiteralPath $journal)){throw 'The app did not save a journal before dispatch'}
    $saved=Get-Content -Raw -LiteralPath $journal|ConvertFrom-Json;Save ('startup-'+$label+'-journal') $saved
    if($label -eq 'old'){
     $oldGeneration=$saved.generation;Stop-OwnedProcess $app;$null=$app.process.WaitForExit(15000)
     $unstarted=Service 'inspect' $settings 'startup-relaunch';if($unstarted.pending -or $unstarted.recovery){throw 'An unstarted apply blocked the next apply'}
    }else{
     if($saved.generation -ceq $oldGeneration){throw 'The replacement apply did not get a new generation'}
     $hash=(Get-FileHash -LiteralPath $journal).Hash
     [IO.File]::WriteAllText((Join-Path $settings 'old-started.txt.release'),'continue',$utf8)
     if(-not$scripts[0].process.WaitForExit(120000)){throw 'The old apply did not finish after resuming'}
     $changed=(Changed $fixtures).Count;$backupExists=Test-Path -LiteralPath $saved.path
     Save 'startup-old-resumed' @{oldGeneration=$oldGeneration;newGeneration=$saved.generation;changed=$changed;newBackupExists=$backupExists;journalHash=(Get-FileHash -LiteralPath $journal).Hash;expectedJournalHash=$hash}
     if($changed -or $backupExists -or (Get-FileHash -LiteralPath $journal).Hash -cne $hash){throw 'The old apply consumed the newer journal or changed a process'}
     [IO.File]::WriteAllText($release,'continue',$utf8)
     if(-not$app.process.WaitForExit(120000)){throw 'The replacement apply did not finish'}
     $newResult=Get-Content -Raw (Join-Path $directory 'startup-new-apply.json')|ConvertFrom-Json
     if($newResult.result.Error -or -not$newResult.result.RecoveryPath -or (Changed $fixtures).Count -ne 1){throw 'The replacement apply did not keep its own restore point'}
    }
   }
   [IO.File]::WriteAllText($applyPath,$applyText,$utf8)
   $null=Offered $settings 'startup-final-relaunch';$results['startup-race']=RestoreAll $fixtures $before $settings 'startup-restore'
  }finally{foreach($app in $apps){Stop-OwnedProcess $app};foreach($script in $scripts){Stop-OwnedProcess $script};[IO.File]::WriteAllText($applyPath,$applyText,$utf8);StopFixtures $fixtures}
 }
 if($Cases -contains 'journal-path'){
  $fixtures=Fixtures 'journal-path' 1;Profile $fixtures;$before=Before $fixtures;$settings=Settings 'journal-path'
  $applyPath=Join-Path $root 'backend\scripts\Apply-ProcessProfile.ps1';$applyText=[IO.File]::ReadAllText($applyPath);$app=$null;$script=$null
  try {
   $marker=Join-Path $settings 'started.txt';$release=$marker+'.release'
   $pause="[IO.File]::WriteAllText('$($marker.Replace("'","''"))','started'); while(-not [IO.File]::Exists('$($release.Replace("'","''"))')){Start-Sleep -Milliseconds 20}"
   [IO.File]::WriteAllText($applyPath,$applyText.Replace(". (Join-Path `$PSScriptRoot 'ProcessProfile.Common.ps1')",". (Join-Path `$PSScriptRoot 'ProcessProfile.Common.ps1')`r`n"+$pause),$utf8)
   $app=StartApply $settings 'journal-path-apply';$script=ScriptOf $app;$deadline=[DateTime]::UtcNow.AddSeconds(90)
   while(-not(Test-Path -LiteralPath $marker)){if($script.process.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'The apply never reached startup'};Start-Sleep -Milliseconds 20}
   $journal=Join-Path $settings 'process-profile-apply.json'
   if(-not(Test-Path -LiteralPath $journal)){throw 'The app did not save a journal before dispatch'}
   $saved=Get-Content -Raw -LiteralPath $journal|ConvertFrom-Json;$outside=Join-Path $directory 'redirected-backup.json';$saved.path=$outside
   [IO.File]::WriteAllText($journal,($saved|ConvertTo-Json -Depth 10),$utf8);$hash=(Get-FileHash -LiteralPath $journal).Hash;Save 'journal-path-header' $saved
   [IO.File]::WriteAllText($release,'continue',$utf8)
   if(-not$app.process.WaitForExit(120000)){throw 'The redirected apply did not finish'}
   $changed=(Changed $fixtures).Count;$outsideExists=Test-Path -LiteralPath $outside;Save 'journal-path-resumed' @{changed=$changed;outsideBackupExists=$outsideExists}
   if($changed -or $outsideExists){throw 'The apply trusted a redirected backup path and changed a process'}
   $inspect=Service 'inspect' $settings 'journal-path-relaunch';$state=State $settings
   if($inspect.pending -or $inspect.recovery -or $state.journal -or $state.archived.Count -ne 1 -or (Get-FileHash (Join-Path $settings $state.archived[0])).Hash -cne $hash){throw 'The redirected journal was not kept intact'}
   if(-not(Same (Read $fixtures[0]) $before[$fixtures[0].Id])){throw 'Refusing the redirected journal changed an original value'}
   $results['journal-path']='passed'
  }finally{if($app){Stop-OwnedProcess $app};if($script){Stop-OwnedProcess $script};[IO.File]::WriteAllText($applyPath,$applyText,$utf8);StopFixtures $fixtures}
 }
 if($Cases -contains 'boundaries'){
  $applyPath=Join-Path $root 'backend\scripts\Apply-ProcessProfile.ps1';$commonPath=Join-Path $root 'backend\scripts\ProcessProfile.Common.ps1';$statePath=Join-Path $root 'backend\scripts\OperationState.Common.ps1'
  $applyText=[IO.File]::ReadAllText($applyPath);$commonText=[IO.File]::ReadAllText($commonPath);$stateText=[IO.File]::ReadAllText($statePath);$boundaryFailures=@()
  $outputCall='Write-RooIndustriesJsonOutput $applyEnvelope $OutputPath'
  if(-not$applyText.Contains($outputCall)){throw 'The real successful apply output call was not found'}
  try {
   $points=@('backup-before','backup-flushed','backup-after','backup-replacing','backup-replaced','output')+@('priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority'|ForEach-Object {$_+'-before';$_+'-written';$_+'-after'})
   foreach($point in $points){
    $name='boundary-'+$point;$fixtures=Fixtures $name 1 -Gpu;Profile $fixtures;$before=Before $fixtures;$settings=Settings $name
    try {
     $profilePath=Join-Path $root 'backend\profiles\game-session.profile.json';$profile=Get-Content -Raw $profilePath|ConvertFrom-Json
     $mask=[long]$fixtures[0].ProcessorAffinity.ToInt64();$profile.rules[0].action|Add-Member affinityMask ($mask -band (-$mask));$profile.rules[0].action|Add-Member ioPriority 'VeryLow';$profile.rules[0].action|Add-Member gpuPriority 'BelowNormal'
     [IO.File]::WriteAllText($profilePath,($profile|ConvertTo-Json -Depth 30),$utf8)
     $gpuBefore=[RooIndustriesBackgroundOracle]::Gpu($fixtures[0]);$marker=Join-Path $settings 'checkpoint.txt'
     $checkpoint="function Wait-RooIndustriesInterruptedBoundary([string]`$point){if(`$point -ceq '$point'){[IO.File]::WriteAllText('$($marker.Replace("'","''"))',`$point);while(`$true){Start-Sleep -Milliseconds 100}}}"
     $instrumented=$applyText.Replace(". (Join-Path `$PSScriptRoot 'ProcessProfile.Common.ps1')",". (Join-Path `$PSScriptRoot 'ProcessProfile.Common.ps1')`r`n"+$checkpoint)
     $instrumented=$instrumented.Replace('Write-RooIndustriesOperationJson $backupManifest $backupPath',"Wait-RooIndustriesInterruptedBoundary 'backup-before'; Write-RooIndustriesOperationJson `$backupManifest `$backupPath; Wait-RooIndustriesInterruptedBoundary 'backup-after'")
     $instrumented=$instrumented.Replace($outputCall,("Wait-RooIndustriesInterruptedBoundary 'output'; "+$outputCall))
     [IO.File]::WriteAllText($applyPath,$instrumented,$utf8)
     $start=$commonText.IndexOf('function Invoke-RooIndustriesProcessControlChange {');if($start -lt 0){throw 'The real process writer was not found'}
     $tail=$commonText.Substring($start).Replace('switch ($control) {',"Wait-RooIndustriesInterruptedBoundary (`$control+'-before'); switch (`$control) {")
     $tail=$tail.Replace('$actual = Get-RooIndustriesProcessControlReadback $Process $control',"Wait-RooIndustriesInterruptedBoundary (`$control+'-written'); `$actual = Get-RooIndustriesProcessControlReadback `$Process `$control")
     $tail=$tail.Replace("`$Change.outcome = 'applied'","`$Change.outcome = 'applied'; Wait-RooIndustriesInterruptedBoundary (`$control+'-after')")
     [IO.File]::WriteAllText($commonPath,($commonText.Substring(0,$start)+$tail),$utf8)
     $stateInstrumented=$stateText.Replace('$stream.Flush($true)',"`$stream.Flush(`$true); Wait-RooIndustriesInterruptedBoundary 'backup-flushed'")
     $stateInstrumented=$stateInstrumented.Replace('[IO.File]::Replace($temporary,$full,[System.Management.Automation.Language.NullString]::Value)',"Wait-RooIndustriesInterruptedBoundary 'backup-replacing'; [IO.File]::Replace(`$temporary,`$full,[System.Management.Automation.Language.NullString]::Value); Wait-RooIndustriesInterruptedBoundary 'backup-replaced'")
     [IO.File]::WriteAllText($statePath,$stateInstrumented,$utf8)
     $app=StartApply $settings ($name+'-apply');$script=ScriptOf $app;$deadline=[DateTime]::UtcNow.AddSeconds(120)
     while(-not(Test-Path -LiteralPath $marker)){if($script.process.HasExited -or [DateTime]::UtcNow -gt $deadline){throw ('The real apply never reached '+$point)};Start-Sleep -Milliseconds 10}
     Stop-OwnedProcess $app;Stop-OwnedProcess $script;$null=$app.process.WaitForExit(15000);$null=$script.process.WaitForExit(15000)
     [IO.File]::WriteAllText($applyPath,$applyText,$utf8);[IO.File]::WriteAllText($commonPath,$commonText,$utf8);[IO.File]::WriteAllText($statePath,$stateText,$utf8)
     $atCut=Read $fixtures[0];Save ($name+'-cut') @{point=$point;before=$before[$fixtures[0].Id];after=$atCut;gpuBefore=$gpuBefore;gpuAfter=[RooIndustriesBackgroundOracle]::Gpu($fixtures[0])}
     if($point -match '^(priorityClass|affinityMask|ioPriority|memoryPriority)-(before|written|after)$'){
      $control=$Matches[1];$position=$Matches[2];$wanted=switch($control){'priorityClass'{'BelowNormal'};'affinityMask'{$mask -band (-$mask)};'ioPriority'{0};'memoryPriority'{2}}
      $expected=if($position -eq 'before'){$before[$fixtures[0].Id][$control]}else{$wanted}
      if([string]$atCut[$control] -cne [string]$expected){throw ('The cut did not observe the real '+$control+' write at '+$point)}
     }
     if($point -match '^gpuPriority-(before|written|after)$'){
      $expected=if($Matches[1] -eq 'before'){$gpuBefore}else{1}
      if([RooIndustriesBackgroundOracle]::Gpu($fixtures[0]) -ne $expected){throw ('The cut did not observe the real GPU priority write at '+$point)}
     }
     if($point -in 'backup-before','backup-flushed'){
      $inspect=Service 'inspect' $settings ($name+'-relaunch');if($inspect.pending -or $inspect.recovery -or -not(Same $atCut $before[$fixtures[0].Id])){throw 'An apply killed before its backup left changes or blocked Apply'}
     }else{
      $null=Offered $settings ($name+'-relaunch');$null=RestoreAll $fixtures $before $settings ($name+'-restore')
      if([RooIndustriesBackgroundOracle]::Gpu($fixtures[0]) -ne $gpuBefore){throw ('Restore changed the original GPU priority at '+$point)}
     }
     $results[$name]='passed'
    } catch {$boundaryFailures+=($point+': '+$_.Exception.Message);$results[$name]=$_.Exception.Message}
    finally {StopFixtures $fixtures;[IO.File]::WriteAllText($applyPath,$applyText,$utf8);[IO.File]::WriteAllText($commonPath,$commonText,$utf8);[IO.File]::WriteAllText($statePath,$stateText,$utf8)}
   }
   Save 'boundaries' $results
   if($boundaryFailures.Count){throw ($boundaryFailures -join '; ')}
  } finally {[IO.File]::WriteAllText($applyPath,$applyText,$utf8);[IO.File]::WriteAllText($commonPath,$commonText,$utf8);[IO.File]::WriteAllText($statePath,$stateText,$utf8)}
 }
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
  $outside=Join-Path $directory 'outside-backup.json';[IO.File]::WriteAllText($outside,'{"actionId":"performance.applyProfile"}',$utf8);$outsideHash=(Get-FileHash $outside).Hash
  [IO.File]::WriteAllText($journal,(@{path=$outside;generation=$generationId}|ConvertTo-Json),$utf8)
  $foreign=Service 'inspect' $settings 'stale-journal-outside';$state=State $settings;Save 'stale-journal-outside-state' $state
  if($foreign.pending -or $state.journal -or $state.archived.Count -ne 2 -or (Get-FileHash $outside).Hash -ne $outsideHash){throw 'A journal naming a file outside its folder was not set aside'}
  $invalidJournals=@('null','{}',(@{path=$null;generation=$generationId}|ConvertTo-Json),(@{path=(Join-Path $folder 'backup.json');generation=$null}|ConvertTo-Json),'{"path":"unused","generation":"old-version"}',(@{path='unused';generation=$generationId;schemaVersion=2}|ConvertTo-Json))
  for($i=0;$i -lt $invalidJournals.Count;$i++){
   [IO.File]::WriteAllText($journal,$invalidJournals[$i],$utf8);$hash=(Get-FileHash $journal).Hash;$archivedBefore=@((State $settings).archived)
   $invalid=Service 'inspect' $settings ('stale-journal-shape-'+$i);$state=State $settings;$newArchives=@($state.archived|Where-Object {$_ -notin $archivedBefore})
   if($invalid.pending -or $invalid.recovery -or $state.journal -or $newArchives.Count -ne 1 -or (Get-FileHash (Join-Path $settings $newArchives[0])).Hash -ne $hash){throw ('An invalid journal was not kept intact: '+$invalidJournals[$i])}
  }
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
