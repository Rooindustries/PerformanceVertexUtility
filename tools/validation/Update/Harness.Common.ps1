. (Join-Path $PSScriptRoot '..\LoadTimes\CleanupOwnership.Common.ps1')
if(-not ('RooIndustriesHarnessWindow' -as [type])){
 Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesHarnessWindow {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectoryW(string path,IntPtr security);
 public static void CreateDirectory(string path) { if(!CreateDirectoryW(path,IntPtr.Zero))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out int p);
 delegate bool EnumWindow(IntPtr h,IntPtr data);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow callback,IntPtr data);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 public static IntPtr[] VisibleWindows(int pid) { var result=new System.Collections.Generic.List<IntPtr>();EnumWindows((h,data)=>{int owner;GetWindowThreadProcessId(h,out owner);if(owner==pid && IsWindowVisible(h))result.Add(h);return true;},IntPtr.Zero);return result.ToArray(); }
}
'@
}
function Get-HarnessLongPath([string]$Path){
 if($Path.StartsWith('\\?\',[StringComparison]::Ordinal)){return $Path}
 $plain=$Path.Replace('/','\')
 $stream='';$offset=[RooIndustriesValidationOwnership.Native]::StreamOffset($plain)
 if($offset -ge 0){
  $stream=$plain.Substring($offset)
  if($stream.Substring(1) -cnotmatch '^[^\\/:*?"<>|]+(:\$DATA)?$'){throw ('Invalid stream name; refused: '+$Path)}
  $plain=$plain.Substring(0,$offset)
 }
 $plain=[RooIndustriesValidationOwnership.Native]::FullPath($plain)
 if($plain.StartsWith('\\',[StringComparison]::Ordinal)){return '\\?\UNC\'+$plain.Substring(2)+$stream}
 return '\\?\'+$plain+$stream
}
function Get-HarnessPlainPath([string]$Path){
 $long=Get-HarnessLongPath $Path
 if($long.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)){return '\\'+$long.Substring(8)}
 return $long.Substring(4)
}
function Get-HarnessToolPath([string]$Path){
 $plain=Get-HarnessPlainPath $Path
 if([RooIndustriesValidationOwnership.Native]::StreamOffset($plain) -ge 0){throw 'stream paths are .NET-only; cmdlets take -Stream separately'}
 if($plain.Length -ge 260){throw ('Path reaches the 260-character tool limit; use a shorter frame: '+$plain)}
 return $plain
}
function Get-HarnessToolArguments([string]$Arguments){[RooIndustriesValidationOwnership.Native]::ToolArguments($Arguments)}
function Test-HarnessPath([string]$Path,[ValidateSet('Any','Leaf','Container')][string]$PathType='Any'){
 if($Path -match '^(HKLM|HKCU|Cert):'){if($PathType -eq 'Any'){return Test-Path -LiteralPath $Path};return Test-Path -LiteralPath $Path -PathType $PathType}
 $long=Get-HarnessLongPath $Path
 try{$attributes=[IO.File]::GetAttributes($long)}catch [IO.FileNotFoundException]{return $false}catch [IO.DirectoryNotFoundException]{return $false}
 $directory=[bool]($attributes -band [IO.FileAttributes]::Directory)
 if($PathType -eq 'Leaf'){return -not$directory}
 if($PathType -eq 'Container'){return $directory}
 return $true
}
function Get-HarnessItem([string]$Path,[switch]$Force){
 $long=Get-HarnessLongPath $Path;$plain=Get-HarnessPlainPath $long;$attributes=[IO.File]::GetAttributes($long)
 $directory=[bool]($attributes -band [IO.FileAttributes]::Directory)
 $parent=[IO.Path]::GetDirectoryName($plain.TrimEnd('\'))
 $target=$null
 if($attributes -band [IO.FileAttributes]::ReparsePoint){$target=@([RooIndustriesValidationOwnership.Native]::JunctionTarget($long))}
 [pscustomobject]@{FullName=$plain;LongPath=$long;Name=[IO.Path]::GetFileName($plain.TrimEnd('\'));Extension=[IO.Path]::GetExtension($plain);DirectoryName=$parent;Directory=if($parent){[IO.DirectoryInfo]::new((Get-HarnessLongPath $parent))}else{$null};Target=$target;PSIsContainer=$directory;IsDirectory=$directory;Attributes=$attributes;Length=if($directory){0}else{[IO.FileInfo]::new($long).Length};CreationTimeUtc=[IO.File]::GetCreationTimeUtc($long);LastWriteTimeUtc=[IO.File]::GetLastWriteTimeUtc($long);VersionInfo=if(-not$directory -and [IO.Path]::GetExtension($plain) -in '.exe','.dll'){[Diagnostics.FileVersionInfo]::GetVersionInfo($long)}else{$null}}
}
function Get-HarnessChildren([string]$Path,[switch]$File,[switch]$Directory,[string]$Filter='*',[switch]$Force,[string]$ErrorAction='Stop'){
 $root=Get-HarnessPlainPath $Path
 if($ErrorAction -eq 'SilentlyContinue' -and -not(Test-HarnessPath $root)){return}
 foreach($item in @(Get-HarnessTree $root -Depth 1)){
  if([IO.Path]::GetDirectoryName($item.FullName) -ine $root.TrimEnd('\')){continue}
  if($File -and $item.IsDirectory -or $Directory -and -not$item.IsDirectory){continue}
  if(-not$Force -and ($item.Attributes -band [IO.FileAttributes]::Hidden)){continue}
  if([IO.Path]::GetFileName($item.FullName) -notlike $Filter){continue}
  Get-HarnessItem $item.LongPath
 }
}
function Get-HarnessTree([string]$Root,[switch]$FilesOnly,[ValidateRange(1,2147483647)][int]$Depth=[int]::MaxValue){
 $long=Get-HarnessLongPath $Root
 $attributes=[IO.File]::GetAttributes($long)
 if($attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Reparse point retained: '+$Root)}
 if(-not($attributes -band [IO.FileAttributes]::Directory)){throw ('Tree root is not a directory: '+$Root)}
 $queue=[Collections.Generic.Stack[object]]::new();$queue.Push(@{path=$long;depth=0})
 while($queue.Count){
  $parent=$queue.Pop()
  foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($parent.path)){
   $attributes=[IO.File]::GetAttributes($entry)
   $plain=if($entry.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)){'\\'+$entry.Substring(8)}else{$entry.Substring(4)}
   if($attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Reparse point retained: '+$plain)}
   $isDirectory=[bool]($attributes -band [IO.FileAttributes]::Directory)
   if($isDirectory -and $parent.depth+1 -lt $Depth){$queue.Push(@{path=$entry;depth=$parent.depth+1})}
   if(-not$FilesOnly -or -not$isDirectory){[pscustomobject]@{FullName=$plain;LongPath=$entry;IsDirectory=$isDirectory;Attributes=$attributes;Length=if($isDirectory){0}else{[IO.FileInfo]::new($entry).Length};CreationTimeUtc=[IO.File]::GetCreationTimeUtc($entry)}}
  }
 }
}
function Get-HarnessFileSha256([string]$Path){
 $stream=[IO.File]::OpenRead((Get-HarnessLongPath $Path));$sha=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$sha.Dispose();$stream.Dispose()}
}
function Test-HarnessVisiblePath($Item,[string]$Root){
 for($path=$Item.FullName;$path -ine $Root;$path=[IO.Path]::GetDirectoryName($path)){
  if(-not$path){throw 'Tree item is outside its root.'}
  if([IO.File]::GetAttributes((Get-HarnessLongPath $path)) -band [IO.FileAttributes]::Hidden){return $false}
 }
 return $true
}
function New-HarnessConsoleAssembly([string]$Path,[string]$Code){
 $plain=Get-HarnessToolPath $Path
 if(Test-HarnessPath $plain){throw 'Console fixture output exists; retained.'}
 Add-Type -OutputAssembly $plain -OutputType ConsoleApplication -TypeDefinition $Code
}
function Get-HarnessFolderIdentity([string]$Path){
 $long=Get-HarnessLongPath $Path;$attributes=[IO.File]::GetAttributes($long)
 if(-not($attributes -band [IO.FileAttributes]::Directory) -or $attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned folder identity is not a plain directory.'}
 $plain=if($long.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)){'\\'+$long.Substring(8)}else{$long.Substring(4)}
 @{path=$plain;creationTimeFileTimeUtc=[IO.Directory]::GetCreationTimeUtc($long).ToFileTimeUtc().ToString()}
}
function Invoke-HarnessCheckpoint([string]$Name){if($script:HarnessCheckpoint){& $script:HarnessCheckpoint $Name}}
function Read-HarnessLedger([string]$Path){
 $ledger=[IO.File]::ReadAllText((Get-HarnessLongPath $Path))|ConvertFrom-Json
 if($ledger.frameId -cne $script:Harness.FrameId -or $ledger.manifestSha256 -cne $script:Harness.Manifest -or $ledger.machine -cne $env:COMPUTERNAME){throw 'Harness ledger scope changed; retained.'}
 return $ledger
}
function Invoke-HarnessLedger([scriptblock]$Action,[switch]$NoWrite){
 if(-not$script:Harness){throw 'Harness invocation has no verified frame scope.'}
 $stream=$script:Harness.LedgerLock;$ownsLock=$null -eq $stream
 for($attempt=0;$ownsLock -and $attempt -lt 10;$attempt++){
  try{
   $path=Get-HarnessLongPath ($script:Harness.LedgerPath+'.lock')
   if($env:OS -eq 'Windows_NT'){
    $handle=[RooIndustriesValidationOwnership.Native]::CreateFile($path,[uint32]3221291008,0,[IntPtr]::Zero,4,0,[IntPtr]::Zero)
    if($handle.IsInvalid){$errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error();$handle.Dispose();throw [IO.IOException]::new('The frame journal lock could not be acquired.',[ComponentModel.Win32Exception]::new($errorCode))}
    try{$stream=[IO.FileStream]::new($handle,[IO.FileAccess]::ReadWrite)}catch{$handle.Dispose();throw}
   }else{$stream=[IO.FileStream]::new($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
   $script:Harness.LedgerLock=$stream;break
  }
  catch [IO.IOException]{if($attempt -eq 9){throw};Start-Sleep -Milliseconds 200}
 }
 try{
  $path=$script:Harness.LedgerPath
  if(-not(Test-HarnessPath $path -PathType Leaf)){$path+='.previous'}
  $ledger=Read-HarnessLedger $path
  $result=& $Action $ledger
  if(-not$script:Harness.ReadOnly -and -not$NoWrite){
   $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($ledger|ConvertTo-Json -Depth 60))
   $temp=Get-HarnessLongPath ($script:Harness.LedgerPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp')
   Invoke-HarnessCheckpoint 'journal:before-temp'
   $replacement=[IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
   try{
    Invoke-HarnessCheckpoint 'journal:temp-created'
    $half=[int][Math]::Floor($bytes.Length/2);$replacement.Write($bytes,0,$half)
    Invoke-HarnessCheckpoint 'journal:partial-write'
    $replacement.Write($bytes,$half,$bytes.Length-$half);$replacement.Flush($true)
    Invoke-HarnessCheckpoint 'journal:flushed'
   }finally{$replacement.Dispose()}
   Invoke-HarnessCheckpoint 'journal:before-replace'
   if(Test-HarnessPath $script:Harness.LedgerPath -PathType Leaf){[IO.File]::Replace($temp,(Get-HarnessLongPath $script:Harness.LedgerPath),(Get-HarnessLongPath ($script:Harness.LedgerPath+'.previous')))}
   else{[IO.File]::Move($temp,(Get-HarnessLongPath $script:Harness.LedgerPath))}
   Invoke-HarnessCheckpoint 'journal:replaced'
  }
  return $result
 }finally{if($ownsLock){$script:Harness.LedgerLock=$null;$stream.Dispose()}}
}
function Open-HarnessRun([string]$FrameRoot,[string]$FrameId,[string]$ManifestSha256,[string]$Nonce,[switch]$ReadOnly){
 $root=(Get-HarnessPlainPath $FrameRoot).TrimEnd('\')
 if($root -notmatch '^C:\\RooBuild\\roo-industries-[A-Za-z0-9_-]+-[a-f0-9]{32}$' -or $FrameId -cne $root.Substring($root.Length-32)){throw 'Harness frame scope differs.'}
 $script:Harness=@{Root=$root;FrameId=$FrameId;Manifest=$ManifestSha256;Nonce=$Nonce;LedgerPath=(Join-Path $root 'ledger.json');ReadOnly=[bool]$ReadOnly;Handles=@{};Scenario='';Scope=''}
 if(-not(Test-HarnessPath $script:Harness.LedgerPath -PathType Leaf) -and -not(Test-HarnessPath ($script:Harness.LedgerPath+'.previous') -PathType Leaf)){throw 'Frame has no creation ledger; stage a fresh frame.'}
 Invoke-HarnessLedger {param($ledger) $null} -NoWrite|Out-Null
}
function Initialize-HarnessInvocation([string]$Scenario,[string]$Scope){
 if(-not$global:RooIndustriesVerificationInvocationContext -or -not$global:RooIndustriesVerificationInvocationContext.frame){throw 'A verified windows_ssh interactive invocation is required.'}
 $context=$global:RooIndustriesVerificationInvocationContext;$frame=$context.frame
 if(-not$script:Harness -or $script:Harness.Nonce -cne $context.nonce){Open-HarnessRun $frame.runRoot $frame.frameId $frame.manifestSha256 $context.nonce}
 $script:Harness.Scenario=$Scenario;$script:Harness.Scope=$Scope
 Invoke-HarnessLedger {param($ledger)
  if(@($ledger.invocations|Where-Object nonce -CEQ $context.nonce).Count){$i=@($ledger.invocations|Where-Object nonce -CEQ $context.nonce)[0];if($i.scenario -like 'Invoke-*'){$i.scenario=$Scenario;$i.scope=$Scope}}else{$ledger.invocations=@($ledger.invocations)+@([pscustomobject]@{nonce=$context.nonce;scenario=$Scenario;scope=$Scope;startedAtUtc=[DateTime]::UtcNow.ToString('o');status='running';cleanupErrors=@()})}
 }|Out-Null
 $known=Get-HarnessProcess $PID
 if(-not$known){throw 'Interactive child was not recorded immediately after creation.'}
 $script:Harness.Handles[$PID]=$known
 Start-ProcessTrace|Out-Null
 return $script:Harness.Nonce
}
function Add-HarnessEntry([string]$Kind,$Identity,[string]$Purpose='',[string]$Lifetime='invocation',$Metadata=$null){
 if($Kind -eq 'file' -and $Identity.id){$Identity|Add-Member creationTimeFileTimeUtc ($Identity.id.Split(':')[-1]) -Force}
 $entry=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');nonce=$script:Harness.Nonce;kind=$Kind;identity=$Identity;purpose=$Purpose;lifetime=$Lifetime;metadata=$Metadata;createdAtUtc=[DateTime]::UtcNow.ToString('o');state='active';cleanupError=$null}
 return Invoke-HarnessLedger {param($ledger)
  if($Kind -eq 'process'){$existing=@($ledger.entries|Where-Object {$_.kind -eq 'process' -and $_.state -eq 'active' -and $_.identity.pid -eq $Identity.pid -and $_.identity.creationTimeFileTimeUtc -ceq $Identity.creationTimeFileTimeUtc -and $_.identity.imagePath -ieq $Identity.imagePath});if($existing.Count -gt 1){throw 'Process has ambiguous creation entries; retained.'};if($existing.Count){return $existing[0]}}
  $ledger.entries=@($ledger.entries)+@($entry);return $entry
 }
}
function Get-HarnessEntries{Invoke-HarnessLedger {param($ledger) @($ledger.entries)} -NoWrite}
function Set-HarnessEntryState([string]$Id,[string]$State,[string]$Error=''){
 Invoke-HarnessLedger {param($ledger) $entry=@($ledger.entries|Where-Object id -CEQ $Id);if($entry.Count -ne 1){throw 'Ledger entry is missing or ambiguous.'};$entry[0].state=$State;$entry[0].cleanupError=$Error}|Out-Null
}
function Enter-HarnessHostLease{
 $path='C:\RooBuild\host-lease.json'
 if(-not(Test-HarnessPath $path)){
  $value=@{frameId=$script:Harness.FrameId;nonce=$script:Harness.Nonce;runRoot=$script:Harness.Root;createdUtc=[DateTime]::UtcNow.ToString('o')}
  try{New-HarnessText $path ($value|ConvertTo-Json -Compress) 'host-lease' 'frame'|Out-Null}catch [IO.IOException]{if(-not(Test-HarnessPath $path)){throw}}
 }
 Assert-HarnessHostLease
}
function Assert-HarnessHostLease{
 $path='C:\RooBuild\host-lease.json'
 if(-not(Test-HarnessPath $path)){throw 'Test PC has no host lease for this frame.'}
 $lease=[IO.File]::ReadAllText((Get-HarnessLongPath $path))|ConvertFrom-Json
 if($lease.frameId -cne $script:Harness.FrameId -or $lease.runRoot -ine $script:Harness.Root){
  if(Test-HarnessPath $lease.runRoot -PathType Container){throw ('Test PC is leased by frame '+$lease.frameId)}
  throw ('Stale host lease from frame '+$lease.frameId+'; clear it with that frame''s ledger or remove it by hand.')
 }
 $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.purpose -eq 'host-lease' -and $_.identity.path -ieq $path -and $_.state -eq 'active' -and $_.nonce -ceq $lease.nonce})
 if($entry.Count -ne 1){throw 'Host lease is not in this frame creation ledger; retained.'}
 $probe=[RooIndustriesValidationOwnership.ProbeFile]::Open((Get-HarnessLongPath $path),$entry[0].identity.id,$entry[0].identity.hash)
 try{$verified=$probe.ReadText()|ConvertFrom-Json;if($verified.frameId -cne $script:Harness.FrameId -or $verified.nonce -cne $lease.nonce){throw 'Host lease identity changed; retained.'}}finally{$probe.Dispose()}
}
function Assert-HarnessInstallStart([string]$Image){Assert-HarnessHostLease;Assert-NoForeignInstance $Image}
function Get-HarnessProcess([int]$ProcessId){
 Receive-ProcessTrace
 $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.metadata.platform -ne 'linux' -and $_.identity.pid -eq $ProcessId -and $_.state -eq 'active'})
 foreach($entry in $entries){
  $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if(-not$process){continue}
  $receipt=New-OwnedProcess $process
  if($receipt -and $receipt.Identity.creationTimeFileTimeUtc -ceq $entry.identity.creationTimeFileTimeUtc -and $receipt.Identity.imagePath -ieq $entry.identity.imagePath){$receipt|Add-Member LedgerId $entry.id;$receipt|Add-Member Nonce $entry.nonce;$receipt|Add-Member OwnershipProof $(if($entry.metadata.ownershipProof){$entry.metadata.ownershipProof}else{@{kind='creation-ledger'}});return $receipt}
  $process.Dispose()
 }
 return $null
}
function Start-ProcessTrace($Anchor=$null){
 if(-not$script:Harness -or $script:Harness.ReadOnly){throw 'Process trace needs a writable verified invocation.'}
 if($Anchor){$known=Get-HarnessProcess ([int]$Anchor.Identity.pid);if(-not$known -or $known.Identity.creationTimeFileTimeUtc -cne $Anchor.Identity.creationTimeFileTimeUtc -or $known.Identity.imagePath -ine $Anchor.Identity.imagePath){throw 'Trace anchor is not in this creation ledger; retained.'}}
 if($script:Harness.Trace){return $script:Harness.Trace}
 if(-not$global:RooIndustriesHarnessTraces){$global:RooIndustriesHarnessTraces=@{}}
 $key=$script:Harness.FrameId+':'+$script:Harness.Nonce
 if($global:RooIndustriesHarnessTraces.ContainsKey($key)){$script:Harness.Trace=$global:RooIndustriesHarnessTraces[$key];return $script:Harness.Trace}
 $invocation=Invoke-HarnessLedger {param($ledger) @($ledger.invocations|Where-Object nonce -CEQ $script:Harness.Nonce)|Select-Object -First 1} -NoWrite
 if(-not$invocation){throw 'Process trace has no invocation window.'}
 if(-not('RooIndustriesHarnessProcessTrace' -as [type])){Add-Type -Path (Get-HarnessToolPath (Join-Path $PSScriptRoot 'HarnessTrace.cs')) -ReferencedAssemblies System.dll,System.Management.dll}
 $traceNonce=[Guid]::NewGuid().ToString('N');$started=[DateTime]::UtcNow
 $receiver=[RooIndustriesHarnessProcessTrace]::new($traceNonce)
 $script:Harness.Trace=@{Receiver=$receiver;Nonce=$traceNonce;Start=[DateTime]::Parse($invocation.startedAtUtc).ToUniversalTime();Subscribed=$started;Stopped=$false}
 $global:RooIndustriesHarnessTraces[$key]=$script:Harness.Trace
 Invoke-HarnessLedger {param($ledger) $i=@($ledger.invocations|Where-Object nonce -CEQ $script:Harness.Nonce)[0];$i|Add-Member trace ([pscustomobject]@{nonce=$traceNonce;subscribedAtUtc=$started.ToString('o')}) -Force}|Out-Null
 return $script:Harness.Trace
}
function Receive-ProcessTrace{
 $trace=$script:Harness.Trace
 if(-not$trace){return}
 if($trace.Receiver.Error){throw ('Process-start trace failed: '+$trace.Receiver.Error)}
 $batch=@($trace.Receiver.Pending())
 if(-not$batch.Count){return}
 Invoke-HarnessLedger {param($ledger)
  foreach($event in $batch){
   if(@($ledger.entries|Where-Object {$_.kind -eq 'trace' -and $_.identity.eventNonce -ceq $event.EventNonce}).Count){continue}
   $ledger.entries=@($ledger.entries)+@([pscustomobject]@{id=[Guid]::NewGuid().ToString('N');nonce=$script:Harness.Nonce;kind='trace';identity=[pscustomobject]@{eventNonce=$event.EventNonce;traceNonce=$event.TraceNonce;processId=$event.ProcessId;parentProcessId=$event.ParentProcessId;processName=$event.ProcessName;timeCreatedFileTimeUtc=$event.TimeCreatedFileTimeUtc};purpose='process-start';lifetime='invocation';metadata=$null;createdAtUtc=$event.ReceivedAtUtc;state='active';cleanupError=$null})
  }
 }|Out-Null
 $trace.Receiver.Acknowledge($batch.Count)
}
function Stop-ProcessTrace{
 if($script:Harness.Trace -and -not$script:Harness.Trace.Stopped){$script:Harness.Trace.Receiver.Stop();$script:Harness.Trace.Stopped=$true}
 Receive-ProcessTrace
}
function Get-HarnessBirthMatch($Events,[int]$ProcessId,[long]$NativeBirth){
 $matches=@($Events|Where-Object {$_.identity.processId -eq $ProcessId -and ([long]$_.identity.timeCreatedFileTimeUtc-$NativeBirth) -ge -10000000 -and ([long]$_.identity.timeCreatedFileTimeUtc-$NativeBirth) -le 100000000})
 @{matches=$matches;unique=($matches.Count -eq 1);lagMs=if($matches.Count -eq 1){([long]$matches[0].identity.timeCreatedFileTimeUtc-$NativeBirth)/10000.0}else{$null};nativeBirth=$NativeBirth.ToString()}
}
function Register-HarnessTraceRefusal([int]$ProcessId,[string]$Reason,$Events){
 $births=@(foreach($id in @(@($Events|ForEach-Object {$_.identity.processId})+@($ProcessId)|Select-Object -Unique)){
  $p=Get-Process -Id $id -ErrorAction SilentlyContinue
  if($p){try{$birth=[RooIndustriesValidationOwnership.Native]::Created($p.Handle);@{pid=$id;nativeBirth=$birth.ToString();lagsMs=@($Events|Where-Object {$_.identity.processId -eq $id}|ForEach-Object {([long]$_.identity.timeCreatedFileTimeUtc-$birth)/10000.0})}}catch{@{pid=$id;nativeBirth=$null;error=$_.Exception.Message}}finally{$p.Dispose()}}
  else{@{pid=$id;nativeBirth=$null;absent=$true}}
 })
 Add-HarnessEntry 'trace-refusal' @{processId=$ProcessId;reason=$Reason;candidates=$births} 'trace-refusal'|Out-Null
 return $false
}
function Test-TracedDescendant([int]$ProcessId,[switch]$PassThru,$Ancestor=$null){
 if(-not$script:Harness.Trace -or $script:Harness.Trace.Stopped -or $ProcessId -le 4){return $false}
 Receive-ProcessTrace
 $trace=$script:Harness.Trace;$end=[DateTime]::UtcNow.ToFileTimeUtc();$start=$trace.Start.ToFileTimeUtc()
 $entries=@(Get-HarnessEntries);$traceEvents=@($entries|Where-Object {$_.kind -eq 'trace' -and $_.nonce -ceq $script:Harness.Nonce -and $_.identity.traceNonce -ceq $trace.Nonce});$events=@($traceEvents|Where-Object {[long]$_.identity.timeCreatedFileTimeUtc -ge $start -and [long]$_.identity.timeCreatedFileTimeUtc -le $end})
 $candidates=@($events|Where-Object {$_.identity.processId -eq $ProcessId})
 $existing=Get-HarnessProcess $ProcessId
 if($existing -and $existing.Nonce -ceq $script:Harness.Nonce -and $existing.OwnershipProof.kind -ceq 'trace'){
  $proof=$existing.OwnershipProof
  $birthMatch=Get-HarnessBirthMatch $traceEvents $ProcessId ([long]$existing.Identity.creationTimeFileTimeUtc)
  $ancestorMatches=-not$Ancestor -or ($proof.root.pid -eq $Ancestor.Identity.pid -and $proof.root.creationTimeFileTimeUtc -ceq $Ancestor.Identity.creationTimeFileTimeUtc -and $proof.root.imagePath -ieq $Ancestor.Identity.imagePath)
  if($proof.traceNonce -ceq $trace.Nonce -and $proof.nativeBirth -ceq $existing.Identity.creationTimeFileTimeUtc -and $birthMatch.unique -and $birthMatch.matches[0].identity.eventNonce -ceq $proof.eventIds[0] -and $ancestorMatches){
   $existing|Add-Member RetainedOwnershipProof $true -Force
   if($PassThru){return $existing};return $true
  }
 }
 if(-not$candidates.Count){return Register-HarnessTraceRefusal $ProcessId 'No start event' $candidates}
 $proofs=@()
 foreach($candidate in $candidates){
  $chain=@($candidate);$seen=@{};$seen[$ProcessId]=$true;$cursor=$candidate;$root=$null
  for($hop=0;$hop -lt 64;$hop++){
   $parentId=[int]$cursor.identity.parentProcessId
   if($parentId -le 4 -or $seen.ContainsKey($parentId)){break};$seen[$parentId]=$true
   $owned=@($entries|Where-Object {$_.kind -eq 'process' -and $_.state -eq 'active' -and $_.metadata.platform -ne 'linux' -and $_.identity.pid -eq $parentId -and [long]$_.identity.creationTimeFileTimeUtc -le [long]$cursor.identity.timeCreatedFileTimeUtc})
   if($Ancestor){$owned=@($owned|Where-Object {$_.identity.pid -eq $Ancestor.Identity.pid -and $_.identity.creationTimeFileTimeUtc -ceq $Ancestor.Identity.creationTimeFileTimeUtc})}
   foreach($entry in $owned){
    $held=if($script:Harness.Handles.ContainsKey($parentId)){$script:Harness.Handles[$parentId]}else{Get-HarnessProcess $parentId}
    if(-not$held -or $held.Identity.creationTimeFileTimeUtc -cne $entry.identity.creationTimeFileTimeUtc -or [RooIndustriesValidationOwnership.Native]::Created($held.handle).ToString() -cne $entry.identity.creationTimeFileTimeUtc){continue}
    if([long]$entry.identity.creationTimeFileTimeUtc -lt $trace.Subscribed.ToFileTimeUtc() -and $held.process.HasExited){continue}
    $rootEvents=@($events|Where-Object {$_.identity.processId -eq $parentId -and [long]$_.identity.timeCreatedFileTimeUtc -le [long]$cursor.identity.timeCreatedFileTimeUtc}|Sort-Object {[long]$_.identity.timeCreatedFileTimeUtc} -Descending)
    if($rootEvents.Count){
     $rootMatch=Get-HarnessBirthMatch $traceEvents $parentId ([long]$entry.identity.creationTimeFileTimeUtc);$rootMatches=@($rootMatch.matches|Where-Object {$_.identity.processName -ieq [IO.Path]::GetFileName($entry.identity.imagePath)})
     if(-not$rootMatch.unique -or $rootMatches.Count -ne 1 -or $rootMatches[0].id -cne $rootEvents[0].id){continue}
    }elseif($held.process.HasExited){continue}
    $root=$entry;break
   }
   if($root){break}
   $parents=@($events|Where-Object {$_.identity.processId -eq $parentId -and [long]$_.identity.timeCreatedFileTimeUtc -le [long]$cursor.identity.timeCreatedFileTimeUtc}|Sort-Object {[long]$_.identity.timeCreatedFileTimeUtc} -Descending)
   if(-not$parents.Count){break}
   $latest=$parents[0];if(@($parents|Where-Object {$_.identity.timeCreatedFileTimeUtc -ceq $latest.identity.timeCreatedFileTimeUtc}).Count -ne 1){break}
   $cursor=$latest;$chain+=@($cursor)
  }
  if($root){$proofs+=@(@{candidate=$candidate;chain=$chain;root=$root})}
 }
 if(-not$proofs.Count){return Register-HarnessTraceRefusal $ProcessId 'No owned parent chain' $candidates}
 $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
 if(-not$process){return Register-HarnessTraceRefusal $ProcessId 'Process exited before birth could be re-read' $candidates}
 $receipt=$null;$accepted=$false
 try{
  $receipt=New-OwnedProcess $process
  if(-not$receipt -or $process.HasExited){return Register-HarnessTraceRefusal $ProcessId 'Process ended before ownership proof' $candidates}
  $birth=[long]$receipt.Identity.creationTimeFileTimeUtc
  $birthMatch=Get-HarnessBirthMatch $traceEvents $ProcessId $birth;$matching=@($birthMatch.matches|Where-Object {$_.identity.processName -ieq [IO.Path]::GetFileName($receipt.Identity.imagePath)})
  if(-not$birthMatch.unique -or $matching.Count -ne 1){return Register-HarnessTraceRefusal $ProcessId 'Native birth is outside the interval or ambiguous' $candidates}
  $valid=@($proofs|Where-Object {$_.candidate.id -ceq $matching[0].id})
  if($valid.Count -ne 1 -or [long]$valid[0].root.identity.creationTimeFileTimeUtc -gt $birth -or [RooIndustriesValidationOwnership.Native]::Created($receipt.handle) -ne $birth -or $process.HasExited){return Register-HarnessTraceRefusal $ProcessId 'Parent proof or retained native identity changed' $candidates}
  $proof=@{kind='trace';traceNonce=$trace.Nonce;eventIds=@($valid[0].chain|ForEach-Object {$_.identity.eventNonce});root=$valid[0].root.identity;nativeBirth=$birth.ToString();eventTime=$matching[0].identity.timeCreatedFileTimeUtc;lagMs=$birthMatch.lagMs;windowStart=$trace.Start.ToString('o');windowEnd=[DateTime]::FromFileTimeUtc($end).ToString('o')}
  $entry=Add-HarnessEntry 'process' $receipt.Identity 'descendant' 'invocation' @{ownershipProof=$proof}
  Invoke-HarnessLedger {param($ledger) $record=@($ledger.entries|Where-Object id -CEQ $entry.id)[0];if(-not$record.metadata){$record.metadata=[pscustomobject]@{}};$record.metadata|Add-Member ownershipProof ([pscustomobject]$proof) -Force}|Out-Null
  $receipt|Add-Member LedgerId $entry.id;$receipt|Add-Member Nonce $script:Harness.Nonce;$receipt|Add-Member OwnershipProof $proof
  $script:Harness.Handles[$ProcessId]=$receipt;$accepted=$true
  if($PassThru){return $receipt};return $true
 }finally{if(-not$accepted){$process.Dispose()}}
}
function Register-HarnessStartedProcess($Process,[string]$Purpose='',[string]$Lifetime='invocation'){
 $handle=$Process.Handle
 $receipt=[pscustomobject]@{process=$Process;handle=$handle;Identity=[pscustomobject]@{pid=$Process.Id;creationTimeFileTimeUtc=[RooIndustriesValidationOwnership.Native]::Created($handle).ToString();imagePath=[RooIndustriesValidationOwnership.Native]::Image($handle)}}
 $entry=Add-HarnessEntry 'process' $receipt.Identity $Purpose $Lifetime
 $receipt|Add-Member LedgerId $entry.id;$receipt|Add-Member Nonce $script:Harness.Nonce
 $script:Harness.Handles[[int]$receipt.Identity.pid]=$receipt
 return $receipt
}
function Start-OwnedProcess([string]$FilePath,[string]$ArgumentList='',[string]$WindowStyle='Hidden',[string]$Purpose='',[string]$Lifetime='invocation',[Diagnostics.ProcessStartInfo]$StartInfo,[string]$WorkingDirectory=''){
 if($StartInfo -and $StartInfo.UseShellExecute){throw 'Run ShellExecute in a separate owned launcher so its dialogs cannot block the harness.'}
 if($StartInfo){
  $StartInfo.FileName=Get-HarnessToolPath $StartInfo.FileName
  if($StartInfo.WorkingDirectory){$StartInfo.WorkingDirectory=Get-HarnessToolPath $StartInfo.WorkingDirectory}
  $StartInfo.Arguments=Get-HarnessToolArguments $StartInfo.Arguments
  $process=[Diagnostics.Process]::Start($StartInfo)
 }else{
  if(-not[IO.Path]::IsPathRooted($FilePath) -and $FilePath -notmatch '[\\/]'){$FilePath=(Get-Command $FilePath -CommandType Application -ErrorAction Stop).Source}
  $arguments=@{FilePath=(Get-HarnessToolPath $FilePath);WindowStyle=$WindowStyle;PassThru=$true}
  if($WorkingDirectory){$arguments.WorkingDirectory=Get-HarnessToolPath $WorkingDirectory}
  if(-not[string]::IsNullOrEmpty($ArgumentList)){$arguments.ArgumentList=Get-HarnessToolArguments $ArgumentList}
  $process=Start-Process @arguments
 }
 return Register-HarnessStartedProcess $process $Purpose $Lifetime
}
function Get-HarnessExplorerBroker{
 $shell=New-Object -ComObject Shell.Application
 try{
  [int]$hwnd=0
  $desktop=$shell.Windows().FindWindowSW(0,$null,8,[ref]$hwnd,1)
  if(-not$desktop -or -not$hwnd){throw 'Desktop Explorer dispatch is unavailable.'}
  [int]$owner=0;[RooIndustriesHarnessWindow]::GetWindowThreadProcessId([IntPtr]::new($hwnd),[ref]$owner)|Out-Null
  $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$owner)
  if(-not$process -or [IO.Path]::GetFileName($process.ExecutablePath) -ine 'explorer.exe'){throw 'Desktop shell is not Explorer.'}
  return @{shell=$shell;dispatch=$desktop.Document.Application;explorer=$process}
 }catch{[Runtime.InteropServices.Marshal]::ReleaseComObject($shell)|Out-Null;throw}
}
function Start-HarnessExplorerProcess([string]$Image,[string]$Arguments,[string]$Purpose='explorer-fixture'){
 $file=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.identity.path -ieq $Image -and $_.state -eq 'active'})
 if($file.Count -ne 1){throw 'Explorer launch requires one file created by this run.'}
 if(@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -IEQ $Image).Count){throw 'A fixture instance already exists; retained.'}
 $broker=Get-HarnessExplorerBroker;$owned=$null
 try{
  $started=[DateTime]::UtcNow
  $broker.dispatch.ShellExecute((Get-HarnessToolPath $Image),(Get-HarnessToolArguments $Arguments),(Get-HarnessToolPath ([IO.Path]::GetDirectoryName($Image))),'open',0)
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  do{
   $matches=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -IEQ $Image)
   if($matches.Count -gt 1){throw 'Explorer fixture identity is ambiguous; retained.'}
   if($matches.Count -eq 1){break}
   Start-Sleep -Milliseconds 50
  }while([DateTime]::UtcNow -lt $deadline)
  if($matches.Count -ne 1 -or $matches[0].CreationDate.ToUniversalTime() -lt $started){throw 'New Explorer fixture creation was not observed.'}
  $match=$matches[0];$parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$match.ParentProcessId)
  if(-not$parent -or $parent.ProcessId -ne $broker.explorer.ProcessId -or $parent.CreationDate -ne $broker.explorer.CreationDate){throw 'Fixture was not launched by the verified desktop Explorer; retained.'}
  $owned=Register-HarnessStartedProcess (Get-Process -Id $match.ProcessId) $Purpose
  $owned|Add-Member ExplorerLaunchUtc $started;$owned|Add-Member ExplorerParent $parent
  return $owned
 }finally{[Runtime.InteropServices.Marshal]::ReleaseComObject($broker.shell)|Out-Null}
}
function Test-OwnedDescendant([int]$ProcessId,[switch]$PassThru,$Ancestor=$null){
 $traced=Test-TracedDescendant $ProcessId -PassThru -Ancestor $Ancestor
 if($traced){if($PassThru){return $traced};return $true}
 Receive-ProcessTrace
 if($Ancestor){
  $ancestorId=[int]$Ancestor.Identity.pid;$seen=@{};$childTime=$null;$cursor=$ProcessId;$reached=$false
  for($hop=0;$hop -lt 32;$hop++){
   if($cursor -le 4 -or $seen.ContainsKey($cursor)){return $false};$seen[$cursor]=$true
   $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$cursor) -ErrorAction SilentlyContinue
   if(-not$cim -or -not$cim.CreationDate){return $false}
   $created=$cim.CreationDate.ToUniversalTime().ToFileTimeUtc()
   if($childTime -and $created -gt $childTime){return $false}
   if($cursor -eq $ancestorId){
    if([RooIndustriesValidationOwnership.Native]::Created($Ancestor.handle).ToString() -cne $Ancestor.Identity.creationTimeFileTimeUtc -or [Math]::Abs([long]$Ancestor.Identity.creationTimeFileTimeUtc-$created) -gt 10){return $false}
    $reached=$true;break
   }
   $childTime=$created;$cursor=[int]$cim.ParentProcessId
  }
  if(-not$reached){return $false}
 }
 $known=Get-HarnessProcess $ProcessId
 if($known){if($PassThru){return $known};return $true}
 $chain=@();$seen=@{};$childTime=$null;$anchor=$null
 for($hop=0;$hop -lt 32;$hop++){
  if($ProcessId -le 4 -or $seen.ContainsKey($ProcessId)){return $false};$seen[$ProcessId]=$true
  if($script:Harness.Handles.ContainsKey($ProcessId)){
   $held=$script:Harness.Handles[$ProcessId]
   if([RooIndustriesValidationOwnership.Native]::Created($held.handle).ToString() -cne $held.Identity.creationTimeFileTimeUtc){return $false}
   $live=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ProcessId) -ErrorAction SilentlyContinue
   if($live -and [Math]::Abs([long]$held.Identity.creationTimeFileTimeUtc-$live.CreationDate.ToUniversalTime().ToFileTimeUtc()) -gt 10){return $false}
   if($childTime -and [long]$held.Identity.creationTimeFileTimeUtc -gt $childTime){return $false}
   $anchor=$held;break
  }
  $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ProcessId) -ErrorAction SilentlyContinue
  if(-not$cim -or -not$cim.CreationDate){return $false}
  $created=$cim.CreationDate.ToUniversalTime().ToFileTimeUtc()
  if($childTime -and $created -gt $childTime){return $false}
  $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.state -eq 'active' -and $_.identity.pid -eq $ProcessId -and [Math]::Abs([long]$_.identity.creationTimeFileTimeUtc-$created) -le 10})
  if($entry.Count -eq 1){$anchor=Get-HarnessProcess $ProcessId;if($anchor){$script:Harness.Handles[$ProcessId]=$anchor;break};return $false}
  $chain+=@($cim);$childTime=$created;$ProcessId=[int]$cim.ParentProcessId
 }
 if(-not$anchor){return $false}
 $receipts=@()
 foreach($cim in $chain){
  $process=Get-Process -Id $cim.ProcessId -ErrorAction SilentlyContinue
  if(-not$process){return $false}
  $receipt=New-OwnedProcess $process
  if(-not$receipt -or [Math]::Abs([long]$receipt.Identity.creationTimeFileTimeUtc-$cim.CreationDate.ToUniversalTime().ToFileTimeUtc()) -gt 10 -or $process.Path -ine $cim.ExecutablePath){return $false}
  $receipts+=@($receipt)
 }
 foreach($receipt in $receipts){$proof=@{kind='live-chain';root=$anchor.Identity};$entry=Add-HarnessEntry 'process' $receipt.Identity 'descendant' 'invocation' @{ownershipProof=$proof};$receipt|Add-Member OwnershipProof $proof;$receipt|Add-Member LedgerId $entry.id;$receipt|Add-Member Nonce $script:Harness.Nonce;$script:Harness.Handles[[int]$receipt.Identity.pid]=$receipt}
 if($PassThru){return $receipts[0]};return $true
}
function Assert-NoForeignInstance([string]$Image){
 foreach($cim in @(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $Image})){if(-not(Get-HarnessProcess ([int]$cim.ProcessId))){throw 'An app instance is already running that this run did not start; retained.'}}
}
function Register-HarnessWindow($Window){
 $owner=Test-OwnedDescendant ([int]$Window.Current.ProcessId) -PassThru
 if(-not$owner){throw 'Window belongs to a non-owned process; retained.'}
 $hwnd=$Window.Current.NativeWindowHandle
 if($hwnd -and -not@(Get-HarnessEntries|Where-Object {$_.kind -eq 'window' -and $_.state -eq 'active' -and $_.identity.hwnd -eq $hwnd -and $_.identity.ownerCreationTime -ceq $owner.Identity.creationTimeFileTimeUtc}).Count){Add-HarnessEntry 'window' @{hwnd=$hwnd;ownerPid=$owner.Identity.pid;ownerCreationTime=$owner.Identity.creationTimeFileTimeUtc} 'ui'|Out-Null}
 return $Window
}
function New-HarnessDirectory([string]$Path,[string]$Purpose='',[string]$Lifetime='run'){
 $full=(Get-HarnessPlainPath $Path).TrimEnd('\')
 if([IO.File]::Exists((Get-HarnessLongPath $full)) -or [IO.Directory]::Exists((Get-HarnessLongPath $full))){throw 'Directory exists before this creation; retained.'}
 $missing=[Collections.Generic.Stack[string]]::new();$parent=$full
 while(-not[IO.Directory]::Exists((Get-HarnessLongPath $parent))){$missing.Push($parent);$parent=[IO.Path]::GetDirectoryName($parent);if(-not$parent){throw 'Directory has no existing ancestor.'}}
 Get-HarnessFolderIdentity $parent|Out-Null
 $leaf=$null
 while($missing.Count){
  $next=$missing.Pop();[RooIndustriesHarnessWindow]::CreateDirectory((Get-HarnessLongPath $next))
  $entry=Add-HarnessEntry 'folder' (Get-HarnessFolderIdentity $next) $Purpose $Lifetime $(if($next -ine $full){@{emptyOnly=$true}}else{$null})
  if($next -ieq $full){$leaf=$entry}
 }
 return $leaf
}
function Register-HarnessFile([string]$Path,[string]$Purpose='',[string]$Lifetime='run',$Metadata=$null){
 $handle=[RooIndustriesValidationOwnership.Native]::CreateFile((Get-HarnessLongPath $Path),[uint32]2147483648,7,[IntPtr]::Zero,3,0x00200000,[IntPtr]::Zero)
 try{$id=[RooIndustriesValidationOwnership.Native]::FileId($handle)}finally{$handle.Dispose()}
 $probe=[RooIndustriesValidationOwnership.ProbeFile]::Open((Get-HarnessLongPath $Path),$id,(Get-HarnessFileSha256 $Path));$probe.Identity.path=(Get-HarnessPlainPath $Path)
 try{return Add-HarnessEntry 'file' $probe.Identity $Purpose $Lifetime $Metadata}finally{$probe.Dispose()}
}
function New-HarnessEvidenceDirectory([string]$OutRoot,[string]$Name){
 if(-not$script:Harness){throw 'Evidence directory requires a verified invocation.'}
 $path=Join-Path $OutRoot ($Name+'-'+$script:Harness.Nonce)
 New-HarnessDirectory $path 'evidence' 'run'|Out-Null
 return $path
}
function Copy-HarnessFile([string]$Source,[string]$Destination,[string]$Purpose='fixture',[string]$Lifetime='run'){
 $probe=[RooIndustriesValidationOwnership.ProbeFile]::Copy((Get-HarnessLongPath $Source),(Get-HarnessLongPath $Destination));$probe.Identity.path=(Get-HarnessPlainPath $Destination)
 try{return Add-HarnessEntry 'file' $probe.Identity $Purpose $Lifetime}finally{$probe.Dispose()}
}
function Get-HarnessEntryById([string]$Id){$rows=@(Get-HarnessEntries|Where-Object id -CEQ $Id);if($rows.Count -ne 1){throw 'Creation ledger entry is missing or ambiguous.'};return $rows[0]}
function Stop-HarnessProcess($Receipt){if($Receipt){Remove-HarnessEntry (Get-HarnessEntryById $Receipt.LedgerId)}}
function Assert-HarnessSmartScreen($Window,[string]$Directory){
 $name=$Window.Current.Name;$process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Window.Current.ProcessId) -ErrorAction SilentlyContinue
 if($name -eq 'Windows protected your PC' -or $name -like '*Microsoft Defender SmartScreen*' -or ($process -and $process.Name -ieq 'smartscreen.exe')){
  Add-Type -AssemblyName System.Drawing,System.Windows.Forms,UIAutomationClient
  $tree=@($Window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;class=$_.Current.ClassName;pid=$_.Current.ProcessId}})
  Write-HarnessResult $Directory 'smartscreen-tree.json' @{title=$name;hwnd=$Window.Current.NativeWindowHandle;controls=$tree}|Out-Null
  $rectangle=$Window.Current.BoundingRectangle;$path=Join-Path $Directory ('smartscreen-'+$script:Harness.Nonce+'.png')
  $file=[IO.FileStream]::new((Get-HarnessLongPath $path),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $bitmap=[Drawing.Bitmap]::new([int]$rectangle.Width,[int]$rectangle.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  try{$graphics.CopyFromScreen([int]$rectangle.X,[int]$rectangle.Y,0,0,$bitmap.Size);$bitmap.Save($file,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose();$file.Dispose()}
  Register-HarnessFile $path 'screenshot'|Out-Null
  throw 'SmartScreen shown; a tester presses More info -> Run anyway'
 }
}
function Assert-HarnessNewSmartScreen($Before,[string]$Directory){
 foreach($window in @([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition))){
  if($window.Current.NativeWindowHandle -notin $Before){Assert-HarnessSmartScreen $window $Directory}
 }
}
function New-HarnessText([string]$Path,[string]$Text,[string]$Purpose='',[string]$Lifetime='run'){
 $probe=[RooIndustriesValidationOwnership.ProbeFile]::Text((Get-HarnessLongPath $Path),$Text);$probe.Identity.path=(Get-HarnessPlainPath $Path)
 try{return Add-HarnessEntry 'file' $probe.Identity $Purpose $Lifetime}finally{$probe.Dispose()}
}
function Write-HarnessResult([string]$Directory,[string]$Name,$Value){
 $sequence=Invoke-HarnessLedger {param($ledger) @($ledger.entries|Where-Object {$_.nonce -ceq $script:Harness.Nonce -and $_.purpose -eq 'result'}).Count+1} -NoWrite
 $file=[IO.Path]::GetFileNameWithoutExtension($Name)+'-'+$script:Harness.Nonce+'-'+('{0:D4}' -f $sequence)+[IO.Path]::GetExtension($Name)
 $path=Join-Path $Directory $file
 $json=@{nonce=$script:Harness.Nonce;data=$Value}|ConvertTo-Json -Depth 60
 $entry=New-HarnessText $path $json 'result'
 Invoke-HarnessLedger {param($ledger) $e=@($ledger.entries|Where-Object id -CEQ $entry.id)[0];$e.metadata=[pscustomobject]@{name=$Name;directory=$Directory;scenario=$script:Harness.Scenario;sequence=$sequence}}|Out-Null
 return $path
}
function Read-HarnessResult([string]$Path,[string]$Nonce){
 $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.purpose -eq 'result' -and $_.identity.path -ieq $Path -and $_.nonce -ceq $Nonce -and $_.state -eq 'active'})
 if($entry.Count -ne 1){throw 'Result is not bound to the requested invocation nonce.'}
 $probe=[RooIndustriesValidationOwnership.ProbeFile]::Open((Get-HarnessLongPath $entry[0].identity.path),$entry[0].identity.id,$entry[0].identity.hash)
 try{$value=$probe.ReadText()|ConvertFrom-Json;if($value.nonce -cne $Nonce){throw 'Result content nonce differs.'};return $value.data}finally{$probe.Dispose()}
}
function Read-HarnessInputText([string]$Path){
 $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.identity.path -ieq $Path -and $_.state -eq 'active'})
 if($entry.Count -ne 1){throw 'Input file is not in this run creation ledger; retained.'}
 $probe=[RooIndustriesValidationOwnership.ProbeFile]::Open((Get-HarnessLongPath $entry[0].identity.path),$entry[0].identity.id,$entry[0].identity.hash)
 try{return $probe.ReadText()}finally{$probe.Dispose()}
}
function Read-HarnessLatestResult([string]$Name,[string]$Scenario='', [string]$Nonce=''){
 if(-not$Nonce -and $Scenario -ceq $script:Harness.Scenario -and @(Get-HarnessEntries|Where-Object {$_.nonce -ceq $script:Harness.Nonce -and $_.purpose -eq 'result' -and $_.metadata.name -ceq $Name}).Count){$Nonce=$script:Harness.Nonce}
 if(-not$Nonce){
  $invocation=Invoke-HarnessLedger {param($ledger) @($ledger.invocations|Where-Object {$_.scenario -ceq $Scenario -and $_.status -eq 'pass'})|Select-Object -Last 1} -NoWrite
  if(-not$invocation){throw 'Earlier scenario has no completed invocation in this frame.'};$Nonce=$invocation.nonce
 }
 $entry=@(Get-HarnessEntries|Where-Object {$_.nonce -ceq $Nonce -and $_.purpose -eq 'result' -and $_.metadata.name -ceq $Name}|Sort-Object {$_.metadata.sequence}|Select-Object -Last 1)
 if($entry.Count -ne 1){throw 'Invocation result is missing.'}
 return Read-HarnessResult $entry[0].identity.path $Nonce
}
function Remove-HarnessHostsLine([string]$Path,[string]$Line,[string]$Marker,[scriptblock]$WhileLocked){
 $stream=$null
 for($attempt=0;$attempt -lt 10;$attempt++){
  try{$stream=[IO.FileStream]::new((Get-HarnessLongPath $Path),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);break}
  catch [IO.IOException]{if(($_.Exception.HResult -band 0xffff) -notin 32,33 -or $attempt -eq 9){throw};Start-Sleep -Milliseconds 200}
 }
 try{
  $memory=[IO.MemoryStream]::new();$stream.CopyTo($memory);$encoding=[Text.Encoding]::GetEncoding(28591);$text=$encoding.GetString($memory.ToArray());$memory.Dispose()
  $owned="`r`n"+$Line+"`r`n"
  if($text.Split(@($Marker),[StringSplitOptions]::None).Count -ne 2 -or -not$text.Contains($owned)){throw 'Owned hosts marker was changed or removed; retain evidence.'}
  if($WhileLocked){& $WhileLocked}
  $bytes=$encoding.GetBytes($text.Replace($owned,''));$stream.Position=0;$stream.SetLength(0);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
 }finally{$stream.Dispose()}
}
function Remove-HarnessEntry($Entry){
 if($Entry.state -notin 'active','error'){return}
 try{
  switch($Entry.kind){
   'process'{
    if($Entry.metadata.platform -eq 'linux'){throw 'Linux process requires cleanup by its native-handle owner; retained.'}
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToFileTimeUtc()
    if([long]$Entry.identity.creationTimeFileTimeUtc -lt $boot -or -not(Get-Process -Id $Entry.identity.pid -ErrorAction SilentlyContinue)){Set-HarnessEntryState $Entry.id 'absent';return}
    Stop-OwnedProcessIdentity $Entry.identity
   }
   'task'{Remove-OwnedTask $Entry.identity}
   'window'{
    if([RooIndustriesHarnessWindow]::IsWindow([IntPtr]::new([long]$Entry.identity.hwnd))){[int]$owner=0;[RooIndustriesHarnessWindow]::GetWindowThreadProcessId([IntPtr]::new([long]$Entry.identity.hwnd),[ref]$owner)|Out-Null;if($owner -ne $Entry.identity.ownerPid){throw 'Window owner changed; retained.'};$held=Get-HarnessProcess $owner;if(-not$held){throw 'Window owner is no longer an owned process; retained.'};if($held.Identity.creationTimeFileTimeUtc -cne $Entry.identity.ownerCreationTime){throw 'Window process identity changed; retained.'}}
   }
   'file'{if([IO.File]::Exists((Get-HarnessLongPath $Entry.identity.path))){
    $identity=$Entry.identity
    if(-not$identity.id){
     $handle=[RooIndustriesValidationOwnership.Native]::CreateFile((Get-HarnessLongPath $identity.path),[uint32]2147483648,7,[IntPtr]::Zero,3,0x00200000,[IntPtr]::Zero)
     try{$id=[RooIndustriesValidationOwnership.Native]::FileId($handle)}finally{$handle.Dispose()}
     if($id.Split(':')[-1] -cne $identity.creationTimeFileTimeUtc){throw 'File creation identity changed; retained.'}
     $identity=@{path=$identity.path;id=$id;hash=$identity.hash}
    }
    $probe=[RooIndustriesValidationOwnership.ProbeFile]::Open((Get-HarnessLongPath $identity.path),$identity.id,$identity.hash);try{Remove-OwnedProbe $probe}finally{$probe.Dispose()}
   }}
   {$_ -in 'folder','cache'}{
    if(Test-HarnessPath $Entry.identity.path -PathType Container){
     if($Entry.metadata.reparseTarget){$item=Get-HarnessItem $Entry.identity.path -Force;if(-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.CreationTimeUtc.ToFileTimeUtc().ToString() -cne $Entry.identity.creationTimeFileTimeUtc -or @($item.Target).Count -ne 1 -or $item.Target[0] -ine $Entry.metadata.reparseTarget){throw 'Owned junction fixture identity changed; retained.'};[IO.Directory]::Delete((Get-HarnessLongPath $Entry.identity.path),$false)}
     elseif($Entry.metadata.emptyOnly){$actual=Get-HarnessFolderIdentity $Entry.identity.path;if($actual.creationTimeFileTimeUtc -cne $Entry.identity.creationTimeFileTimeUtc){throw 'Folder identity changed; retained.'};[IO.Directory]::Delete((Get-HarnessLongPath $Entry.identity.path),$false)}
     else{$actual=Get-HarnessFolderIdentity $Entry.identity.path;if($actual.creationTimeFileTimeUtc -cne $Entry.identity.creationTimeFileTimeUtc){throw 'Folder identity changed; retained.'};if(@(Get-HarnessEntries|Where-Object {$_.state -eq 'error' -and $_.identity.path -and $_.identity.path.StartsWith($Entry.identity.path+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Folder has a child with a failed cleanup identity; retained.'};Remove-HarnessDirectory $Entry.identity.path}
    }
   }
   'trace'{}
   'trace-refusal'{}
   'firewall'{$rule=Get-NetFirewallRule -Name $Entry.identity.name -ErrorAction SilentlyContinue;if($rule){if($rule.Description -cne $Entry.identity.nonce){throw 'Firewall ownership changed; retained.'};$rule|Remove-NetFirewallRule}}
   'hosts'{Remove-HarnessHostsLine $Entry.identity.path $Entry.identity.line $Entry.identity.marker; Invoke-HarnessProcess (Join-Path $env:SystemRoot 'System32\ipconfig.exe') '/flushdns' 'flush-dns'|Out-Null}
   'cert'{$path=$Entry.identity.store+'\'+$Entry.identity.thumbprint;if(Test-Path $path){$cert=Get-Item $path;if($cert.Subject -cne $Entry.identity.subject){throw 'Certificate identity changed; retained.'};Remove-Item -LiteralPath $path -DeleteKey}}
   default{throw 'Unknown ledger cleanup kind; retained.'}
  }
  Set-HarnessEntryState $Entry.id 'removed'
 }catch{Set-HarnessEntryState $Entry.id 'error' $_.Exception.Message;throw}
}
function Complete-HarnessInvocation([string]$Status,[switch]$Cleanup){
 $errors=[Collections.Generic.List[string]]::new()
 try{Stop-ProcessTrace}catch{$errors.Add($_.Exception.Message)}
 if($Cleanup){
  $entries=@(Get-HarnessEntries|Where-Object {$_.nonce -ceq $script:Harness.Nonce -and $_.lifetime -eq 'invocation' -and $_.state -in 'active','error'});[array]::Reverse($entries)
  foreach($entry in $entries){if($entry.kind -eq 'trace'){continue};try{Remove-HarnessEntry $entry}catch{$errors.Add($_.Exception.Message)}}
  $traceIds=@($entries|Where-Object kind -EQ 'trace'|ForEach-Object {$_.id})
  if($traceIds.Count){Invoke-HarnessLedger {param($ledger) foreach($id in $traceIds){(@($ledger.entries|Where-Object id -CEQ $id)[0]).state='removed'}}|Out-Null}
 }
 if($script:Harness.Trace){try{$script:Harness.Trace.Receiver.Dispose()}catch{$errors.Add($_.Exception.Message)}; $global:RooIndustriesHarnessTraces.Remove($script:Harness.FrameId+':'+$script:Harness.Nonce);$script:Harness.Trace=$null}
 $failed=@(Get-HarnessEntries|Where-Object {$_.nonce -ceq $script:Harness.Nonce -and $_.state -eq 'error'})
 $previous=Invoke-HarnessLedger {param($ledger) (@($ledger.invocations|Where-Object nonce -CEQ $script:Harness.Nonce)[0]).status} -NoWrite
 if($errors.Count -or $failed.Count -or $previous -eq 'fail'){$Status='fail'}
 Invoke-HarnessLedger {param($ledger) $i=@($ledger.invocations|Where-Object nonce -CEQ $script:Harness.Nonce)[0];$i.status=$Status;$i.cleanupErrors=@($i.cleanupErrors)+@($errors)}|Out-Null
 if($Status -eq 'fail' -and $errors.Count){throw ('Harness cleanup failed: '+($errors -join '; '))}
 return $Status
}
function Assert-HarnessFreshData([string]$ActiveRoot,$Before){
 $root=@($Before.dataRoots|Where-Object {$_.path -ieq $ActiveRoot})
 if($root.Count -ne 1 -or $root[0].exists){throw 'The active data root was present before this invocation or is unknown; retained.'}
}
function Register-HarnessCreatedData([string]$ActiveRoot,$Before){
 Assert-HarnessFreshData $ActiveRoot $Before
 if(Test-HarnessPath $ActiveRoot){
  $identity=Get-HarnessFolderIdentity $ActiveRoot
  $known=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.purpose -eq 'fresh-install-data' -and $_.identity.path -ieq $ActiveRoot -and $_.state -eq 'active'})
  if($known.Count){if($known.Count -ne 1 -or $known[0].identity.creationTimeFileTimeUtc -cne $identity.creationTimeFileTimeUtc){throw 'Fresh data root identity changed; retained.'};return $known[0]}
  return Add-HarnessEntry 'folder' $identity 'fresh-install-data' 'run'
 }
}
function Initialize-HarnessCache([string]$Updates,[string[]]$Versions){
 Invoke-HarnessLedger {param($ledger)
  if(-not$ledger.PSObject.Properties['cachePreflight']){
   $rows=@($Versions|ForEach-Object {@{version=$_;path=(Join-Path $Updates $_);absent=(-not(Test-HarnessPath (Join-Path $Updates $_)))}})
   if(@($rows|Where-Object {-not$_.absent}).Count){throw 'A foreign cache for A or B exists at run start; retained.'}
   $ledger|Add-Member cachePreflight ([pscustomobject]@{timeUtc=[DateTime]::UtcNow.ToString('o');versions=$rows})
  }elseif(@($Versions|Where-Object {$_ -notin $ledger.cachePreflight.versions.version}).Count){throw 'Cache preflight versions changed.'}
 }|Out-Null
}
function Register-HarnessCache([string]$Version){
 $before=Invoke-HarnessLedger {param($ledger) $ledger.cachePreflight} -NoWrite
 $row=@($before.versions|Where-Object version -CEQ $Version)
 if($row.Count -ne 1 -or -not$row[0].absent){throw 'Cache was not absent at run preflight; retained.'}
 $path=$row[0].path
 $owned=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'cache' -and $_.identity.path -ieq $path -and $_.state -eq 'active'})
 if($owned.Count -gt 1){throw 'Cache has ambiguous creation identities; retained.'}
 if(-not(Test-HarnessPath $path)){if($owned.Count){Set-HarnessEntryState $owned[0].id 'removed'};return $null}
 if($owned.Count){if((Get-HarnessFolderIdentity $path).creationTimeFileTimeUtc -cne $owned[0].identity.creationTimeFileTimeUtc){throw 'Cache identity changed; retained.'};return $owned[0]}
 if((Get-HarnessItem $path).CreationTimeUtc -lt [DateTime]::Parse($before.timeUtc).ToUniversalTime()){throw 'Cache predates this run; retained.'}
 return Add-HarnessEntry 'cache' (Get-HarnessFolderIdentity $path) 'update-cache' 'run' @{version=$Version;preflightAbsent=$true}
}
function Test-HarnessEncodedReference([string]$Image,[string]$CommandLine,[string]$Frame){
 if([IO.Path]::GetFileName($Image) -inotmatch '^(powershell|pwsh)\.exe$'){return $false}
 $arguments=@([regex]::Matches($CommandLine,'"([^"]*)"|(\S+)')|ForEach-Object {if($_.Groups[1].Success){$_.Groups[1].Value}else{$_.Groups[2].Value}})
 for($i=0;$i -lt $arguments.Count;$i++){
  if($arguments[$i] -notmatch '^(?:--?|/)([A-Za-z]+)$'){continue}
  $name=$Matches[1].ToLowerInvariant()
  $encoded=($name -in @('e','ec')) -or ($name.Length -ge 2 -and 'encodedcommand'.StartsWith($name)) -or ($name.Length -ge 8 -and 'encodedarguments'.StartsWith($name))
  if(-not$encoded){continue}
  if($i+1 -ge $arguments.Count){return $true}
  try{$bytes=[Convert]::FromBase64String($arguments[++$i]);if($bytes.Length % 2){return $true};$text=[Text.UnicodeEncoding]::new($false,$false,$true).GetString($bytes)}catch{return $true}
  if($text.IndexOf($Frame,[StringComparison]::OrdinalIgnoreCase) -ge 0){return $true}
 }
 return $false
}
function Assert-HarnessFrameIdle([string]$Frame){
 foreach($process in @(Get-CimInstance Win32_Process)){
  if(($process.ExecutablePath -and $process.ExecutablePath.StartsWith($Frame+'\',[StringComparison]::OrdinalIgnoreCase)) -or ($process.CommandLine -and $process.CommandLine.IndexOf($Frame,[StringComparison]::OrdinalIgnoreCase) -ge 0)){throw 'Update frame still has running processes; retained'}
  if(Test-HarnessEncodedReference $process.Name $process.CommandLine $Frame){throw 'Encoded PowerShell runner references the frame or cannot be inspected; retained.'}
 }
 foreach($entry in @(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.state -eq 'active'})){if(Get-HarnessProcess ([int]$entry.identity.pid)){throw 'A recorded runner child for this frame is still live; retained.'}}
}
function Assert-ShippedFreshApp($Process,[DateTime]$After){if($Process.StartTime.ToUniversalTime() -lt $After){throw 'App instance predates this owned launch; retained.'}}
function Assert-ShippedNoApp([string]$Image){Assert-NoForeignInstance $Image}
function Get-ShippedFixture([string]$Path,[DateTime]$After){
 $matches=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $Path})
 if($matches.Count -ne 1){throw 'Saved-rule fixture identity is ambiguous or missing; retained.'};$match=$matches[0]
 if($match.CreationDate.ToUniversalTime() -lt $After){throw 'Saved-rule fixture predates the Explorer launch; retained.'}
 $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$match.ParentProcessId)
 if(-not$parent -or [IO.Path]::GetFileName($parent.ExecutablePath) -ine 'explorer.exe' -or $parent.CreationDate -gt $match.CreationDate){throw 'Fixture was not launched by desktop Explorer.'}
 return $match
}
function Move-ShippedFreshData([string]$ActiveRoot,$Before,[string]$Destination){
 Assert-HarnessFreshData $ActiveRoot $Before
 $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.purpose -eq 'fresh-install-data' -and $_.identity.path -ieq $ActiveRoot -and $_.state -eq 'active'})
 if($entry.Count -ne 1){throw 'Data root is not in this invocation creation ledger; retained.'}
 $actual=Get-HarnessFolderIdentity $ActiveRoot;if($actual.creationTimeFileTimeUtc -cne $entry[0].identity.creationTimeFileTimeUtc){throw 'Data root identity changed; retained.'}
 if(Test-HarnessPath $Destination){throw 'Data archive exists; retained.'}
 @(Get-HarnessTree $ActiveRoot)|Out-Null
 [IO.Directory]::Move((Get-HarnessLongPath $ActiveRoot),(Get-HarnessLongPath $Destination));Set-HarnessEntryState $entry[0].id 'removed';Add-HarnessEntry 'folder' (Get-HarnessFolderIdentity $Destination) 'data-archive' 'run'|Out-Null
}
function New-ShippedFirewall([string]$Name,[string]$Nonce,[string]$Image){
 if(Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue){throw 'Offline rule already exists; retained.'}
 New-NetFirewallRule -Name $Name -DisplayName $Name -Description $Nonce -Direction Outbound -Action Block -Program $Image -Enabled True|Out-Null
 Add-HarnessEntry 'firewall' @{name=$Name;nonce=$Nonce} 'offline'|Out-Null
}
function Remove-ShippedFirewall([string]$Name,[string]$Nonce,[bool]$Created){
 if(-not$Created){return};$entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'firewall' -and $_.identity.name -ceq $Name -and $_.identity.nonce -ceq $Nonce -and $_.state -eq 'active'})
 if($entry.Count -ne 1){throw 'Firewall rule is not in this creation ledger; retained.'};Remove-HarnessEntry $entry[0]
}
function Get-ShippedLogCursor([string]$Path){$text=if(Test-HarnessPath $Path){[IO.File]::ReadAllText((Get-HarnessLongPath $Path))}else{''};return @{path=$Path;prefix=$text;length=$text.Length}}
function Read-ShippedLog($Cursor){
 $text=if(Test-HarnessPath $Cursor.path){[IO.File]::ReadAllText((Get-HarnessLongPath $Cursor.path))}else{''}
 if($text.Length -ge $Cursor.length -and $text.StartsWith($Cursor.prefix,[StringComparison]::Ordinal)){return $text.Substring($Cursor.length)}
 $old=if(Test-HarnessPath ($Cursor.path+'.old')){[IO.File]::ReadAllText((Get-HarnessLongPath ($Cursor.path+'.old')))}else{''}
 if($Cursor.length -and -not$old.StartsWith($Cursor.prefix,[StringComparison]::Ordinal)){throw 'App-log history rotated more than once; keep evidence and rerun in a fresh window.'};return $old.Substring($Cursor.length)+$text
}
function Test-ShippedRequestTimeout([string]$Text,[double]$Seconds){return $Text -ceq "Couldn't check for updates. The request timed out." -and $Seconds -ge 18 -and $Seconds -le 30}
function Test-ShippedGovernorReplacement($Before,$After){return $Before -and $After -and $After.pid -ne $Before.pid -and $After.creationTimeUtc -ne $Before.creationTimeUtc}
function Get-ShippedFinalStatus([string]$Status,$CleanupErrors){if(@($CleanupErrors).Count){return 'fail'};return $Status}
function Remove-ShippedHostsLine([string]$Path,[string]$Line,[string]$Marker){Remove-HarnessHostsLine $Path $Line $Marker}

