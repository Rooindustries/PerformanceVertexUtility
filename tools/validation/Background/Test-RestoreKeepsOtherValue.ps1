param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
$utf8=[Text.UTF8Encoding]::new($false)
function Save([string]$directory,[string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 40),$utf8)}
function Start-Fixture([string]$directory,[string]$name){
 $path=Join-Path $directory ($name+'.exe');Copy-Item "$env:SystemRoot\System32\PING.EXE" $path
 $p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned=New-OwnedProcess $p
 $p.PriorityClass='Normal';$p.Refresh()
 return [pscustomobject]@{process=$p;owned=$owned}
}
function Read-Fixture($p){$p.Refresh();return [pscustomobject]@{priorityClass=[string]$p.PriorityClass;affinityMask=$p.ProcessorAffinity.ToInt64()}}
function Test-LeftItem($result,[int]$processId,[string]$control,[string]$value){
 $items=@($result.result.leftAsSetItems|Where-Object {$_.processId -eq $processId -and $_.control -eq $control -and [string]$_.currentValue -eq $value})
 return $items.Count -eq 1 -and [string]$result.result.summary -like '*Left as another program set it*'
}
function Set-ChangeBreakpoint($p,[string]$Command,[string]$Value){
 $race=@{done=$false;process=$p;value=$Value}
 return Set-PSBreakpoint -Command $Command -Action ({if(-not$race.done){$race.done=$true;$race.process.PriorityClass=$race.value}}.GetNewClosure())
}

