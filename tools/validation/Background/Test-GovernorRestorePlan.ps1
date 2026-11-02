param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
# Drives the real watch restore, Restore preview and status hold check with recorded process
# states for every control, including one Windows can't read. No process is opened or changed.
. (Join-Path $Source 'backend/scripts/ProcessGovernor.Common.ps1')
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$failures=New-Object System.Collections.Generic.List[string]
function Case([bool]$passed,[string]$name){[Console]::WriteLine($(if($passed){'PASS '}else{'FAIL '})+$name);if(-not$passed){$failures.Add($name)}}
function Get-ScriptFunction([string]$Script,[string]$Name){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Source $Script),[ref]$tokens,[ref]$errors)
 $found=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name},$true))
 if($errors.Count -or $found.Count -ne 1){throw "$Script must define $Name once."}
 $found[0].Extent.Text
}
. ([scriptblock]::Create((Get-ScriptFunction 'backend/scripts/Stop-ProcessGovernorSession.ps1' 'New-GovernorRestorePreview')))
. ([scriptblock]::Create((Get-ScriptFunction 'backend/scripts/Start-ProcessGovernorSession.ps1' 'New-GovernorRestoredItem')))
. ([scriptblock]::Create((Get-ScriptFunction 'backend/scripts/Start-ProcessGovernorSession.ps1' 'Invoke-GovernorActiveRestore')))
$script:GovernorAlreadyClosed='closed';$script:GovernorKeptItems=New-Object System.Collections.Generic.List[object]

# The recorded process: its state is what Windows would read now; $null means the read failed.
$script:state=$null;$script:failing=@();$script:writes=0
function Test-RooIndustriesSnapshotReleased {$false}
function Get-RooIndustriesProcessGovernorSnapshotIdentity {param($Snapshot)[pscustomobject]@{exists=$true;matches=$true;instanceEnded=$false;process=$null;currentControlState=$script:state}}
function Get-RooIndustriesProcessGovernorLiveIdentity {param($Entry)Get-RooIndustriesProcessGovernorSnapshotIdentity $Entry}
function Get-RooIndustriesProcessControlState {param([int]$ProcessId,$FallbackPriorityClass,$Process,[switch]$ReadGpu)$script:state}
function Invoke-RooIndustriesProcessControlChange {param($Process,$Change)
 if($script:failing -contains $Change.control){$Change.outcome='failed';throw 'Windows refused the write.'}
 $script:state.($Change.control)=$Change.proposedValue;$Change.outcome='applied'
}
function Write-RooIndustriesProcessGovernorJsonFile {param($Value,$Path)$script:writes++}

$values=[ordered]@{
 priorityClass=@('Normal','BelowNormal','AboveNormal')
 affinityMask=@([int64]3,[int64]1,[int64]2)
 ioPriority=@('Normal','Low','VeryLow')
 memoryPriority=@(5,2,3)
 gpuPriority=@('Normal','BelowNormal','AboveNormal')
}
$fields=@{priorityClass='PriorityClass';affinityMask='AffinityMask';ioPriority='IoPriority';memoryPriority='MemoryPriority';gpuPriority='GpuPriority'}
function New-Snapshot{
 $snapshot=[ordered]@{processId=4242;processName='Fixture';processStartTimeUtc='2026-01-01T00:00:00.0000000Z';capturedAtUtc='2026-01-01T00:01:00.0000000Z';sessionId='process-governor-plan'}
 $changes=foreach($control in $values.Keys){$snapshot['original'+$fields[$control]]=$values[$control][0];$snapshot['proposed'+$fields[$control]]=$values[$control][1];[pscustomobject]@{control=$control;proposedValue=$values[$control][1];outcome='applied';blocked=$false}}
 $snapshot.controlChanges=@($changes);[pscustomobject]$snapshot
}
function New-State([string]$Control,$Value,[int]$Others){
 $state=[ordered]@{exists=$true;gpuPriorityAvailable=$true}
 foreach($name in $values.Keys){$state[$name]=if($name -eq $Control){$Value}else{$values[$name][$Others]}}
 if($Control -eq 'gpuPriority' -and $null -eq $Value){$state.gpuPriorityAvailable=$false}
 [pscustomobject]$state
}
function Format-Plan($changes){(@($changes|ForEach-Object {'{0}|{1}|{2}|{3}' -f $_.control,[bool]$_.blocked,$_.blockedReason,$_.proposedValue}) -join ';')}
function Test-Holds($snapshot){Test-RooIndustriesProcessGovernorBackupHolds ([pscustomobject]@{snapshots=@($snapshot)})}

