param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
$directory=Join-Path $OutRoot 'fix-round';[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$owned=[Collections.Generic.List[object]]::new();$jobs=[Collections.Generic.List[IntPtr]]::new()
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 40),$utf8)}
function Fixture([string]$name){$path=Join-Path $directory ($name+'.exe');Copy-Item "$env:SystemRoot\System32\PING.EXE" $path;$p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $p));return $p}
function Read($p){$p.Refresh();@{pid=$p.Id;name=$p.ProcessName;path=$p.Path;startTimeUtc=$p.StartTime.ToUniversalTime().ToString('o');priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p)}}
function Equal($a,$b,[string[]]$fields=@('priorityClass','affinityMask','ioPriority','memoryPriority')){foreach($field in $fields){if([string]$a.$field -cne [string]$b.$field){throw ($field+': '+$a.$field+' != '+$b.$field)}}}
function Backend([string]$name,[hashtable]$params,[string]$evidence){$raw=& (Join-Path $Source ('backend\scripts\'+$name+'.ps1')) @params;$value=$raw|ConvertFrom-Json;Save $evidence $value;if(@($value.errors).Count){throw ($evidence+': '+($value.errors|ConvertTo-Json -Depth 10 -Compress))};return $value}
function Profile($p,[string]$name){$v=Get-Content -Raw (Join-Path $Source 'backend\profiles\game-session.profile.json')|ConvertFrom-Json;$v.profileId='roo20-fix-'+$name;$v.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json';$v.foregroundGame.processNames=@('RooFixtureAbsentGame.exe');$v.targetGames=@();$v.rules=@([pscustomobject]@{ruleId='fixture-background';enabled=$true;match=@{processNames=@($p.ProcessName+'.exe')};action=@{actionType='setPriority';priorityClass='BelowNormal'};risk='low'});return $v}
function Governor($p,[string]$name){$v=Get-Content -Raw (Join-Path $Source 'backend\profiles\probalance-governor.profile.json')|ConvertFrom-Json;$v.profileId='roo20-fix-'+$name;$v.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json';$v.governor.candidateSelectors=@([pscustomobject]@{ruleId='fixture-limits';enabled=$true;match=@{processNames=@($p.ProcessName+'.exe')}});$v.governor.thresholds.totalCpuPressureThresholdPercent=0;$v.governor.thresholds.perProcessCpuThresholdPercent=0;$v.governor.thresholds.timeOverThresholdSeconds=0;$v.governor.thresholds.minimumRestraintSeconds=120;return $v}
function StartGovernor($p,$profile,[string]$name){Save ($name+'-profile') $profile;return (Backend 'Start-ProcessGovernorSession' @{ProfilePath=(Join-Path $directory ($name+'-profile.json'));StateRoot=(Join-Path $directory ($name+'-state'));ConfirmApply=$true;MaxDurationSeconds=3;PollIntervalSeconds=1;SampleIntervalMilliseconds=250} ($name+'-start'))}
try {
 foreach($flow in 'placement','game','governor'){
  $p=Fixture ('RooFixtureUpdater'+$flow);$job=[RooBackgroundOracle]::PinPriority($p,0x4000);$jobs.Add($job)
  [RooBackgroundOracle]::SetIo($p,2);[RooBackgroundOracle]::SetMemory($p,3)
  if($flow -eq 'placement'){[RooBackgroundOracle]::SetIo($p,1)}
  $before=Read $p;Save ($flow+'-before') $before;if($before.priorityClass -ne 'BelowNormal'){throw 'BelowNormal job did not pin the decisive input'}
  $profile=Profile $p $flow
  switch($flow){
   'placement' {Save 'placement-profile' $profile;$apply=Backend 'Apply-ProcessProfile' @{ProfilePath=(Join-Path $directory 'placement-profile.json');Preset='placement';StateRoot=(Join-Path $directory 'placement-state');ConfirmApply=$true} 'placement-apply';$backup=$apply.backup.location}
   'game' {$profile.foregroundGame.processNames=@($p.ProcessName+'.exe');$profile.targetGames=@([pscustomobject]@{gameId='fixture';processNames=@($p.ProcessName+'.exe')});$profile.rules=@();Save 'game-profile' $profile;$apply=Backend 'Start-GameTuneSession' @{ProfilePath=(Join-Path $directory 'game-profile.json');StateRoot=(Join-Path $directory 'game-state');ConfirmApply=$true;MaxDurationSeconds=2;PollIntervalSeconds=1} 'game-start';$backup=$apply.backup.location}
   'governor' {$profile=Governor $p $flow;$profile.governor.restraint.priorityClass='Normal';$apply=StartGovernor $p $profile 'governor';$backup=$apply.backup.location}
  }
  Save ($flow+'-after') (Read $p)
  if(($apply|ConvertTo-Json -Depth 40 -Compress) -notmatch 'Windows kept a different value'){throw ($flow+' did not report readback failure')}
  $manifest=Get-Content -Raw $backup|ConvertFrom-Json;Save ($flow+'-backup') $manifest
  $snapshot=@($manifest.snapshots|Where-Object processId -eq $p.Id)|Select-Object -Last 1
  $cpu=@($snapshot.controlChanges|Where-Object control -eq 'priorityClass')|Select-Object -Last 1
  if($cpu.outcome -ne 'failed'){throw ($flow+' still owns the failed CPU control')}
  [RooBackgroundOracle]::ChangeJobPriority($job,0);$p.PriorityClass='AboveNormal';$external=Read $p;Save ($flow+'-external') $external
  switch($flow){
   'placement' {$restore=Backend 'Restore-ProcessProfileBackup' @{BackupPath=$backup;ConfirmApply=$true} 'placement-restore'}
   'game' {$restore=Backend 'Stop-GameTuneSession' @{BackupPath=$backup;ConfirmApply=$true} 'game-restore'}
   'governor' {$restore=Backend 'Stop-ProcessGovernorSession' @{BackupPath=$backup;ConfirmApply=$true} 'governor-restore'}
  }
  $restored=Read $p;Save ($flow+'-restored') $restored;Equal $restored $before @('affinityMask','ioPriority','memoryPriority');if($restored.priorityClass -ne 'AboveNormal'){throw ($flow+' overwrote a CPU priority it did not apply')}
 }
 $p=Fixture 'RooFixtureWebHelperConflict';$p.PriorityClass='Normal';[RooBackgroundOracle]::SetIo($p,2);[RooBackgroundOracle]::SetMemory($p,5)
 $before=Read $p;Save 'conflict-before' $before;$start=StartGovernor $p (Governor $p 'conflict') 'conflict';Save 'conflict-applied' (Read $p)
 $p.PriorityClass='AboveNormal';Save 'conflict-external' (Read $p)
 $stop=Backend 'Stop-ProcessGovernorSession' @{BackupPath=$start.backup.location;ConfirmApply=$true} 'conflict-stop'
 $after=Read $p;Save 'conflict-restored' $after;Equal $after $before @('affinityMask','ioPriority','memoryPriority');if($after.priorityClass -ne 'AboveNormal' -or ($stop|ConvertTo-Json -Depth 40) -notmatch 'changed externally'){throw 'Per-field governor restore did not preserve/report the external CPU change'}
 $p.PriorityClass='Normal';$start=StartGovernor $p (Governor $p 'identity') 'identity';$before=Read $p;Save 'identity-applied' $before
 $manifest=Get-Content -Raw $start.backup.location|ConvertFrom-Json;$savedStart=$manifest.snapshots[0].processStartTimeUtc
 foreach($snapshot in $manifest.snapshots){$snapshot.processStartTimeUtc='2000-01-01T00:00:00.0000000Z'};Save 'identity-wrong-backup' $manifest
 $stop=Backend 'Stop-ProcessGovernorSession' @{BackupPath=(Join-Path $directory 'identity-wrong-backup.json');ConfirmApply=$true} 'identity-refusal';Equal (Read $p) $before
 if(@($stop.preview|Where-Object {-not$_.blocked -or $_.processStartTimeUtc -ne '2000-01-01T00:00:00.0000000Z'}).Count){throw 'Governor restore dropped the saved start time or accepted the mismatch'}
 $stop=Backend 'Stop-ProcessGovernorSession' @{BackupPath=$start.backup.location;ConfirmApply=$true} 'identity-correct-stop';Save 'identity-restored' (Read $p)
 Save 'done' @{status='passed';flows=@('placement','game','governor');externalConflict=$true;startTimeMismatch=$true;savedStartTime=$savedStart;machine=$env:COMPUTERNAME}
} catch {Save 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};throw}
finally {foreach($receipt in $owned){Stop-OwnedProcess $receipt};foreach($job in $jobs){[RooBackgroundOracle]::CloseHandle($job)|Out-Null};Save 'cleanup' @($owned|ForEach-Object {@{pid=$_.Identity.pid;exited=$_.Process.HasExited}})}