function Invoke-GameScenario([string]$name,[ValidateSet('before','race','back')][string]$Mode){
 $directory=Join-Path $OutRoot $name;[IO.Directory]::CreateDirectory($directory)|Out-Null
 $game=$null;$breakpoint=$null
 try{
  $game=Start-Fixture $directory ('Keep'+$name);$p=$game.process;$before=Read-Fixture $p
  $affinity=if(($before.affinityMask -band 1) -eq 1 -and $before.affinityMask -ne 1){1}elseif(($before.affinityMask -band 2) -eq 2){2}else{throw 'The fixture needs at least two CPUs to change its affinity'}
  $profile=[pscustomobject]@{
   schemaVersion=1;productName='Roo Industries Optimization Suite';profileId='keep-other-value-game';name='Keep another program value';profileKind='process-controls';risk='medium'
   protectedCatalogPath=(Join-Path $Source 'backend\profiles\protected-processes.json')
   foregroundGame=[pscustomobject]@{ruleId='keep-value-game';processNames=@($p.ProcessName+'.exe');priorityClass='AboveNormal';affinityMask=[int64]$affinity;reason='Validate that undo keeps a value another program set.';reasonCodes=@('LIVE_VALIDATION')}
   targetGames=@();protectedCompanions=@();protectedPreviewProcessNames=@();safeCandidates=@();rules=@()
   rollbackPolicy=[pscustomobject]@{supported=$true;scope='process-controls';stateRoot=(Join-Path $directory 'state');restoreOriginalPriorityClass=$true}
   safety=[pscustomobject]@{confirmedApplyChanges=@('PriorityClass','Affinity');continuousEnforcement=$true;runtimeService=$false}
  }
  Save $directory 'profile' $profile
  $start=& (Join-Path $Source 'backend\scripts\Start-GameTuneSession.ps1') -ProfilePath (Join-Path $directory 'profile.json') -TargetGameProcessName ($p.ProcessName+'.exe') -PollIntervalSeconds 1 -MaxDurationSeconds 1 -StateRoot (Join-Path $directory 'state') -ConfirmApply|ConvertFrom-Json;Save $directory 'start' $start
  $applied=Read-Fixture $p
  if($applied.priorityClass -ne 'AboveNormal' -or $applied.affinityMask -ne $affinity){throw ('Game Tune did not apply priority and affinity to the fixture: '+$applied.priorityClass+' '+$applied.affinityMask)}
  if($Mode -eq 'race'){
   $breakpoint=Set-ChangeBreakpoint $p 'Invoke-RooIndustriesProcessControlChange' 'BelowNormal'
  }else{
   $p.PriorityClass='BelowNormal'
   $preview=& (Join-Path $Source 'backend\scripts\Stop-GameTuneSession.ps1') -SessionPath $start.sessionPath|ConvertFrom-Json;Save $directory 'preview' $preview
   $entry=@($preview.preview|Where-Object processId -eq $p.Id)|Select-Object -First 1
   if(-not$entry -or @($entry.controlChanges|Where-Object control -eq 'priorityClass').Count -or @($entry.leftAsSet|Where-Object {$_.control -eq 'priorityClass' -and $_.currentValue -eq 'BelowNormal'}).Count -ne 1){throw 'Game Tune undo preview still proposes overwriting the priority another program set'}
   if($Mode -eq 'back'){$breakpoint=Set-ChangeBreakpoint $p 'Confirm-RooIndustriesLeftAsSet' 'AboveNormal'}
  }
  $undo=& (Join-Path $Source 'backend\scripts\Stop-GameTuneSession.ps1') -SessionPath $start.sessionPath -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
  if($breakpoint){Remove-PSBreakpoint $breakpoint;$breakpoint=$null}
  $status=& (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1') -SessionPath $start.sessionPath|ConvertFrom-Json;Save $directory 'status' $status
  $after=Read-Fixture $p
  if($Mode -eq 'back'){
   Save $directory 'undo-first' $undo;Save $directory 'status-first' $status
   if($after.priorityClass -ne 'AboveNormal'){throw ('Game Tune changed-back undo wrote the priority: '+$after.priorityClass)}
   if($after.affinityMask -ne $before.affinityMask){throw ('Game Tune undo did not restore the affinity it changed: '+$after.affinityMask+' instead of '+$before.affinityMask)}
   if(@($undo.result.leftAsSetItems|Where-Object control -eq 'priorityClass').Count){throw 'Game Tune undo claimed it left a priority that changed back'}
   if(-not$undo.restorable -or -not$status.restorable){throw ('Game Tune changed-back undo lost the recovery point: undo '+$undo.restorable+' session '+$status.restorable)}
   $undo=& (Join-Path $Source 'backend\scripts\Stop-GameTuneSession.ps1') -SessionPath $start.sessionPath -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
   $status=& (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1') -SessionPath $start.sessionPath|ConvertFrom-Json;Save $directory 'status' $status
   $after=Read-Fixture $p
   if($after.priorityClass -ne 'Normal'){throw ('Game Tune second undo did not restore the original priority: '+$after.priorityClass)}
   if($undo.restorable -or $undo.status -ne 'completed' -or $status.restorable){throw ('Game Tune second undo did not finish: '+$undo.status+' restorable '+$undo.restorable+' session '+$status.restorable)}
   Save $directory 'done' @{passed=$true;mode=$Mode;kept='priorityClass AboveNormal on first undo';restored='affinityMask and priorityClass Normal on second undo'}
   return
  }
  if($after.priorityClass -ne 'BelowNormal'){throw ('Game Tune undo overwrote the priority another program set: '+$after.priorityClass)}
  if($after.affinityMask -ne $before.affinityMask){throw ('Game Tune undo did not restore the affinity it changed: '+$after.affinityMask+' instead of '+$before.affinityMask)}
  if(-not(Test-LeftItem $undo $p.Id 'priorityClass' 'BelowNormal')){throw 'Game Tune undo did not name the priority it left as another program set it'}
  if($undo.status -ne 'completed' -or $undo.result.status -ne 'rolledBack' -or $undo.restorable -or $status.restorable){throw ('Game Tune undo did not finish: '+$undo.status+' '+$undo.result.status+' restorable '+$undo.restorable+' session '+$status.status)}
  Save $directory 'done' @{passed=$true;race=($Mode -eq 'race');kept='priorityClass BelowNormal';restored='affinityMask'}
 } catch {Save $directory 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};$failures.Add($name+': '+$_.Exception.Message)|Out-Null}
 finally{if($breakpoint){Remove-PSBreakpoint $breakpoint};if($game){Stop-OwnedProcess $game.owned}}
}

function Invoke-ProfileScenario([string]$name,[ValidateSet('before','race','back')][string]$Mode){
 $directory=Join-Path $OutRoot $name;[IO.Directory]::CreateDirectory($directory)|Out-Null
 $kept=$null;$untouched=$null;$breakpoint=$null
 try{
  $keptDirectory=Join-Path $directory 'a';$sameDirectory=Join-Path $directory 'b';[IO.Directory]::CreateDirectory($keptDirectory)|Out-Null;[IO.Directory]::CreateDirectory($sameDirectory)|Out-Null
  $kept=Start-Fixture $keptDirectory 'KeepValueTarget';$untouched=Start-Fixture $sameDirectory 'KeepValueTarget'
  $profile=[pscustomobject]@{
   schemaVersion=1;productName='Roo Industries Optimization Suite';profileId='keep-other-value-profile';name='Keep another program value';profileKind='process-controls';risk='medium'
   protectedCatalogPath=(Join-Path $Source 'backend\profiles\protected-processes.json')
   foregroundGame=[pscustomobject]@{ruleId='keep-value-profile';processNames=@('KeepValueTarget.exe');priorityClass='AboveNormal';reason='Validate that profile restore keeps a value another program set.';reasonCodes=@('LIVE_VALIDATION')}
   targetGames=@();protectedCompanions=@();protectedPreviewProcessNames=@();safeCandidates=@();rules=@()
   rollbackPolicy=[pscustomobject]@{supported=$true;scope='process-controls';stateRoot=(Join-Path $directory 'state');restoreOriginalPriorityClass=$true}
   safety=[pscustomobject]@{confirmedApplyChanges=@('PriorityClass');continuousEnforcement=$true;runtimeService=$false}
  }
  Save $directory 'profile' $profile
  $apply=& (Join-Path $Source 'backend\scripts\Apply-ProcessProfile.ps1') -ProfilePath (Join-Path $directory 'profile.json') -TargetGameProcessName 'KeepValueTarget.exe' -StateRoot (Join-Path $directory 'state') -ConfirmApply|ConvertFrom-Json;Save $directory 'apply' $apply
  foreach($fixture in $kept,$untouched){if((Read-Fixture $fixture.process).priorityClass -ne 'AboveNormal'){throw ('The profile did not raise fixture '+$fixture.process.Id)}}
  if($Mode -eq 'race'){$breakpoint=Set-ChangeBreakpoint $kept.process 'Invoke-RooIndustriesProcessControlChange' 'BelowNormal'}else{
   $kept.process.PriorityClass='BelowNormal'
   if($Mode -eq 'back'){$breakpoint=Set-ChangeBreakpoint $kept.process 'Confirm-RooIndustriesLeftAsSet' 'AboveNormal'}
  }
  $undo=& (Join-Path $Source 'backend\scripts\Restore-ProcessProfileBackup.ps1') -BackupPath $apply.backup.location -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
  if($breakpoint){Remove-PSBreakpoint $breakpoint;$breakpoint=$null}
  $keptAfter=Read-Fixture $kept.process;$untouchedAfter=Read-Fixture $untouched.process
  if($Mode -eq 'back'){
   Save $directory 'undo-first' $undo
   if($keptAfter.priorityClass -ne 'AboveNormal'){throw ('Profile changed-back restore wrote the priority: '+$keptAfter.priorityClass)}
   if($untouchedAfter.priorityClass -ne 'Normal'){throw ('Profile restore did not put back the untouched priority: '+$untouchedAfter.priorityClass)}
   if(@($undo.result.leftAsSetItems|Where-Object processId -eq $kept.process.Id).Count){throw 'Profile restore claimed it left a priority that changed back'}
   if($undo.status -ne 'partial' -or $undo.result.restorePendingCount -ne 1){throw ('Profile changed-back restore lost the recovery point: '+$undo.status+' pending '+$undo.result.restorePendingCount)}
   $undo=& (Join-Path $Source 'backend\scripts\Restore-ProcessProfileBackup.ps1') -BackupPath $apply.backup.location -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
   $keptAfter=Read-Fixture $kept.process
   if($keptAfter.priorityClass -ne 'Normal'){throw ('Profile second restore did not restore the original priority: '+$keptAfter.priorityClass)}
   if($undo.status -ne 'success' -or $undo.result.restorePendingCount -ne 0){throw ('Profile second restore did not finish: '+$undo.status+' pending '+$undo.result.restorePendingCount)}
   Save $directory 'done' @{passed=$true;mode=$Mode;kept='priorityClass AboveNormal on first restore';restored='priorityClass Normal on second restore'}
   return
  }
  if($keptAfter.priorityClass -ne 'BelowNormal'){throw ('Profile restore overwrote the priority another program set: '+$keptAfter.priorityClass)}
  if($untouchedAfter.priorityClass -ne 'Normal'){throw ('Profile restore did not put back the untouched priority: '+$untouchedAfter.priorityClass)}
  if(-not(Test-LeftItem $undo $kept.process.Id 'priorityClass' 'BelowNormal')){throw 'Profile restore did not name the priority it left as another program set it'}
  if($undo.status -ne 'success' -or $undo.result.restorePendingCount -ne 0){throw ('Profile restore did not finish: '+$undo.status+' pending '+$undo.result.restorePendingCount)}
  Save $directory 'done' @{passed=$true;race=($Mode -eq 'race');kept='priorityClass BelowNormal';restored='priorityClass Normal'}
 } catch {Save $directory 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};$failures.Add($name+': '+$_.Exception.Message)|Out-Null}
 finally{if($breakpoint){Remove-PSBreakpoint $breakpoint};foreach($fixture in $kept,$untouched){if($fixture){Stop-OwnedProcess $fixture.owned}}}
}

$failures=New-Object System.Collections.Generic.List[string]
Invoke-GameScenario 'game' 'before'
Invoke-GameScenario 'game-race' 'race'
Invoke-GameScenario 'game-back' 'back'
Invoke-ProfileScenario 'profile' 'before'
Invoke-ProfileScenario 'profile-race' 'race'
Invoke-ProfileScenario 'profile-back' 'back'
if($failures.Count){throw ($failures -join '; ')}
