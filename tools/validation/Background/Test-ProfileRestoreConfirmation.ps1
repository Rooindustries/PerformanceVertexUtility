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
Save $OutRoot 'summary' @{proof='Dependency simulation, not a real Windows gate';cases=@($observations.ToArray());failures=@($failures.ToArray())}
if($failures.Count){throw ($failures -join '; ')}
"Completed $($observations.Count) profile confirmation integration scenarios."