function Ensure-HarnessOutputDirectory([string]$Path){
 $full=(Get-HarnessPlainPath $Path)
 if(-not$full.StartsWith($script:Harness.Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Harness output is outside its verified frame.'}
 if(-not(Test-HarnessPath $full)){New-HarnessDirectory $full 'harness-output'|Out-Null;return}
 $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.state -eq 'active' -and $_.identity.path -ieq $full})
 if($entries.Count -ne 1){throw 'Existing output folder is not in this frame creation ledger.'}
 $actual=Get-HarnessFolderIdentity $full
 if($actual.creationTimeFileTimeUtc -cne $entries[0].identity.creationTimeFileTimeUtc){throw 'Output folder identity changed; retained.'}
}
function Get-HarnessOutputPath([string]$Directory,[string]$Name){
 $path=Join-Path $Directory ([IO.Path]::GetFileNameWithoutExtension($Name)+'-'+$script:Harness.Nonce+'-'+[Guid]::NewGuid().ToString('N')+[IO.Path]::GetExtension($Name))
 if(Test-HarnessPath $path){throw 'Invocation output already exists; retained.'};return $path
}
function Receive-HarnessResults([string]$Scenario,[string]$Name){Read-HarnessLatestResult $Name $Scenario}
function Invoke-HarnessProcess([string]$File,[string]$Arguments,[string]$Purpose='command'){
 $start=[Diagnostics.ProcessStartInfo]::new($File);$start.Arguments=$Arguments;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $owned=Start-OwnedProcess -StartInfo $start -Purpose $Purpose
 $process=$owned.process;$read=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
 if(-not$process.WaitForExit(2400000)){Stop-HarnessProcess $owned;throw ($Purpose+' timed out')}
 $text=$read.GetAwaiter().GetResult();$errorText=$errors.GetAwaiter().GetResult()
 New-HarnessText (Get-HarnessOutputPath $script:Harness.Root ($Purpose+'-stdout.log')) $text 'command-output'|Out-Null
 New-HarnessText (Get-HarnessOutputPath $script:Harness.Root ($Purpose+'-stderr.log')) $errorText 'command-output'|Out-Null
 if($process.ExitCode -ne 0){throw ($Purpose+' failed: '+$text+$errorText)}
 return $text
}

