param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
$directory=Join-Path $OutRoot 'restore-identity';[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$p=$null;$owned=$null
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 40),$utf8)}
function Read{$p.Refresh();@{pid=$p.Id;priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64();ioPriority=[RooBackgroundOracle]::Io($p);memoryPriority=[RooBackgroundOracle]::Memory($p)}}
try{
 $path=Join-Path $directory 'RooFixtureWebHelperIdentity.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $path;$p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned=New-OwnedProcess $p;$p.PriorityClass='BelowNormal';[RooBackgroundOracle]::SetIo($p,1);[RooBackgroundOracle]::SetMemory($p,2)
 $p.PriorityClass='Normal';[RooBackgroundOracle]::SetIo($p,2);[RooBackgroundOracle]::SetMemory($p,5)
 $profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\probalance-governor.profile.json')|ConvertFrom-Json;$profile.profileId='roo20-reopen-identity';$profile.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json';$profile.governor.candidateSelectors=@([pscustomobject]@{ruleId='fixture';enabled=$true;match=@{processNames=@($p.ProcessName+'.exe')}})
 $profile.governor.thresholds.totalCpuPressureThresholdPercent=0;$profile.governor.thresholds.perProcessCpuThresholdPercent=0;$profile.governor.thresholds.timeOverThresholdSeconds=0;$profile.governor.thresholds.minimumRestraintSeconds=120;Save 'profile' $profile
 $raw=& (Join-Path $Source 'backend\scripts\Start-ProcessGovernorSession.ps1') -ProfilePath (Join-Path $directory 'profile.json') -StateRoot (Join-Path $directory 'state') -ConfirmApply -MaxDurationSeconds 3 -PollIntervalSeconds 1 -SampleIntervalMilliseconds 250;$start=$raw|ConvertFrom-Json;Save 'start' $start
 if(@($start.errors).Count -or -not$start.backup.location){throw 'Governor did not produce a valid fixture backup'}
 $backup=Get-Content -Raw $start.backup.location|ConvertFrom-Json;Save 'backup' $backup;$snapshot=$backup.snapshots[0]
 $original=Join-Path $Source 'backend\scripts\Stop-ProcessGovernorSession.ps1';$text=[IO.File]::ReadAllText($original)
 $needle='$identity = Get-RooIndustriesProcessGovernorLiveIdentity $entry'
 if(-not$text.Contains($needle)){throw 'Restore no longer reopens through the verified identity path'}
 $text=$text.Replace(". (Join-Path `$PSScriptRoot 'ProcessGovernor.Common.ps1')",(". '"+(Join-Path $Source 'backend\scripts\ProcessGovernor.Common.ps1')+"'"))
 $record='($entry | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath '''+(Join-Path $directory 'valid-entry-before-reopen.json')+''' -Encoding UTF8;'
 $text=$text.Replace($needle,($record+' $entry.processStartTimeUtc = ''2000-01-01T00:00:00.0000000Z'';' + "`n            "+$needle))
 $driver=Join-Path $directory 'restore-after-identity-change.ps1';[IO.File]::WriteAllText($driver,$text,$utf8)
 Save 'instrumentation' @{source=$original;sourceSha256=(Get-FileHash $original).Hash;driver=$driver;driverSha256=(Get-FileHash $driver).Hash;injectedInput='Only restore entry start time changes after preview, immediately before reopening';physicalPidReuse=$false}
 $before=Read;Save 'before' $before;$raw=& $driver -BackupPath (Join-Path $directory 'backup.json') -ConfirmApply;$result=$raw|ConvertFrom-Json;Save 'result' $result;$after=Read;Save 'after' $after
 $valid=Get-Content -Raw (Join-Path $directory 'valid-entry-before-reopen.json')|ConvertFrom-Json
 if(@($result.preview).Count -ne 1 -or $valid.blocked -or $valid.processStartTimeUtc -ne $snapshot.processStartTimeUtc){throw 'Initial preview was not independently valid or dropped start time'}
 if(($result|ConvertTo-Json -Depth 40) -notmatch 'start time does not match' -or @($result.result.restoredItems).Count){throw 'Reopened target was not rejected after identity changed'}
 foreach($field in 'priorityClass','affinityMask','ioPriority','memoryPriority'){if([string]$before.$field -cne [string]$after.$field){throw ('Identity change still wrote '+$field)}}
 Save 'done' @{passed=$true;validPreview=$true;identityChangedBeforeReopen=$true;allControlsUnchanged=$true}
} catch {Save 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};throw}
finally{if($owned){Stop-OwnedProcess $owned};Save 'cleanup' @{fixtureStopped=if($p){$p.HasExited}else{$true}}}
