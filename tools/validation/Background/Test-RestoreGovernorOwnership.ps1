param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false)
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$failures=New-Object System.Collections.Generic.List[string]
$cases=New-Object System.Collections.Generic.List[object]
function Save([string]$Directory,[string]$Name,$Value){[IO.File]::WriteAllText((Join-Path $Directory ($Name+'.json')),($Value|ConvertTo-Json -Depth 40),$utf8)}
function Check([bool]$Condition,[string]$Message){if($Condition){"PASS $Message"}else{$failures.Add($Message)|Out-Null;"FAIL $Message"}}
function Read-Ast([string]$Path){$e=$null;$t=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Source $Path),[ref]$t,[ref]$e);if($e.Count){throw ($e -join '; ')};return $a}
function Invoke-Scenario([string]$Kind,[string]$Mode){
 $name=$Kind+'-'+$Mode;$directory=Join-Path $OutRoot $name;[IO.Directory]::CreateDirectory($directory)|Out-Null
 & {
  foreach($path in 'backend/scripts/OperationState.Common.ps1','backend/scripts/ProcessProfile.Common.ps1','backend/scripts/GameTuneSession.Common.ps1','backend/scripts/Restore-ProcessProfileBackup.ps1','backend/scripts/Stop-GameTuneSession.ps1'){
   foreach($s in (Read-Ast $path).EndBlock.Statements){if($s -is [System.Management.Automation.Language.FunctionDefinitionAst] -or (($path -like '*Common.ps1' -or $path -like '*Stop-GameTuneSession.ps1') -and $s -is [System.Management.Automation.Language.AssignmentStatementAst])){. ([scriptblock]::Create($s.Extent.Text))}}
  }
  $script:RooIndustriesGovernorManaged='Managed by the governor'
  $withPeer=$Mode -notin @('gate-busy','gate-throw','unreadable')
  $snapshots=@([pscustomobject]@{processId=1001;processName='MemoryTarget';originalPriorityClass='Normal';originalMemoryPriority=5;proposedMemoryPriority=2;controlChanges=@([pscustomobject]@{control='memoryPriority';proposedValue=2;outcome='applied'})})
  if($withPeer){$snapshots+=[pscustomobject]@{processId=1002;processName='CpuPeer';originalPriorityClass='Normal';controlChanges=@([pscustomobject]@{control='priorityClass';proposedValue='AboveNormal';outcome='applied'})}}
  $backupFile=Join-Path $directory 'backup.json';$sessionFile=Join-Path $directory 'session.json'
  Save $directory 'backup' ([pscustomobject]@{actionId='performance.gameTune.startSession';dryRun=$false;sessionId='governor-session';profileId='governor-profile';backupId='governor-backup';createdAtUtc='2026-10-01T00:00:00Z';snapshots=$snapshots})
  Save $directory 'session' ([pscustomobject]@{sessionId='governor-session';profileId='governor-profile';sessionPath=$sessionFile;backupManifestPath=$backupFile;dryRun=$false;status='completed';sessionStatus='completed';restorable=$true;restoredItems=@();skippedItems=@();completedAtUtc=$null;changedItems=@([pscustomobject]@{processName='MemoryTarget';appliedControls=@([pscustomobject]@{control='memoryPriority';currentValue=5;proposedValue=2;outcome='applied'})})})
  $script:Owned=$Mode -in @('governed-external','governed-original')
  $script:Memory=if($Mode -in @('governed-original','takeover-original','original')){5}elseif($Mode -like 'writer-*'){2}else{1}
  $script:Peer='AboveNormal';$script:TargetCalls=0;$script:CurrentId=0;$script:Retry=$false;$script:Unreadable=$Mode -eq 'unreadable'
  $script:GateAttempts=0;$script:Acquired=0;$script:Released=0;$script:ExitCalls=0;$script:Held=$false;$script:OutsideReads=0;$script:OwnershipChecks=0;$script:Injected=0
  $script:Writes=New-Object System.Collections.Generic.List[object];$script:Attempts=New-Object System.Collections.Generic.List[object]
  function Resolve-RooIndustriesPath {param($Path,$DefaultPath) return $Path}
  function Resolve-RooIndustriesGameTuneSessionFile {param($SessionId,$SessionPath,$StateRoot) return $sessionFile}
  function Resolve-RooIndustriesGameTuneStateRoot {param($StateRoot) return $directory}
  function Get-FixtureState([int]$Id){return [pscustomobject]@{priorityClass=if($Id -eq 1002){$script:Peer}else{'Normal'};memoryPriority=$script:Memory;memoryPriorityAvailable=$true;process=[Diagnostics.Process]::GetCurrentProcess()}}
  function Get-FixtureCandidate($Entry){
   $script:CurrentId=[int]$Entry.processId
   if($script:CurrentId -eq 1001){$script:TargetCalls++;if($script:TargetCalls -eq 2 -and $Mode -like 'takeover-*' -and -not$script:Retry){$script:Owned=$true;$script:Injected++}}
   $state=Get-FixtureState $script:CurrentId
   return [pscustomobject]@{exists=$true;matches=$true;instanceEnded=$false;process=$state.process;currentPriorityClass=$state.priorityClass;currentMemoryPriority=$state.memoryPriority;currentControlState=$state;blockedReason=$null;reason=$null}
  }
  function Get-RestoreCandidate {param($Snapshot) return Get-FixtureCandidate $Snapshot}
  function Get-RooIndustriesGameTuneLiveProcessIdentity {param($Entry) return Get-FixtureCandidate $Entry}
  function Get-RooIndustriesProcessControlState {param($ProcessId,$Unused,[switch]$ReadGpu) return Get-FixtureState $ProcessId}
  function Test-RooIndustriesGovernorOwnsControl {param($Process,$Control) $script:OwnershipChecks++;return $Control -eq 'memoryPriority' -and $script:Owned}
  function Enter-RooIndustriesGovernorGate {
   param($Seconds)
   $script:GateAttempts++
   if(-not$script:Retry -and $Mode -eq 'gate-throw'){throw 'Simulated governor gate failure'}
   if(-not$script:Retry -and $Mode -eq 'gate-busy'){return $null}
   $script:Acquired++;$script:Held=$true;return [pscustomobject]@{fixtureGate=$script:Acquired}
  }
  function Exit-RooIndustriesGovernorGate {param($Gate) $script:ExitCalls++;if($null -ne $Gate){$script:Released++;$script:Held=$false}}
  function Get-RooIndustriesProcessControlReadback {
   param($Process,$Control)
   if($Control -eq 'memoryPriority'){
    if(-not$script:Held){$script:OutsideReads++}
    if($script:Unreadable){return $null}
    return $script:Memory
   }
   return $script:Peer
  }
  function Invoke-RooIndustriesProcessControlChange {
   param($Process,$Change)
   $script:Attempts.Add([pscustomobject]@{processId=$script:CurrentId;control=$Change.control})|Out-Null
   if($Change.control -eq 'memoryPriority' -and -not$script:Retry -and $Mode -like 'writer-*'){
    $script:Memory=switch($Mode){'writer-original'{5};'writer-owned'{2};default{1}}
    if($Mode -eq 'writer-takeover'){$script:Owned=$true}
    if($Mode -eq 'writer-unreadable'){$script:Unreadable=$true}
    $script:Injected++;throw $script:RooIndustriesChangedExternally
   }
   if($Change.control -eq 'memoryPriority' -and $script:Owned){throw $script:RooIndustriesGovernorManaged}
   $script:Writes.Add([pscustomobject]@{processId=$script:CurrentId;control=$Change.control;value=$Change.proposedValue})|Out-Null
   if($Change.control -eq 'memoryPriority'){$script:Memory=$Change.proposedValue}else{$script:Peer=$Change.proposedValue}
   $Change.outcome='applied'
  }
  function Write-RooIndustriesJsonOutput {param($Value,$OutputPath) return $Value}
  function Invoke-Undo {
   $ConfirmApply=$true;$BackupPath=$backupFile;$SessionPath=$sessionFile;$SessionId='governor-session';$StateRoot=$directory;$OutputPath=''
   $path=if($Kind -eq 'profile'){'backend/scripts/Restore-ProcessProfileBackup.ps1'}else{'backend/scripts/Stop-GameTuneSession.ps1'}
   $body=(Read-Ast $path).EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
   return & ([scriptblock]::Create($body.Extent.Text))
  }
  function Read-Status([string]$Label){
   $SessionPath=$sessionFile;$SessionId='governor-session';$StateRoot=$directory;$OutputPath=''
   $body=(Read-Ast 'backend/scripts/Get-GameTuneSessionStatus.ps1').EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
   $value=& ([scriptblock]::Create($body.Extent.Text));Save $directory $Label $value;return $value
  }
  if($Kind -eq 'game'){
   [IO.File]::Copy($sessionFile,(Join-Path $directory 'session-before.json'),$true)
   $before=Read-Status 'status-before';Check ($before.restoreAttempted -is [bool] -and -not$before.restoreAttempted) "$name real status identifies the pre-Undo phase"
  }
  $first=Invoke-Undo;Save $directory 'first' $first
  Save $directory 'first-observation' @{proof='Simulated ownership, gate and process I/O; real restore, persistence and status bodies';memory=$script:Memory;peer=$script:Peer;writes=@($script:Writes.ToArray());attempts=@($script:Attempts.ToArray());ownershipChecks=$script:OwnershipChecks;injectionReached=$script:Injected;gateAttempts=$script:GateAttempts;acquired=$script:Acquired;released=$script:Released;exitCalls=$script:ExitCalls;outsideMemoryReads=$script:OutsideReads;gateHeld=$script:Held}
  $retained=$Mode -notin @('external','original','writer-external','writer-original')
  $pending=if($Kind -eq 'profile'){$first.result.restorePendingCount -eq 1}else{$first.restorable}
  $finished=if($Kind -eq 'profile'){$first.status -eq 'success' -and $first.result.restorePendingCount -eq 0}else{$first.status -eq 'completed' -and -not$first.restorable}
  Check ($(if($retained){$pending -and $first.result.status -in @('partial','failed')}else{$finished})) "$name recovery follows current governor ownership and read certainty"
  Check (@($script:Writes|Where-Object control -eq 'memoryPriority').Count -eq 0) "$name first Undo writes no memory setting"
  $external=$Mode -in @('external','writer-external')
  Check (@($first.result.leftAsSetItems|Where-Object control -eq 'memoryPriority').Count -eq $(if($external){1}else{0})) "$name certifies only an unowned external memory value"
  if($external){Check ($first.result.leftAsSetItems[0].processName -eq 'MemoryTarget' -and $first.result.leftAsSetItems[0].currentValue -eq 1) "$name names the actual external memory value"}
  if($Mode -like 'governed-*' -or $Mode -like 'takeover-*' -or $Mode -in @('writer-takeover','gate-busy')){Check (@($first.result.skippedItems|Where-Object {$_.processId -eq 1001 -and $_.reason -eq ('memoryPriority: '+$script:RooIndustriesGovernorManaged)}).Count -eq 1) "$name reports the exact managed-control reason"}
  if($Mode -like 'takeover-*' -or $Mode -like 'writer-*'){Check ($script:Injected -eq 1) "$name reached the old and new body injection boundary"}
  if($withPeer){Check ($script:Peer -eq 'Normal' -and @($script:Writes|Where-Object control -eq 'priorityClass').Count -eq 1) "$name independently restores the CPU peer exactly once"}
  Check ($script:Acquired -eq $script:Released -and -not$script:Held -and $script:GateAttempts -eq $script:ExitCalls) "$name releases every acquired gate through finally"
  if($Mode -notlike 'governed-*'){
   Check ($script:GateAttempts -gt 0 -and $script:OutsideReads -eq 0) "$name certifies memory only under the governor gate"
  }
  if($Kind -eq 'game'){
   [IO.File]::Copy($sessionFile,(Join-Path $directory 'session-first.json'),$true)
   $after=Read-Status 'status-first'
   Check ($after.restoreAttempted -is [bool] -and $after.restoreAttempted -and $after.restorable -eq $first.restorable) "$name real status identifies a confirmed Undo attempt"
  }
  if($retained){
   $script:Retry=$true;$script:Owned=$false;$script:Memory=2;$script:Unreadable=$false;$script:TargetCalls=0;$script:Writes.Clear()
   $retry=Invoke-Undo;Save $directory 'retry' $retry
   Save $directory 'retry-observation' @{memory=$script:Memory;peer=$script:Peer;writes=@($script:Writes.ToArray());acquired=$script:Acquired;released=$script:Released;gateHeld=$script:Held}
   Check ($(if($Kind -eq 'profile'){$retry.status -eq 'success' -and $retry.result.restorePendingCount -eq 0}else{$retry.status -eq 'completed' -and -not$retry.restorable})) "$name explicit retry finishes after governor rollback to the recorded target"
   Check ($script:Memory -eq 5 -and $script:Writes.Count -eq 1 -and $script:Writes[0].control -eq 'memoryPriority' -and $script:Writes[0].value -eq 5) "$name retry restores only the saved memory original"
   Check ($script:Acquired -eq $script:Released -and -not$script:Held) "$name retry leaves no gate held"
  }
  $cases.Add([pscustomobject]@{name=$name;status=$first.result.status;retained=$retained})|Out-Null
 }
}
foreach($kind in 'profile','game'){foreach($mode in 'governed-external','governed-original','takeover-left','takeover-original','writer-takeover','writer-external','writer-original','writer-owned','writer-unreadable','external','original','gate-busy','gate-throw','unreadable'){Invoke-Scenario $kind $mode}}
Save $OutRoot 'summary' @{proof='Linux dependency simulation; not native Windows governor proof';cases=@($cases.ToArray());failures=@($failures.ToArray())}
if($failures.Count){throw ($failures -join '; ')}
"Completed $($cases.Count) governor restore integration scenarios."
