param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false)
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
function Save([string]$directory,[string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory ($name+'.json')),($value|ConvertTo-Json -Depth 40),$utf8)}
function Read-Ast([string]$Path){
 $errors=$null;$tokens=$null
 $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Source $Path),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($errors -join '; ')}
 return $ast
}
function Test-RooIndustriesGovernorOwnsControl {param($Process,$Control) return $false}
function Enter-RooIndustriesGovernorGate {param($Seconds) return [pscustomobject]@{fixtureGate=$true}}
function Exit-RooIndustriesGovernorGate {param($Gate)}
$common=Read-Ast 'backend/scripts/ProcessProfile.Common.ps1'
$restore=Read-Ast 'backend/scripts/Restore-ProcessProfileBackup.ps1'
$failures=New-Object System.Collections.Generic.List[string]
$observations=New-Object System.Collections.Generic.List[object]
function Check([bool]$Condition,[string]$Message){
 if($Condition){"PASS $Message"}else{$failures.Add($Message)|Out-Null;"FAIL $Message"}
}
function Invoke-Scenario([string]$Mode,[bool]$WithPeer,[bool]$EndDuringRebuild=$false){
 $name=$Mode+'-'+$(if($WithPeer){'peer'}else{'single'})+$(if($EndDuringRebuild){'-ended'}else{''})
 $directory=Join-Path $OutRoot $name;[IO.Directory]::CreateDirectory($directory)|Out-Null
 & {
  foreach($statement in $common.EndBlock.Statements){
   if($statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $statement -is [System.Management.Automation.Language.AssignmentStatementAst]){. ([scriptblock]::Create($statement.Extent.Text))}
  }
  foreach($statement in $restore.EndBlock.Statements){if($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create($statement.Extent.Text))}}
  $snapshots=@([pscustomobject]@{processId=1001;processName='Target';originalPriorityClass='Normal';proposedPriorityClass='AboveNormal';controlChanges=@([pscustomobject]@{control='priorityClass';proposedValue='AboveNormal';outcome='applied'})})
  if($WithPeer){$snapshots+= [pscustomobject]@{processId=1002;processName='Peer';originalPriorityClass='Normal';proposedPriorityClass='AboveNormal';controlChanges=@([pscustomobject]@{control='priorityClass';proposedValue='AboveNormal';outcome='applied'})}}
  $script:FixtureBackup=[pscustomobject]@{backupId='confirmation-fixture';createdAtUtc='2026-10-01T00:00:00Z';snapshots=$snapshots}
  $script:FixtureValues=@{1001='BelowNormal';1002='AboveNormal'}
  $script:FixtureMode=$Mode;$script:FixtureEnded=$EndDuringRebuild
  $script:FixtureWrites=New-Object System.Collections.Generic.List[object]
  $script:FixtureReads=0;$script:FixtureTargetCandidates=0;$script:FixtureCurrentId=0
  function Resolve-RooIndustriesPath {param($Path,$DefaultPath) return $Path}
  function Read-RooIndustriesJsonFile {param($Path) return $script:FixtureBackup}
  function Get-RestoreCandidate {
   param($Snapshot)
   $id=[int]$Snapshot.processId;$script:FixtureCurrentId=$id
   if($id -eq 1001){$script:FixtureTargetCandidates++}
   $ended=$id -eq 1001 -and $script:FixtureEnded -and $script:FixtureTargetCandidates -ge 3
   return [pscustomobject]@{exists=(-not$ended);matches=(-not$ended);instanceEnded=$ended;process=[Diagnostics.Process]::GetCurrentProcess();currentPriorityClass=$script:FixtureValues[$id];currentControlState=[pscustomobject]@{priorityClass=$script:FixtureValues[$id];process=[Diagnostics.Process]::GetCurrentProcess()};blockedReason=if($ended){'This saved instance ended.'}else{$null}}
  }
  function Get-RooIndustriesProcessControlReadback {
   param($Process,$Control)
   $script:FixtureReads++
   switch($script:FixtureMode){'throw'{throw 'Simulated confirmation read failure'};'null'{return $null};'empty'{return ''};default{return $script:FixtureValues[$script:FixtureCurrentId]}}
  }
  function Invoke-RooIndustriesProcessControlChange {
   param($Process,$Change)
   $script:FixtureWrites.Add([pscustomobject]@{processId=$script:FixtureCurrentId;control=$Change.control;value=$Change.proposedValue})|Out-Null
   $script:FixtureValues[$script:FixtureCurrentId]=[string]$Change.proposedValue
   $Change.outcome='applied'
  }
  function Get-RooIndustriesProcessControlState {param($ProcessId,$Unused,[switch]$ReadGpu) return [pscustomobject]@{priorityClass=$script:FixtureValues[[int]$ProcessId]}}
  function Write-RooIndustriesJsonOutput {param($Value,$OutputPath) return $Value}
  function Invoke-RealRestore {
   $ConfirmApply=$true;$BackupPath='confirmation-fixture.json';$OutputPath=''
   $body=$restore.EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
   return & ([scriptblock]::Create($body.Extent.Text))
  }
  $first=Invoke-RealRestore
  Save $directory 'first' $first
  Save $directory 'first-observation' @{proof='Dependency simulation; real production functions and restore main body loaded through AST';writes=@($script:FixtureWrites.ToArray());confirmationReads=$script:FixtureReads;values=@{target=$script:FixtureValues[1001];peer=$script:FixtureValues[1002]}}
  Check ($script:FixtureReads -gt 0) "$name reached the real confirmation read"
  Check (@($script:FixtureWrites|Where-Object processId -eq 1001).Count -eq 0) "$name wrote nothing to the uncertain target"
  Check (@($first.result.leftAsSetItems).Count -eq 0) "$name certified no uncertain kept value"
  Check (@($first.result.skippedItems|Where-Object {$_.processId -eq 1001 -and $_.category -eq 'restore-failed' -and $_.reason -eq ('priorityClass: '+$script:RooIndustriesLeftAsSetChangedBack)}).Count -eq 1) "$name retained the exact failed-confirmation reason"
  if($EndDuringRebuild){
   Check ($first.status -eq 'success' -and $first.result.restorePendingCount -eq 0 -and @($first.result.alreadyClosedItems).Count -eq 1) "$name recognized the ended instance before retaining execution failures"
  }else{
   $expected=if($WithPeer){'partial'}else{'failed'}
   Check ($first.status -eq $expected -and $first.result.status -eq $expected -and $first.result.restorePendingCount -eq 1 -and @($first.result.pendingItems|Where-Object processId -eq 1001).Count -eq 1) "$name retained one pending recovery despite the later external bulk read"
   if($WithPeer){Check ($script:FixtureValues[1002] -eq 'Normal' -and @($script:FixtureWrites|Where-Object processId -eq 1002).Count -eq 1 -and @($first.result.changedItems|Where-Object processId -eq 1002).Count -eq 1) "$name restored the independent owned peer"}
   $afterFirst=$script:FixtureValues.Clone()
   foreach($retryValue in 'BelowNormal','AboveNormal'){
    $script:FixtureValues=$afterFirst.Clone();$script:FixtureValues[1001]=$retryValue
    $script:FixtureMode='readable';$script:FixtureWrites.Clear();$script:FixtureReads=0
    $retry=Invoke-RealRestore
    Save $directory ('retry-'+$retryValue) $retry
    Save $directory ('retry-'+$retryValue+'-observation') @{writes=@($script:FixtureWrites.ToArray());confirmationReads=$script:FixtureReads;values=@{target=$script:FixtureValues[1001];peer=$script:FixtureValues[1002]}}
    Check ($retry.status -eq 'success' -and $retry.result.restorePendingCount -eq 0) "$name explicit $retryValue retry completed with a fresh failure list"
    if($retryValue -eq 'BelowNormal'){
     Check ($script:FixtureWrites.Count -eq 0 -and $script:FixtureValues[1001] -eq 'BelowNormal' -and @($retry.result.leftAsSetItems|Where-Object {$_.processId -eq 1001 -and $_.currentValue -eq 'BelowNormal'}).Count -eq 1) "$name readable external retry was named without a write"
    }else{
     Check ($script:FixtureValues[1001] -eq 'Normal' -and @($script:FixtureWrites|Where-Object {$_.processId -eq 1001 -and $_.value -eq 'Normal'}).Count -eq 1) "$name applied-value retry restored Normal"
    }
   }
  }
  $observations.Add([pscustomobject]@{scenario=$name;status=$first.status;pending=$first.result.restorePendingCount})|Out-Null
 }
}
foreach($mode in 'throw','null','empty'){Invoke-Scenario $mode $false;Invoke-Scenario $mode $true}
Invoke-Scenario 'throw' $false $true
$previewCases=New-Object System.Collections.Generic.List[object]
$previewSchema=Join-Path $OutRoot 'action-preview.schema.json'
$schema=Get-Content -LiteralPath (Join-Path $Source 'backend/contracts/roo-industries-backend-contracts.schema.json') -Raw|ConvertFrom-Json
[IO.File]::WriteAllText($previewSchema,(@{'$schema'=$schema.'$schema';'$defs'=$schema.'$defs';'$ref'='#/$defs/actionPreview'}|ConvertTo-Json -Depth 100),$utf8)
function Invoke-PreviewBranch([string]$Kind,[string]$Branch){
 & {
  foreach($path in 'backend/scripts/OperationState.Common.ps1','backend/scripts/ProcessProfile.Common.ps1','backend/scripts/GameTuneSession.Common.ps1','backend/scripts/Restore-ProcessProfileBackup.ps1','backend/scripts/Stop-GameTuneSession.ps1'){
   $ast=Read-Ast $path
   foreach($statement in $ast.EndBlock.Statements){
    if($statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -or (($path -like '*Common.ps1' -or $path -like '*Stop-GameTuneSession.ps1') -and $statement -is [System.Management.Automation.Language.AssignmentStatementAst])){. ([scriptblock]::Create($statement.Extent.Text))}
   }
  }
  $snapshot=[pscustomobject]@{processId=1001;processName='ContractFixture';processStartTimeUtc='legacy-start-value';originalPriorityClass='Normal';originalMemoryPriority=5;controlChanges=@([pscustomobject]@{control='priorityClass';proposedValue='AboveNormal';outcome='applied'})}
  $candidate=[pscustomobject]@{exists=($Branch -ne 'ended');matches=($Branch -eq 'normal');instanceEnded=($Branch -eq 'ended');reason='Identity could not be checked.';blockedReason='Identity could not be checked.';currentPriorityClass='AboveNormal';currentAffinityMask=1;currentIoPriority='Normal';currentMemoryPriority=5;currentGpuPriority=$null;currentControlState=[pscustomobject]@{priorityClass='AboveNormal';memoryPriority=5;gpuPriorityAvailable=$false;gpuPriorityStatus=-1073741811;process=[Diagnostics.Process]::GetCurrentProcess()}}
  $preview=if($Kind -eq 'profile'){New-RollbackPreviewEntry $snapshot $candidate}else{New-GameTuneRestorePreview $snapshot $candidate}
  $name=$Kind+'-preview-'+$Branch
  Save $OutRoot $name $preview
  $expected=if($Kind -eq 'profile'){if($Branch -eq 'normal'){'ROLLBACK_PROCESS_CONTROLS_RESTORE'}else{'ROLLBACK_SKIPPED'}}elseif($Branch -eq 'normal'){'GAME_TUNE_PROCESS_CONTROLS_RESTORE'}elseif($Branch -eq 'ended'){'GAME_TUNE_ALREADY_CLOSED'}else{'GAME_TUNE_RESTORE_SKIPPED'}
  Check ($preview.reasonCodes -is [array] -and $preview.reasonCodes.Count -eq 1 -and $preview.reasonCodes[0] -eq $expected) "$name emits one array reason code $expected"
  $issues=@();$valid=Test-Json -LiteralPath (Join-Path $OutRoot ($name+'.json')) -SchemaFile $previewSchema -ErrorAction SilentlyContinue -ErrorVariable issues
  $details=New-Object System.Collections.Generic.List[string]
  foreach($issue in $issues){$details.Add($issue.ToString())|Out-Null}
  if(-not$valid){
   $validator=[Json.Schema.JsonSchema]::FromFile($previewSchema);$options=[Json.Schema.EvaluationOptions]::new();$options.OutputFormat=[Json.Schema.OutputFormat]::List
   $node=[System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText((Join-Path $OutRoot ($name+'.json'))))
   foreach($detail in $validator.Evaluate($node,$options).Details){if(-not$detail.IsValid -and $detail.Errors){$details.Add($detail.InstanceLocation.ToString()+': '+($detail.Errors|ConvertTo-Json -Compress))|Out-Null}}
  }
  [IO.File]::WriteAllText((Join-Path $OutRoot ($name+'.errors.log')),($details -join [Environment]::NewLine),$utf8)
  Check $valid "$name raw preview matches the strict actionPreview contract"
  if($Kind -eq 'game'){
   $gameAst=Read-Ast 'backend/scripts/Stop-GameTuneSession.ps1'
   $script:ContractGameBackup=[pscustomobject]@{actionId='performance.gameTune.startSession';dryRun=$false;sessionId='contract-session';profileId='contract-profile';backupId='contract-backup';createdAtUtc='2026-10-01T00:00:00Z';snapshots=@($snapshot)}
   function Resolve-RooIndustriesPath {param($Path,$DefaultPath) return $Path}
   function Read-RooIndustriesJsonFile {param($Path) return $script:ContractGameBackup}
   function Resolve-RooIndustriesGameTuneSessionFile {param($SessionId,$SessionPath,$StateRoot) return ''}
   function Get-RooIndustriesGameTuneLiveProcessIdentity {param($Entry) return $candidate}
   function Invoke-RooIndustriesProcessControlChange {throw 'Contract preview must not write process controls.'}
   function Write-RooIndustriesGameTuneJsonFile {throw 'Contract preview must not write session state.'}
   function Write-RooIndustriesJsonOutput {param($Value,$OutputPath) return $Value}
   $SessionId='';$SessionPath='';$BackupPath='contract-game-backup.json';$StateRoot='';$OutputPath='';$ConfirmApply=$false
   $body=$gameAst.EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
   $envelope=& ([scriptblock]::Create($body.Extent.Text))
   Save $OutRoot ($name+'-envelope') $envelope
   Check ($envelope.actionId -eq 'performance.gameTune.stopSession' -and $envelope.status -eq 'preview' -and @($envelope.preview).Count -eq 1) "$name runs the real Game Tune restore body without writes"
  }
  $previewCases.Add([pscustomobject]@{name=$name;schemaValid=$valid;expectedCode=$expected})|Out-Null
 }
}
foreach($branch in 'normal','blocked'){Invoke-PreviewBranch 'profile' $branch}
foreach($branch in 'normal','blocked','ended'){Invoke-PreviewBranch 'game' $branch}
$decisionCases=New-Object System.Collections.Generic.List[object]
function Invoke-DecisionScenario([string]$Kind,[string]$Outcome,[string]$Bulk,[string]$Fresh=$Bulk,[switch]$Gpu,[switch]$Legacy,[switch]$Ended){
 $name=$Kind+'-'+$Outcome+'-'+$Bulk+'-'+$Fresh+$(if($Gpu){'-gpu'}else{''})+$(if($Legacy){'-legacy'}else{''})+$(if($Ended){'-ended'}else{''})
 $directory=Join-Path $OutRoot $name;[IO.Directory]::CreateDirectory($directory)|Out-Null
 & {
  foreach($path in 'backend/scripts/OperationState.Common.ps1','backend/scripts/ProcessProfile.Common.ps1','backend/scripts/GameTuneSession.Common.ps1','backend/scripts/Restore-ProcessProfileBackup.ps1','backend/scripts/Stop-GameTuneSession.ps1'){
   $ast=Read-Ast $path
   foreach($statement in $ast.EndBlock.Statements){if($statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -or (($path -like '*Common.ps1' -or $path -like '*Stop-GameTuneSession.ps1') -and $statement -is [System.Management.Automation.Language.AssignmentStatementAst])){. ([scriptblock]::Create($statement.Extent.Text))}}
  }
  $snapshot=[pscustomobject]@{processId=1001;processName='Target';originalPriorityClass='Normal';proposedPriorityClass='AboveNormal'}
  if(-not$Legacy){$snapshot|Add-Member -NotePropertyName controlChanges -NotePropertyValue @([pscustomobject]@{control='priorityClass';proposedValue='AboveNormal';outcome=$Outcome})}
  if($Gpu){$snapshot|Add-Member -NotePropertyName originalGpuPriority -NotePropertyValue 'Normal';$snapshot.controlChanges+= [pscustomobject]@{control='gpuPriority';proposedValue='High';outcome=$Outcome}}
  $backupFile=Join-Path $directory 'backup.json';$sessionFile=Join-Path $directory 'session.json'
  Save $directory 'backup' ([pscustomobject]@{actionId='performance.gameTune.startSession';dryRun=$false;sessionId='decision-session';profileId='decision-profile';backupId='decision-backup';createdAtUtc='2026-10-01T00:00:00Z';snapshots=@($snapshot)})
  Save $directory 'session' ([pscustomobject]@{sessionId='decision-session';profileId='decision-profile';sessionPath=$sessionFile;backupManifestPath=$backupFile;dryRun=$false;sessionStatus='completed';status='completed';restorable=$true;restoredItems=@();skippedItems=@();completedAtUtc=$null;changedItems=@([pscustomobject]@{processName='OldApply';appliedControls=@([pscustomobject]@{control='priorityClass';currentValue='Normal';proposedValue='AboveNormal';outcome='applied'})})})
  $script:DecisionBulk=$Bulk;$script:DecisionFresh=$Fresh;$script:DecisionPriority=$Bulk;$script:DecisionGpu='High';$script:DecisionGpuAvailable=(-not$Gpu);$script:DecisionCalls=0;$script:DecisionInjected=0;$script:DecisionReads=0
  $script:DecisionWrites=New-Object System.Collections.Generic.List[object]
  function Resolve-RooIndustriesPath {param($Path,$DefaultPath) return $Path}
  function Resolve-RooIndustriesGameTuneSessionFile {param($SessionId,$SessionPath,$StateRoot) return $sessionFile}
  function Resolve-RooIndustriesGameTuneStateRoot {param($StateRoot) return $directory}
  function Get-DecisionState {
   $priority=if($script:DecisionPriority -in @('null','throw','empty')){$null}else{$script:DecisionPriority}
   return [pscustomobject]@{priorityClass=$priority;gpuPriority=if($script:DecisionGpuAvailable){$script:DecisionGpu}else{$null};gpuPriorityAvailable=$script:DecisionGpuAvailable;gpuPriorityStatus=if($script:DecisionGpuAvailable){0}else{-1073741811};process=[Diagnostics.Process]::GetCurrentProcess()}
  }
  function Get-DecisionCandidate {
   $script:DecisionCalls++
   if($script:DecisionCalls -eq 2){$script:DecisionPriority=$script:DecisionFresh;$script:DecisionInjected++}
   $state=Get-DecisionState
   return [pscustomobject]@{exists=(-not$Ended);matches=(-not$Ended);instanceEnded=[bool]$Ended;process=[Diagnostics.Process]::GetCurrentProcess();currentPriorityClass=$state.priorityClass;currentGpuPriority=$state.gpuPriority;currentControlState=$state;reason='This saved instance ended.';blockedReason='This saved instance ended.'}
  }
  function Get-RestoreCandidate {param($Snapshot) return Get-DecisionCandidate}
  function Get-RooIndustriesGameTuneLiveProcessIdentity {param($Entry) return Get-DecisionCandidate}
  function Get-RooIndustriesProcessControlState {param($ProcessId,$Unused,[switch]$ReadGpu) return Get-DecisionState}
  function Get-RooIndustriesProcessControlReadback {
   param($Process,$Control)
   $script:DecisionReads++
   if($Control -eq 'gpuPriority'){if(-not$script:DecisionGpuAvailable){throw 'Unavailable GPU must never be read at execution'};return $script:DecisionGpu}
   if($script:DecisionPriority -eq 'throw'){throw 'Simulated fresh read failure'}
   if($script:DecisionPriority -eq 'null'){return $null}
   if($script:DecisionPriority -eq 'empty'){return ' '}
   return $script:DecisionPriority
  }
  function Invoke-RooIndustriesProcessControlChange {
   param($Process,$Change)
   $script:DecisionWrites.Add([pscustomobject]@{control=$Change.control;value=$Change.proposedValue})|Out-Null
   if($Change.control -eq 'gpuPriority'){$script:DecisionGpu=$Change.proposedValue}else{$script:DecisionPriority=$Change.proposedValue}
   $Change.outcome='applied'
  }
  function Write-RooIndustriesJsonOutput {param($Value,$OutputPath) return $Value}
  function Invoke-DecisionUndo {
   $ConfirmApply=$true;$BackupPath=$backupFile;$SessionPath=$sessionFile;$SessionId='decision-session';$StateRoot=$directory;$OutputPath=''
   $path=if($Kind -eq 'profile'){'backend/scripts/Restore-ProcessProfileBackup.ps1'}else{'backend/scripts/Stop-GameTuneSession.ps1'}
   $body=(Read-Ast $path).EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
   return & ([scriptblock]::Create($body.Extent.Text))
  }
  function Save-DecisionStatus([string]$Label){
   $SessionPath=$sessionFile;$SessionId='decision-session';$StateRoot=$directory;$OutputPath=''
   $body=(Read-Ast 'backend/scripts/Get-GameTuneSessionStatus.ps1').EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
   $status=& ([scriptblock]::Create($body.Extent.Text));Save $directory $Label $status
   return $status
  }
  if($Kind -eq 'game'){
   [IO.File]::Copy($sessionFile,(Join-Path $directory 'session-before.json'),$true)
   $beforeStatus=Save-DecisionStatus 'status-before'
   Check ($beforeStatus.restoreAttempted -is [bool] -and -not$beforeStatus.restoreAttempted) "$name status reports no confirmed Undo before restoration"
   if($Legacy -and $Bulk -eq 'Normal'){Save $directory 'status-legacy' $beforeStatus;Check ($beforeStatus.leftAsSetItems -is [array] -and $beforeStatus.leftAsSetItems.Count -eq 0) "$name legacy persisted session defaults to an empty kept array"}
  }
  $first=Invoke-DecisionUndo
  Save $directory 'first' $first
  if($Kind -eq 'game'){[IO.File]::Copy($sessionFile,(Join-Path $directory 'session-first.json'),$true)}
  Save $directory 'first-observation' @{proof='Simulated process I/O; real restore bodies, JSON persistence and status body';identityCalls=$script:DecisionCalls;injectionReached=$script:DecisionInjected;freshReads=$script:DecisionReads;priority=$script:DecisionPriority;gpu=$script:DecisionGpu;writes=@($script:DecisionWrites.ToArray())}
  $uncertain=$Gpu -or $Bulk -in @('null','throw') -or ($Bulk -eq 'Normal' -and $Fresh -in @('AboveNormal','null','throw','empty'))
  $pending=if($Kind -eq 'profile'){$first.result.restorePendingCount -eq 1}else{$first.restorable}
  $finished=if($Kind -eq 'profile'){$first.status -eq 'success' -and $first.result.restorePendingCount -eq 0}else{$first.status -eq 'completed' -and -not$first.restorable}
  if($Ended){
   $closed=if($Kind -eq 'profile'){@($first.result.alreadyClosedItems)}else{@($first.result.skippedItems|Where-Object outcome -eq 'alreadyClosed')}
   Check ($finished -and $closed.Count -eq 1 -and $script:DecisionWrites.Count -eq 0) "$name ended instance closes without writes"
  }
  else{
   Check ($script:DecisionInjected -gt 0) "$name reached the shared post-preview identity boundary"
   Check ($(if($uncertain){$pending -and $first.result.status -in @('failed','partial') -and @($first.result.skippedItems).Count -gt 0}else{$finished})) "$name recovery matches fresh ownership evidence"
   $external=$Fresh -eq 'BelowNormal' -and $Bulk -notin @('null','throw')
   Check (@($first.result.leftAsSetItems).Count -eq $(if($external){1}else{0})) "$name certifies only a readable external value"
   if($external){Check ($first.result.leftAsSetItems[0].processName -eq 'Target' -and $first.result.leftAsSetItems[0].currentValue -eq 'BelowNormal') "$name names the actual external target/value"}
   $expectedWrites=if($Bulk -eq 'AboveNormal'){1}else{0}
   Check (@($script:DecisionWrites|Where-Object control -eq 'priorityClass').Count -eq $expectedWrites) "$name writes CPU only when owned and readable"
   if($expectedWrites){Check ($script:DecisionPriority -eq 'Normal') "$name restores the saved CPU original"}
   if($Bulk -eq 'Normal'){Check ($script:DecisionReads -gt 0) "$name freshly verifies an original-value preview"}
   if($Gpu){Check (@($script:DecisionWrites|Where-Object control -eq 'gpuPriority').Count -eq 0 -and $first.result.status -eq 'partial' -and -not$first.preview[0].blocked) "$name unavailable GPU retains only its control while CPU restores"}
  }
  if($Kind -eq 'game'){
   [IO.File]::Delete((Join-Path $directory 'events.jsonl'))
   $status=Save-DecisionStatus 'status-first'
   Check ($status.restoreAttempted -is [bool] -and $status.restoreAttempted) "$name status records the confirmed Undo phase"
   Check ($status.restorable -eq $first.restorable -and ($status.leftAsSetItems|ConvertTo-Json -Depth 20 -Compress) -eq ($first.leftAsSetItems|ConvertTo-Json -Depth 20 -Compress)) "$name persisted status preserves exact kept evidence and recovery"
  }
  if($uncertain -and -not$Ended){
   $script:DecisionWrites.Clear();$script:DecisionCalls=0;$script:DecisionReads=0
   $script:DecisionPriority=if($Gpu){'Normal'}else{'AboveNormal'};$script:DecisionFresh=$script:DecisionPriority;$script:DecisionGpuAvailable=$true
   $retry=Invoke-DecisionUndo;Save $directory 'retry' $retry
   Save $directory 'retry-observation' @{priority=$script:DecisionPriority;gpu=$script:DecisionGpu;writes=@($script:DecisionWrites.ToArray())}
   Check ($(if($Kind -eq 'profile'){$retry.status -eq 'success' -and $retry.result.restorePendingCount -eq 0}else{-not$retry.restorable -and $retry.status -eq 'completed'})) "$name explicit readable retry finishes recovery"
   Check ($script:DecisionWrites.Count -eq 1 -and $script:DecisionWrites[0].control -eq $(if($Gpu){'gpuPriority'}else{'priorityClass'}) -and $script:DecisionWrites[0].value -eq 'Normal') "$name retry writes exactly the unresolved field"
  }
  $decisionCases.Add([pscustomobject]@{name=$name;status=$first.result.status;uncertain=$uncertain;injectionReached=$script:DecisionInjected})|Out-Null
 }
}
foreach($kind in 'profile','game'){
 foreach($outcome in 'pending','failed'){
  foreach($bulk in 'AboveNormal','BelowNormal','Normal','null','throw'){Invoke-DecisionScenario $kind $outcome $bulk}
 }
 foreach($outcome in 'applied','pending','failed'){
  foreach($fresh in 'AboveNormal','BelowNormal','null','throw','empty'){Invoke-DecisionScenario $kind $outcome 'Normal' $fresh}
 }
 Invoke-DecisionScenario $kind 'applied' 'AboveNormal' -Gpu
 Invoke-DecisionScenario $kind 'legacy' 'BelowNormal' -Legacy
 Invoke-DecisionScenario $kind 'legacy' 'Normal' 'AboveNormal' -Legacy
 Invoke-DecisionScenario $kind 'applied' 'AboveNormal' -Ended
}
Save $OutRoot 'summary' @{proof='Dependency simulation, not a real Windows gate';cases=@($observations.ToArray());previewCases=@($previewCases.ToArray());decisionCases=@($decisionCases.ToArray());failures=@($failures.ToArray())}
if($failures.Count){throw ($failures -join '; ')}
"Completed $($observations.Count) profile confirmation integration scenarios."
"Completed $($previewCases.Count) restore preview contract branches."
"Completed $($decisionCases.Count) shared restore-decision scenarios."
