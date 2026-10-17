param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
$directory=Join-Path $OutRoot 'auto-restore';[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$p=$null;$worker=$null;$owned=$null;$workerOwned=$null;$job=[IntPtr]::Zero
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 40),$utf8)}
try{
 $path=Join-Path $directory 'RooFixtureUpdaterAuto.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $path;$p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned=New-OwnedProcess $p
 $p.PriorityClass='Normal';[RooIndustriesBackgroundOracle]::SetIo($p,2);[RooIndustriesBackgroundOracle]::SetMemory($p,5)
 $profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\probalance-governor.profile.json')|ConvertFrom-Json;$profile.profileId='roo20-auto-restore';$profile.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json'
 $profile.governor.candidateSelectors=@([pscustomobject]@{ruleId='fixture';enabled=$true;match=@{processNames=@('RooFixtureUpdaterAuto.exe')}})
 $profile.governor.thresholds.totalCpuPressureThresholdPercent=0;$profile.governor.thresholds.perProcessCpuThresholdPercent=0;$profile.governor.thresholds.timeOverThresholdSeconds=0;$profile.governor.thresholds.minimumRestraintSeconds=0;$profile.governor.thresholds.restoreCpuThresholdPercent=100;$profile.governor.thresholds.cooldownAfterRestoreSeconds=120
 Save 'profile' $profile
 $state=Join-Path $directory 'state';$script=Join-Path $directory 'start.ps1';$output=Join-Path $directory 'start-result.json'
 $text='$ErrorActionPreference=''Stop''; & '''+(Join-Path $Source 'backend\scripts\Start-ProcessGovernorSession.ps1')+''' -ProfilePath '''+(Join-Path $directory 'profile.json')+''' -StateRoot '''+$state+''' -ConfirmApply -MaxDurationSeconds 12 -PollIntervalSeconds 1 -SampleIntervalMilliseconds 250 -OutputPath '''+$output+''''
 [IO.File]::WriteAllText($script,$text,$utf8)
 $worker=Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$script+'"') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $directory 'worker.log') -RedirectStandardError (Join-Path $directory 'worker-error.log') -PassThru;$workerOwned=New-OwnedProcess $worker
 $deadline=[DateTime]::UtcNow.AddSeconds(30);$sessionFile=$null
 while([DateTime]::UtcNow -lt $deadline){$sessionFile=Get-ChildItem $state -Filter 'session.json' -Recurse -ErrorAction SilentlyContinue|Select-Object -First 1;$p.Refresh();if($sessionFile -and [string]$p.PriorityClass -eq 'BelowNormal'){break};if($worker.HasExited){throw 'Governor exited before restraint'};Start-Sleep -Milliseconds 20}
 if(-not$sessionFile -or [string]$p.PriorityClass -ne 'BelowNormal'){throw 'Governor restraint was not established'}
 $job=[RooIndustriesBackgroundOracle]::PinPriority($p,0x4000);Save 'job-pinned' @{pid=$p.Id;priorityClass=[string]$p.PriorityClass;ioPriority=[RooIndustriesBackgroundOracle]::Io($p);memoryPriority=[RooIndustriesBackgroundOracle]::Memory($p)}
 if(-not$worker.WaitForExit(60000)){throw 'Governor did not finish'}
 $stateValue=Get-Content -Raw $sessionFile.FullName|ConvertFrom-Json;$result=Get-Content -Raw $output|ConvertFrom-Json;Save 'session' $stateValue;Save 'result' $result
 if(($result|ConvertTo-Json -Depth 40) -notmatch 'Windows kept a different value' -or -not$stateValue.restorable -or @($stateValue.activeRestraints).Count -ne 1){throw 'Failed automatic restore lost its active original snapshot'}
 $p.Refresh();Save 'after-failed-restore' @{priorityClass=[string]$p.PriorityClass;ioPriority=[RooIndustriesBackgroundOracle]::Io($p);memoryPriority=[RooIndustriesBackgroundOracle]::Memory($p)}
 if([string]$p.PriorityClass -ne 'BelowNormal' -or [RooIndustriesBackgroundOracle]::Io($p) -ne 2 -or [RooIndustriesBackgroundOracle]::Memory($p) -ne 5){throw 'Automatic restore did not restore independent fields'}
 [RooIndustriesBackgroundOracle]::ChangeJobPriority($job,0)
 $raw=& (Join-Path $Source 'backend\scripts\Stop-ProcessGovernorSession.ps1') -SessionPath $sessionFile.FullName -ConfirmApply;$restore=$raw|ConvertFrom-Json;Save 'stop' $restore;$p.Refresh();if([string]$p.PriorityClass -ne 'Normal'){throw 'Retry lost the original Normal priority'}
 Save 'done' @{passed=$true;externalInput='Job becomes pinned to BelowNormal after governor restraint';restorableAfterFailure=$stateValue.restorable;independentFieldsRestored=$true;retryPriority=[string]$p.PriorityClass}
} catch {Save 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};throw}
finally{if($workerOwned){Stop-OwnedProcess $workerOwned};if($owned){Stop-OwnedProcess $owned};if($job -ne [IntPtr]::Zero){[RooIndustriesBackgroundOracle]::CloseHandle($job)|Out-Null};Save 'cleanup' @{fixtureStopped=if($p){$p.HasExited}else{$true};workerStopped=if($worker){$worker.HasExited}else{$true}}}
