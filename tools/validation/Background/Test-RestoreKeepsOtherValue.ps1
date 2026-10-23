param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
function Invoke-E2EBackend {
 param([string]$Script,[string]$ProfilePath='',[string]$TargetGameProcessName='',[string]$StateRoot='',[string]$SessionPath='',[string]$BackupPath='',[int]$PollIntervalSeconds=1,[int]$MaxDurationSeconds=1,[switch]$ConfirmApply)
 . (Join-Path $Source 'backend\scripts\GameTuneSession.Common.ps1')
 $script:RestoreE2ELegacyData=Join-Path $OutRoot 'owned-data'
 function Get-RooIndustriesLocalDataRoot{return $script:RestoreE2ELegacyData}
 $tokens=$null;$errors=$null;$path=Join-Path $Source ('backend\scripts\'+$Script)
 $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($errors -join '; ')}
 foreach($statement in $ast.EndBlock.Statements){
  if($statement -is [Management.Automation.Language.FunctionDefinitionAst] -or $statement -is [Management.Automation.Language.AssignmentStatementAst]){. (New-BackendBlock $path $statement.Extent)}
 }
 foreach($parameter in @($ast.ParamBlock.Parameters)){$name=$parameter.Name.VariablePath.UserPath;if(-not(Get-Variable -Name $name -Scope 0 -ErrorAction SilentlyContinue)){Set-Variable -Name $name -Value $(if($parameter.DefaultValue){& (New-BackendBlock $path $parameter.DefaultValue.Extent)}elseif($parameter.StaticType -eq [switch]){$false}) -Scope 0}}
 $OutputPath='';$SessionId=''
 $body=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
 if($body.Count -ne 1){throw 'Expected one real backend body'}
 & (New-BackendBlock $path $body[0].Extent)
}
function New-BackendBlock([string]$Path,$Extent){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput(("`n"*($Extent.StartLineNumber-1))+$Extent.Text,$Path,[ref]$tokens,[ref]$errors);if($errors.Count){throw ($errors -join '; ')};return $ast.GetScriptBlock()}
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
function Assert-UnprovenReason($result,[string]$kind){
 $text=$result|ConvertTo-Json -Depth 40 -Compress
 if($text -notlike '*It resets when that app restarts.*' -or $text -like '*Run Undo again*' -or [string]$result.result.summary -like '*..*'){throw ($kind+' Undo of a value it can''t prove it set must say the value resets when that app restarts, not Run Undo again, and end the summary with one period: '+$text)}
}
function Set-ChangeBreakpoint($p,[string]$Command,[string]$Value){
 $race=@{done=$false;process=$p;value=$Value}
 return Set-PSBreakpoint -Command $Command -Action ({if(-not$race.done){$race.done=$true;$race.process.PriorityClass=$race.value}}.GetNewClosure())
}
function Set-ConfirmationChangeBreakpoint($p,[string]$Value){
 $race=@{done=$false;process=$p;value=$Value}
 return Set-PSBreakpoint -Command Confirm-RooIndustriesRestoreControl -Action ({if(-not$race.done){$race.done=$true;$race.process.PriorityClass=$race.value}}.GetNewClosure())
}