function Get-HarnessMachineSnapshot{
 . (Get-HarnessToolPath (Join-Path $PSScriptRoot '..\..\..\backend\scripts\BrandCompatibility.Common.ps1'))
 $local=Get-RooIndustriesLocalAppData
 $install=Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite'
 $key='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'
 $roots=@(foreach($name in 'RooOptimizationSuite','RooIndustriesOptimizationSuite'){
  $path=Join-Path $local $name
  $files=@(if(Test-HarnessPath $path){Get-HarnessTree $path -FilesOnly|ForEach-Object {@{path=$_.FullName;bytes=$_.Length;sha256=(Get-HarnessFileSha256 $_.LongPath)}}})
  @{path=$path;exists=(Test-HarnessPath $path);files=$files}
 })
 $tasks=@(Get-ScheduledTask|ForEach-Object {@{name=$_.TaskName;path=$_.TaskPath;state=[string]$_.State;enabled=$_.Settings.Enabled;xml=(Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath)}})
 @{takenAtUtc=[DateTime]::UtcNow.ToString('o');installedVersion=if(Test-HarnessPath $key){(Get-ItemProperty $key).DisplayVersion}else{$null};installDirectory=@{path=$install;exists=(Test-HarnessPath $install)};dataRoots=$roots;tasks=$tasks}
}
function Add-HarnessHostsLine([string]$Path,[string]$Line,[string]$Marker){
 $stream=[IO.FileStream]::new((Get-HarnessLongPath $Path),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::GetEncoding(28591),$false,4096,$true);try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()};if($text.Contains($Marker)){throw 'Hosts marker already exists; retained.'};$bytes=[Text.Encoding]::GetEncoding(28591).GetBytes("`r`n"+$Line+"`r`n");$stream.Position=$stream.Length;$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);Add-HarnessEntry 'hosts' @{path=$Path;line=$Line;marker=$Marker} 'offline-hosts'|Out-Null}finally{$stream.Dispose()}
}
function Invoke-HarnessHost([string]$File,[string]$Action,$Request){
 $start=[Diagnostics.ProcessStartInfo]::new($File);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.Arguments=$Action+' -'
 $owned=Start-OwnedProcess -StartInfo $start -Purpose backend
 $process=$owned.process;$read=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
 $process.StandardInput.WriteLine(($Request|ConvertTo-Json -Depth 40 -Compress));$process.StandardInput.Close();if(-not$process.WaitForExit(120000)){Stop-HarnessProcess $owned;throw 'Backend request timed out'}
 $raw=$read.GetAwaiter().GetResult();$errorText=$errors.GetAwaiter().GetResult();if($process.ExitCode -ne 0){throw ($Action+': '+$raw+$errorText)};return $raw|ConvertFrom-Json
}

