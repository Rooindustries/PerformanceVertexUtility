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
   return [pscustomobject]@{exists=(-not$ended);matches=(-not$ended);instanceEnded=$ended;process=[Diagnostics.Process]::GetCurrentProcess();currentPriorityClass=$script:FixtureValues[$id];currentControlState=[pscustomobject]@{priorityClass=$script:FixtureValues[$id]};blockedReason=if($ended){'This saved instance ended.'}else{$null}}
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
  foreach($path in 'backend/scripts/ProcessProfile.Common.ps1','backend/scripts/GameTuneSession.Common.ps1','backend/scripts/Restore-ProcessProfileBackup.ps1','backend/scripts/Stop-GameTuneSession.ps1'){
   $ast=Read-Ast $path
   foreach($statement in $ast.EndBlock.Statements){
    if($statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -or (($path -like '*Common.ps1' -or $path -like '*Stop-GameTuneSession.ps1') -and $statement -is [System.Management.Automation.Language.AssignmentStatementAst])){. ([scriptblock]::Create($statement.Extent.Text))}
   }
  }
  $snapshot=[pscustomobject]@{processId=1001;processName='ContractFixture';processStartTimeUtc='legacy-start-value';originalPriorityClass='Normal';originalMemoryPriority=5;controlChanges=@([pscustomobject]@{control='priorityClass';proposedValue='AboveNormal';outcome='applied'})}
  $candidate=[pscustomobject]@{exists=($Branch -ne 'ended');matches=($Branch -eq 'normal');instanceEnded=($Branch -eq 'ended');reason='Identity could not be checked.';blockedReason='Identity could not be checked.';currentPriorityClass='AboveNormal';currentAffinityMask=1;currentIoPriority='Normal';currentMemoryPriority=5;currentGpuPriority=$null;currentControlState=[pscustomobject]@{priorityClass='AboveNormal';memoryPriority=5;gpuPriorityAvailable=$false;gpuPriorityStatus=-1073741811}}
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
Save $OutRoot 'summary' @{proof='Dependency simulation, not a real Windows gate';cases=@($observations.ToArray());previewCases=@($previewCases.ToArray());failures=@($failures.ToArray())}
if($failures.Count){throw ($failures -join '; ')}
"Completed $($observations.Count) profile confirmation integration scenarios."
"Completed $($previewCases.Count) restore preview contract branches."
