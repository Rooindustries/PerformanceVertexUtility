param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$ServiceProbe)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
Assert-NoUnownedAppProcess
$directory=Join-Path $OutRoot 'recovery-slot';[IO.Directory]::CreateDirectory($directory)|Out-Null
$root=Join-Path $directory 'repo';[IO.Directory]::CreateDirectory($root)|Out-Null;$settings=Join-Path $directory 'settings';[IO.Directory]::CreateDirectory($settings)|Out-Null
Copy-Item (Join-Path $Source 'backend') (Join-Path $root 'backend') -Recurse
[IO.Directory]::CreateDirectory((Join-Path $root 'backend\bin'))|Out-Null
Copy-Item 'C:\Program Files\Roo Industries\Optimization Suite\backend\bin\*' (Join-Path $root 'backend\bin') -Recurse -Force
$pointer=Join-Path $settings 'process-profile-recovery.json';$generation=Join-Path $settings 'process-profile-operation-generation.json'
$owned=[Collections.Generic.List[object]]::new();$fixtures=@()
function Save($name,$value){$value|ConvertTo-Json -Depth 45|Set-Content (Join-Path $directory ($name+'.json')) -Encoding UTF8}
function Service($action,$name){$output=Join-Path $directory ($name+'.json');& (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe') ([IO.Path]::ChangeExtension($ServiceProbe,'.dll')) --recovery-slot $action $output $root $settings *> (Join-Path $directory ($name+'.log'));if($LASTEXITCODE){throw ('Recovery service '+$name+' failed')};Get-Content -Raw $output|ConvertFrom-Json}
function Fixture($name){$path=Join-Path $directory ($name+'.exe');Copy-Item "$env:SystemRoot\System32\PING.EXE" $path;$p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $p));$p.PriorityClass='Normal';[RooBackgroundOracle]::SetIo($p,2);[RooBackgroundOracle]::SetMemory($p,5);$p}
function Read($p){$p.Refresh();@{pid=$p.Id;name=$p.ProcessName;priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p)}}
function StopFixture($p){Stop-OwnedProcess ($owned|Where-Object {$_.Identity.pid -eq $p.Id}|Select-Object -First 1)}
function Profile($pids){$profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\game-session.profile.json')|ConvertFrom-Json;$profile.profileId='roo20-recovery-slot';$profile.foregroundGame.processNames=@();$profile.targetGames=@();$profile.rules=@([pscustomobject]@{ruleId='fixture';enabled=$true;match=@{processNames=@($pids|ForEach-Object {$_.ProcessName+'.exe'})};action=@{actionType='setPriority';priorityClass='BelowNormal'}});$profile|ConvertTo-Json -Depth 30|Set-Content (Join-Path $root 'backend\profiles\game-session.profile.json') -Encoding UTF8}
function Applied($name){$result=Service 'apply' $name;if($result.result.Error -or -not$result.pending){throw ('Apply did not create a recovery slot: '+$name)};$result}
function Released($name){$result=Service 'restore' $name;if($result.result.Error -or $result.pending -or (Test-Path $pointer)){throw ('Restore left a slot: '+$name)};$raw=$result.result.Value|ConvertFrom-Json;if($raw.result.restorePendingCount -ne 0 -or $raw.status -ne 'success'){throw 'Completion evidence differs'};$result}
try {
 foreach($case in 'one-closed','all-closed','restarted','unverified-start','live-refused'){
  $fixtures=@((Fixture ('RooFixtureWebHelper'+$case+'A')),(Fixture ('RooFixtureUpdater'+$case+'B')));Profile $fixtures;$before=@($fixtures|ForEach-Object {Read $_});Save ($case+'-before') $before;$apply=Applied ($case+'-apply');$backup=(Get-Content -Raw $pointer|ConvertFrom-Json).path
  if($case -eq 'one-closed'){StopFixture $fixtures[0]}
  if($case -eq 'all-closed'){foreach($p in $fixtures){StopFixture $p}}
  if($case -eq 'restarted' -or $case -eq 'unverified-start'){$saved=Get-Content -Raw $backup|ConvertFrom-Json;foreach($snapshot in $saved.snapshots){$snapshot.processStartTimeUtc=if($case -eq 'restarted'){[DateTime]::UtcNow.AddDays(-1).ToString('o')}else{$null}};$saved|ConvertTo-Json -Depth 40|Set-Content $backup -Encoding UTF8}
  $job=[IntPtr]::Zero
  try {
   if($case -eq 'live-refused'){$job=[RooBackgroundOracle]::PinPriority($fixtures[0],0x4000)}
   if($case -in 'unverified-start','live-refused'){$result=Service 'restore' ($case+'-restore');if(-not$result.pending -or -not(Test-Path $pointer)){throw 'An unverifiable/unrestored live entry released its slot'};$raw=$result.result.Value|ConvertFrom-Json;if($raw.result.summary -match 'Restore completed' -or $raw.result.summary -notmatch 'still need attention:' -or $raw.result.summary -notmatch [regex]::Escape($fixtures[0].ProcessName+'.exe')){throw 'Incomplete restore wording claims completion or omits the live app'};if($case -eq 'live-refused' -and $raw.result.summary -notmatch 'Windows kept a different value'){throw 'Partial restore omitted the failed-control reason'};if($case -eq 'unverified-start'){$saved=Get-Content -Raw $backup|ConvertFrom-Json;foreach($snapshot in $saved.snapshots){$p=$fixtures|Where-Object Id -eq $snapshot.processId;$snapshot.processStartTimeUtc=$p.StartTime.ToUniversalTime().ToString('o')};$saved|ConvertTo-Json -Depth 40|Set-Content $backup -Encoding UTF8}else{[RooBackgroundOracle]::ChangeJobPriority($job,0)};Released ($case+'-retry')|Out-Null}
   else{$result=Released ($case+'-restore');$raw=$result.result.Value|ConvertFrom-Json;if(@($raw.result.alreadyClosedItems).Count -ne $(if($case -eq 'one-closed'){1}else{2})){throw 'Closed instance evidence missing'}}
   if($case -eq 'one-closed'){foreach($field in 'priorityClass','affinityMask','ioPriority','memoryPriority'){if([string](Read $fixtures[1]).$field -cne [string]$before[1].$field){throw ('Live original differs: '+$field)}}}
   Save ($case+'-after') @($fixtures|Where-Object {-not$_.HasExited}|ForEach-Object {Read $_})
  }finally{if($job -ne [IntPtr]::Zero){[RooBackgroundOracle]::CloseHandle($job)|Out-Null};foreach($p in $fixtures){StopFixture $p}}
 }
 foreach($case in 'corrupt-pointer','missing-backup','corrupt-backup','generation-mismatch'){
  $fixtures=@((Fixture ('RooFixtureWebHelper'+$case)));Profile $fixtures;$null=Applied ($case+'-apply');$saved=Get-Content -Raw $pointer|ConvertFrom-Json
  switch($case){'corrupt-pointer'{[IO.File]::WriteAllText($pointer,'{truncated')};'missing-backup'{Move-Item $saved.path ($saved.path+'.fixture-removed')};'corrupt-backup'{[IO.File]::WriteAllText($saved.path,'{truncated')};'generation-mismatch'{[IO.File]::WriteAllText($generation,(@{id='a-different-operation'}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}}
  $oldBytes=[IO.File]::ReadAllBytes($pointer);$oldHash=(Get-FileHash $pointer).Hash;$prior=@(Get-ChildItem $settings -Filter 'process-profile-recovery.json.invalid-*'|ForEach-Object FullName)
  $result=Service 'apply' ($case+'-new-apply');if($result.result.Error -or -not$result.result.Value -or $result.pending){throw ('Invalid pointer still blocks Apply: '+$case)}
  $archive=@(Get-ChildItem $settings -Filter 'process-profile-recovery.json.invalid-*'|Where-Object {$prior -notcontains $_.FullName});if($archive.Count -ne 1 -or (Get-FileHash $archive[0].FullName).Hash -ne $oldHash){throw 'Invalid pointer bytes were not kept aside'}
  Save ($case+'-archive') @{path=$archive[0].FullName;sha256=$oldHash;bytes=$oldBytes.Length;preserved=$true}
  foreach($p in $fixtures){StopFixture $p}
 }
 Save 'done' @{status='passed';cases=@('one-closed','all-closed','restarted','unverified-start','live-refused','corrupt-pointer','missing-backup','corrupt-backup','generation-mismatch')}
}catch{Save 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};throw}
finally{foreach($r in $owned){Stop-OwnedProcess $r};Save 'cleanup' @($owned|ForEach-Object {@{pid=$_.Identity.pid;exited=$_.Process.HasExited}})}
