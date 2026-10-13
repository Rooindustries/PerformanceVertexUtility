param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'trace-ownership' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot 'trace-ownership'
$main=$script:Harness;$rows=[Collections.Generic.List[object]]::new();$status='fail';$foreign=$null
function Wait-Trace([scriptblock]$Action,[string]$Name){$until=[DateTime]::UtcNow.AddSeconds(20);do{$value=& $Action;if($value){return $value};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $until);throw ('Trace fixture timed out: '+$Name)}
function Trigger($Root,[string]$Gate){
 $ready=Wait-Trace {try{[Threading.EventWaitHandle]::OpenExisting($Gate)}catch [Threading.WaitHandleCannotBeOpenedException]{$null}} 'root ready event'
 $locked=$null
 try{
  $until=[DateTime]::UtcNow.AddSeconds(5)
  while(-not$locked){try{$locked=[IO.FileStream]::new((Get-HarnessLongPath $script:Harness.LedgerPath),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}catch [IO.IOException]{if(($_.Exception.HResult -band 0xffff) -notin 32,33 -or [DateTime]::UtcNow -ge $until){throw};Start-Sleep -Milliseconds 50}}
  $ready.Set()|Out-Null;Start-Sleep -Milliseconds 800
 }
 finally{if($locked){$locked.Dispose()};$ready.Dispose()}
 if(-not$Root.process.WaitForExit(10000)){throw 'Fixture root did not exit'}
}
function ChildPid([string]$Image){
 Wait-Trace {$matches=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -IEQ $Image);if($matches.Count -gt 1){throw 'Fixture child is ambiguous'};if($matches.Count){[int]$matches[0].ProcessId}} 'unique child'
}
function TraceEntry([int]$ProcessId){
 Wait-Trace {Receive-ProcessTrace;$events=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'trace' -and $_.nonce -ceq $script:Harness.Nonce -and $_.identity.processId -eq $ProcessId});if($events.Count -gt 1){throw 'Fixture trace event is ambiguous'};if($events.Count){$events[0]}} 'process-start event'
}
try{
 $launcher=Join-Path $directory 'RooTraceParent.exe'
 New-HarnessConsoleAssembly -Path $launcher -Code @'
using System;
using System.Diagnostics;
using System.Threading;
public static class RooTraceParent {
 public static void Main(string[] args) {
  if(args[0]=="child"){Thread.Sleep(120000);return;}
  if(args[0]=="middle"){Process.Start(new ProcessStartInfo(args[1],"child"){UseShellExecute=false,CreateNoWindow=true});Thread.Sleep(25);return;}
  using(var ready=new EventWaitHandle(false,EventResetMode.ManualReset,args[2]))ready.WaitOne();
  var middle=Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName,"middle \""+args[1]+"\""){UseShellExecute=false,CreateNoWindow=true});middle.WaitForExit();
 }
}
'@
 Register-HarnessFile $launcher 'trace-fixture'|Out-Null
 $image=Join-Path $directory 'RooTraceSharedChild.exe';Copy-HarnessFile $launcher $image|Out-Null
 $gate='Local\RooTrace-'+$nonce+'-owned'
 $root=Start-OwnedProcess -FilePath $launcher -ArgumentList ('root "'+$image+'" "'+$gate+'"') -Purpose trace-fixture
 Trigger $root $gate;$childId=ChildPid $image;$event=TraceEntry $childId
 $child=Wait-Trace {Test-TracedDescendant $childId -PassThru -Ancestor $root} 'trace adoption after parent exit'
 if($child.OwnershipProof.kind -cne 'trace' -or $child.OwnershipProof.eventIds.Count -lt 2 -or -not$root.process.HasExited){throw 'Dead-parent case did not use the recorded trace chain'}
 $rows.Add(@{check='i 25 ms parent during 800 ms ledger lock';status='pass';observed=@{proof=$child.OwnershipProof;root=$root.Identity;child=$child.Identity;rootExited=$root.process.HasExited;middleLifetimeMs=25;ledgerLockedMs=800}})
 Stop-HarnessProcess $child

 $foreignRoot='C:\RooBuild\roo-industries-trace-foreign-'+[Guid]::NewGuid().ToString('N')
 $foreignFolder=New-HarnessDirectory $foreignRoot 'foreign-trace-fixture'
 $foreignId=$foreignRoot.Substring($foreignRoot.Length-32);$foreignNonce=[Guid]::NewGuid().ToString('N');$foreignManifest='0'*64
 $ledger=@{protocol='roo-harness-ledger/v1';machine=$env:COMPUTERNAME;frameId=$foreignId;manifestSha256=$foreignManifest;entries=@();invocations=@(@{nonce=$foreignNonce;scenario='foreign-trace-fixture';startedAtUtc=[DateTime]::UtcNow.ToString('o');status='running';cleanupErrors=@()})}
 $stream=[IO.FileStream]::new((Get-HarnessLongPath (Join-Path $foreignRoot 'ledger.json')),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($ledger|ConvertTo-Json -Depth 20));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 Open-HarnessRun $foreignRoot $foreignId $foreignManifest $foreignNonce
 $foreign=$script:Harness;Start-ProcessTrace|Out-Null
 $foreignLauncher=Join-Path $foreignRoot 'RooTraceParent.exe';Copy-HarnessFile $launcher $foreignLauncher|Out-Null
 $gate='Local\RooTrace-'+$nonce+'-foreign'
 $foreignParent=Start-HarnessExplorerProcess $foreignLauncher ('root "'+$image+'" "'+$gate+'"') 'foreign-trace-parent'
 $script:Harness=$main;Trigger $foreignParent $gate;$childId=ChildPid $image;$event=TraceEntry $childId
 if(Test-TracedDescendant $childId){throw 'Same-image child of a non-owned parent was adopted'}
 if(@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.identity.pid -eq $childId -and $_.state -eq 'active'}).Count){throw 'Refusal wrote a process ownership entry'}
 $rows.Add(@{check='ii same image from non-owned parent';status='pass';observed=@{image=$image;parent=$foreignParent.Identity;childPid=$childId;event=$event.identity;adopted=$false}})
 $script:Harness=$foreign;$foreignChild=Wait-Trace {Test-TracedDescendant $childId -PassThru -Ancestor $foreignParent} 'foreign owner cleanup proof';Stop-HarnessProcess $foreignChild
 Complete-HarnessInvocation 'pass' -Cleanup|Out-Null;$script:Harness=$main
 Remove-HarnessEntry $foreignFolder;$foreign=$null

 $gate='Local\RooTrace-'+$nonce+'-reuse'
 $root=Start-OwnedProcess -FilePath $launcher -ArgumentList ('root "'+$image+'" "'+$gate+'"') -Purpose trace-fixture
 Trigger $root $gate;$childId=ChildPid $image;$event=TraceEntry $childId
 $p=Get-Process -Id $childId;try{$native=[RooValidationOwnership.Native]::Created($p.Handle)}finally{$p.Dispose()}
 $original=$event.identity.timeCreatedFileTimeUtc;$wrong=($native+150000000).ToString()
 Start-Sleep -Seconds 16
 Invoke-HarnessLedger {param($l) (@($l.entries|Where-Object id -CEQ $event.id)[0]).identity.timeCreatedFileTimeUtc=$wrong}|Out-Null
 try{
  if(Test-TracedDescendant $childId){throw 'Native/event creation mismatch was accepted'}
  $inside=[long]$wrong -ge $main.Trace.Start.ToFileTimeUtc() -and [long]$wrong -le [DateTime]::UtcNow.ToFileTimeUtc()
  if(-not$inside){throw 'Reuse fixture accidentally tested an out-of-window event'}
  $rows.Add(@{check='iii simulated PID reuse native/event mismatch';status='pass';observed=@{childPid=$childId;nativeBirth=$native.ToString();eventTime=$wrong;differenceSeconds=15;insideInvocationWindow=$inside;adopted=$false}})
 }finally{Invoke-HarnessLedger {param($l) (@($l.entries|Where-Object id -CEQ $event.id)[0]).identity.timeCreatedFileTimeUtc=$original}|Out-Null}
 $rootEvent=TraceEntry ([int]$root.Identity.pid);$rootName=$rootEvent.identity.processName
 Invoke-HarnessLedger {param($l) (@($l.entries|Where-Object id -CEQ $rootEvent.id)[0]).identity.processName='RooTraceForeignParent.exe'}|Out-Null
 try{
  if(Test-TracedDescendant $childId -Ancestor $root){throw 'A different root start identity was accepted'}
  $rows[$rows.Count-1].observed.rootEventMismatchRefused=$true
 }finally{Invoke-HarnessLedger {param($l) (@($l.entries|Where-Object id -CEQ $rootEvent.id)[0]).identity.processName=$rootName}|Out-Null}
 $child=Wait-Trace {Test-TracedDescendant $childId -PassThru -Ancestor $root} 'cleanup after correct event restored';Stop-HarnessProcess $child
 $birth=[DateTime]::UtcNow.ToFileTimeUtc()
 $synthetic=@(@{identity=@{processId=123;timeCreatedFileTimeUtc=($birth+1000000).ToString()}},@{identity=@{processId=123;timeCreatedFileTimeUtc=($birth+2000000).ToString()}})
 $match=Get-HarnessBirthMatch $synthetic 123 $birth
 if($match.unique -or $match.matches.Count -ne 2){throw 'Ambiguous synthetic birth events were accepted'}
 $rows.Add(@{check='CR9 two same-PID start events in birth window refuse';status='pass';observed=@{standIn=$true;pid=123;events=2;refused=$true}})
 $status='pass'
}finally{
 if($foreign){$script:Harness=$foreign;try{Complete-HarnessInvocation 'fail' -Cleanup|Out-Null}finally{$script:Harness=$main}}
 $status=Complete-HarnessInvocation $status -Cleanup
 Write-HarnessResult $directory 'receipt.json' @{status=$status;checks=@($rows)}|Out-Null
}