function Initialize-HarnessBuildFolders([string]$Base){
 foreach($project in @(Get-HarnessTree $Base -FilesOnly|Where-Object {(Test-HarnessVisiblePath $_ $Base) -and [IO.Path]::GetExtension($_.FullName) -ieq '.csproj' -and $_.FullName.Substring($Base.Length) -notmatch '(^|\\)(bin|obj)(\\|$)'})){
  foreach($name in 'bin','obj'){
   $path=Join-Path ([IO.Path]::GetDirectoryName($project.FullName)) $name
   if(-not[IO.Directory]::Exists((Get-HarnessLongPath $path))){New-HarnessDirectory $path 'generated-build'|Out-Null;continue}
   $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -ieq $path -and $_.state -eq 'active'})
   if($entries.Count -ne 1 -or (Get-HarnessFolderIdentity $path).creationTimeFileTimeUtc -cne $entries[0].identity.creationTimeFileTimeUtc){throw 'An existing build folder is not owned by this run; retained.'}
  }
 }
}

function Remove-HarnessDirectory([string]$Path){
 $items=@(Get-HarnessTree $Path)
 foreach($file in @($items|Where-Object {-not$_.IsDirectory})){
  if($file.Attributes -band [IO.FileAttributes]::ReadOnly){[IO.File]::SetAttributes($file.LongPath,($file.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))}
  [IO.File]::Delete($file.LongPath)
 }
 foreach($folder in @($items|Where-Object IsDirectory|Sort-Object {$_.FullName.Length} -Descending)){[IO.Directory]::Delete($folder.LongPath,$false)}
 [IO.Directory]::Delete((Get-HarnessLongPath $Path),$false)
}
function New-HarnessArchive([string]$Root,[string]$Destination,[scriptblock]$Include){
 Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
 $items=@(Get-HarnessTree $Root -FilesOnly)
 $file=[IO.FileStream]::new((Get-HarnessLongPath $Destination),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 $zip=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Create)
 try{
  foreach($item in $items){
   if($item.FullName -ieq $Destination){continue}
   $relative=$item.FullName.Substring($Root.TrimEnd('\').Length+1)
   if($Include -and -not(& $Include $item $relative)){continue}
   [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$item.LongPath,$relative.Replace('\','/'))|Out-Null
  }
 }finally{$zip.Dispose();$file.Dispose()}
 Register-HarnessFile $Destination 'evidence-archive'|Out-Null
 return $Destination
}
