param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[string[]]$Modes=@())
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false)
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$failures=New-Object System.Collections.Generic.List[string]
$cases=New-Object System.Collections.Generic.List[object]
function Save([string]$Directory,[string]$Name,$Value){[IO.File]::WriteAllText((Join-Path $Directory ($Name+'.json')),($Value|ConvertTo-Json -Depth 50),$utf8)}
function Check([bool]$Condition,[string]$Message){if($Condition){"PASS $Message"}else{$failures.Add($Message)|Out-Null;"FAIL $Message"}}
function Read-Ast([string]$Path){$e=$null;$t=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Source $Path),[ref]$t,[ref]$e);if($e.Count){throw ($e -join '; ')};return $a}
$ownershipMeter={
 $script:PreviewLoads=0;$script:FreshLoads=0
 $raw=Get-Command Read-RooIndustriesProcessOperationOwnership -CommandType Function -ErrorAction SilentlyContinue
 if($null -ne $raw){
  $script:ActualOwnershipReader=$raw.ScriptBlock
  function Read-RooIndustriesProcessOperationOwnership {if($script:Held){$script:FreshLoads++}else{$script:PreviewLoads++};& $script:ActualOwnershipReader}
 }else{
  $script:ActualOwnershipReader=(Get-Command Get-RooIndustriesProcessOperationControls -CommandType Function).ScriptBlock
  function Get-RooIndustriesProcessOperationControls {param($Process,[switch]$ForPreview) if($script:Held){$script:FreshLoads++}else{$script:PreviewLoads++};& $script:ActualOwnershipReader $Process}
 }
}
function Invoke-Scenario([string]$Kind,[string]$Mode,[string]$RootStatus='applied',[string]$ChangeStatus='applied'){
 $name=$Kind+'-'+$Mode+$(if($Mode -eq 'table'){'-'+$RootStatus+'-'+$ChangeStatus}else{''})
 $directory=Join-Path $OutRoot $name;[IO.Directory]::CreateDirectory($directory)|Out-Null
 & {
  foreach($path in 'backend/scripts/OperationState.Common.ps1','backend/scripts/GovernorOwnership.Common.ps1','backend/scripts/ProcessProfile.Common.ps1','backend/scripts/GameTuneSession.Common.ps1','backend/scripts/Restore-ProcessProfileBackup.ps1','backend/scripts/Stop-GameTuneSession.ps1'){
   foreach($s in (Read-Ast $path).EndBlock.Statements){if($s -is [System.Management.Automation.Language.FunctionDefinitionAst] -or (($path -like '*Common.ps1' -or $path -like '*Stop-GameTuneSession.ps1') -and $s -is [System.Management.Automation.Language.AssignmentStatementAst])){. ([scriptblock]::Create($s.Extent.Text))}}
  }
  $dataRoot=Join-Path $directory 'data';[IO.Directory]::CreateDirectory($dataRoot)|Out-Null
  function Get-RooIndustriesLocalDataRoot {return $dataRoot}
  function Test-RooIndustriesGovernorOwnsControl {param($Process,$Control) return $false}
  $live=[Diagnostics.Process]::GetCurrentProcess()
  $identity=[pscustomobject]@{processId=$live.Id;creationTimeFileTimeUtc=[string]$live.StartTime.ToUniversalTime().ToFileTimeUtc();executablePath=$live.MainModule.FileName}
  $memory=$Mode -eq 'protected-launcher';$gpu=$Mode -eq 'protected-game'
  $control=if($memory){'memoryPriority'}elseif($gpu){'gpuPriority'}else{'priorityClass'}
  $native=if($memory){'memoryPriority'}elseif($gpu){'gpuPriority'}else{'cpuPriority'}
  $original=if($memory){5}else{'Normal'};$target=if($memory){2}elseif($gpu){'BelowNormal'}else{'AboveNormal'};$external=if($memory){1}else{'High'}
  $cpuPeer=$memory -or $gpu
  $peerControl=if($cpuPeer){'priorityClass'}else{'memoryPriority'};$peerOriginal=if($cpuPeer){'Normal'}else{5};$peerTarget=if($cpuPeer){'AboveNormal'}else{2}
  $script:Values=@{};$script:Values[$control]=if($Mode -in @('original','arrival-original')){$original}elseif($Mode -eq 'writer-arrival'){$target}else{$external};$script:Values[$peerControl]=$peerTarget
  $script:Retry=$false;$script:CandidateCalls=0;$script:Injected=0;$script:Held=$false;$script:Acquired=0;$script:Released=0;$script:OutsideReads=0
  $script:Writes=New-Object System.Collections.Generic.List[object]
  $script:Attempts=New-Object System.Collections.Generic.List[object]
  $operationsRoot=Join-Path $dataRoot 'operations'
  $sessionRoot=Join-Path (Join-Path $operationsRoot 'game-session-0123456789abcdef0123456789abcdef') 'session'
  $journalPath=switch($Mode){'protected-launcher'{Join-Path $sessionRoot 'launcher-journal.json'};'protected-game'{Join-Path (Join-Path (Join-Path (Join-Path $sessionRoot 'games') ($identity.processId.ToString()+'-'+$identity.creationTimeFileTimeUtc)) 'gpuPriority') 'journal.json'};default{Join-Path (Join-Path $operationsRoot 'process-fixture') 'journal.json'}}
  $journalRelative=$journalPath.Substring($operationsRoot.Length+1)
  $journal=[pscustomobject]@{schemaVersion=1;status=$RootStatus;preview=[pscustomobject]@{identity=$identity};changes=@([pscustomobject]@{name=$native;status=$ChangeStatus;original=$target;desired=$external;observed=$external})}
  if($gpu){$journal.changes[0].original=1;$journal.changes[0].desired=4;$journal.changes[0].observed=4}
  function Write-Journal {
   [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($journalPath))|Out-Null
   [IO.File]::WriteAllText($journalPath,(ConvertTo-Json -InputObject $journal -Depth 30),$utf8)
  }
  switch($Mode){
   'alias'{$journal.changes[0].name='priorityClass'}
   'cpuSets'{$journal.changes[0].name='cpuSets'}
   'different-pid'{$identity.processId++}
   'different-creation'{$identity.creationTimeFileTimeUtc=[string]([long]$identity.creationTimeFileTimeUtc+1)}
   'different-path'{$identity.executablePath+='.different'}
   'different-creation-path'{$identity.creationTimeFileTimeUtc=[string]([long]$identity.creationTimeFileTimeUtc+1);$identity.executablePath+='.different'}
   'different-pid-path'{$identity.processId++;$identity.executablePath+='.different'}
   'unknown-schema'{$journal.schemaVersion=2}
   'unknown-root'{$journal.status='unknown'}
   'unknown-change'{$journal.changes[0].status='unknown'}
   'unknown-control'{$journal.changes[0].name='unknown'}
   'missing-identity'{$journal.preview.identity=$null}
   'invalid-pid'{$identity.processId=0}
   'invalid-creation'{$identity.creationTimeFileTimeUtc='0'}
   'relative-path'{$identity.executablePath='relative.exe'}
   'scalar-changes'{$journal.changes='applied'}
   'null-change'{$journal.changes=@($null)}
   'scalar-root'{$journal='invalid'}
   'array-root'{$journal=@($journal)}
  }
  $uncertain=$Mode -in @('unknown-schema','unknown-root','unknown-change','unknown-control','missing-identity','invalid-pid','invalid-creation','relative-path','scalar-changes','null-change','scalar-root','array-root','malformed-json','unreadable-journal','directory-error','enumeration-error','cached-error-repair')
  $claim=if($Mode -eq 'table'){$RootStatus -in @('applying','applied','needsReconciliation') -and ($ChangeStatus -in @('applyIntent','applied','restoreIntent') -or ($RootStatus -eq 'applying' -and $ChangeStatus -eq 'pending'))}else{$Mode -notin @('different-pid','different-creation','different-creation-path','different-pid-path','cpuSets','missing-journal','missing-operations','unrelated-file')}
  $retained=$claim -or $uncertain
  if($Mode -notin @('arrival-left','arrival-original','writer-arrival','missing-operations','directory-error','enumeration-error','unrelated-file')){Write-Journal}
  if($Mode -eq 'missing-journal'){[IO.File]::Delete($journalPath)}
  if($Mode -in @('malformed-json','cached-error-repair')){[IO.File]::WriteAllText($journalPath,'{broken',$utf8)}
  if($Mode -eq 'unreadable-journal'){[IO.File]::Delete($journalPath);[IO.Directory]::CreateDirectory($journalPath)|Out-Null}
  if($Mode -eq 'directory-error'){[IO.File]::WriteAllText((Join-Path $dataRoot 'operations'),'not a directory',$utf8)}
  if($Mode -eq 'enumeration-error'){
   [IO.Directory]::CreateDirectory((Join-Path $dataRoot 'operations'))|Out-Null
   $actualDirectories=Get-Command Get-RooIndustriesProcessOperationDirectories -CommandType Function -ErrorAction SilentlyContinue
   $actualDirectoryBody=if($null -ne $actualDirectories){$actualDirectories.ScriptBlock}else{$null}
   function Get-RooIndustriesProcessOperationDirectories {param($Path) throw [UnauthorizedAccessException]::new('Simulated denied directory enumeration')}
   if($null -eq $actualDirectories){function Get-ChildItem {param($LiteralPath,[switch]$Directory,$ErrorAction) throw [UnauthorizedAccessException]::new('Simulated denied directory enumeration')}}
  }
  if($Mode -eq 'unrelated-file'){
   $unrelated=Join-Path $dataRoot 'operations/cleanup-fixture';[IO.Directory]::CreateDirectory($unrelated)|Out-Null
   [IO.File]::WriteAllText((Join-Path $unrelated 'journal.json'),'{"unrelated":true}',$utf8)
  }
  if([IO.File]::Exists($journalPath)){[IO.File]::Copy($journalPath,(Join-Path $directory 'journal-first.txt'),$true)}
  if($Mode -in @('cached-positive-release','cached-error-repair')){[IO.File]::Copy($journalPath,(Join-Path $directory 'journal-preview.txt'),$true)}
  $changes=@([pscustomobject]@{control=$control;proposedValue=$target;outcome='applied'},[pscustomobject]@{control=$peerControl;proposedValue=$peerTarget;outcome='applied'})
  $snapshot=[pscustomobject]@{processId=$live.Id;processName='NativeTarget';originalPriorityClass='Normal';originalMemoryPriority=5;controlChanges=$changes}
  if($gpu){$snapshot|Add-Member -NotePropertyName originalGpuPriority -NotePropertyValue 'Normal';$snapshot|Add-Member -NotePropertyName proposedGpuPriority -NotePropertyValue 'BelowNormal'}
  $backupFile=Join-Path $directory 'backup.json';$sessionFile=Join-Path $directory 'session.json'
  Save $directory 'backup' ([pscustomobject]@{actionId='performance.gameTune.startSession';dryRun=$false;sessionId='operation-session';profileId='operation-profile';backupId='operation-backup';createdAtUtc='2026-10-01T00:00:00Z';snapshots=@($snapshot)})
  Save $directory 'session' ([pscustomobject]@{sessionId='operation-session';profileId='operation-profile';sessionPath=$sessionFile;backupManifestPath=$backupFile;dryRun=$false;status='completed';sessionStatus='completed';restorable=$true;restoredItems=@();skippedItems=@();completedAtUtc=$null;changedItems=@([pscustomobject]@{processName='HistoricalApply';appliedControls=@([pscustomobject]@{control='priorityClass';currentValue='Normal';proposedValue='AboveNormal';outcome='applied'})})})
  function Resolve-RooIndustriesPath {param($Path,$DefaultPath) return $Path}
  function Resolve-RooIndustriesGameTuneSessionFile {param($SessionId,$SessionPath,$StateRoot) return $sessionFile}
  function Resolve-RooIndustriesGameTuneStateRoot {param($StateRoot) return $directory}
  function Get-FixtureState {return [pscustomobject]@{priorityClass=$script:Values['priorityClass'];memoryPriority=$script:Values['memoryPriority'];memoryPriorityAvailable=$true;gpuPriority=$script:Values['gpuPriority'];gpuPriorityAvailable=$gpu;gpuPriorityStatus=if($gpu){0}else{$null};process=$live}}
  function Get-FixtureCandidate {
   $script:CandidateCalls++
   if($script:CandidateCalls -eq 2 -and $Mode -like 'arrival-*' -and -not$script:Retry){Write-Journal;$script:Injected++}
   if($script:CandidateCalls -eq 2 -and $Mode -in @('cached-positive-release','cached-error-repair') -and -not$script:Retry){$journal=[pscustomobject]@{schemaVersion=1;status='restored'};Write-Journal;$script:Values[$control]=$target;$script:Injected++}
   $state=Get-FixtureState
   return [pscustomobject]@{exists=$true;matches=$true;instanceEnded=$false;process=$live;currentPriorityClass=$state.priorityClass;currentMemoryPriority=$state.memoryPriority;currentGpuPriority=$state.gpuPriority;currentControlState=$state;blockedReason=$null;reason=$null}
  }
  function Get-RestoreCandidate {param($Snapshot) return Get-FixtureCandidate}
  function Get-RooIndustriesGameTuneLiveProcessIdentity {param($Entry) return Get-FixtureCandidate}
  function Get-RooIndustriesProcessControlState {param($ProcessId,$Unused,[switch]$ReadGpu) return Get-FixtureState}
  function Enter-RooIndustriesGovernorGate {param($Seconds) $script:Acquired++;$script:Held=$true;return [pscustomobject]@{fixtureGate=$true}}
  function Exit-RooIndustriesGovernorGate {param($Gate) if($null -ne $Gate){$script:Released++;$script:Held=$false}}
  function Get-RooIndustriesProcessControlReadback {param($Process,$Control) if(-not$script:Held){$script:OutsideReads++};return $script:Values[$Control]}
  function Invoke-RooIndustriesProcessControlChange {
   param($Process,$Change)
   $script:Attempts.Add($Change.control)|Out-Null
   if(-not$script:Retry -and $Mode -eq 'writer-arrival' -and $Change.control -eq $control){Write-Journal;$script:Injected++;$script:Values[$control]=$external;throw $script:RooIndustriesChangedExternally}
   $script:Writes.Add([pscustomobject]@{control=$Change.control;value=$Change.proposedValue})|Out-Null
   $script:Values[$Change.control]=$Change.proposedValue;$Change.outcome='applied'
  }
  function Write-RooIndustriesJsonOutput {param($Value,$OutputPath) return $Value}
  function Invoke-Undo {
   $ConfirmApply=$true;$BackupPath=$backupFile;$SessionPath=$sessionFile;$SessionId='operation-session';$StateRoot=$directory;$OutputPath=''
   $path=if($Kind -eq 'profile'){'backend/scripts/Restore-ProcessProfileBackup.ps1'}else{'backend/scripts/Stop-GameTuneSession.ps1'}
   $body=(Read-Ast $path).EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
   return & ([scriptblock]::Create($body.Extent.Text))
  }
  function Read-Status([string]$Label){
   $SessionPath=$sessionFile;$SessionId='operation-session';$StateRoot=$directory;$OutputPath=''
   $body=(Read-Ast 'backend/scripts/Get-GameTuneSessionStatus.ps1').EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
   $value=& ([scriptblock]::Create($body.Extent.Text));Save $directory $Label $value;return $value
  }
  . $ownershipMeter
  $expectedFirst=if($Mode -eq 'writer-arrival'){$external}elseif($Mode -in @('cached-positive-release','cached-error-repair')){$target}else{$script:Values[$control]}
  $readerControls=$null
  if($Mode -in @('protected-launcher','protected-game','different-path','different-creation-path','different-pid-path')){
   $readerControls=@(Get-RooIndustriesProcessOperationControls $live)
   Check (($readerControls -contains $native) -eq $claim -and $readerControls -notcontains $(if($cpuPeer){'cpuPriority'}else{'memoryPriority'})) "$name actual reader distinguishes same and different process instances per control"
  }
  $script:PreviewLoads=0;$script:FreshLoads=0
  $first=Invoke-Undo;Save $directory 'first' $first
  if([IO.File]::Exists($journalPath)){[IO.File]::Copy($journalPath,(Join-Path $directory 'journal-first.txt'),$true)}
  Save $directory 'first-observation' @{proof='Real saved journal files/reader, restore/persistence/status; simulated Linux process I/O and gate; enumeration-error alone injects directory denial; no native GPU proof';sessionRoot=$sessionRoot;journalPath=$journalPath;journalRelative=$journalRelative;readerControls=$readerControls;values=$script:Values;writes=@($script:Writes.ToArray());attempts=@($script:Attempts.ToArray());injectionReached=$script:Injected;previewLoads=$script:PreviewLoads;freshLoads=$script:FreshLoads;acquired=$script:Acquired;released=$script:Released;outsideCertificationReads=$script:OutsideReads;held=$script:Held;retained=$retained;uncertain=$uncertain}
  Check ($script:PreviewLoads -eq 1) "$name shares one raw preview snapshot across controls and rebuild"
  Check ($script:FreshLoads -eq $script:Acquired) "$name reads fresh ownership inside every closing-decision gate"
  $pending=if($Kind -eq 'profile'){$first.result.restorePendingCount -eq 1}else{$first.restorable}
  Check ($pending -eq $retained) "$name recovery follows real saved-operation evidence"
  if($retained){Check ($first.result.status -in @('partial','failed')) "$name retained recovery reports an incomplete Undo"}
  Check (@($script:Writes|Where-Object control -eq $control).Count -eq 0) "$name first Undo never writes the target field"
  Check ($script:Values[$control] -eq $expectedFirst -and $script:Values[$peerControl] -eq $(if($uncertain){$peerTarget}else{$peerOriginal})) "$name actual readback preserves target and restores the independent peer"
  Check (@($first.result.leftAsSetItems|Where-Object control -eq $control).Count -eq $(if($retained){0}else{1})) "$name never certifies an owned or unknown field as external"
  if(-not$retained){Check (@($first.result.leftAsSetItems|Where-Object {$_.control -eq $control -and $_.currentValue -eq $external -and $_.processName -eq 'NativeTarget'}).Count -eq 1) "$name names the actual unowned external readback"}
  Check (@($script:Writes|Where-Object control -eq $peerControl).Count -eq $(if($uncertain){0}else{1})) "$name independent peer restoration follows per-control evidence"
  if($retained){
   $reason=if($uncertain){$script:RooIndustriesLeftAsSetChangedBack}else{$script:RooIndustriesProcessOperationManaged}
   Check (@($first.result.skippedItems|Where-Object { ($_.reason -split '; ') -contains ($control+': '+$reason) }).Count -eq 1) "$name reports the exact retryable ownership reason"
  }
  if($Mode -like 'arrival-*' -or $Mode -eq 'writer-arrival'){
   Check ($script:Injected -eq 1 -and [IO.File]::ReadAllText($journalPath).Contains('"applied"')) "$name injects the actual journal at the old/new body boundary"
   Check ($script:Acquired -gt 0) "$name reaches gated final certification"
  }
  if($Mode -in @('cached-positive-release','cached-error-repair')){Check ($script:Injected -eq 1 -and [IO.File]::ReadAllText($journalPath).Contains('"restored"')) "$name releases or repairs real evidence after preview without clearing the cached refusal"}
  Check ($script:Acquired -eq $script:Released -and -not$script:Held -and $script:OutsideReads -eq 0) "$name releases acquired gates and certifies only inside them"
  if($Kind -eq 'game'){$null=Read-Status 'status-first'}
  if($retained){
   if($Mode -eq 'enumeration-error'){if($null -ne $actualDirectoryBody){Set-Item Function:\Get-RooIndustriesProcessOperationDirectories -Value $actualDirectoryBody}else{Remove-Item Function:\Get-ChildItem}}
   if($Mode -eq 'directory-error'){[IO.File]::Delete((Join-Path $dataRoot 'operations'))}
   if($Mode -eq 'unreadable-journal'){[IO.Directory]::Delete($journalPath)}
   $journal=[pscustomobject]@{schemaVersion=1;status='restored'};Write-Journal
   $script:Retry=$true;$script:Values[$control]=$target;$script:CandidateCalls=0;$script:Writes.Clear();$script:PreviewLoads=0;$script:FreshLoads=0
   $retry=Invoke-Undo;Save $directory 'retry' $retry
   Save $directory 'retry-observation' @{values=$script:Values;writes=@($script:Writes.ToArray());previewLoads=$script:PreviewLoads;freshLoads=$script:FreshLoads;acquired=$script:Acquired;released=$script:Released;held=$script:Held}
   Check ($script:PreviewLoads -eq 1) "$name explicit retry resets positive, negative and failed preview snapshots"
   Check ($(if($Kind -eq 'profile'){$retry.status -eq 'success' -and $retry.result.restorePendingCount -eq 0}else{$retry.status -eq 'completed' -and -not$retry.restorable})) "$name explicit retry finishes after native ownership releases"
   Check ($script:Values[$control] -eq $original -and @($script:Writes|Where-Object {$_.control -eq $control -and $_.value -eq $original}).Count -eq 1 -and $script:Writes.Count -eq $(if($uncertain){2}else{1})) "$name retry restores saved original and does not repeat a restored peer"
   Check ($script:Acquired -eq $script:Released -and -not$script:Held) "$name retry releases all gates"
  }
  $cases.Add([pscustomobject]@{name=$name;retained=$retained;status=$first.result.status})|Out-Null
 }
}
function Invoke-TwoProcessScenario([string]$Kind){
 $name=$Kind+'-second-process';$directory=Join-Path $OutRoot $name;[IO.Directory]::CreateDirectory($directory)|Out-Null
 $probe=$null;$probeId=0;$exited=$false
 try {
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='/bin/sleep';$start.Arguments='600';$start.UseShellExecute=$false
  $probe=[Diagnostics.Process]::Start($start);$probeId=$probe.Id
  Save $directory 'owned-probes' @{processes=@(@{processId=$probe.Id;creationTimeFileTimeUtc=[string]$probe.StartTime.ToUniversalTime().ToFileTimeUtc()})}
  & {
   foreach($path in 'backend/scripts/OperationState.Common.ps1','backend/scripts/GovernorOwnership.Common.ps1','backend/scripts/ProcessProfile.Common.ps1','backend/scripts/GameTuneSession.Common.ps1','backend/scripts/Restore-ProcessProfileBackup.ps1','backend/scripts/Stop-GameTuneSession.ps1'){
    foreach($s in (Read-Ast $path).EndBlock.Statements){if($s -is [System.Management.Automation.Language.FunctionDefinitionAst] -or (($path -like '*Common.ps1' -or $path -like '*Stop-GameTuneSession.ps1') -and $s -is [System.Management.Automation.Language.AssignmentStatementAst])){. ([scriptblock]::Create($s.Extent.Text))}}
   }
   $firstProcess=[Diagnostics.Process]::GetCurrentProcess();$byId=@{};$byId[$firstProcess.Id]=$firstProcess;$byId[$probe.Id]=$probe
   $script:TwoValues=@{};$script:TwoValues[$firstProcess.Id]='AboveNormal';$script:TwoValues[$probe.Id]='High'
   $script:TwoWrites=New-Object System.Collections.Generic.List[object]
   $script:Held=$false;$script:Acquired=0;$script:Released=0;$script:OutsideReads=0
   $dataRoot=Join-Path $directory 'data';$operation=Join-Path $dataRoot 'operations/process-second';[IO.Directory]::CreateDirectory($operation)|Out-Null
   $journalPath=Join-Path $operation 'journal.json'
   [IO.File]::WriteAllText($journalPath,([pscustomobject]@{schemaVersion=1;status='applied';preview=@{identity=@{processId=$probe.Id;creationTimeFileTimeUtc=[string]$probe.StartTime.ToUniversalTime().ToFileTimeUtc();executablePath=$probe.MainModule.FileName}};changes=@(@{name='cpuPriority';status='applied';original='AboveNormal';desired='High';observed='High'})}|ConvertTo-Json -Depth 30),$utf8)
   $snapshots=@(foreach($process in @($firstProcess,$probe)){[pscustomobject]@{processId=$process.Id;processName=if($process.Id -eq $firstProcess.Id){'First'}else{'Second'};originalPriorityClass='Normal';controlChanges=@([pscustomobject]@{control='priorityClass';proposedValue='AboveNormal';outcome='applied'})}})
   $backupFile=Join-Path $directory 'backup.json';$sessionFile=Join-Path $directory 'session.json'
   Save $directory 'backup' @{actionId='performance.gameTune.startSession';dryRun=$false;sessionId='two-session';profileId='two-profile';backupId='two-backup';snapshots=$snapshots}
   Save $directory 'session' @{sessionId='two-session';profileId='two-profile';dryRun=$false;status='completed';sessionStatus='completed';restorable=$true;backupManifestPath=$backupFile;restoredItems=@();changedItems=@();skippedItems=@();completedAtUtc=$null}
   function Get-RooIndustriesLocalDataRoot {return $dataRoot}
   function Test-RooIndustriesGovernorOwnsControl {param($Process,$Control) return $false}
   function Resolve-RooIndustriesPath {param($Path,$DefaultPath) return $Path}
   function Resolve-RooIndustriesGameTuneSessionFile {param($SessionId,$SessionPath,$StateRoot) return $sessionFile}
   function Resolve-RooIndustriesGameTuneStateRoot {param($StateRoot) return $directory}
   function Get-TwoState([int]$Id){return [pscustomobject]@{priorityClass=$script:TwoValues[$Id];process=$byId[$Id]}}
   function Get-TwoCandidate($Entry){$state=Get-TwoState $Entry.processId;return [pscustomobject]@{exists=$true;matches=$true;instanceEnded=$false;process=$state.process;currentPriorityClass=$state.priorityClass;currentControlState=$state;blockedReason=$null;reason=$null}}
   function Get-RestoreCandidate {param($Snapshot) return Get-TwoCandidate $Snapshot}
   function Get-RooIndustriesGameTuneLiveProcessIdentity {param($Entry) return Get-TwoCandidate $Entry}
   function Get-RooIndustriesProcessControlState {param($ProcessId,$Unused,[switch]$ReadGpu) return Get-TwoState $ProcessId}
   function Enter-RooIndustriesGovernorGate {param($Seconds) $script:Held=$true;$script:Acquired++;return [pscustomobject]@{fixtureGate=$true}}
   function Exit-RooIndustriesGovernorGate {param($Gate) if($null -ne $Gate){$script:Held=$false;$script:Released++}}
   function Get-RooIndustriesProcessControlReadback {param($Process,$Control) if(-not$script:Held){$script:OutsideReads++};return $script:TwoValues[$Process.Id]}
   function Invoke-RooIndustriesProcessControlChange {param($Process,$Change) $script:TwoWrites.Add([pscustomobject]@{processId=$Process.Id;value=$Change.proposedValue})|Out-Null;$script:TwoValues[$Process.Id]=$Change.proposedValue;$Change.outcome='applied'}
   function Write-RooIndustriesJsonOutput {param($Value,$OutputPath) return $Value}
   function Invoke-TwoUndo {
    $ConfirmApply=$true;$BackupPath=$backupFile;$SessionPath=$sessionFile;$SessionId='two-session';$StateRoot=$directory;$OutputPath=''
    $path=if($Kind -eq 'profile'){'backend/scripts/Restore-ProcessProfileBackup.ps1'}else{'backend/scripts/Stop-GameTuneSession.ps1'}
    $body=(Read-Ast $path).EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
    return & ([scriptblock]::Create($body.Extent.Text))
   }
   . $ownershipMeter
   $first=Invoke-TwoUndo;Save $directory 'first' $first
   Save $directory 'first-observation' @{proof='Two distinct live Linux processes and real journal/reader/restore bodies; simulated process controls and gate';firstProcessId=$firstProcess.Id;secondProcessId=$probe.Id;values=@($byId.Keys|ForEach-Object {[pscustomobject]@{processId=$_;value=$script:TwoValues[$_]}});writes=@($script:TwoWrites.ToArray());previewLoads=$script:PreviewLoads;freshLoads=$script:FreshLoads;acquired=$script:Acquired;released=$script:Released;outsideCertificationReads=$script:OutsideReads;held=$script:Held}
   Check ($firstProcess.Id -ne $probe.Id -and $script:PreviewLoads -eq 1) "$name loads all claims once before projecting two distinct process identities"
   Check ($(if($Kind -eq 'profile'){$first.result.restorePendingCount -eq 1}else{$first.restorable}) -and $first.result.status -eq 'partial') "$name retains only the second process recovery"
   Check ($script:TwoValues[$firstProcess.Id] -eq 'Normal' -and $script:TwoValues[$probe.Id] -eq 'High' -and $script:TwoWrites.Count -eq 1 -and $script:TwoWrites[0].processId -eq $firstProcess.Id -and @($first.result.leftAsSetItems).Count -eq 0) "$name restores the first process once and never certifies or writes the second owned field"
   [IO.File]::WriteAllText($journalPath,'{"schemaVersion":1,"status":"restored"}',$utf8)
   $script:TwoValues[$probe.Id]='AboveNormal';$script:TwoWrites.Clear();$script:PreviewLoads=0;$script:FreshLoads=0
   $retry=Invoke-TwoUndo;Save $directory 'retry' $retry
   Save $directory 'retry-observation' @{values=@($byId.Keys|ForEach-Object {[pscustomobject]@{processId=$_;value=$script:TwoValues[$_]}});writes=@($script:TwoWrites.ToArray());previewLoads=$script:PreviewLoads;freshLoads=$script:FreshLoads;acquired=$script:Acquired;released=$script:Released;outsideCertificationReads=$script:OutsideReads;held=$script:Held}
   Check ($(if($Kind -eq 'profile'){$retry.status -eq 'success' -and $retry.result.restorePendingCount -eq 0}else{$retry.status -eq 'completed' -and -not$retry.restorable}) -and $script:PreviewLoads -eq 1) "$name explicit retry resets the all-process snapshot and finishes"
   Check ($script:TwoValues[$firstProcess.Id] -eq 'Normal' -and $script:TwoValues[$probe.Id] -eq 'Normal' -and $script:TwoWrites.Count -eq 1 -and $script:TwoWrites[0].processId -eq $probe.Id) "$name retry restores only the second process original"
   Check ($script:FreshLoads -eq 1 -and $script:Acquired -eq $script:Released -and -not$script:Held -and $script:OutsideReads -eq 0) "$name fresh verification for the first original remains inside the released gate"
   $cases.Add([pscustomobject]@{name=$name;retained=$true;status=$first.result.status})|Out-Null
  }
 }finally{
  if($null -ne $probe){try{if(-not$probe.HasExited){$probe.Kill();$probe.WaitForExit()};$exited=$probe.HasExited}finally{$probe.Dispose()}}
  Save $directory 'cleanup' @{ownedProcessId=$probeId;exited=$exited}
 }
}
foreach($kind in 'profile','game'){
 if($Modes.Count -eq 0 -or 'second-process' -in $Modes){Invoke-TwoProcessScenario $kind}
 foreach($mode in 'apply-once','original','arrival-left','arrival-original','writer-arrival','protected-launcher','protected-game','alias','cpuSets','different-pid','different-creation','different-path','different-creation-path','different-pid-path','missing-journal','missing-operations','unrelated-file','unknown-schema','unknown-root','unknown-change','unknown-control','missing-identity','invalid-pid','invalid-creation','relative-path','scalar-changes','null-change','scalar-root','array-root','malformed-json','unreadable-journal','directory-error','enumeration-error','cached-positive-release','cached-error-repair'){if($Modes.Count -eq 0 -or $mode -in $Modes){Invoke-Scenario $kind $mode}}
 if($Modes.Count -eq 0 -or 'table' -in $Modes){foreach($root in 'applying','applied','needsReconciliation','restored','expired'){foreach($change in 'pending','unchanged','applyIntent','applied','restoreIntent','restored','leftAsSet'){Invoke-Scenario $kind 'table' $root $change}}}
}
& {
 foreach($path in 'backend/scripts/OperationState.Common.ps1','backend/scripts/ProcessProfile.Common.ps1','backend/scripts/GameTuneSession.Common.ps1'){
  foreach($s in (Read-Ast $path).EndBlock.Statements){if($s -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $s -is [System.Management.Automation.Language.AssignmentStatementAst]){. ([scriptblock]::Create($s.Extent.Text))}}
 }
 foreach($phase in 'completed','failed'){
  $directory=Join-Path $OutRoot ('legacy-'+$phase);[IO.Directory]::CreateDirectory($directory)|Out-Null
  $sessionFile=Join-Path $directory 'session.json';$backupFile=Join-Path $directory 'backup.json'
  Save $directory 'backup' @{actionId='performance.gameTune.startSession';dryRun=$false;sessionId='legacy-session';profileId='legacy-profile';backupId='legacy-backup';snapshots=@(@{processId=123})}
  Save $directory 'session' @{sessionId='legacy-session';profileId='legacy-profile';dryRun=$false;sessionStatus=$phase;status=$phase;restorable=($phase -eq 'failed');backupManifestPath=$backupFile;changedItems=@(@{processName='LegacyApply';appliedControls=@(@{control='priorityClass';currentValue='Normal';proposedValue='AboveNormal';outcome='applied'})});skippedItems=@(@{processName='LegacyApply';reason='Legacy Undo could not verify the process.'});restoredItems=@();completedAtUtc='2026-10-01T00:00:00Z'}
  function Resolve-RooIndustriesGameTuneSessionFile {param($SessionId,$SessionPath,$StateRoot) return $sessionFile}
  function Resolve-RooIndustriesGameTuneStateRoot {param($StateRoot) return $directory}
  function Write-RooIndustriesJsonOutput {param($Value,$OutputPath) return $Value}
  $SessionPath=$sessionFile;$SessionId='legacy-session';$StateRoot=$directory;$OutputPath=''
  $body=(Read-Ast 'backend/scripts/Get-GameTuneSessionStatus.ps1').EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
  $status=& ([scriptblock]::Create($body.Extent.Text));Save $directory 'status' $status
  Check ($status.status -eq $phase -and $status.restoreAttempted -is [bool] -and -not$status.restoreAttempted -and @($status.restoredItems).Count -eq 0 -and @($status.leftAsSetItems).Count -eq 0) "legacy-$phase real GetStatus preserves the ambiguous explicit-false zero-write phase"
 }
}
Save $OutRoot 'summary' @{proof='Linux dependency simulation, real journal reader/full restore bodies; not native Windows proof';cases=@($cases.ToArray());failures=@($failures.ToArray())}
if($failures.Count){throw ($failures -join '; ')}
"Completed $($cases.Count) saved process operation integration scenarios."