function Invoke-GameScenario([string]$name,[ValidateSet('before','race','back','original','pending','damaged')][string]$Mode){
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
  $start=Invoke-E2EBackend 'Start-GameTuneSession.ps1' -ProfilePath (Join-Path $directory 'profile.json') -TargetGameProcessName ($p.ProcessName+'.exe') -PollIntervalSeconds 1 -MaxDurationSeconds 1 -StateRoot (Join-Path $directory 'state') -ConfirmApply|ConvertFrom-Json;Save $directory 'start' $start
  $applied=Read-Fixture $p
  if($applied.priorityClass -ne 'AboveNormal' -or $applied.affinityMask -ne $affinity){throw ('Game Tune did not apply priority and affinity to the fixture: '+$applied.priorityClass+' '+$applied.affinityMask)}
  $statusBefore=& (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1') -SessionPath $start.sessionPath|ConvertFrom-Json;Save $directory 'status-before' $statusBefore
  if($statusBefore.restoreAttempted -isnot [bool] -or $statusBefore.restoreAttempted){throw 'Game Tune status did not identify the pre-Undo phase'}
  if($Mode -eq 'damaged'){
   $damaged=[IO.Directory]::CreateDirectory((Join-Path $OutRoot ('owned-data\operations\game-session-roo711-'+[guid]::NewGuid().ToString('N')+'\session'))).Parent.FullName
   try{
    [IO.File]::WriteAllText((Join-Path $damaged 'session\launcher-journal.json'),'{',$utf8)
    $undo=Invoke-E2EBackend 'Stop-GameTuneSession.ps1' -SessionPath $start.sessionPath -ConfirmApply|ConvertFrom-Json;Save $directory 'undo-first' $undo
   }finally{[IO.Directory]::Delete($damaged,$true)}
   $text=$undo|ConvertTo-Json -Depth 40 -Compress;$held=Read-Fixture $p
   if($held.priorityClass -ne 'AboveNormal' -or $held.affinityMask -ne $affinity -or -not $undo.restorable -or $text -notlike '*A saved change file is damaged: operations\\game-session-roo711-*' -or $text -like '*Run Undo again*'){throw ('A Game Tune Stop refused by a damaged saved change must change nothing and name the file: '+$text)}
   $undo=Invoke-E2EBackend 'Stop-GameTuneSession.ps1' -SessionPath $start.sessionPath -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
   $after=Read-Fixture $p
   if($after.priorityClass -ne 'Normal' -or $after.affinityMask -ne $before.affinityMask -or $undo.restorable -or $undo.status -ne 'completed'){throw ('The next Game Tune Stop did not restore: '+$after.priorityClass+' '+$after.affinityMask+' '+$undo.status+' restorable '+$undo.restorable)}
   Save $directory 'done' @{passed=$true;mode=$Mode;refused='A saved change file is damaged: operations\game-session-roo711-...';restored='priorityClass Normal and affinityMask'}
   return
  }
  if($Mode -eq 'pending'){
   $backup=Get-Content -LiteralPath $start.backupManifestPath -Raw|ConvertFrom-Json
   $pendingControls=0
   foreach($snapshot in @($backup.snapshots|Where-Object processId -eq $p.Id)){foreach($change in @($snapshot.controlChanges|Where-Object control -eq 'priorityClass')){$change.outcome='pending';$pendingControls++}}
   if($pendingControls -ne 1){throw 'Expected one Game Tune priority journal for the pending fixture'}
   [IO.File]::WriteAllText($start.backupManifestPath,($backup|ConvertTo-Json -Depth 40),$utf8)
   Save $directory 'pending-input' $backup
  }
  if($Mode -eq 'race'){
   $breakpoint=Set-ChangeBreakpoint $p 'Invoke-RooIndustriesProcessControlChange' 'BelowNormal'
  }else{
   $p.PriorityClass=if($Mode -eq 'original'){'Normal'}else{'BelowNormal'}
   $preview=Invoke-E2EBackend 'Stop-GameTuneSession.ps1' -SessionPath $start.sessionPath|ConvertFrom-Json;Save $directory 'preview' $preview
   $entry=@($preview.preview|Where-Object processId -eq $p.Id)|Select-Object -First 1
   if($Mode -notin @('original','pending') -and (-not$entry -or @($entry.controlChanges|Where-Object control -eq 'priorityClass').Count -or @($entry.leftAsSet|Where-Object {$_.control -eq 'priorityClass' -and $_.currentValue -eq 'BelowNormal'}).Count -ne 1)){throw 'Game Tune undo preview still proposes overwriting the priority another program set'}
   if($Mode -in @('back','original')){$breakpoint=Set-ConfirmationChangeBreakpoint $p 'AboveNormal'}
  }
  $undo=Invoke-E2EBackend 'Stop-GameTuneSession.ps1' -SessionPath $start.sessionPath -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
  $breakpointHits=0;if($breakpoint){$breakpointHits=$breakpoint.HitCount;Remove-PSBreakpoint $breakpoint;$breakpoint=$null}
  $status=& (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1') -SessionPath $start.sessionPath|ConvertFrom-Json;Save $directory 'status' $status
  if($status.restoreAttempted -isnot [bool] -or -not$status.restoreAttempted){throw 'Game Tune status lost the confirmed Undo phase'}
  $after=Read-Fixture $p
  if($Mode -in @('back','original')){
   Save $directory 'undo-first' $undo;Save $directory 'status-first' $status
   Save $directory 'readback-first' @{breakpointHitCount=$breakpointHits;process=$after}
   if($breakpointHits -le 0){throw 'Game Tune changed-back breakpoint did not run'}
   if($after.priorityClass -ne 'AboveNormal'){throw ('Game Tune changed-back undo wrote the priority: '+$after.priorityClass)}
   if($after.affinityMask -ne $before.affinityMask){throw ('Game Tune undo did not restore the affinity it changed: '+$after.affinityMask+' instead of '+$before.affinityMask)}
   if(@($undo.result.leftAsSetItems|Where-Object control -eq 'priorityClass').Count){throw 'Game Tune undo claimed it left a priority that changed back'}
   if(-not$undo.restorable -or -not$status.restorable){throw ('Game Tune changed-back undo lost the recovery point: undo '+$undo.restorable+' session '+$status.restorable)}
   if($Mode -eq 'original' -and @($entry.alreadyOriginal|Where-Object control -eq 'priorityClass').Count -ne 1){throw 'Game Tune original-value preview lost its fresh verification check'}
   $undo=Invoke-E2EBackend 'Stop-GameTuneSession.ps1' -SessionPath $start.sessionPath -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
   $status=& (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1') -SessionPath $start.sessionPath|ConvertFrom-Json;Save $directory 'status' $status
   $after=Read-Fixture $p
   if($after.priorityClass -ne 'Normal'){throw ('Game Tune second undo did not restore the original priority: '+$after.priorityClass)}
   if($undo.restorable -or $undo.status -ne 'completed' -or $status.restorable){throw ('Game Tune second undo did not finish: '+$undo.status+' restorable '+$undo.restorable+' session '+$status.restorable)}
   Save $directory 'done' @{passed=$true;mode=$Mode;kept='priorityClass AboveNormal on first undo';restored='affinityMask and priorityClass Normal on second undo'}
   return
  }
  if($Mode -eq 'pending'){
   if($after.priorityClass -ne 'BelowNormal' -or -not $undo.restorable -or -not $status.restorable -or @($undo.result.leftAsSetItems).Count){throw 'Unverified Game Tune drift must remain pending without kept attribution'}
   Assert-UnprovenReason $undo 'Game Tune'
   if($after.affinityMask -ne $before.affinityMask){throw 'Independent affinity did not restore'}
   $repeat=Invoke-E2EBackend 'Stop-GameTuneSession.ps1' -SessionPath $start.sessionPath -ConfirmApply|ConvertFrom-Json;Save $directory 'repeat' $repeat
   if(-not $repeat.restorable -or (Read-Fixture $p).priorityClass -ne 'BelowNormal' -or @($repeat.result.leftAsSetItems).Count){throw 'Repeated unverified Undo incorrectly closed recovery'}
   $p.PriorityClass='Normal'
   $resolved=Invoke-E2EBackend 'Stop-GameTuneSession.ps1' -SessionPath $start.sessionPath -ConfirmApply|ConvertFrom-Json;Save $directory 'original-resolution' $resolved
   if($resolved.restorable -or (Read-Fixture $p).priorityClass -ne 'Normal'){throw 'Actual original did not safely resolve pending Game Tune recovery'}
   Save $directory 'done' @{passed=$true;mode=$Mode;pendingDrift='BelowNormal';resolvedOriginal='Normal'}
   return
  }
  if($after.priorityClass -ne 'BelowNormal'){throw ('Game Tune undo overwrote the priority another program set: '+$after.priorityClass)}
  if($after.affinityMask -ne $before.affinityMask){throw ('Game Tune undo did not restore the affinity it changed: '+$after.affinityMask+' instead of '+$before.affinityMask)}
  if(-not(Test-LeftItem $undo $p.Id 'priorityClass' 'BelowNormal')){throw 'Game Tune undo did not name the priority it left as another program set it'}
  $keptName=[string](@($undo.result.leftAsSetItems|Where-Object {$_.processId -eq $p.Id -and $_.control -eq 'priorityClass'})[0].processName)
  if([string]::IsNullOrWhiteSpace($keptName) -or @($status.leftAsSetItems|Where-Object {$_.processId -eq $p.Id -and $_.processName -eq $keptName -and $_.control -eq 'priorityClass' -and $_.currentValue -eq 'BelowNormal'}).Count -ne 1){throw 'Game Tune status lost the persisted kept priority/name'}
  if($undo.status -ne 'completed' -or $undo.result.status -ne 'rolledBack' -or $undo.restorable -or $status.restorable){throw ('Game Tune undo did not finish: '+$undo.status+' '+$undo.result.status+' restorable '+$undo.restorable+' session '+$status.status)}
  Save $directory 'done' @{passed=$true;race=($Mode -eq 'race');kept='priorityClass BelowNormal';restored='affinityMask'}
 } catch {Save $directory 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};$failures.Add($name+': '+$_.Exception.Message)|Out-Null}
 finally{if($breakpoint){Remove-PSBreakpoint $breakpoint};if($game){Stop-OwnedProcess $game.owned}}
}

function Invoke-ProfileScenario([string]$name,[ValidateSet('before','race','back','original','pending','damaged','busy')][string]$Mode){
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
  $apply=Invoke-E2EBackend 'Apply-ProcessProfile.ps1' -ProfilePath (Join-Path $directory 'profile.json') -TargetGameProcessName 'KeepValueTarget.exe' -StateRoot (Join-Path $directory 'state') -ConfirmApply|ConvertFrom-Json;Save $directory 'apply' $apply
  foreach($fixture in $kept,$untouched){if((Read-Fixture $fixture.process).priorityClass -ne 'AboveNormal'){throw ('The profile did not raise fixture '+$fixture.process.Id)}}
  if($Mode -eq 'pending'){
   $backup=Get-Content -LiteralPath $apply.backup.location -Raw|ConvertFrom-Json
   $pendingControls=0
   foreach($snapshot in @($backup.snapshots|Where-Object processId -eq $kept.process.Id)){foreach($change in @($snapshot.controlChanges|Where-Object control -eq 'priorityClass')){$change.outcome='pending';$pendingControls++}}
   if($pendingControls -ne 1){throw 'Expected one profile priority journal for the pending fixture'}
   [IO.File]::WriteAllText($apply.backup.location,($backup|ConvertTo-Json -Depth 40),$utf8)
   Save $directory 'pending-input' $backup
  }
  if($Mode -in @('damaged','busy')){
   $damaged=$null;$holder=$null;$release=Join-Path $directory 'gate-release.txt'
   try{
    if($Mode -eq 'damaged'){
     $damaged=[IO.Directory]::CreateDirectory((Join-Path $OutRoot ('owned-data\operations\process-roo711-'+[guid]::NewGuid().ToString('N')))).FullName
     [IO.File]::WriteAllText((Join-Path $damaged 'journal.json'),'{',$utf8)
    }else{
     $ready=Join-Path $directory 'gate-held.txt'
     $hold="`$m=[Threading.Mutex]::new(`$false,'Global\RooIndustriesGovernorGate-"+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+"');if(`$m.WaitOne(10000)){[IO.File]::WriteAllText('"+$ready.Replace("'","''")+"','held');while(-not[IO.File]::Exists('"+$release.Replace("'","''")+"')){Start-Sleep -Milliseconds 50};`$m.ReleaseMutex()};`$m.Dispose()"
     $p=Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hold))) -WindowStyle Hidden -PassThru
     $holder=[pscustomobject]@{process=$p;owned=(New-OwnedProcess $p)}
     $deadline=[DateTime]::UtcNow.AddSeconds(15);while(-not[IO.File]::Exists($ready)){if([DateTime]::UtcNow -gt $deadline){throw 'The fixture could not hold the governor gate'};Start-Sleep -Milliseconds 50}
    }
    $undo=Invoke-E2EBackend 'Restore-ProcessProfileBackup.ps1' -BackupPath $apply.backup.location -ConfirmApply|ConvertFrom-Json;Save $directory 'undo-first' $undo
   }finally{
    if($damaged){[IO.Directory]::Delete($damaged,$true)}
    if($holder){[IO.File]::WriteAllText($release,'release',$utf8);if(-not$holder.process.WaitForExit(15000)){Stop-OwnedProcess $holder.owned}}
   }
   $text=$undo|ConvertTo-Json -Depth 40 -Compress
   $expected=if($Mode -eq 'damaged'){'A saved change file is damaged: operations\\process-roo711-'}else{'Background limits were busy, so this setting was left alone. Try again in a moment.'}
   foreach($fixture in $kept,$untouched){if((Read-Fixture $fixture.process).priorityClass -ne 'AboveNormal'){throw ('A refused profile Undo changed fixture '+$fixture.process.Id)}}
   if($undo.result.restorePendingCount -lt 1 -or $text -notlike ('*'+$expected+'*') -or $text -like '*Run Undo again*' -or [string]$undo.result.summary -like '*..*'){throw ('A profile Undo refused by '+$(if($Mode -eq 'damaged'){'a damaged saved change'}else{'busy background limits'})+' must say so: '+$text)}
   $undo=Invoke-E2EBackend 'Restore-ProcessProfileBackup.ps1' -BackupPath $apply.backup.location -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
   foreach($fixture in $kept,$untouched){if((Read-Fixture $fixture.process).priorityClass -ne 'Normal'){throw ('The next profile Undo did not restore fixture '+$fixture.process.Id)}}
   if($undo.status -ne 'success' -or $undo.result.restorePendingCount -ne 0){throw ('The next profile Undo did not finish: '+$undo.status+' pending '+$undo.result.restorePendingCount)}
   Save $directory 'done' @{passed=$true;mode=$Mode;refused=$expected;restored='priorityClass Normal'}
   return
  }
  if($Mode -eq 'race'){$breakpoint=Set-ChangeBreakpoint $kept.process 'Invoke-RooIndustriesProcessControlChange' 'BelowNormal'}else{
   $kept.process.PriorityClass=if($Mode -eq 'original'){'Normal'}else{'BelowNormal'}
   if($Mode -in @('back','original')){$breakpoint=Set-ConfirmationChangeBreakpoint $kept.process 'AboveNormal'}
  }
  $undo=Invoke-E2EBackend 'Restore-ProcessProfileBackup.ps1' -BackupPath $apply.backup.location -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
  $breakpointHits=0;if($breakpoint){$breakpointHits=$breakpoint.HitCount;Remove-PSBreakpoint $breakpoint;$breakpoint=$null}
  $keptAfter=Read-Fixture $kept.process;$untouchedAfter=Read-Fixture $untouched.process
  if($Mode -in @('back','original')){
   Save $directory 'undo-first' $undo
   Save $directory 'readback-first' @{breakpointHitCount=$breakpointHits;kept=$keptAfter;untouched=$untouchedAfter}
   if($breakpointHits -le 0){throw 'Profile changed-back breakpoint did not run'}
   if($keptAfter.priorityClass -ne 'AboveNormal'){throw ('Profile changed-back restore wrote the priority: '+$keptAfter.priorityClass)}
   if($untouchedAfter.priorityClass -ne 'Normal'){throw ('Profile restore did not put back the untouched priority: '+$untouchedAfter.priorityClass)}
   if(@($undo.result.leftAsSetItems|Where-Object processId -eq $kept.process.Id).Count){throw 'Profile restore claimed it left a priority that changed back'}
   if($undo.status -ne 'partial' -or $undo.result.restorePendingCount -ne 1){throw ('Profile changed-back restore lost the recovery point: '+$undo.status+' pending '+$undo.result.restorePendingCount)}
   $undo=Invoke-E2EBackend 'Restore-ProcessProfileBackup.ps1' -BackupPath $apply.backup.location -ConfirmApply|ConvertFrom-Json;Save $directory 'undo' $undo
   $keptAfter=Read-Fixture $kept.process
   if($keptAfter.priorityClass -ne 'Normal'){throw ('Profile second restore did not restore the original priority: '+$keptAfter.priorityClass)}
   if($undo.status -ne 'success' -or $undo.result.restorePendingCount -ne 0){throw ('Profile second restore did not finish: '+$undo.status+' pending '+$undo.result.restorePendingCount)}
   Save $directory 'done' @{passed=$true;mode=$Mode;kept='priorityClass AboveNormal on first restore';restored='priorityClass Normal on second restore'}
   return
  }
  if($Mode -eq 'pending'){
   if($keptAfter.priorityClass -ne 'BelowNormal' -or $untouchedAfter.priorityClass -ne 'Normal' -or $undo.result.restorePendingCount -ne 1 -or @($undo.result.leftAsSetItems).Count){throw 'Unverified profile drift must remain pending while its peer restores'}
   Assert-UnprovenReason $undo 'Profile'
   $repeat=Invoke-E2EBackend 'Restore-ProcessProfileBackup.ps1' -BackupPath $apply.backup.location -ConfirmApply|ConvertFrom-Json;Save $directory 'repeat' $repeat
   if($repeat.result.restorePendingCount -ne 1 -or (Read-Fixture $kept.process).priorityClass -ne 'BelowNormal' -or @($repeat.result.leftAsSetItems).Count){throw 'Repeated unverified profile drift incorrectly closed recovery'}
   $kept.process.PriorityClass='Normal'
   $resolved=Invoke-E2EBackend 'Restore-ProcessProfileBackup.ps1' -BackupPath $apply.backup.location -ConfirmApply|ConvertFrom-Json;Save $directory 'original-resolution' $resolved
   if($resolved.result.restorePendingCount -ne 0 -or (Read-Fixture $kept.process).priorityClass -ne 'Normal'){throw 'Actual original did not safely resolve profile recovery'}
   Save $directory 'done' @{passed=$true;mode=$Mode;pendingDrift='BelowNormal';resolvedOriginal='Normal'}
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
Invoke-GameScenario 'game-original' 'original'
Invoke-GameScenario 'game-pending' 'pending'
Invoke-GameScenario 'game-damaged-saved-change' 'damaged'
Invoke-ProfileScenario 'profile-original' 'original'
Invoke-ProfileScenario 'profile-pending' 'pending'
Invoke-ProfileScenario 'profile-damaged-saved-change' 'damaged'
Invoke-ProfileScenario 'profile-governor-busy' 'busy'
if($failures.Count){throw ($failures -join '; ')}
[IO.File]::WriteAllText((Join-Path $OutRoot 'summary.json'),(@{passed=$true;cases=13;engine=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json))
'ROO_INDUSTRIES_RESTORE_KEEPS_VALUE_E2E_COMPLETE'
