param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[ValidateSet('all','placement','query-only','gpu-controls')][string]$Mode='all')
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1')
. (Join-Path $Source 'backend\scripts\BackgroundPlacement.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
$directory=Join-Path $OutRoot 'review2';[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$owned=[Collections.Generic.List[object]]::new();$query=$null;$dacl=$null;$debugPrior=$null
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 45),$utf8)}
function WaitGpu($p){if($Mode -eq 'gpu-controls'){$until=[DateTime]::UtcNow.AddSeconds(15);while(-not(Test-Path (Join-Path $directory ($p.ProcessName+'.signal.gpu-ready'))) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 100};if($p.HasExited -or [DateTime]::UtcNow -ge $until){throw 'GPU fixture did not create its D3D device'}}}
function Fixture([string]$name){$path=Join-Path $directory ($name+'.exe');if($Mode -eq 'gpu-controls'){Copy-Item $launcherExe $path;$arguments='"'+(Join-Path $directory ($name+'.signal'))+'" "'+$childPath+'" --gpu'}else{Copy-Item "$env:SystemRoot\System32\PING.EXE" $path;$arguments='-t 127.0.0.1'};$p=Start-Process $path -ArgumentList $arguments -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $p));WaitGpu $p;return $p}
function Read($p,[switch]$NoGpu){$p.Refresh();[pscustomobject]@{pid=$p.Id;name=$p.ProcessName;path=$p.Path;startTimeUtc=$p.StartTime.ToUniversalTime().ToString('o');priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p);gpuPriority=if($Mode -eq 'gpu-controls' -and -not$NoGpu){[RooBackgroundOracle]::Gpu($p)}else{$null}}}
function Equal($actual,$expected){foreach($field in 'priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority'){if([string]$actual.$field -cne [string]$expected.$field){throw ($actual.name+' '+$field+': '+$actual.$field+' != '+$expected.$field)}}}
function Backend([string]$name,[hashtable]$fields,[string]$evidence){$value=(& (Join-Path $Source ('backend\scripts\'+$name+'.ps1')) @fields)|ConvertFrom-Json;Save $evidence $value;if($null -ne $value.errors -and @($value.errors).Count){throw ($value.errors|ConvertTo-Json -Depth 10 -Compress)};return $value}
function Child($parent,[string]$flow){$output=Join-Path $directory ($flow+'-'+$parent.ProcessName+'-child.pid');[IO.File]::WriteAllText((Join-Path $directory ($parent.ProcessName+'.signal')),$output);$until=[DateTime]::UtcNow.AddSeconds(15);while(-not(Test-Path $output) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 100};if(-not(Test-Path $output)){throw 'Launcher did not create a child'};$child=Get-Process -Id ([int][IO.File]::ReadAllText($output));$owned.Add((New-OwnedProcess $child));$read=Read $child -NoGpu;Save ($flow+'-'+$parent.ProcessName+'-child') $read;return $read}
try {
 $launcherExe=Join-Path $directory 'steam.exe'
 & "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /out:$launcherExe (Join-Path $Source 'tools\validation\Background\LauncherFixture.cs')
 if($LASTEXITCODE){throw 'Launcher fixture compile failed'}
 Copy-Item $launcherExe (Join-Path $directory 'RooFixtureLauncher.exe')
 Copy-Item $launcherExe (Join-Path $directory 'gamelaunchhelper.exe')
 $childPath=Join-Path $directory 'RooFixtureChild.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $childPath
 $launchers=@(foreach($name in 'steam','RooFixtureLauncher','gamelaunchhelper'){$arguments='"'+(Join-Path $directory ($name+'.signal'))+'" "'+$childPath+'"'+$(if($Mode -eq 'gpu-controls'){' --gpu'}else{''});$p=Start-Process (Join-Path $directory ($name+'.exe')) -ArgumentList $arguments -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $p));WaitGpu $p;$p})
 $updater=Fixture 'RooFixtureUpdater';$web=Fixture 'RooFixtureWebHelper';$game=Fixture 'RooFixtureGame';$protected=Fixture 'MsMpEng';$fixtures=@($launchers)+@($updater,$web,$game,$protected)
 foreach($p in $fixtures){$p.PriorityClass='Normal';[RooBackgroundOracle]::SetIo($p,2);[RooBackgroundOracle]::SetMemory($p,5)}
 $originals=@($fixtures|ForEach-Object {Read $_});Save 'originals' $originals
 $profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\game-session.profile.json')|ConvertFrom-Json
 $profile.profileId='roo20-review2-background';$profile.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json';$profile.foregroundGame.processNames=@('RooFixtureGame.exe');$profile.targetGames=@([pscustomobject]@{gameId='fixture';processNames=@('RooFixtureGame.exe')})
 $profile.rules=@($profile.rules|Where-Object {$_.ruleId -ne 'boost-foreground-game'});foreach($rule in $profile.rules){$rule.match=@{processNames=@($fixtures|ForEach-Object {$_.ProcessName+'.exe'})}}
 if($Mode -eq 'gpu-controls'){foreach($rule in $profile.rules){$rule.action|Add-Member -NotePropertyName gpuPriority -NotePropertyValue 'BelowNormal' -Force};$limited=Get-RooIndustriesProcessGpuPriority $updater;$explicit=Get-RooIndustriesProcessGpuPriority $updater -ForControl;Save 'gpu-reader' @{limited=$limited;explicit=$explicit};if($limited.available -or -not$explicit.available){throw 'GPU reader did not distinguish bulk and explicit-control access'}}
 Save 'profile' $profile;$profilePath=Join-Path $directory 'profile.json';$state=Join-Path $directory 'state';$placement=Read-RooIndustriesBackgroundPlacement;Save 'placement' $placement
 $flows=if($Mode -eq 'query-only'){@()}elseif($Mode -eq 'placement'){@('placement')}elseif($Mode -eq 'gpu-controls'){@('lower','game','limits')}else{@('lower','placement','game','limits')}
 foreach($flow in $flows){
  foreach($p in @($updater,$web)){$p.PriorityClass='AboveNormal';[RooBackgroundOracle]::SetIo($p,1);[RooBackgroundOracle]::SetMemory($p,3)}
  $before=@($fixtures|ForEach-Object {Read $_});Save ($flow+'-before') $before
  if($flow -eq 'limits'){
   $governor=Get-Content -Raw (Join-Path $Source 'backend\profiles\probalance-governor.profile.json')|ConvertFrom-Json;$governor.profileId='roo20-review2-limits';$governor.protectedCatalogPath=$profile.protectedCatalogPath
   $governor.governor.candidateSelectors=@([pscustomobject]@{ruleId='fixture';enabled=$true;match=@{processNames=@($fixtures|Where-Object {$_.Id -ne $game.Id}|ForEach-Object {$_.ProcessName+'.exe'})}})
   $governor.governor.thresholds.totalCpuPressureThresholdPercent=0;$governor.governor.thresholds.perProcessCpuThresholdPercent=0;$governor.governor.thresholds.timeOverThresholdSeconds=0;$governor.governor.thresholds.minimumRestraintSeconds=120;if($Mode -eq 'gpu-controls'){$governor.governor.restraint|Add-Member -NotePropertyName gpuPriority -NotePropertyValue 'BelowNormal' -Force};Save 'governor-profile' $governor
   $preview=Backend 'Preview-ProcessGovernor' @{ProfilePath=(Join-Path $directory 'governor-profile.json');SampleIntervalMilliseconds=250} ($flow+'-preview')
   $apply=Backend 'Start-ProcessGovernorSession' @{ProfilePath=(Join-Path $directory 'governor-profile.json');StateRoot=$state;ConfirmApply=$true;MaxDurationSeconds=3;PollIntervalSeconds=1;SampleIntervalMilliseconds=250} ($flow+'-apply')
  }else{
   $preview=Backend 'Preview-ProcessProfile' @{ProfilePath=$profilePath;Preset=$(if($flow -eq 'placement'){'placement'}else{'lower'})} ($flow+'-preview')
   if($flow -eq 'game'){$apply=Backend 'Start-GameTuneSession' @{ProfilePath=$profilePath;StateRoot=$state;ConfirmApply=$true;MaxDurationSeconds=2;PollIntervalSeconds=1} ($flow+'-apply')}
   else{$apply=Backend 'Apply-ProcessProfile' @{ProfilePath=$profilePath;Preset=$flow;StateRoot=$state;ConfirmApply=$true} ($flow+'-apply')}
  }
  foreach($launcher in $launchers){
   $entry=@($preview.preview|Where-Object processId -eq $launcher.Id)|Select-Object -First 1
   if(-not$entry -or $entry.reason -notmatch 'Game launchers are left unchanged' -or @($entry.controlChanges|Where-Object {-not$_.blocked}).Count){throw ($flow+' launcher exclusion/reason missing for '+$launcher.ProcessName)}
   Equal (Read $launcher) ($before|Where-Object pid -eq $launcher.Id)
   $child=Child $launcher $flow;if($child.priorityClass -ne 'Normal' -or $child.affinityMask -ne ($before|Where-Object pid -eq $launcher.Id).affinityMask){throw ($flow+' changed inherited child priority/affinity')}
  }
  Save ($flow+'-after') @($fixtures|ForEach-Object {Read $_})
  foreach($p in @($updater,$web)){$actual=Read $p;if($flow -eq 'placement'){if($actual.priorityClass -ne 'Normal' -or $actual.affinityMask -ne $placement.mask -or $actual.ioPriority -ne 2 -or $actual.memoryPriority -ne 5){throw 'Placement positive control failed'}}elseif($actual.priorityClass -ne 'BelowNormal' -or $actual.memoryPriority -ne 2){throw ($flow+' updater/web-helper positive control failed')}}
  if($Mode -eq 'gpu-controls'){foreach($p in @($updater,$web)){if((Read $p).gpuPriority -ne 1){throw ($flow+' requested GPU control was not applied')}}}
  Equal (Read $protected) ($before|Where-Object pid -eq $protected.Id)
  $scriptName=switch($flow){'game'{'Stop-GameTuneSession'};'limits'{'Stop-ProcessGovernorSession'};default{'Restore-ProcessProfileBackup'}}
  $restore=Backend $scriptName @{BackupPath=$apply.backup.location;ConfirmApply=$true} ($flow+'-restore');foreach($p in $fixtures){Equal (Read $p) ($before|Where-Object pid -eq $p.Id)}
  Save ($flow+'-restored') @($fixtures|ForEach-Object {Read $_})
 }
 . (Join-Path $Source 'backend\scripts\ProcessPolicy.Common.ps1')
 $aligned=Get-Content -Raw (Join-Path $Source 'backend\profiles\persistent-policy.profile.json')|ConvertFrom-Json
 $catalog=Get-Content -Raw (Join-Path $Source 'backend\profiles\protected-processes.json')|ConvertFrom-Json
 foreach($launcher in $launchers){
  $row=[pscustomobject]@{pid=$launcher.Id;name=($launcher.ProcessName+'.exe');category='backgroundApp';priorityClass='Normal';executablePath=$launcher.Path}
  $entry=New-RooIndustriesProcessPolicyPreviewEntry $row $aligned $catalog;Save ('persistent-'+$launcher.ProcessName) $entry
  if(-not$entry.blocked -or $entry.reason -notmatch 'Game launchers are left unchanged'){throw 'Persistent profile launcher protection is missing'}
 }
 $alignedPreview=Backend 'Preview-ProcessProfile' @{ProfilePath=(Join-Path $Source 'backend\profiles\background-demotion.profile.json')} 'background-demotion-preview'
 foreach($launcher in $launchers){$entry=@($alignedPreview.preview|Where-Object processId -eq $launcher.Id)|Select-Object -First 1;if(-not$entry -or $entry.reason -notmatch 'Game launchers are left unchanged' -or @($entry.controlChanges|Where-Object {-not$_.blocked}).Count){throw 'Background demotion profile launcher protection is missing'}}
 if($Mode -ne 'placement'){
  $query=Fixture 'RooFixtureQueryOnly';[RooBackgroundOracle]::SetMemory($query,3);$null=$query.Handle;$dacl=[RooBackgroundOracle]::QueryOnly($query);$fresh=Get-Process -Id $query.Id;$debugPrior=[RooBackgroundOracle]::DebugPrivilege($false)
  $rights=@(foreach($access in @(0x1000,0x101000,0x200,0x1fffff)){@{access=$access;error=[RooBackgroundOracle]::OpenError($query,$access)}});Save 'query-only-rights' $rights
  if(@($rights|Where-Object {$_.access -in @(0x1000,0x101000) -and $_.error -ne 0}).Count -or @($rights|Where-Object {$_.access -in @(0x200,0x1fffff) -and $_.error -ne 5}).Count){throw 'DACL fixture rights differ from query-only contract'}
  $memory=Get-RooIndustriesProcessMemoryPriority $fresh;Save 'query-only-memory' $memory
  $classification=Backend 'Get-ProcessClassification' @{ProfilePath=$profilePath} 'query-only-classification';$row=@($classification.processes|Where-Object pid -eq $query.Id)|Select-Object -First 1
  if(-not$memory.available -or $memory.value -ne 3 -or -not$row.memoryPriorityAvailable -or $row.memoryPriority -ne 3){throw 'Query-only classification memory read failed'}
  [RooBackgroundOracle]::RestoreDacl($query,$dacl);$dacl=$null;$null=[RooBackgroundOracle]::DebugPrivilege(($debugPrior -band 2) -ne 0);Save 'debug-privilege' @{originalAttributes=$debugPrior;restored=$true};$debugPrior=$null
 }
 Save 'done' @{status='passed';flows=$flows;machine=$env:COMPUTERNAME;placementMask=$placement.mask;queryOnly=($Mode -eq 'all')}
}catch{Save 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};throw}
finally {if($debugPrior -ne $null){$null=[RooBackgroundOracle]::DebugPrivilege(($debugPrior -band 2) -ne 0)};if($query -and $dacl){[RooBackgroundOracle]::RestoreDacl($query,$dacl)};foreach($receipt in $owned){Stop-OwnedProcess $receipt};Save 'cleanup' @($owned|ForEach-Object {@{pid=$_.Identity.pid;exited=$_.Process.HasExited}})}
