param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[ValidateSet('presets','placement-origins','game-memory','limits-memory','identity','memory-controls')][string]$Scenario='presets',[string]$BackendSource='')
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1')
. (Join-Path $Source 'backend\scripts\BackgroundPlacement.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
$directory=Join-Path $OutRoot $Scenario
[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$owned=[Collections.Generic.List[object]]::new()
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory $name),($value|ConvertTo-Json -Depth 40),$utf8)}
function Fixture([string]$name){$path=Join-Path $directory ($name+'.exe');Copy-Item "$env:SystemRoot\System32\PING.EXE" $path; $p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $p));return $p}
function Read($p){$p.Refresh();[pscustomobject]@{pid=$p.Id;name=$p.ProcessName;path=$p.Path;startTimeUtc=$p.StartTime.ToUniversalTime().ToString('o');priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p)}}
function ReadAll{@($fixtures|ForEach-Object {Read $_})}
function Equal($actual,$expected){foreach($field in 'priorityClass','affinityMask','ioPriority','memoryPriority'){if([string]$actual.$field -cne [string]$expected.$field){throw ($actual.name+' '+$field+': '+$actual.$field+' != '+$expected.$field)}}}
function Backend([string]$name,[hashtable]$arguments){$root=if($BackendSource){$BackendSource}else{$Source};$raw=& (Join-Path $root ('backend\scripts\'+$name+'.ps1')) @arguments;$value=$raw|ConvertFrom-Json;Save ($name+'.json') $value;if($value.errors.Count){throw ($name+': '+($value.errors|ConvertTo-Json -Depth 8 -Compress))};return $value}
try {
 $updater=Fixture 'RooFixtureUpdater';$web=Fixture 'RooFixtureWebHelper';$game=Fixture 'RooFixtureGame';$protected=Fixture 'MsMpEng'
 $fixtures=@($updater,$web,$game,$protected)
 foreach($p in $fixtures){$p.PriorityClass='Normal';[RooBackgroundOracle]::SetIo($p,2);[RooBackgroundOracle]::SetMemory($p,5)}
 $originals=ReadAll;Save 'as-found.json' $originals;Save 'owned-processes.json' @($owned|ForEach-Object {$_.Identity})
 $profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\game-session.profile.json')|ConvertFrom-Json
 $profile.profileId='roo20-fixture-background'
 $profile.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json'
 $profile.foregroundGame.processNames=@('RooFixtureGame.exe')
 $profile.targetGames=@([pscustomobject]@{gameId='fixture-game';processNames=@('RooFixtureGame.exe')})
 $profile.rules=@([pscustomobject]@{ruleId='fixture-background';enabled=$true;match=@{processNames=@('RooFixtureUpdater.exe','RooFixtureWebHelper.exe','RooFixtureGame.exe','MsMpEng.exe')};action=@{actionType='setPriority';priorityClass='BelowNormal'};risk='low'})
 $profilePath=Join-Path $directory 'profile.json';[IO.File]::WriteAllText($profilePath,($profile|ConvertTo-Json -Depth 30),$utf8)
 $state=Join-Path $directory 'state'
 $placement=Read-RooIndustriesBackgroundPlacement;Save 'placement.json' $placement
 switch($Scenario){
  'presets' {
   foreach($preset in 'lower','placement'){
    foreach($p in @($updater,$web)){$p.PriorityClass='AboveNormal';[RooBackgroundOracle]::SetIo($p,1);[RooBackgroundOracle]::SetMemory($p,3)}
    $before=ReadAll;Save ($preset+'-before.json') $before
    $preview=Backend 'Preview-ProcessProfile' @{ProfilePath=$profilePath;Preset=$preset};Save ($preset+'-preview.json') $preview
    $apply=Backend 'Apply-ProcessProfile' @{ProfilePath=$profilePath;Preset=$preset;StateRoot=$state;ConfirmApply=$true};Save ($preset+'-apply.json') $apply
    $after=ReadAll;Save ($preset+'-after.json') $after
    foreach($p in @($updater,$web)){$a=Read $p;if($preset -eq 'lower'){if($a.priorityClass -ne 'BelowNormal' -or $a.memoryPriority -ne 2){throw 'Lower preset did not lower CPU and memory'}}else{if(-not$placement.available){throw $placement.reason};if($a.priorityClass -ne 'Normal' -or $a.ioPriority -ne 2 -or $a.memoryPriority -ne 5 -or $a.affinityMask -ne $placement.mask){throw 'Placement readback differs from the preset'}}}
    Equal (Read $protected) ($before|Where-Object pid -eq $protected.Id)
    if($preset -eq 'placement'){Equal (Read $game) ($before|Where-Object pid -eq $game.Id)}
    $backup=$apply.backup.location;if(-not$backup){throw 'Apply did not save originals'}
    $restore=Backend 'Restore-ProcessProfileBackup' @{BackupPath=$backup;ConfirmApply=$true};Save ($preset+'-restore.json') $restore
    $restored=ReadAll;Save ($preset+'-restored.json') $restored
    foreach($p in $fixtures){Equal (Read $p) ($before|Where-Object pid -eq $p.Id)}
    foreach($p in @($updater,$web)){$o=$originals|Where-Object pid -eq $p.Id;$p.PriorityClass=$o.priorityClass;[RooBackgroundOracle]::SetIo($p,$o.ioPriority);[RooBackgroundOracle]::SetMemory($p,$o.memoryPriority)}
   }
  }
  'placement-origins' {
   $results=@()
   foreach($case in @(@{name='original-realtime';cpu='RealTime';io=1},@{name='original-io-high';cpu='AboveNormal';io=3})){
    $privilegeBefore=[RooBackgroundOracle]::IoPrivilegeAttributes()
    $updater.PriorityClass=$case.cpu;[RooBackgroundOracle]::SetIo($updater,$case.io);[RooBackgroundOracle]::SetMemory($updater,3)
    $before=Read $updater;Save ($case.name+'-before.json') $before
    if($before.priorityClass -ne $case.cpu -or $before.ioPriority -ne $case.io){throw 'Windows did not establish the original control value'}
    $apply=Backend 'Apply-ProcessProfile' @{ProfilePath=$profilePath;Preset='placement';StateRoot=$state;ConfirmApply=$true};Save ($case.name+'-apply.json') $apply
    $after=Read $updater;Save ($case.name+'-after.json') $after
    if($after.priorityClass -ne 'Normal' -or $after.ioPriority -ne 2 -or $after.memoryPriority -ne 5 -or $after.affinityMask -ne $placement.mask){throw 'Original-value case did not apply the normal placement'}
    $restore=Backend 'Restore-ProcessProfileBackup' @{BackupPath=$apply.backup.location;ConfirmApply=$true};Save ($case.name+'-restore.json') $restore
    $restored=Read $updater;Save ($case.name+'-restored.json') $restored
    $errorText=$null;try{Equal $restored $before}catch{$errorText=$_.Exception.Message}
    $privilegeAfter=[RooBackgroundOracle]::IoPrivilegeAttributes()
    if($privilegeAfter -ne $privilegeBefore){throw 'The inverse restore changed the evidence process token privilege'}
    $results+=@{case=$case.name;passed=(-not$errorText);error=$errorText;privilegeBefore=$privilegeBefore;privilegeAfter=$privilegeAfter}
    $updater.PriorityClass='Normal';[RooBackgroundOracle]::SetIo($updater,2);[RooBackgroundOracle]::SetMemory($updater,5);$updater.ProcessorAffinity=[IntPtr]$originals[0].affinityMask
   }
   Save 'results.json' $results
   if(@($results|Where-Object {-not$_.passed}).Count){throw 'Placement did not restore an original priority; inspect results.json'}
  }
  'game-memory' {
   $web.PriorityClass='RealTime';[RooBackgroundOracle]::SetIo($web,3)
   $profile.rules[0].action['ioPriority']='Normal'
   [IO.File]::WriteAllText($profilePath,($profile|ConvertTo-Json -Depth 30),$utf8)
   $privilegeBefore=[RooBackgroundOracle]::IoPrivilegeAttributes()
   [RooBackgroundOracle]::SetMemory($game,2);$before=ReadAll;Save 'before.json' $before
   $start=Backend 'Start-GameTuneSession' @{ProfilePath=$profilePath;StateRoot=$state;ConfirmApply=$true;MaxDurationSeconds=2;PollIntervalSeconds=1}
   $after=ReadAll;Save 'after.json' $after
   $gameAfter=Read $game;$webAfter=Read $web
   if($gameAfter.memoryPriority -ne 5 -or $gameAfter.priorityClass -ne 'AboveNormal' -or $webAfter.memoryPriority -ne 2 -or $webAfter.priorityClass -ne 'BelowNormal' -or $webAfter.ioPriority -ne 2){throw 'Game Tune CPU, I/O or memory defaults not applied'}
   Equal (Read $protected) ($before|Where-Object pid -eq $protected.Id)
   $stop=Backend 'Stop-GameTuneSession' @{SessionPath=$start.sessionPath;BackupPath=$start.backup.location;ConfirmApply=$true}
   Save 'restored.json' (ReadAll);foreach($p in $fixtures){Equal (Read $p) ($before|Where-Object pid -eq $p.Id)}
   Save 'privilege.json' @{before=$privilegeBefore;after=[RooBackgroundOracle]::IoPrivilegeAttributes()}
   if([RooBackgroundOracle]::IoPrivilegeAttributes() -ne $privilegeBefore){throw 'Game Tune restore retained an I/O privilege change'}
  }
  'limits-memory' {
   [RooBackgroundOracle]::SetIo($web,3);$privilegeBefore=[RooBackgroundOracle]::IoPrivilegeAttributes()
   $governor=Get-Content -Raw (Join-Path $Source 'backend\profiles\probalance-governor.profile.json')|ConvertFrom-Json
   $governor.profileId='roo20-fixture-limits';$governor.protectedCatalogPath=$profile.protectedCatalogPath
   $governor.governor.candidateSelectors=@([pscustomobject]@{ruleId='fixture-limits';enabled=$true;match=@{processNames=@('RooFixtureWebHelper.exe','MsMpEng.exe')}})
   $governor.governor.thresholds.totalCpuPressureThresholdPercent=0;$governor.governor.thresholds.perProcessCpuThresholdPercent=0;$governor.governor.thresholds.timeOverThresholdSeconds=0;$governor.governor.thresholds.minimumRestraintSeconds=120
   $governorPath=Join-Path $directory 'governor.json';[IO.File]::WriteAllText($governorPath,($governor|ConvertTo-Json -Depth 30),$utf8)
   $before=ReadAll;Save 'before.json' $before
   $start=Backend 'Start-ProcessGovernorSession' @{ProfilePath=$governorPath;StateRoot=$state;ConfirmApply=$true;MaxDurationSeconds=4;PollIntervalSeconds=1;SampleIntervalMilliseconds=250}
   Save 'after.json' (ReadAll);$a=Read $web;if($a.memoryPriority -ne 2 -or $a.ioPriority -ne 1 -or $a.priorityClass -ne 'BelowNormal'){throw 'Background limits memory restraint missing'}
   Equal (Read $protected) ($before|Where-Object pid -eq $protected.Id)
   $stop=Backend 'Stop-ProcessGovernorSession' @{SessionPath=$start.sessionPath;BackupPath=$start.backup.location;ConfirmApply=$true}
   Save 'restored.json' (ReadAll);foreach($p in $fixtures){Equal (Read $p) ($before|Where-Object pid -eq $p.Id)}
   Save 'privilege.json' @{before=$privilegeBefore;after=[RooBackgroundOracle]::IoPrivilegeAttributes()}
   if([RooBackgroundOracle]::IoPrivilegeAttributes() -ne $privilegeBefore){throw 'Background limits restore retained an I/O privilege change'}
  }
  'identity' {
   $apply=Backend 'Apply-ProcessProfile' @{ProfilePath=$profilePath;StateRoot=$state;ConfirmApply=$true}
   $backup=Get-Content -Raw $apply.backup.location|ConvertFrom-Json
   foreach($snapshot in $backup.snapshots){$snapshot.processStartTimeUtc='2000-01-01T00:00:00.0000000Z'}
   $altered=Join-Path $directory 'wrong-start-backup.json';[IO.File]::WriteAllText($altered,($backup|ConvertTo-Json -Depth 30),$utf8)
   $before=ReadAll;Save 'before-mismatch.json' $before
   $refusal=Backend 'Restore-ProcessProfileBackup' @{BackupPath=$altered;ConfirmApply=$true};if(@($refusal.preview|Where-Object {-not$_.blocked}).Count){throw 'Start-time mismatch was not blocked'}
   foreach($p in $fixtures){Equal (Read $p) ($before|Where-Object pid -eq $p.Id)}
   $restore=Backend 'Restore-ProcessProfileBackup' @{BackupPath=$apply.backup.location;ConfirmApply=$true}
   . (Join-Path $Source 'backend\scripts\GameTuneSession.Common.ps1')
   $entry=@{processId=$web.Id;processName=$web.ProcessName;executablePath=$web.Path;processStartTimeUtc='2000-01-01T00:00:00.0000000Z'}
   $identity=Get-RooIndustriesGameTuneLiveProcessIdentity $entry;Save 'game-tune-mismatch.json' @{matches=$identity.matches;reason=$identity.reason};if($identity.matches){throw 'Game Tune accepted a reused PID identity'}
   [RooBackgroundOracle]::SetMemory($game,2);$gameOriginals=ReadAll;Save 'game-tune-before.json' $gameOriginals
   $start=Backend 'Start-GameTuneSession' @{ProfilePath=$profilePath;StateRoot=$state;ConfirmApply=$true;MaxDurationSeconds=2;PollIntervalSeconds=1}
   $backupBytes=[IO.File]::ReadAllBytes($start.backup.location);$gameBackup=Get-Content -Raw $start.backup.location|ConvertFrom-Json
   foreach($snapshot in $gameBackup.snapshots){$snapshot.processStartTimeUtc='2000-01-01T00:00:00.0000000Z'}
   [IO.File]::WriteAllText($start.backup.location,($gameBackup|ConvertTo-Json -Depth 30),$utf8)
   $beforeStop=ReadAll;Save 'game-tune-before-mismatch-stop.json' $beforeStop
   $refusal=Backend 'Stop-GameTuneSession' @{SessionPath=$start.sessionPath;BackupPath=$start.backup.location;ConfirmApply=$true};Save 'game-tune-mismatch-stop.json' $refusal
   if(@($refusal.preview|Where-Object {-not$_.blocked}).Count){throw 'Game Tune stop accepted a start-time mismatch'}
   foreach($p in $fixtures){Equal (Read $p) ($beforeStop|Where-Object pid -eq $p.Id)}
   [IO.File]::WriteAllBytes($start.backup.location,$backupBytes)
   $restore=Backend 'Stop-GameTuneSession' @{SessionPath=$start.sessionPath;BackupPath=$start.backup.location;ConfirmApply=$true};Save 'game-tune-correct-stop.json' $restore
   Save 'game-tune-restored.json' (ReadAll);foreach($p in $fixtures){Equal (Read $p) ($gameOriginals|Where-Object pid -eq $p.Id)}
  }
  'memory-controls' {
   $results=@();$before=Read $updater;Save 'before.json' $before
   foreach($value in 1..5){Set-RooIndustriesProcessMemoryPriority $updater $value;$controlState=Get-RooIndustriesProcessControlState $updater.Id;$observed=[RooBackgroundOracle]::Memory($updater);$results+=@{requested=$value;observed=$observed;state=($controlState|Select-Object exists,priorityClass,affinityMask,ioPriority,memoryPriority,memoryPriorityName,memoryPriorityAvailable,memoryPriorityStatus,systemAffinityMask,startTimeUtc)};if($observed -ne $value -or -not$controlState.memoryPriorityAvailable -or $controlState.memoryPriority -ne $value){throw 'Native memory read/write differs from independent readback'}}
   foreach($value in @($null,-1,0,6,2.5,'not-a-priority')){$prior=[RooBackgroundOracle]::Memory($updater);$refusal=$null;try{Set-RooIndustriesProcessMemoryPriority $updater $value}catch{$refusal=$_.Exception.Message};$after=[RooBackgroundOracle]::Memory($updater);$results+=@{requested=$value;error=$refusal;before=$prior;after=$after};if(-not$refusal -or $prior -ne $after){throw 'Invalid memory priority was not refused without a write'}}
   [RooBackgroundOracle]::SetMemory($updater,$before.memoryPriority);Save 'results.json' $results;Save 'restored.json' (Read $updater);Equal (Read $updater) $before
  }
 }
 Save 'done.json' @{status='passed';scenario=$Scenario;machine=$env:COMPUTERNAME;utc=[DateTime]::UtcNow.ToString('o')}
} finally {
 foreach($receipt in $owned){Stop-OwnedProcess $receipt}
 Save 'cleanup.json' @($owned|ForEach-Object {@{pid=$_.Identity.pid;exited=$_.Process.HasExited}})
}
