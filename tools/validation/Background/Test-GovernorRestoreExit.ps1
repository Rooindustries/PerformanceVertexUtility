param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
$utf8=[Text.UTF8Encoding]::new($false)
function Save([string]$directory,[string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 40),$utf8)}
function Test-ExitDuringRestore([string]$name,[string]$needle,[bool]$beforeWrites){
 $directory=Join-Path $OutRoot $name;[IO.Directory]::CreateDirectory($directory)|Out-Null;$p=$null;$owned=$null
 try{
  $path=Join-Path $directory 'GovernorExitFixture.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $path;$p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned=New-OwnedProcess $p
  $p.PriorityClass='Normal';[RooIndustriesBackgroundOracle]::SetIo($p,2);[RooIndustriesBackgroundOracle]::SetMemory($p,5)
  $profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\probalance-governor.profile.json')|ConvertFrom-Json;$profile.profileId='roo411-'+$name;$profile.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json';$profile.governor.candidateSelectors=@([pscustomobject]@{ruleId='fixture';enabled=$true;match=@{processNames=@($p.ProcessName+'.exe')}})
  $profile.governor.thresholds.totalCpuPressureThresholdPercent=0;$profile.governor.thresholds.perProcessCpuThresholdPercent=0;$profile.governor.thresholds.timeOverThresholdSeconds=0;$profile.governor.thresholds.minimumRestraintSeconds=120;Save $directory 'profile' $profile
  $raw=& (Join-Path $Source 'backend\scripts\Start-ProcessGovernorSession.ps1') -ProfilePath (Join-Path $directory 'profile.json') -StateRoot (Join-Path $directory 'state') -ConfirmApply -MaxDurationSeconds 3 -PollIntervalSeconds 1 -SampleIntervalMilliseconds 250;$start=$raw|ConvertFrom-Json;Save $directory 'start' $start
  if(@($start.errors).Count -or -not$start.backup.location){throw 'Governor did not produce a valid fixture backup'}
  $applied=@($start.changedItems|Where-Object processId -eq $p.Id)|Select-Object -First 1
  if(-not$applied -or @($applied.appliedControls).Count -lt 2 -or [string]$applied.appliedPriorityClass -ne 'BelowNormal'){throw 'Governor did not lower both priority and I/O on the fixture'}
  $p.PriorityClass='High'
  $original=Join-Path $Source 'backend\scripts\Stop-ProcessGovernorSession.ps1';$text=[IO.File]::ReadAllText($original)
  if(-not$text.Contains($needle)){throw 'Restore no longer has the expected step: '+$needle.Trim()}
  $text=$text.Replace(". (Join-Path `$PSScriptRoot 'ProcessGovernor.Common.ps1')",(". '"+(Join-Path $Source 'backend\scripts\ProcessGovernor.Common.ps1')+"'"))
  $text=$text.Replace($needle,"            if (`$processId -eq $($p.Id)) { `$live.Kill(); `$live.WaitForExit(5000) | Out-Null }`n"+$needle)
  $driver=Join-Path $directory 'restore-with-exit.ps1';[IO.File]::WriteAllText($driver,$text,$utf8)
  Save $directory 'instrumentation' @{source=$original;sourceSha256=(Get-FileHash $original).Hash;driver=$driver;driverSha256=(Get-FileHash $driver).Hash;externalControl='priorityClass';injected=$(if($beforeWrites){'The fixture exits right before its remaining controls are written back'}else{'The fixture exits right after its remaining controls are written back'})}
  $raw=& $driver -SessionPath $start.sessionPath -ConfirmApply;$result=$raw|ConvertFrom-Json;Save $directory 'result' $result
  $status=& (Join-Path $Source 'backend\scripts\Get-ProcessGovernorSessionStatus.ps1') -SessionPath $start.sessionPath|ConvertFrom-Json;Save $directory 'status' $status
  $preview=@($result.preview|Where-Object processId -eq $p.Id)|Select-Object -First 1
  if(-not$preview -or @($preview.controlChanges|Where-Object {$_.blocked}).Count -lt 1){throw 'The outside change was not recorded as a preserved control'}
  if(-not$p.HasExited){throw 'The fixture did not exit during the restore'}
  $closed=@($result.skippedItems|Where-Object {$_.processId -eq $p.Id -and $_.outcome -eq 'alreadyClosed'}).Count
  if(@($result.skippedItems|Where-Object {$_.processId -eq $p.Id -and $_.outcome -ne 'alreadyClosed'}).Count -or $closed -ne $(if($beforeWrites){1}else{0})){throw ($name+': an app that exited during the restore kept a skipped restore')}
  if(-not$beforeWrites -and @($result.restoredItems|Where-Object processId -eq $p.Id).Count -ne 1){throw ($name+': the controls written before the exit were not reported as restored')}
  if($result.status -ne 'completed' -or $result.restorable -or $status.restorable){throw ($name+': restore after the exit did not finish: '+$result.status+' restorable '+$result.restorable+' session '+$status.status)}
  Save $directory 'done' @{passed=$true;externalControl='priorityClass';alreadyClosed=$beforeWrites;restorable=$false}
 } catch {Save $directory 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};throw}
 finally{if($owned){Stop-OwnedProcess $owned};Save $directory 'cleanup' @{fixtureStopped=if($p){$p.HasExited}else{$true}}}
}
Test-ExitDuringRestore 'restore-exit' '            foreach ($change in $entryControlChanges) {' $true
Test-ExitDuringRestore 'restore-exit-after-writes' '            if ($appliedControls.Count -gt 0) {' $false
