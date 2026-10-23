param(
 [Parameter(Mandatory)][string]$Source,
 [Parameter(Mandatory)][string]$OutRoot,
 [ValidateRange(0,150)][int]$History=50,
 [ValidateRange(1,80)][int]$Apps=40,
 [ValidateSet('target','original','external','all')][string]$Mode='all',
 [ValidateSet('profile','game','all')][string]$Kind='all'
)
$ErrorActionPreference='Stop'
if($env:OS -eq 'Windows_NT'){throw 'This check uses owned Linux probes; Windows scale proof is a separate gate.'}
$utf8=[Text.UTF8Encoding]::new($false)
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$fixture=Join-Path $OutRoot ('fixture-'+[guid]::NewGuid().ToString('N'))
$dataRoot=Join-Path $fixture 'data'
$script:ScaleDataRoot=$dataRoot
$operations=Join-Path $dataRoot 'operations'
$probes=New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
$results=New-Object System.Collections.Generic.List[object]
$failures=New-Object System.Collections.Generic.List[string]
function Save([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 40),$utf8)}
function Check([bool]$Ok,[string]$Message){if(-not$Ok){$failures.Add($Message)|Out-Null}}
function Read-Ast([string]$Path){
 $e=$null;$t=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Source $Path),[ref]$t,[ref]$e)
 if($e.Count){throw ($e -join '; ')}
 return $a
}
. (Join-Path $Source 'tools/validation/Background/RestoreSimulation.Common.ps1')
function New-HistoryJournal([int]$Id,[string]$Field,[string]$Path){
 $value=if($Field -eq 'cpuPriority'){'Normal'}elseif($Field -eq 'gpuPriority'){2}else{5}
 return [ordered]@{
  schemaVersion=1
  preview=[ordered]@{schemaVersion=1;operationId=([guid]::NewGuid().ToString('N'));owner=@{userSid='S-1-5-21-1-2-3-1001';machine='Fixture';processId=1234;creationTimeFileTimeUtc='133000000000000000'};identity=@{processId=$Id;creationTimeFileTimeUtc='133100000000000000';executablePath=$Path};original=@{$Field=@{known=$true;value=$value;error=$null}};desired=@{$Field=$value};topologyHash=('a'*64)}
  reviewHash=('b'*64);previewPath='C:\Fixture\preview.json';status='restored'
  changes=@(@{name=$Field;original=$value;desired=$value;status='restored';observed=$value;error=$null;errorKind=$null})
  updatedAtUtc='2026-10-01T00:00:00Z'
 }
}
try {
 [IO.Directory]::CreateDirectory($operations)|Out-Null
 for($i=0;$i -lt $History;$i++){
  $session=Join-Path (Join-Path $operations ('game-session-'+[guid]::NewGuid().ToString('N'))) 'session'
  [IO.Directory]::CreateDirectory($session)|Out-Null
  Save (Join-Path $session 'launcher-journal.json') (New-HistoryJournal (5000+$i) 'memoryPriority' 'C:\Fixture\launcher.exe')
  $field=Join-Path $session ('games/'+(6000+$i)+'-133100000000000000/gpuPriority')
  [IO.Directory]::CreateDirectory($field)|Out-Null
  Save (Join-Path $field 'journal.json') (New-HistoryJournal (6000+$i) 'gpuPriority' 'C:\Fixture\game.exe')
  $process=Join-Path $operations ('process-'+[guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($process)|Out-Null
  Save (Join-Path $process 'preview.json') @{}
  if($i % 2 -eq 0){Save (Join-Path $process 'journal.json') (New-HistoryJournal (7000+$i) 'cpuPriority' 'C:\Fixture\app.exe')}
 }
 for($i=0;$i -lt $Apps;$i++){
  $start=[Diagnostics.ProcessStartInfo]::new()
  $start.FileName='/bin/sleep';$start.Arguments='1200';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
  $probe=[Diagnostics.Process]::Start($start)
  $probes.Add($probe)|Out-Null
  Save (Join-Path $OutRoot 'owned-probes.json') @{fixture=$fixture;processes=@($probes|ForEach-Object {@{processId=$_.Id;creationTimeFileTimeUtc=[string]$_.StartTime.ToUniversalTime().ToFileTimeUtc()}})}
 }
 $kinds=if($Kind -eq 'all'){@('profile','game')}else{@($Kind)}
 $modes=if($Mode -eq 'all'){@('target','original','external')}else{@($Mode)}
 foreach($caseKind in $kinds){foreach($caseMode in $modes){& {
  foreach($path in 'backend/scripts/OperationState.Common.ps1','backend/scripts/GovernorOwnership.Common.ps1','backend/scripts/ProcessProfile.Common.ps1','backend/scripts/GameTuneSession.Common.ps1','backend/scripts/Restore-ProcessProfileBackup.ps1','backend/scripts/Stop-GameTuneSession.ps1'){
   foreach($s in (Read-Ast $path).EndBlock.Statements){
    if($s -is [Management.Automation.Language.FunctionDefinitionAst] -or (($path -like '*Common.ps1' -or $path -like '*Stop-GameTuneSession.ps1') -and $s -is [Management.Automation.Language.AssignmentStatementAst])){. ([scriptblock]::Create($s.Extent.Text))}
   }
  }
  $name=$caseKind+'-'+$caseMode
  $directory=Join-Path $OutRoot $name
  [IO.Directory]::CreateDirectory($directory)|Out-Null
  $script:Held=$false;$script:Acquired=0;$script:Released=0;$script:Disposed=0;$script:PreviewLoads=0;$script:FreshLoads=0;$script:ReadOutsideGate=0
  $script:Values=@{};$byId=@{}
  $script:Writes=New-Object System.Collections.Generic.List[object]
  $initial=switch($caseMode){'target'{'BelowNormal'};'original'{'Normal'};default{'High'}}
  $snapshots=@(foreach($probe in $probes){
   $byId[$probe.Id]=$probe;$script:Values[$probe.Id]=$initial
   New-FixtureSnapshot $probe @{originalPriorityClass='Normal';controlChanges=@([pscustomobject]@{control='priorityClass';proposedValue='BelowNormal';outcome='applied'})}
  })
  function Get-RooIndustriesLocalDataRoot {return $script:ScaleDataRoot}
  function Test-RooIndustriesGovernorOwnsControl {param($Process,$Control) return $false}
  $rawCommand=Get-Command Read-RooIndustriesProcessOperationOwnership -CommandType Function -ErrorAction SilentlyContinue
  if($null -ne $rawCommand){
   $script:ActualScaleReader=$rawCommand.ScriptBlock
   function Read-RooIndustriesProcessOperationOwnership {
    if($script:Held){$script:FreshLoads++}else{$script:PreviewLoads++}
    & $script:ActualScaleReader
   }
  } else {
   $script:ActualScaleReader=(Get-Command Get-RooIndustriesProcessOperationControls -CommandType Function).ScriptBlock
   function Get-RooIndustriesProcessOperationControls {
    param($Process,[switch]$ForPreview)
    if($script:Held){$script:FreshLoads++}else{$script:PreviewLoads++}
    & $script:ActualScaleReader $Process
   }
  }
  $backupFile=Join-Path $directory 'backup.json';$sessionFile=Join-Path $directory 'session.json'
  Save $backupFile @{actionId=if($caseKind -eq 'game'){'performance.gameTune.startSession'}else{'performance.applyProfile'};dryRun=$false;sessionId='scale-session';profileId='scale';backupId='scale';snapshots=$snapshots}
  Save $sessionFile @{sessionId='scale-session';profileId='scale';sessionPath=$sessionFile;backupManifestPath=$backupFile;dryRun=$false;status='completed';sessionStatus='completed';restorable=$true;restoredItems=@();skippedItems=@();changedItems=@();completedAtUtc=$null}
  function Resolve-RooIndustriesPath {param($Path,$DefaultPath) return $Path}
  function Resolve-RooIndustriesGameTuneSessionFile {param($SessionId,$SessionPath,$StateRoot) return $sessionFile}
  function Resolve-RooIndustriesGameTuneStateRoot {param($StateRoot) return $directory}
  function Get-FixtureState([int]$Id){return [pscustomobject]@{exists=$true;priorityClass=$script:Values[$Id];process=$byId[$Id]}}
  function Get-FixtureCandidate($Entry){
   $state=Get-FixtureState ([int]$Entry.processId)
   return [pscustomobject]@{exists=$true;matches=$true;instanceEnded=$false;process=$state.process;currentPriorityClass=$state.priorityClass;currentControlState=$state;blockedReason=$null;reason=$null}
  }
  function Get-RestoreCandidate {param($Snapshot) return Get-FixtureCandidate $Snapshot}
  function Get-RooIndustriesGameTuneLiveProcessIdentity {param($Entry) return Get-FixtureCandidate $Entry}
  function Get-RooIndustriesProcessControlState {param($ProcessId,$Unused,[switch]$ReadGpu) return Get-FixtureState $ProcessId}
  function Enter-RooIndustriesGovernorGate {param($Seconds) $script:Held=$true;$script:Acquired++;return New-FixtureGovernorGate}
  function Get-RooIndustriesProcessControlReadback {param($Process,$Control) if(-not$script:Held){$script:ReadOutsideGate++};return $script:Values[$Process.Id]}
  function Invoke-RooIndustriesProcessControlChange {param($Process,$Change) $script:Writes.Add(@{processId=$Process.Id;value=$Change.proposedValue})|Out-Null;$script:Values[$Process.Id]=$Change.proposedValue;$Change.outcome='applied'}
  function Write-RooIndustriesJsonOutput {param($Value,$OutputPath) return $Value}
  $ConfirmApply=$true;$BackupPath=$backupFile;$SessionPath=$sessionFile;$SessionId='scale-session';$StateRoot=$directory;$OutputPath=''
  $path=if($caseKind -eq 'profile'){'backend/scripts/Restore-ProcessProfileBackup.ps1'}else{'backend/scripts/Stop-GameTuneSession.ps1'}
  $body=(Read-Ast $path).EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
  $clock=[Diagnostics.Stopwatch]::StartNew()
  $result=& ([scriptblock]::Create($body.Extent.Text))
  $clock.Stop()
  Save (Join-Path $directory 'result.json') $result
  $expectedWrites=if($caseMode -eq 'target'){$Apps}else{0}
  $expectedKept=if($caseMode -eq 'external'){$Apps}else{0}
  $kept=@(Get-RooIndustriesPropertyArray $result.result 'leftAsSetItems').Count
  $complete=if($caseKind -eq 'profile'){$result.status -eq 'success' -and $result.result.restorePendingCount -eq 0}else{$result.status -eq 'completed' -and -not$result.restorable}
  Check $complete "$name finishes its exact recovery"
  Check ($script:PreviewLoads -eq 1) "$name reads one preview snapshot across distinct processes and rebuild"
  Check ($script:FreshLoads -eq $Apps) "$name rereads under the gate for every closing decision"
  Check ($script:Writes.Count -eq $expectedWrites -and $kept -eq $expectedKept) "$name writes and kept reports match the input state"
  Check (@($script:Values.Values|Where-Object {$_ -ne $(if($caseMode -eq 'external'){'High'}else{'Normal'})}).Count -eq 0) "$name every process ends at its expected value"
  Check ($script:Acquired -eq $script:Released -and $script:Released -eq $script:Disposed -and -not$script:Held -and $script:ReadOutsideGate -eq 0) "$name releases gates and certifies only inside them"
  Check ($clock.Elapsed.TotalSeconds -lt 45) "$name finishes within the app timeout on Linux"
  $metrics=[pscustomobject]@{name=$name;proof='Real Linux files, distinct owned process identities and restore bodies; simulated controls/gate, not Windows proof';apps=$Apps;distinctProcessIds=@($byId.Keys).Count;historyGameSessions=$History;historyProcessFolders=$History;terminalJournals=(2*$History+[int][math]::Ceiling($History/2.0));previewLoads=$script:PreviewLoads;freshLoads=$script:FreshLoads;elapsedMs=[math]::Round($clock.Elapsed.TotalMilliseconds);status=$result.status;writes=@($script:Writes.ToArray());kept=$kept;values=@($byId.Keys|ForEach-Object {[pscustomobject]@{processId=$_;value=$script:Values[$_]}})}
  Save (Join-Path $directory 'metrics.json') $metrics
  $results.Add($metrics)|Out-Null
 }}}
} finally {
 foreach($probe in $probes){try{if(-not$probe.HasExited){$probe.Kill();$probe.WaitForExit()}}finally{$probe.Dispose()}}
 if([IO.Directory]::Exists($fixture)){[IO.Directory]::Delete($fixture,$true)}
 Save (Join-Path $OutRoot 'summary.json') @{proof='Linux integration and scale, not native Windows PS5.1';cases=@($results.ToArray());failures=@($failures.ToArray());ownedProbeCount=$probes.Count;fixturesRemoved=(-not[IO.Directory]::Exists($fixture))}
}
if($failures.Count){throw ($failures -join '; ')}
"Completed $($results.Count) restore ownership scale scenarios."
