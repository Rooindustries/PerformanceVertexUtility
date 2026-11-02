param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
$directory=Join-Path $OutRoot 'second-run';[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false);$scripts=Join-Path $Source 'backend\scripts';$state=Join-Path $directory 'state';$sessions=Join-Path $state 'process-governor-sessions'
$probes=@{};$owned=@{};$worker=$null;$workerOwned=$null;$failures=New-Object System.Collections.Generic.List[string]
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 40),$utf8)}
function Case([bool]$passed,[string]$name){[Console]::WriteLine($(if($passed){'PASS '}else{'FAIL '})+$name);if(-not$passed){$failures.Add($name)}}
function Start-Probe([string]$name){
 $path=Join-Path $directory ($name+'.exe');if(-not(Test-Path -LiteralPath $path)){Copy-Item "$env:SystemRoot\System32\PING.EXE" $path}
 $p=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$script:owned[$name]=New-OwnedProcess $p;$script:probes[$name]=$p;Reset-Probe $name
}
function Reset-Probe([string]$name){$p=$probes[$name];$p.PriorityClass='Normal';[RooIndustriesBackgroundOracle]::SetIo($p,2);[RooIndustriesBackgroundOracle]::SetMemory($p,5)}
function Read-Probe([string]$name){$p=$probes[$name];$p.Refresh();[pscustomobject]@{priorityClass=[string]$p.PriorityClass;ioPriority=[RooIndustriesBackgroundOracle]::Io($p);memoryPriority=[RooIndustriesBackgroundOracle]::Memory($p)}}
function Test-Original([string]$name){$value=Read-Probe $name;$value.priorityClass -eq 'Normal' -and $value.ioPriority -eq 2 -and $value.memoryPriority -eq 5}
function New-Profile([string]$name,[string[]]$images,[double]$over,[double]$minimum){
 $profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\probalance-governor.profile.json')|ConvertFrom-Json;$profile.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json'
 $profile.governor.candidateSelectors=@([pscustomobject]@{ruleId='fixture';enabled=$true;match=@{processNames=@($images|ForEach-Object {$_+'.exe'})}})
 $thresholds=$profile.governor.thresholds;$thresholds.totalCpuPressureThresholdPercent=0;$thresholds.perProcessCpuThresholdPercent=0;$thresholds.timeOverThresholdSeconds=$over;$thresholds.minimumRestraintSeconds=$minimum
 $path=Join-Path $directory ($name+'-profile.json');[IO.File]::WriteAllText($path,($profile|ConvertTo-Json -Depth 40),$utf8);$path
}
function Start-Limits([string]$name,[string]$profile,[int]$duration,[int]$poll,[switch]$Review){
 $output=Join-Path $directory ($name+'.json');$arguments=@{ProfilePath=$profile;StateRoot=$state;MaxDurationSeconds=$duration;PollIntervalSeconds=$poll;SampleIntervalMilliseconds=250;OutputPath=$output}
 if(-not$Review){$arguments.ConfirmApply=$true};& (Join-Path $scripts 'Start-ProcessGovernorSession.ps1') @arguments|Out-Null;Get-Content -Raw $output|ConvertFrom-Json
}
function Get-Status([string]$name){$output=Join-Path $directory ($name+'.json');& (Join-Path $scripts 'Get-ProcessGovernorSessionStatus.ps1') -StateRoot $state -OutputPath $output|Out-Null;Get-Content -Raw $output|ConvertFrom-Json}
function Stop-Limits([string]$name,$run){$output=Join-Path $directory ($name+'.json');& (Join-Path $scripts 'Stop-ProcessGovernorSession.ps1') -SessionPath $run.sessionPath -StateRoot $state -ConfirmApply -OutputPath $output|Out-Null;Get-Content -Raw $output|ConvertFrom-Json}
function Hold-NewestSession{
 $newest=@(Get-ChildItem -LiteralPath $sessions -Directory|Sort-Object CreationTimeUtc -Descending|Select-Object -First 1)
 if(-not$newest.Count){return};$path=Join-Path $newest[0].FullName 'session.json'
 try{$stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)}catch{return}
 try{Start-Sleep -Milliseconds 400;$script:heldReads++}finally{$stream.Dispose()}
}
function Get-SessionCount{@(Get-ChildItem -LiteralPath $sessions -Directory -ErrorAction SilentlyContinue).Count}
try{
 Start-Probe 'LimitsFixtureA'
 $shipped=New-Profile 'shipped' @('LimitsFixtureA','LimitsFixtureB') 0 15
 $first=Start-Limits 'first-start' $shipped 12 2;$afterFirst=Read-Probe 'LimitsFixtureA';Save 'after-first' $afterFirst
 Case ($first.restorable -and @($first.activeRestraints).Count -eq 1 -and $afterFirst.priorityClass -eq 'BelowNormal' -and $afterFirst.ioPriority -ne 2) 'A legacy 12 second run retains its original backup until Restore'
 Start-Probe 'LimitsFixtureB';$count=Get-SessionCount
 $second=Start-Limits 'second-start' $shipped 12 2
 Case ($second.status -eq 'completed' -and $second.restorable -and (Get-SessionCount) -eq $count+1) 'A second Start creates a run while the earlier one still holds an app'
 Case ((Read-Probe 'LimitsFixtureB').priorityClass -eq 'BelowNormal' -and (Read-Probe 'LimitsFixtureA').priorityClass -eq 'BelowNormal') 'The second Start lowers the new app and keeps the earlier app lowered'
 $status=Get-Status 'status-after-refusal'
 Case ($status.sessionId -eq $second.sessionId -and $status.restorable) 'Status reports the newest run that still holds an app'
 $legacyId='process-governor-probalance-governor-legacy';$legacy=Join-Path $sessions $legacyId;[IO.Directory]::CreateDirectory($legacy)|Out-Null
 Save 'legacy-input' @{sessionId=$legacyId;profileId='probalance-governor';dryRun=$false;sessionStatus='completed';status='completed';restorable=$false;sessionPath=(Join-Path $legacy 'session.json');backupManifestPath=$null;activeRestraints=@();changedItems=@();skippedItems=@();restoredItems=@()}
 Copy-Item (Join-Path $directory 'legacy-input.json') (Join-Path $legacy 'session.json')
 $status=Get-Status 'status-with-later-run'
 Case ($status.sessionId -eq $second.sessionId -and $status.restorable) 'Status still reports the held run after a later run that changed nothing'
 $review=Start-Limits 'review-while-held' $shipped 3 1 -Review
 Case ($review.dryRun -and $review.status -eq 'completed' -and (Read-Probe 'LimitsFixtureB').priorityClass -eq 'BelowNormal' -and (Read-Probe 'LimitsFixtureA').priorityClass -eq 'BelowNormal') 'Review still previews while earlier runs hold apps and changes nothing'
 $undo=Stop-Limits 'undo-second' $second
 Case ($undo.result.status -eq 'rolledBack' -and (Test-Original 'LimitsFixtureB') -and (Get-Status 'status-before-first-undo').sessionId -eq $first.sessionId) 'Restoring the newer run leaves the earlier run reachable'
 $undo=Stop-Limits 'undo-first' $first
 Case ($undo.result.status -eq 'rolledBack' -and (Test-Original 'LimitsFixtureA')) 'Restore puts the first run''s app back exactly'
 Case (-not (Get-Status 'status-after-undo').restorable) 'Nothing is offered for Restore once the held run is restored'

 $quick=New-Profile 'quick' @('LimitsFixtureA','LimitsFixtureB') 0 600;$quickA=New-Profile 'quick-a' @('LimitsFixtureA') 0 600;$quickB=New-Profile 'quick-b' @('LimitsFixtureB') 0 600
 $third=Start-Limits 'third-start' $quick 3 1
 Case ($third.status -eq 'completed' -and $third.restorable -and (Read-Probe 'LimitsFixtureA').priorityClass -eq 'BelowNormal' -and (Read-Probe 'LimitsFixtureB').priorityClass -eq 'BelowNormal') 'Start runs again after Restore'
 $undo=Stop-Limits 'undo-third' $third
 Case ($undo.result.status -eq 'rolledBack' -and (Test-Original 'LimitsFixtureA') -and (Test-Original 'LimitsFixtureB')) 'Restore of the new run puts both apps back exactly'

 Start-Probe 'LimitsFixtureC';$quickC=New-Profile 'quick-c' @('LimitsFixtureC') 0 600
 $beforeClosed=Start-Limits 'before-closed' $quickA 3 1
 $closed=Start-Limits 'closed-run' $quickC 3 1;Stop-OwnedProcess $owned['LimitsFixtureC'];$probes['LimitsFixtureC'].WaitForExit(10000)|Out-Null
 Case ($beforeClosed.restorable -and $closed.restorable -and (Get-Status 'status-after-closed').sessionId -eq $beforeClosed.sessionId) 'Status skips a newer run whose app has closed and reports the older run that still holds an app'
 $afterClosed=Start-Limits 'after-closed' $quickB 3 1
 Case ($afterClosed.status -eq 'completed' -and $afterClosed.restorable) 'A run whose app has closed doesn''t block the next Start'
 Case (-not (Get-Content -Raw $closed.sessionPath|ConvertFrom-Json).restorable -and (Get-Content -Raw $beforeClosed.sessionPath|ConvertFrom-Json).restorable) 'The next Start closes a run whose apps have all closed and keeps runs that still hold one'
 $undo=Stop-Limits 'undo-after-closed' $afterClosed;Case (Test-Original 'LimitsFixtureB') 'Restore after the closed run puts the newer app back'
 $protected=@(Get-Process -Name csrss -ErrorAction SilentlyContinue|Select-Object -First 1)
 if($protected.Count -ne 1){throw 'No protected Windows process is available for the reused process ID check.'}
 $reopened=Get-Content -Raw $closed.sessionPath|ConvertFrom-Json;$reopened.restorable=$true;[IO.File]::WriteAllText($closed.sessionPath,($reopened|ConvertTo-Json -Depth 40),$utf8)
 $reused=Get-Content -Raw $closed.backupManifestPath|ConvertFrom-Json;foreach($snapshot in @($reused.snapshots)){$snapshot.processId=$protected[0].Id}
 [IO.File]::WriteAllText($closed.backupManifestPath,($reused|ConvertTo-Json -Depth 40),$utf8)
 $status=Get-Status 'status-reused-id'
 Case ($status.sessionId -eq $beforeClosed.sessionId -and $status.restorable) 'A run whose closed app''s process ID now belongs to a protected Windows process is not reported as holding it'
 foreach($snapshot in @($reused.snapshots)){$snapshot.processName=$protected[0].ProcessName+'.exe';$snapshot.processStartTimeUtc='2001-01-01T00:00:00.0000000Z'}
 [IO.File]::WriteAllText($closed.backupManifestPath,($reused|ConvertTo-Json -Depth 40),$utf8)
 $status=Get-Status 'status-reused-same-name'
 Case ($status.sessionId -eq $beforeClosed.sessionId -and $status.restorable) 'A same-named protected process with a different start time is not the app the run lowered'
 $undo=Stop-Limits 'undo-reused-id' $closed
 Case ($undo.result.status -eq 'rolledBack' -and -not$undo.restorable) 'Restore closes that run as already ended without touching the protected process'
 $lost=Start-Limits 'lost-backup' $quickB 3 1;Remove-Item -LiteralPath $lost.backupManifestPath
 $status=Get-Status 'status-lost-backup'
 Case ($lost.restorable -and $status.sessionId -eq $beforeClosed.sessionId -and $status.restorable) 'A run whose backup file is gone does not block status for other runs'
 $undo=Stop-Limits 'undo-before-closed' $beforeClosed;Case (Test-Original 'LimitsFixtureA') 'Restore of the run before the closed one puts its app back'
 Reset-Probe 'LimitsFixtureB'

 $kept=Start-Limits 'kept-run' $quickA 3 1;$keptLowered=Read-Probe 'LimitsFixtureA';$p=$probes['LimitsFixtureA'];$p.PriorityClass='AboveNormal';[RooIndustriesBackgroundOracle]::SetIo($p,0);[RooIndustriesBackgroundOracle]::SetMemory($p,3);Save 'kept-by-other-program' (Read-Probe 'LimitsFixtureA')
 $afterKept=Start-Limits 'after-kept' $quickB 3 1;$keptValue=Read-Probe 'LimitsFixtureA'
 Case ($kept.restorable -and $afterKept.status -eq 'completed' -and $afterKept.restorable) 'A run whose lowered values another program changed doesn''t block the next Start'
 Case ($keptValue.priorityClass -eq 'AboveNormal' -and $keptValue.ioPriority -eq 0 -and $keptValue.memoryPriority -eq 3) 'The next Start leaves the other program''s values'
 $undo=Stop-Limits 'undo-after-kept' $afterKept;Case (Test-Original 'LimitsFixtureB') 'Restore after the kept run puts the other app back'
 Case (@($undo.result.leftAsSetItems|Where-Object {$_.processId -eq $p.Id}).Count -eq 3 -and $undo.result.summary -match 'Left as another program set it: ') 'That Restore also lets go of the kept run''s settings another program changed, and names each one'
 $undo=Stop-Limits 'undo-kept' $kept;$keptValue=Read-Probe 'LimitsFixtureA'
 Case ($keptValue.priorityClass -eq 'AboveNormal' -and $keptValue.ioPriority -eq 0 -and $keptValue.memoryPriority -eq 3) 'Restore of the kept run leaves the other program''s values'
 Case ($undo.result.status -eq 'rolledBack' -and -not$undo.restorable) 'Restore of the kept run finishes instead of failing, with nothing left that is its own'
 Case (-not (Get-Status 'status-after-kept').restorable) 'Status offers no Restore while the only run left keeps another program''s values'
 $p.PriorityClass=$keptLowered.priorityClass;[RooIndustriesBackgroundOracle]::SetIo($p,$keptLowered.ioPriority);[RooIndustriesBackgroundOracle]::SetMemory($p,$keptLowered.memoryPriority)
 Case (-not (Get-Status 'status-kept-returned').restorable) 'Once a run kept another program''s values, a later return to the lowered values is not offered for Restore'
 $undo=Stop-Limits 'undo-kept-returned' $kept;$keptValue=Read-Probe 'LimitsFixtureA'
 Case ($keptValue.priorityClass -eq $keptLowered.priorityClass -and $keptValue.ioPriority -eq $keptLowered.ioPriority -and $keptValue.memoryPriority -eq $keptLowered.memoryPriority) 'Restore then leaves the lowered values another program set'
 Reset-Probe 'LimitsFixtureA'
 $olderHeld=Start-Limits 'older-held' $quickB 3 1;$newerKept=Start-Limits 'newer-kept' $quickA 3 1
 $p=$probes['LimitsFixtureA'];$p.PriorityClass='AboveNormal';[RooIndustriesBackgroundOracle]::SetIo($p,0);[RooIndustriesBackgroundOracle]::SetMemory($p,3)
 Case ((Get-Status 'kept-chain-status-1').sessionId -eq $olderHeld.sessionId) 'Status passes over a newer run whose only changes another program replaced'
 $undo=Stop-Limits 'kept-chain-undo-newer' $newerKept
 Case ($undo.result.status -eq 'rolledBack' -and (Get-Status 'kept-chain-status-2').sessionId -eq $olderHeld.sessionId) 'Restoring a newer run that only kept another program''s values moves on to the older run'
 $undo=Stop-Limits 'kept-chain-undo-older' $olderHeld
 Case ((Test-Original 'LimitsFixtureB') -and (Read-Probe 'LimitsFixtureA').priorityClass -eq 'AboveNormal') 'The older run''s app comes back exactly and the other program''s value stays'
 Reset-Probe 'LimitsFixtureA'

 Start-Probe 'LimitsFixtureD';Start-Probe 'LimitsFixtureE';$quickD=New-Profile 'quick-d' @('LimitsFixtureD') 0 600;$quickE=New-Profile 'quick-e' @('LimitsFixtureE') 0 600
 $older=Start-Limits 'stack-older' $quickD 3 1
 $newer=Start-Limits 'stack-newer' $quickE 3 1
 Case ($newer.restorable -and (Get-Status 'stack-status-1').sessionId -eq $newer.sessionId) 'With two runs holding apps, status reports the newer one first'
 $undo=Stop-Limits 'stack-undo-newer' $newer;$status=Get-Status 'stack-status-2'
 Case ((Test-Original 'LimitsFixtureE') -and $status.sessionId -eq $older.sessionId -and $status.restorable) 'After restoring the newer run, status reports the older run that still holds an app'
 $undo=Stop-Limits 'stack-undo-older' $older
 Case ((Test-Original 'LimitsFixtureD') -and -not (Get-Status 'stack-status-3').restorable) 'After restoring both runs nothing is offered for Restore'

 $older=Start-Limits 'same-control-older' $quickD 3 1
 $different=New-Profile 'different-restraint' @('LimitsFixtureD') 0 600
 $value=Get-Content -Raw $different|ConvertFrom-Json;$value.governor.restraint.priorityClass='Idle';$value.governor.restraint.ioPriority='VeryLow';[IO.File]::WriteAllText($different,($value|ConvertTo-Json -Depth 40),$utf8)
 $newer=Start-Limits 'same-control-newer' $different 3 1
 Case ((Read-Probe 'LimitsFixtureD').priorityClass -eq 'Idle') 'A newer run can apply different limits to the same app'
 $undo=Stop-Limits 'same-control-undo-newer' $newer
 Case ((Read-Probe 'LimitsFixtureD').priorityClass -eq 'BelowNormal') 'The newer restore returns the earlier run''s value first'
 $undo=Stop-Limits 'same-control-undo-older' $older
 Case (Test-Original 'LimitsFixtureD') 'Restoring the older run then returns the exact original controls'

 $older=Start-Limits 'order-older' $quickD 3 1;$loweredMemory=(Read-Probe 'LimitsFixtureD').memoryPriority;$newer=Start-Limits 'order-newer' $different 3 1
 $undo=Stop-Limits 'order-undo-older-first' $older
 Case ($undo.restorable -and (Read-Probe 'LimitsFixtureD').priorityClass -eq 'Idle' -and ($undo.skippedItems|ConvertTo-Json -Depth 10) -match 'A newer Background limits run still holds this setting') 'Restoring an older run first keeps it open while a newer run holds the same setting'
 Case ($loweredMemory -ne 5 -and (Read-Probe 'LimitsFixtureD').memoryPriority -eq 5) 'That older Restore already puts back the memory priority no newer run holds'
 [RooIndustriesBackgroundOracle]::SetMemory($probes['LimitsFixtureD'],$loweredMemory);Save 'order-memory-by-other-program' (Read-Probe 'LimitsFixtureD')
 $undo=Stop-Limits 'order-undo-newer' $newer
 Case ((Read-Probe 'LimitsFixtureD').priorityClass -eq 'BelowNormal') 'The newer run then returns the older run''s value'
 $undo=Stop-Limits 'order-undo-older' $older;$value=Read-Probe 'LimitsFixtureD'
 Case ($value.priorityClass -eq 'Normal' -and $value.ioPriority -eq 2 -and -not$undo.restorable) 'The older run then returns the exact original and closes'
 Case ($value.memoryPriority -eq $loweredMemory) 'A memory priority another program set after Restore put it back stays as that program set it, even at the lowered value'
 Reset-Probe 'LimitsFixtureD'

 $older=Start-Limits 'covered-older' $quickD 3 1;$probes['LimitsFixtureD'].PriorityClass='High';$newer=Start-Limits 'covered-newer' $quickD 3 1
 $undo=Stop-Limits 'covered-undo-older-first' $older
 Case ($undo.restorable -and (Read-Probe 'LimitsFixtureD').priorityClass -eq 'BelowNormal') 'Restoring an older run first leaves a setting a newer run recorded at the same lowered value'
 $undo=Stop-Limits 'covered-undo-newer' $newer
 Case ((Read-Probe 'LimitsFixtureD').priorityClass -eq 'High') 'The newer run then returns the value the user set between the runs'
 $undo=Stop-Limits 'covered-undo-older' $older
 Case ((Read-Probe 'LimitsFixtureD').priorityClass -eq 'High' -and @($undo.result.leftAsSetItems).Count -eq 1) 'The older run then keeps the user''s value and names it'
 Reset-Probe 'LimitsFixtureD'

 $alreadyOriginal=Start-Limits 'already-original-start' $quickD 3 1;Reset-Probe 'LimitsFixtureD'
 $undo=Stop-Limits 'already-original-undo' $alreadyOriginal
 Case ($undo.result.status -eq 'rolledBack' -and -not$undo.restorable -and (Test-Original 'LimitsFixtureD')) 'Controls already put back by Processes Undo close recovery without another write'

 # The plan Restore previews is the one status uses, for each control the run sets at its original,
 # lowered and another program's value, and for a GPU priority Windows can't read on this probe.
 Start-Probe 'LimitsFixtureG';$quickG=New-Profile 'quick-g' @('LimitsFixtureG') 0 600
 $plan=Start-Limits 'plan-start' $quickG 3 1;$planLowered=Read-Probe 'LimitsFixtureG';$p=$probes['LimitsFixtureG']
 $setters=@{priorityClass={param($v)$p.PriorityClass=$v};ioPriority={param($v)[RooIndustriesBackgroundOracle]::SetIo($p,$v)};memoryPriority={param($v)[RooIndustriesBackgroundOracle]::SetMemory($p,$v)}}
 $values=@{priorityClass=@('Normal',$planLowered.priorityClass,'AboveNormal');ioPriority=@(2,$planLowered.ioPriority,@(0,1|Where-Object {$_ -ne $planLowered.ioPriority})[0]);memoryPriority=@(5,$planLowered.memoryPriority,@(3,4|Where-Object {$_ -ne $planLowered.memoryPriority})[0])}
 foreach($control in 'priorityClass','ioPriority','memoryPriority'){
  foreach($case in @(@{name='original';index=0;holds=$false},@{name='lowered';index=1;holds=$true},@{name='set by another program';index=2;holds=$false})){
   foreach($other in $values.Keys){& $setters[$other] $(if($other -eq $control){$values[$other][$case.index]}else{$values[$other][0]})}
   $review=Join-Path $directory ('plan-'+$control+'-'+$case.index+'.json');& (Join-Path $scripts 'Stop-ProcessGovernorSession.ps1') -SessionPath $plan.sessionPath -StateRoot $state -OutputPath $review|Out-Null
   $planned=@(@((Get-Content -Raw $review|ConvertFrom-Json).preview)[0].controlChanges|Where-Object {$_.control -eq $control})
   $expected=switch($case.index){0{$planned.Count -eq 0}1{$planned.Count -eq 1 -and -not$planned[0].blocked}2{$planned.Count -eq 1 -and $planned[0].blocked -and $planned[0].blockedReason -eq 'The control changed externally; its current value was preserved.'}}
   Case $expected ('Restore plans '+$control+' at '+$case.name+' as status does: '+($planned|ConvertTo-Json -Compress -Depth 5))
   $held=Get-Status ('plan-status-'+$control+'-'+$case.index)
   Case (($held.restorable -and $held.sessionId -eq $plan.sessionId) -eq $case.holds) ('Status counts '+$control+' at '+$case.name+' as '+$(if($case.holds){'still held'}else{'not held'}))
  }
 }
 foreach($other in $values.Keys){& $setters[$other] $values[$other][0]}
 # The run also lowered a GPU priority that Windows can't read on this probe now.
 $saved=Get-Content -Raw $plan.backupManifestPath|ConvertFrom-Json
 foreach($snapshot in @($saved.snapshots)){
  $snapshot|Add-Member -NotePropertyName originalGpuPriority -NotePropertyValue 'Normal' -Force;$snapshot|Add-Member -NotePropertyName proposedGpuPriority -NotePropertyValue 'BelowNormal' -Force
  $snapshot.controlChanges=@($snapshot.controlChanges)+@([pscustomobject]@{control='gpuPriority';currentValue='Normal';proposedValue='BelowNormal';action='setGpuPriority';outcome='applied';blocked=$false})
 }
 [IO.File]::WriteAllText($plan.backupManifestPath,($saved|ConvertTo-Json -Depth 40),$utf8)
 $review=Join-Path $directory 'plan-gpu.json';& (Join-Path $scripts 'Stop-ProcessGovernorSession.ps1') -SessionPath $plan.sessionPath -StateRoot $state -OutputPath $review|Out-Null
 $planned=@(@((Get-Content -Raw $review|ConvertFrom-Json).preview)[0].controlChanges|Where-Object {$_.control -eq 'gpuPriority'})
 Case ($planned.Count -eq 1 -and $planned[0].blocked -and $planned[0].blockedReason -match 'couldn''t read' -and (Get-Status 'plan-gpu-status').sessionId -eq $plan.sessionId) 'With every readable setting at its original, a GPU priority Windows can''t read stays planned and keeps the run held'

 # Settings found back at their original are no longer the run's once a confirmed Restore sees them,
 # even while the unreadable GPU priority keeps the run open.
 $undo=Stop-Limits 'settled-undo' $plan
 $closed=@(@(@((Get-Content -Raw $plan.backupManifestPath|ConvertFrom-Json).snapshots)[0].controlChanges|Where-Object {$_.restoredAtUtc}|ForEach-Object {$_.control})|Sort-Object)
 Case ($undo.restorable -and (Test-Original 'LimitsFixtureG') -and (@($undo.skippedItems|ForEach-Object {$_.reason}) -join ' ') -match 'couldn''t read this setting') 'Restore keeps the run open for the GPU priority it can''t read'
 Case (($closed -join ',') -eq 'ioPriority,memoryPriority,priorityClass') ('That Restore saves the settings it found at their original as no longer the run''s: '+($closed -join ','))
 $p.PriorityClass=$planLowered.priorityClass
 $undo=Stop-Limits 'settled-undo-again' $plan
 Case ((Read-Probe 'LimitsFixtureG').priorityClass -eq $planLowered.priorityClass) 'A later Restore of that open run leaves a lowered CPU priority another program set'
 Stop-OwnedProcess $owned['LimitsFixtureG'];$probes['LimitsFixtureG'].WaitForExit(10000)|Out-Null

 Start-Probe 'LimitsFixtureF';$quickF=New-Profile 'quick-f' @('LimitsFixtureF') 0 600
 $script=Join-Path $directory 'crash-start.ps1';$crashOutput=Join-Path $directory 'crash-start.json'
 [IO.File]::WriteAllText($script,('$ErrorActionPreference=''Stop''; & '''+(Join-Path $scripts 'Start-ProcessGovernorSession.ps1').Replace("'","''")+''' -ProfilePath '''+$quickF.Replace("'","''")+''' -StateRoot '''+$state.Replace("'","''")+''' -ConfirmApply -MaxDurationSeconds 120 -PollIntervalSeconds 1 -SampleIntervalMilliseconds 250 -OutputPath '''+$crashOutput.Replace("'","''")+''''),[Text.UTF8Encoding]::new($true))
 $count=Get-SessionCount
 $worker=Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$script+'"') -WindowStyle Hidden -PassThru;$workerOwned=New-OwnedProcess $worker
 $deadline=[DateTime]::UtcNow.AddSeconds(60);while([DateTime]::UtcNow -lt $deadline -and ((Read-Probe 'LimitsFixtureF').priorityClass -ne 'BelowNormal' -or (Get-SessionCount) -eq $count)){if($worker.HasExited){break};Start-Sleep -Milliseconds 100}
 Start-Sleep -Milliseconds 500;Stop-OwnedProcess $workerOwned;$worker.WaitForExit(10000)|Out-Null
 $crashed=Get-Status 'crash-status'
 Case ($crashed.restorable -and $crashed.rawSessionStatus -eq 'running' -and (Read-Probe 'LimitsFixtureF').priorityClass -eq 'BelowNormal') 'A Start that was killed mid-run is reported for Restore'
 Case ($crashed.status -eq 'restorable' -and $crashed.interrupted -and -not$crashed.active) 'A Start that was killed mid-run no longer reads as running'
 $legacyRunning=Get-Content -Raw $third.sessionPath|ConvertFrom-Json;$legacyRunning.sessionStatus='running';$legacyRunning.status='running';$legacyRunning.restorable=$false;$legacyRunning.startedAtUtc=[DateTime]::UtcNow.AddHours(-1).ToString('o');$legacyRunning.PSObject.Properties.Remove('worker')
 [IO.File]::WriteAllText($third.sessionPath,($legacyRunning|ConvertTo-Json -Depth 40),$utf8)
 $legacyOutput=Join-Path $directory 'legacy-running-status.json';& (Join-Path $scripts 'Get-ProcessGovernorSessionStatus.ps1') -SessionId $third.sessionId -StateRoot $state -OutputPath $legacyOutput|Out-Null;$legacyStatus=Get-Content -Raw $legacyOutput|ConvertFrom-Json
 Case ($legacyStatus.status -eq 'completed' -and $legacyStatus.interrupted) 'A running session from an older build that is long past its watch time no longer reads as running'
 $afterCrash=Start-Limits 'after-crash' $quickB 3 1
 Case ($afterCrash.status -eq 'completed' -and (Read-Probe 'LimitsFixtureB').priorityClass -eq 'BelowNormal') 'Start still lowers a new app after an earlier worker was killed'
 $undo=Stop-Limits 'undo-after-crash' $afterCrash;Case (Test-Original 'LimitsFixtureB') 'Restore puts the newer app back after the killed worker'
 $undo=Stop-Limits 'undo-crash' $crashed;Case (Test-Original 'LimitsFixtureF') 'Restore of the killed run puts the app back exactly'

 $serializedScript=Join-Path $directory 'serialized-start.ps1';$serializedOutput=Join-Path $directory 'serialized-first.json'
 $text='& '''+(Join-Path $scripts 'Start-ProcessGovernorSession.ps1').Replace("'","''")+''' -ProfilePath '''+$quickD.Replace("'","''")+''' -StateRoot '''+$state.Replace("'","''")+''' -ConfirmApply -MaxDurationSeconds 3 -PollIntervalSeconds 1 -SampleIntervalMilliseconds 250 -OutputPath '''+$serializedOutput.Replace("'","''")+''''
 [IO.File]::WriteAllText($serializedScript,$text,[Text.UTF8Encoding]::new($true))
 $worker=Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$serializedScript+'"') -WindowStyle Hidden -PassThru;$workerOwned=New-OwnedProcess $worker
 $deadline=[DateTime]::UtcNow.AddSeconds(20);while([DateTime]::UtcNow -lt $deadline -and (Read-Probe 'LimitsFixtureD').priorityClass -ne 'BelowNormal'){if($worker.HasExited){break};Start-Sleep -Milliseconds 50}
 Case ((Read-Probe 'LimitsFixtureD').priorityClass -eq 'BelowNormal') 'The first live run reaches its write before the queued Start'
 $queued=Start-Limits 'serialized-second' $different 3 1
 if(-not$worker.WaitForExit(10000)){throw 'The first serialized run did not finish'}
 $serialFirst=Get-Content -Raw $serializedOutput|ConvertFrom-Json
 Case ([DateTime]::Parse($queued.startedAtUtc) -ge [DateTime]::Parse($serialFirst.completedAtUtc) -and $queued.sessionId -ne $serialFirst.sessionId) 'The queued run creates its unique session only after the first run saves its final state'
 Case ($queued.restorable -and (Read-Probe 'LimitsFixtureD').priorityClass -eq 'Idle') 'The queued run lowers the app further after the first run finished'
 $undo=Stop-Limits 'serialized-undo-queued' $queued
 Case ($undo.result.status -eq 'rolledBack' -and (Read-Probe 'LimitsFixtureD').priorityClass -eq 'BelowNormal') 'Restoring the queued run first puts back the value the first run left'
 $undo=Stop-Limits 'serialized-undo' $serialFirst
 Case ((Test-Original 'LimitsFixtureD') -and -not(Get-Status 'serialized-status').restorable) 'Concurrent callers keep the true original reachable for Restore'

 $calmName='PvuCalm'+[Guid]::NewGuid().ToString('N').Substring(0,6);$calmExe=Join-Path $directory ($calmName+'.exe');$idle=Join-Path $directory 'idle'
 Add-Type -TypeDefinition 'using System; using System.IO; using System.Threading; class PvuCalmProbe { static void Main(string[] args) { while (!File.Exists(args[0])) Thread.SpinWait(100000); while (true) Thread.Sleep(1000); } }' -OutputAssembly $calmExe -OutputType ConsoleApplication
 $probe=Start-Process $calmExe -ArgumentList ('"'+$idle+'"') -WindowStyle Hidden -PassThru;$owned[$calmName]=New-OwnedProcess $probe;$probes[$calmName]=$probe;Reset-Probe $calmName
 $calmProfile=New-Profile 'calm' @($calmName) 8 15
 $value=Get-Content -Raw $calmProfile|ConvertFrom-Json;$value.governor.thresholds.perProcessCpuThresholdPercent=0.1;$value.governor.thresholds.cooldownAfterRestoreSeconds=120;[IO.File]::WriteAllText($calmProfile,($value|ConvertTo-Json -Depth 40),$utf8)
 $calmOutput=Join-Path $directory 'calm-start.json';$calmScript=Join-Path $directory 'calm-start.ps1'
 $text='& '''+(Join-Path $scripts 'Start-ProcessGovernorSession.ps1').Replace("'","''")+''' -ProfilePath '''+$calmProfile.Replace("'","''")+''' -StateRoot '''+$state.Replace("'","''")+''' -ConfirmApply -MaxDurationSeconds 60 -PollIntervalSeconds 2 -SampleIntervalMilliseconds 250 -OutputPath '''+$calmOutput.Replace("'","''")+''''
 [IO.File]::WriteAllText($calmScript,$text,[Text.UTF8Encoding]::new($true))
 $worker=Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$calmScript+'"') -WindowStyle Hidden -PassThru;$workerOwned=New-OwnedProcess $worker
 $statusReads=0;$heldReads=0;$deadline=[DateTime]::UtcNow.AddSeconds(40);while([DateTime]::UtcNow -lt $deadline -and (Read-Probe $calmName).priorityClass -ne 'BelowNormal'){if($worker.HasExited){break};Get-Status 'calm-status'|Out-Null;$statusReads++;Hold-NewestSession}
 Case ((Read-Probe $calmName).priorityClass -eq 'BelowNormal') 'The busy probe is lowered after the shipped pressure window'
 Save 'calm-lowered' (Read-Probe $calmName);[IO.File]::WriteAllText($idle,'idle',$utf8)
 $deadline=[DateTime]::UtcNow.AddSeconds(90);while(-not$worker.HasExited -and [DateTime]::UtcNow -lt $deadline){Get-Status 'calm-status'|Out-Null;$statusReads++;Hold-NewestSession}
 if(-not$worker.WaitForExit(1000)){throw 'The calm-probe governor worker did not finish'}
 $calmResult=Get-Content -Raw $calmOutput|ConvertFrom-Json
 Case ($statusReads -gt 5 -and $heldReads -gt 5 -and $calmResult.status -eq 'completed' -and @($calmResult.errors).Count -eq 0) ('Status reads and a reader that blocks deletes never break a live run''s saved state ('+$statusReads+' status reads, '+$heldReads+' blocking reads)')
 Case ((Test-Original $calmName) -and @($calmResult.restoredItems).Count -gt 0 -and -not$calmResult.restorable) 'A busy probe that becomes idle is restored exactly during the app''s 60 second watch, without Restore'
 $keptName='PvuKept'+[Guid]::NewGuid().ToString('N').Substring(0,6);Copy-Item $calmExe (Join-Path $directory ($keptName+'.exe'));$keptIdle=Join-Path $directory 'kept-idle'
 $probe=Start-Process (Join-Path $directory ($keptName+'.exe')) -ArgumentList ('"'+$keptIdle+'"') -WindowStyle Hidden -PassThru;$owned[$keptName]=New-OwnedProcess $probe;$probes[$keptName]=$probe;Reset-Probe $keptName
 $keptProfile=New-Profile 'calm-kept' @($keptName) 8 15
 $value=Get-Content -Raw $keptProfile|ConvertFrom-Json;$value.governor.thresholds.perProcessCpuThresholdPercent=0.1;$value.governor.thresholds.cooldownAfterRestoreSeconds=120;[IO.File]::WriteAllText($keptProfile,($value|ConvertTo-Json -Depth 40),$utf8)
 $keptOutput=Join-Path $directory 'calm-kept-start.json';$keptScript=Join-Path $directory 'calm-kept-start.ps1'
 $text='& '''+(Join-Path $scripts 'Start-ProcessGovernorSession.ps1').Replace("'","''")+''' -ProfilePath '''+$keptProfile.Replace("'","''")+''' -StateRoot '''+$state.Replace("'","''")+''' -ConfirmApply -MaxDurationSeconds 60 -PollIntervalSeconds 2 -SampleIntervalMilliseconds 250 -OutputPath '''+$keptOutput.Replace("'","''")+''''
 [IO.File]::WriteAllText($keptScript,$text,[Text.UTF8Encoding]::new($true))
 $worker=Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$keptScript+'"') -WindowStyle Hidden -PassThru;$workerOwned=New-OwnedProcess $worker
 $deadline=[DateTime]::UtcNow.AddSeconds(40);while([DateTime]::UtcNow -lt $deadline -and (Read-Probe $keptName).priorityClass -ne 'BelowNormal'){if($worker.HasExited){break};Start-Sleep -Milliseconds 100}
 $keptLowered=Read-Probe $keptName
 Case ($keptLowered.priorityClass -eq 'BelowNormal') 'A second busy probe is lowered during its watch'
 $busyStop=Stop-Limits 'stop-during-run' $third
 Case ($busyStop.status -eq 'failed' -and @($busyStop.errors)[0].code -eq 'PROCESS_GOVERNOR_RUN_BUSY' -and $busyStop.restorable -and (Read-Probe $keptName).priorityClass -eq 'BelowNormal') 'Restore while another run is still going says so and changes nothing'
 $probes[$keptName].PriorityClass='AboveNormal';[IO.File]::WriteAllText($keptIdle,'idle',$utf8)
 if(-not$worker.WaitForExit(90000)){throw 'The kept-probe governor worker did not finish'}
 $keptResult=Get-Content -Raw $keptOutput|ConvertFrom-Json;$keptNow=Read-Probe $keptName
 Case ($keptResult.restorable -and $keptResult.status -eq 'completed' -and @($keptResult.activeRestraints).Count -eq 0 -and @($keptResult.result.leftAsSetItems).Count -eq 1 -and $keptResult.result.summary -match 'Left as another program set it: ' -and $keptNow.priorityClass -eq 'AboveNormal' -and $keptNow.ioPriority -eq 2 -and $keptNow.memoryPriority -eq 5) 'When the watch puts a calm app back, it keeps and names a value another program set, finishes normally and keeps the run''s backup'
 [RooIndustriesBackgroundOracle]::SetIo($probes[$keptName],$keptLowered.ioPriority);Save 'kept-watch-io-by-other-program' (Read-Probe $keptName)
 Case (-not (Get-Status 'kept-watch-io-status').restorable) 'An I/O priority the watch put back is not offered for Restore when another program later picks the lowered value'
 $probes[$keptName].PriorityClass=$keptLowered.priorityClass
 Case (-not (Get-Status 'kept-watch-status').restorable) 'A CPU priority the watch kept as another program set it is not offered for Restore when the lowered value comes back'
 $undo=Stop-Limits 'kept-watch-undo' $keptResult;$keptNow=Read-Probe $keptName
 Case ($keptNow.priorityClass -eq $keptLowered.priorityClass -and $keptNow.memoryPriority -eq 5) 'Restore leaves that lowered CPU priority as the other program set it'
 Case ($keptNow.ioPriority -eq $keptLowered.ioPriority) 'That Restore leaves the I/O priority another program set after the watch put it back'
 Save 'done' @{passed=($failures.Count -eq 0);failures=@($failures)}
 if($failures.Count){throw ('Background limits second-run checks failed: '+($failures -join '; '))}
} catch {Save 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};throw}
finally{
 if($workerOwned){Stop-OwnedProcess $workerOwned}
 foreach($name in @($owned.Keys)){Stop-OwnedProcess $owned[$name]}
 Save 'cleanup' @{probesStopped=@($probes.Values|ForEach-Object {$_.HasExited});workerStopped=if($worker){$worker.HasExited}else{$true}}
}