try{
 # Every control in every state: Restore's preview must plan exactly what the shared plan does,
 # and status must count a control Windows can't read as still held.
 foreach($control in $values.Keys){
  foreach($case in @(@{name='original';value=$values[$control][0];holds=$false},@{name='lowered';value=$values[$control][1];holds=$true},@{name='set by another program';value=$values[$control][2];holds=$false},@{name='unreadable';value=$null;holds=$true})){
   $snapshot=New-Snapshot;$script:state=New-State $control $case.value 0
   $plan=@(Get-RooIndustriesGovernorRestoreChanges $snapshot $script:state)
   $preview=New-GovernorRestorePreview $snapshot (Get-RooIndustriesProcessGovernorSnapshotIdentity $snapshot)
   Case ((Format-Plan $plan) -ceq (Format-Plan @($preview.controlChanges))) ("Restore plans the same as the watch and status for $control "+$case.name+': '+(Format-Plan @($preview.controlChanges)))
   $own=@($plan|Where-Object {$_.control -eq $control})
   $expected=switch($case.name){
    'original'{$own.Count -eq 0}
    'lowered'{$own.Count -eq 1 -and -not$own[0].blocked}
    'set by another program'{$own.Count -eq 1 -and (Test-RooIndustriesGovernorChangeLeftAsSet $own[0])}
    'unreadable'{$own.Count -eq 1 -and $own[0].blocked -and -not(Test-RooIndustriesGovernorChangeLeftAsSet $own[0])}
   }
   Case $expected ("The plan for $control "+$case.name+' is right: '+(Format-Plan $own))
   Case ((Test-Holds $snapshot) -eq $case.holds) ("Status counts $control "+$case.name+' as '+$(if($case.holds){'still held'}else{'not held'}))
  }
 }
}catch{
 Case $false ('The plan matrix ran: '+$_.Exception.Message)
}

try{
 # A control the run already put back is no longer its own, even when another program later picks the lowered value.
 $snapshot=New-Snapshot;$script:state=New-State 'ioPriority' 'Low' 0
 Complete-RooIndustriesGovernorRestoredControls $snapshot @([pscustomobject]@{control='ioPriority'})
 Case (@(Get-RooIndustriesGovernorRestoreChanges $snapshot $script:state).Count -eq 0 -and -not(Test-Holds $snapshot)) 'A control already put back drops out of the plan and status when another program sets the lowered value'
 Case (@(New-GovernorRestorePreview $snapshot (Get-RooIndustriesProcessGovernorSnapshotIdentity $snapshot)).controlChanges.Count -eq 0) 'Restore leaves that control alone'
}catch{
 Case $false ('The put-back check ran: '+$_.Exception.Message)
}

try{
 # The watch: CPU priority kept as another program set it, memory priority write fails, so the restore retries.
 $snapshot=New-Snapshot;$script:state=New-State 'priorityClass' 'AboveNormal' 1;$script:failing=@('memoryPriority');$script:writes=0
 $manifest=[pscustomobject]@{snapshots=@($snapshot)};$active=@{};$active['fixture']=[pscustomobject]@{restrainedAtLocal=(Get-Date).AddMinutes(-5);lowCpuSampleCount=5;snapshot=$snapshot}
 $restored=New-Object System.Collections.Generic.List[object];$errors=New-Object System.Collections.Generic.List[object]
 $call=@{Key='fixture';Active=$active['fixture'];Process=[pscustomobject]@{cpuPercent=0};Config=[pscustomobject]@{minimumRestraintSeconds=0;restoreCpuThresholdPercent=3};ActiveRestraints=$active;LastRestoreAt=@{};RestoredItems=$restored;PollRestoredItems=(New-Object System.Collections.Generic.List[object]);Errors=$errors;Reason='calm';Now=(Get-Date)}
 if((Get-Command Invoke-GovernorActiveRestore).Parameters.ContainsKey('BackupManifest')){$call.BackupManifest=$manifest;$call.BackupPath=(Join-Path $OutRoot 'backup.json')}
 foreach($poll in 1..3){$call.PollIndex=$poll;Invoke-GovernorActiveRestore @call|Out-Null}
 Case ($active.ContainsKey('fixture') -and $script:GovernorKeptItems.Count -eq 1) ('Retried watch restores name the kept CPU priority once ('+$script:GovernorKeptItems.Count+' entries)')
 Case ($script:writes -gt 0 -and @($snapshot.controlChanges|Where-Object {$_.control -eq 'ioPriority' -and $_.restoredAtUtc}).Count -eq 1) 'The watch saves each control it put back before the next check'
 $script:state.ioPriority='Low';$script:failing=@();$call.PollIndex=4;Invoke-GovernorActiveRestore @call|Out-Null
 Case (-not$active.ContainsKey('fixture') -and $script:state.memoryPriority -eq 5 -and $script:state.ioPriority -eq 'Low' -and $script:state.priorityClass -eq 'AboveNormal' -and $script:GovernorKeptItems.Count -eq 1) 'The last retry restores the failed control and leaves an I/O priority another program set after the watch put it back'
 Case (-not(Test-Holds $snapshot)) 'Status then sees nothing of that run left to restore'
}catch{
 Case $false ('The watch retry check ran: '+$_.Exception.Message)
}
[IO.File]::WriteAllText((Join-Path $OutRoot 'restore-plan.json'),(@{passed=($failures.Count -eq 0);failures=@($failures)}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
if($failures.Count){throw ('Background limits restore plan checks failed: '+($failures -join '; '))}
