. (Join-Path $PSScriptRoot '..\LoadTimes\CleanupOwnership.Common.ps1')
if(-not ('RooHarnessWindow' -as [type])){
 Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RooHarnessWindow {
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
function Get-HarnessFolderIdentity([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force
 if(-not$item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned folder identity is not a plain directory.'}
 @{path=$item.FullName;creationTimeFileTimeUtc=$item.CreationTimeUtc.ToFileTimeUtc().ToString()}
}
function Invoke-HarnessLedger([scriptblock]$Action){
 if(-not$script:Harness){throw 'Harness invocation has no verified frame scope.'}
 $stream=$null
 for($attempt=0;$attempt -lt 10;$attempt++){
  try{$stream=[IO.FileStream]::new($script:Harness.LedgerPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);break}
  catch [IO.IOException]{if($attempt -eq 9){throw};Start-Sleep -Milliseconds 200}
 }
 try{
  $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$true,4096,$true)
  try{$ledger=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
  if($ledger.frameId -cne $script:Harness.FrameId -or $ledger.manifestSha256 -cne $script:Harness.Manifest -or $ledger.machine -cne $env:COMPUTERNAME){throw 'Harness ledger scope changed; retained.'}
  $result=& $Action $ledger
  if(-not$script:Harness.ReadOnly){
   $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($ledger|ConvertTo-Json -Depth 60))
   $stream.Position=0;$stream.SetLength(0);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
  }
  return $result
 }finally{$stream.Dispose()}
}
function Open-HarnessRun([string]$FrameRoot,[string]$FrameId,[string]$ManifestSha256,[string]$Nonce,[switch]$ReadOnly){
 $root=[IO.Path]::GetFullPath($FrameRoot).TrimEnd('\')
 if($root -notmatch '^C:\\RooBuild\\roo-industries-[A-Za-z0-9_-]+-[a-f0-9]{32}$' -or $FrameId -cne $root.Substring($root.Length-32)){throw 'Harness frame scope differs.'}
 $script:Harness=@{Root=$root;FrameId=$FrameId;Manifest=$ManifestSha256;Nonce=$Nonce;LedgerPath=(Join-Path $root 'ledger.json');ReadOnly=[bool]$ReadOnly;Handles=@{};Scenario='';Scope=''}
 if(-not(Test-Path $script:Harness.LedgerPath -PathType Leaf)){throw 'Frame has no creation ledger; stage a fresh frame.'}
 Invoke-HarnessLedger {param($ledger) $null}|Out-Null
}
function Initialize-HarnessInvocation([string]$Scenario,[string]$Scope){
 if(-not$global:RooVerificationInvocationContext -or -not$global:RooVerificationInvocationContext.frame){throw 'A verified windows_ssh interactive invocation is required.'}
 $context=$global:RooVerificationInvocationContext;$frame=$context.frame
 if(-not$script:Harness -or $script:Harness.Nonce -cne $context.nonce){Open-HarnessRun $frame.runRoot $frame.frameId $frame.manifestSha256 $context.nonce}
 $script:Harness.Scenario=$Scenario;$script:Harness.Scope=$Scope
 Invoke-HarnessLedger {param($ledger)
  if(@($ledger.invocations|Where-Object nonce -CEQ $context.nonce).Count){$i=@($ledger.invocations|Where-Object nonce -CEQ $context.nonce)[0];if($i.scenario -like 'Invoke-*'){$i.scenario=$Scenario;$i.scope=$Scope}}else{$ledger.invocations=@($ledger.invocations)+@([pscustomobject]@{nonce=$context.nonce;scenario=$Scenario;scope=$Scope;startedAtUtc=[DateTime]::UtcNow.ToString('o');status='running';cleanupErrors=@()})}
 }|Out-Null
 $known=Get-HarnessProcess $PID
 if(-not$known){throw 'Interactive child was not recorded immediately after creation.'}
 $script:Harness.Handles[$PID]=$known
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
function Get-HarnessEntries{Invoke-HarnessLedger {param($ledger) @($ledger.entries)}}
function Set-HarnessEntryState([string]$Id,[string]$State,[string]$Error=''){
 Invoke-HarnessLedger {param($ledger) $entry=@($ledger.entries|Where-Object id -CEQ $Id);if($entry.Count -ne 1){throw 'Ledger entry is missing or ambiguous.'};$entry[0].state=$State;$entry[0].cleanupError=$Error}|Out-Null
}
function Get-HarnessProcess([int]$ProcessId){
 Receive-HarnessDescendants
 $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.metadata.platform -ne 'linux' -and $_.identity.pid -eq $ProcessId -and $_.state -eq 'active'})
 foreach($entry in $entries){
  $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if(-not$process){continue}
  $receipt=New-OwnedProcess $process
  if($receipt -and $receipt.Identity.creationTimeFileTimeUtc -ceq $entry.identity.creationTimeFileTimeUtc -and $receipt.Identity.imagePath -ieq $entry.identity.imagePath){$receipt|Add-Member LedgerId $entry.id;$receipt|Add-Member Nonce $entry.nonce;return $receipt}
  $process.Dispose()
 }
 return $null
}
function Start-HarnessDescendantTracker($Root){
 $known=Get-HarnessProcess ([int]$Root.Identity.pid)
 if(-not$known -or $known.Identity.creationTimeFileTimeUtc -cne $Root.Identity.creationTimeFileTimeUtc -or $known.Identity.imagePath -ine $Root.Identity.imagePath){throw 'Tracking root is not in this creation ledger; retained.'}
 if(-not('RooHarnessProcesses' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'HarnessProcesses.cs') -ReferencedAssemblies System.dll,System.Core.dll,System.Web.Extensions.dll}
 if(-not$script:Harness.Trackers){$script:Harness.Trackers=[Collections.Generic.List[object]]::new()}
 $tracker=[RooHarnessProcesses]::new([int]$Root.Identity.pid,[long]$Root.Identity.creationTimeFileTimeUtc,$Root.Identity.imagePath,$script:Harness.LedgerPath,$script:Harness.FrameId,$script:Harness.Manifest,$script:Harness.Nonce,$env:COMPUTERNAME)
 $script:Harness.Trackers.Add($tracker)
 return $tracker
}
function Receive-HarnessDescendants{
 foreach($tracker in @($script:Harness.Trackers|Where-Object {$null -ne $_})){
  if($tracker.Error){throw ('Owned process tracking failed: '+$tracker.Error)}
  foreach($held in $tracker.Entries()){
   if(-not$script:Harness.Handles.ContainsKey($held.Pid)){$script:Harness.Handles[$held.Pid]=[pscustomobject]@{process=$held.Process;handle=$held.Handle;Identity=[pscustomobject]@{pid=$held.Pid;creationTimeFileTimeUtc=$held.Created.ToString();imagePath=$held.Image};LedgerId=$held.LedgerId;Nonce=$script:Harness.Nonce}}
  }
 }
}
function Stop-HarnessDescendantTrackers{
 foreach($tracker in @($script:Harness.Trackers|Where-Object {$null -ne $_})){$tracker.Stop()}
 Receive-HarnessDescendants
}
function Register-HarnessStartedProcess($Process,[string]$Purpose='',[string]$Lifetime='invocation'){
 $handle=$Process.Handle
 $receipt=[pscustomobject]@{process=$Process;handle=$handle;Identity=[pscustomobject]@{pid=$Process.Id;creationTimeFileTimeUtc=[RooValidationOwnership.Native]::Created($handle).ToString();imagePath=[RooValidationOwnership.Native]::Image($handle)}}
 $entry=Add-HarnessEntry 'process' $receipt.Identity $Purpose $Lifetime
 $receipt|Add-Member LedgerId $entry.id;$receipt|Add-Member Nonce $script:Harness.Nonce
 $script:Harness.Handles[[int]$receipt.Identity.pid]=$receipt
 return $receipt
}
function Start-OwnedProcess([string]$FilePath,[string]$ArgumentList='',[string]$WindowStyle='Hidden',[string]$Purpose='',[string]$Lifetime='invocation',[Diagnostics.ProcessStartInfo]$StartInfo){
 if($StartInfo -and $StartInfo.UseShellExecute){throw 'Run ShellExecute in a separate owned launcher so its dialogs cannot block the harness.'}
 if($StartInfo){$process=[Diagnostics.Process]::Start($StartInfo)}else{
  $arguments=@{FilePath=$FilePath;WindowStyle=$WindowStyle;PassThru=$true}
  if(-not[string]::IsNullOrEmpty($ArgumentList)){$arguments.ArgumentList=$ArgumentList}
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
  [int]$owner=0;[RooHarnessWindow]::GetWindowThreadProcessId([IntPtr]::new($hwnd),[ref]$owner)|Out-Null
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
  $broker.dispatch.ShellExecute($Image,$Arguments,(Split-Path $Image -Parent),'open',0)
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
 Receive-HarnessDescendants
 if($Ancestor){
  $ancestorId=[int]$Ancestor.Identity.pid;$seen=@{};$childTime=$null;$cursor=$ProcessId;$reached=$false
  for($hop=0;$hop -lt 32;$hop++){
   if($cursor -le 4 -or $seen.ContainsKey($cursor)){return $false};$seen[$cursor]=$true
   $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$cursor) -ErrorAction SilentlyContinue
   if(-not$cim -or -not$cim.CreationDate){return $false}
   $created=$cim.CreationDate.ToUniversalTime().ToFileTimeUtc()
   if($childTime -and $created -gt $childTime){return $false}
   if($cursor -eq $ancestorId){
    if([RooValidationOwnership.Native]::Created($Ancestor.handle).ToString() -cne $Ancestor.Identity.creationTimeFileTimeUtc -or [Math]::Abs([long]$Ancestor.Identity.creationTimeFileTimeUtc-$created) -gt 10){return $false}
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
   if([RooValidationOwnership.Native]::Created($held.handle).ToString() -cne $held.Identity.creationTimeFileTimeUtc){return $false}
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
 foreach($receipt in $receipts){$entry=Add-HarnessEntry 'process' $receipt.Identity 'descendant';$receipt|Add-Member LedgerId $entry.id;$receipt|Add-Member Nonce $script:Harness.Nonce;$script:Harness.Handles[[int]$receipt.Identity.pid]=$receipt}
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
 $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
 if(Test-Path -LiteralPath $full){throw 'Directory exists before this creation; retained.'}
 $missing=[Collections.Generic.Stack[string]]::new();$parent=$full
 while(-not(Test-Path -LiteralPath $parent)){$missing.Push($parent);$parent=[IO.Path]::GetDirectoryName($parent);if(-not$parent){throw 'Directory has no existing ancestor.'}}
 Get-HarnessFolderIdentity $parent|Out-Null
 $leaf=$null
 while($missing.Count){
  $next=$missing.Pop();[RooHarnessWindow]::CreateDirectory($next)
  $entry=Add-HarnessEntry 'folder' (Get-HarnessFolderIdentity $next) $Purpose $Lifetime $(if($next -ine $full){@{emptyOnly=$true}}else{$null})
  if($next -ieq $full){$leaf=$entry}
 }
 return $leaf
}
function Register-HarnessFile([string]$Path,[string]$Purpose='',[string]$Lifetime='run',$Metadata=$null){
 $handle=[RooValidationOwnership.Native]::CreateFile($Path,[uint32]2147483648,7,[IntPtr]::Zero,3,0x00200000,[IntPtr]::Zero)
 try{$id=[RooValidationOwnership.Native]::FileId($handle)}finally{$handle.Dispose()}
 $probe=[RooValidationOwnership.ProbeFile]::Open($Path,$id,(Get-FileHash -LiteralPath $Path).Hash)
 try{return Add-HarnessEntry 'file' $probe.Identity $Purpose $Lifetime $Metadata}finally{$probe.Dispose()}
}
function New-HarnessEvidenceDirectory([string]$OutRoot,[string]$Name){
 if(-not$script:Harness){throw 'Evidence directory requires a verified invocation.'}
 $path=Join-Path $OutRoot ($Name+'-'+$script:Harness.Nonce)
 New-HarnessDirectory $path 'evidence' 'run'|Out-Null
 return $path
}
function Copy-HarnessFile([string]$Source,[string]$Destination,[string]$Purpose='fixture',[string]$Lifetime='run'){
 $probe=[RooValidationOwnership.ProbeFile]::Copy($Source,$Destination)
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
  $file=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
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
 $probe=New-OwnedTextFile $Path $Text
 try{return Add-HarnessEntry 'file' $probe.Identity $Purpose $Lifetime}finally{$probe.Dispose()}
}
function Write-HarnessResult([string]$Directory,[string]$Name,$Value){
 $sequence=Invoke-HarnessLedger {param($ledger) @($ledger.entries|Where-Object {$_.nonce -ceq $script:Harness.Nonce -and $_.purpose -eq 'result'}).Count+1}
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
 $probe=Open-OwnedProbe $entry[0].identity
 try{$value=$probe.ReadText()|ConvertFrom-Json;if($value.nonce -cne $Nonce){throw 'Result content nonce differs.'};return $value.data}finally{$probe.Dispose()}
}
function Read-HarnessInputText([string]$Path){
 $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.identity.path -ieq $Path -and $_.state -eq 'active'})
 if($entry.Count -ne 1){throw 'Input file is not in this run creation ledger; retained.'}
 $probe=Open-OwnedProbe $entry[0].identity
 try{return $probe.ReadText()}finally{$probe.Dispose()}
}
function Read-HarnessLatestResult([string]$Name,[string]$Scenario='', [string]$Nonce=''){
 if(-not$Nonce -and $Scenario -ceq $script:Harness.Scenario -and @(Get-HarnessEntries|Where-Object {$_.nonce -ceq $script:Harness.Nonce -and $_.purpose -eq 'result' -and $_.metadata.name -ceq $Name}).Count){$Nonce=$script:Harness.Nonce}
 if(-not$Nonce){
  $invocation=Invoke-HarnessLedger {param($ledger) @($ledger.invocations|Where-Object {$_.scenario -ceq $Scenario -and $_.status -eq 'pass'})|Select-Object -Last 1}
  if(-not$invocation){throw 'Earlier scenario has no completed invocation in this frame.'};$Nonce=$invocation.nonce
 }
 $entry=@(Get-HarnessEntries|Where-Object {$_.nonce -ceq $Nonce -and $_.purpose -eq 'result' -and $_.metadata.name -ceq $Name}|Sort-Object {$_.metadata.sequence}|Select-Object -Last 1)
 if($entry.Count -ne 1){throw 'Invocation result is missing.'}
 return Read-HarnessResult $entry[0].identity.path $Nonce
}
function Remove-HarnessHostsLine([string]$Path,[string]$Line,[string]$Marker,[scriptblock]$WhileLocked){
 $stream=$null
 for($attempt=0;$attempt -lt 10;$attempt++){
  try{$stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);break}
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
 if($Entry.state -ne 'active'){return}
 try{
  switch($Entry.kind){
   'process'{if($Entry.metadata.platform -eq 'linux'){throw 'Linux process requires cleanup by its native-handle owner; retained.'};Stop-OwnedProcessIdentity $Entry.identity}
   'task'{Remove-OwnedTask $Entry.identity}
   'window'{
    if([RooHarnessWindow]::IsWindow([IntPtr]::new([long]$Entry.identity.hwnd))){[int]$owner=0;[RooHarnessWindow]::GetWindowThreadProcessId([IntPtr]::new([long]$Entry.identity.hwnd),[ref]$owner)|Out-Null;if($owner -ne $Entry.identity.ownerPid){throw 'Window owner changed; retained.'};$held=Get-HarnessProcess $owner;if(-not$held){throw 'Window owner is no longer an owned process; retained.'};if($held.Identity.creationTimeFileTimeUtc -cne $Entry.identity.ownerCreationTime){throw 'Window process identity changed; retained.'}}
   }
   'file'{if(Test-Path -LiteralPath $Entry.identity.path){
    $identity=$Entry.identity
    if(-not$identity.id){
     $handle=[RooValidationOwnership.Native]::CreateFile($identity.path,[uint32]2147483648,7,[IntPtr]::Zero,3,0x00200000,[IntPtr]::Zero)
     try{$id=[RooValidationOwnership.Native]::FileId($handle)}finally{$handle.Dispose()}
     if($id.Split(':')[-1] -cne $identity.creationTimeFileTimeUtc){throw 'File creation identity changed; retained.'}
     $identity=@{path=$identity.path;id=$id;hash=$identity.hash}
    }
    $probe=Open-OwnedProbe $identity;try{Remove-OwnedProbe $probe}finally{$probe.Dispose()}
   }}
   {$_ -in 'folder','cache'}{
    if(Test-Path -LiteralPath $Entry.identity.path){
     if($Entry.metadata.reparseTarget){$item=Get-Item -LiteralPath $Entry.identity.path -Force;if(-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.CreationTimeUtc.ToFileTimeUtc().ToString() -cne $Entry.identity.creationTimeFileTimeUtc -or @($item.Target).Count -ne 1 -or $item.Target[0] -ine $Entry.metadata.reparseTarget){throw 'Owned junction fixture identity changed; retained.'};[IO.Directory]::Delete($Entry.identity.path,$false)}
     elseif($Entry.metadata.emptyOnly){$actual=Get-HarnessFolderIdentity $Entry.identity.path;if($actual.creationTimeFileTimeUtc -cne $Entry.identity.creationTimeFileTimeUtc){throw 'Folder identity changed; retained.'};[IO.Directory]::Delete($Entry.identity.path,$false)}
     else{$actual=Get-HarnessFolderIdentity $Entry.identity.path;if($actual.creationTimeFileTimeUtc -cne $Entry.identity.creationTimeFileTimeUtc){throw 'Folder identity changed; retained.'};if(@(Get-HarnessEntries|Where-Object {$_.state -eq 'error' -and $_.identity.path -and $_.identity.path.StartsWith($Entry.identity.path+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Folder has a child with a failed cleanup identity; retained.'};Remove-HarnessDirectory $Entry.identity.path}
    }
   }
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
 try{Stop-HarnessDescendantTrackers}catch{$errors.Add($_.Exception.Message)}
 if($Cleanup){$entries=@(Get-HarnessEntries|Where-Object {$_.nonce -ceq $script:Harness.Nonce -and $_.lifetime -eq 'invocation' -and $_.state -eq 'active'});[array]::Reverse($entries);foreach($entry in $entries){try{Remove-HarnessEntry $entry}catch{$errors.Add($_.Exception.Message)}}}
 foreach($tracker in @($script:Harness.Trackers|Where-Object {$null -ne $_})){try{$tracker.Dispose()}catch{$errors.Add($_.Exception.Message)}}
 $script:Harness.Trackers=$null
 $failed=@(Get-HarnessEntries|Where-Object {$_.nonce -ceq $script:Harness.Nonce -and $_.state -eq 'error'})
 $previous=Invoke-HarnessLedger {param($ledger) (@($ledger.invocations|Where-Object nonce -CEQ $script:Harness.Nonce)[0]).status}
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
 if(Test-Path $ActiveRoot){
  $identity=Get-HarnessFolderIdentity $ActiveRoot
  $known=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.purpose -eq 'fresh-install-data' -and $_.identity.path -ieq $ActiveRoot -and $_.state -eq 'active'})
  if($known.Count){if($known.Count -ne 1 -or $known[0].identity.creationTimeFileTimeUtc -cne $identity.creationTimeFileTimeUtc){throw 'Fresh data root identity changed; retained.'};return $known[0]}
  return Add-HarnessEntry 'folder' $identity 'fresh-install-data' 'run'
 }
}
function Initialize-HarnessCache([string]$Updates,[string[]]$Versions){
 Invoke-HarnessLedger {param($ledger)
  if(-not$ledger.PSObject.Properties['cachePreflight']){
   $rows=@($Versions|ForEach-Object {@{version=$_;path=(Join-Path $Updates $_);absent=(-not(Test-Path (Join-Path $Updates $_)))}})
   if(@($rows|Where-Object {-not$_.absent}).Count){throw 'A foreign cache for A or B exists at run start; retained.'}
   $ledger|Add-Member cachePreflight ([pscustomobject]@{timeUtc=[DateTime]::UtcNow.ToString('o');versions=$rows})
  }elseif(@($Versions|Where-Object {$_ -notin $ledger.cachePreflight.versions.version}).Count){throw 'Cache preflight versions changed.'}
 }|Out-Null
}
function Register-HarnessCache([string]$Version){
 $before=Invoke-HarnessLedger {param($ledger) $ledger.cachePreflight}
 $row=@($before.versions|Where-Object version -CEQ $Version)
 if($row.Count -ne 1 -or -not$row[0].absent){throw 'Cache was not absent at run preflight; retained.'}
 $path=$row[0].path
 $owned=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'cache' -and $_.identity.path -ieq $path -and $_.state -eq 'active'})
 if($owned.Count -gt 1){throw 'Cache has ambiguous creation identities; retained.'}
 if(-not(Test-Path $path)){if($owned.Count){Set-HarnessEntryState $owned[0].id 'removed'};return $null}
 if($owned.Count){if((Get-HarnessFolderIdentity $path).creationTimeFileTimeUtc -cne $owned[0].identity.creationTimeFileTimeUtc){throw 'Cache identity changed; retained.'};return $owned[0]}
 if((Get-Item $path).CreationTimeUtc -lt [DateTime]::Parse($before.timeUtc).ToUniversalTime()){throw 'Cache predates this run; retained.'}
 return Add-HarnessEntry 'cache' (Get-HarnessFolderIdentity $path) 'update-cache' 'run' @{version=$Version;preflightAbsent=$true}
}
function Assert-HarnessFrameIdle([string]$Frame){
 foreach($process in @(Get-CimInstance Win32_Process)){
  if(($process.ExecutablePath -and $process.ExecutablePath.StartsWith($Frame+'\',[StringComparison]::OrdinalIgnoreCase)) -or ($process.CommandLine -and $process.CommandLine.IndexOf($Frame,[StringComparison]::OrdinalIgnoreCase) -ge 0)){throw 'Update frame still has running processes; retained'}
  if($process.Name -ieq 'powershell.exe' -and $process.CommandLine -match '(?i)-(?:EncodedCommand|enc)\s+"?([A-Za-z0-9+/=]+)'){
   try{$decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))}catch{throw 'Encoded PowerShell command cannot be inspected; frame retained.'}
   if($decoded.IndexOf($Frame,[StringComparison]::OrdinalIgnoreCase) -ge 0){throw 'Encoded PowerShell runner still references the frame; retained.'}
  }
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
 if(Test-Path $Destination){throw 'Data archive exists; retained.'}
 foreach($item in @(Get-ChildItem $ActiveRoot -Force -Recurse)){if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Data includes a reparse point; retained.'}}
 [IO.Directory]::Move($ActiveRoot,$Destination);Set-HarnessEntryState $entry[0].id 'removed';Add-HarnessEntry 'folder' (Get-HarnessFolderIdentity $Destination) 'data-archive' 'run'|Out-Null
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
function Get-ShippedLogCursor([string]$Path){$text=if(Test-Path $Path){[IO.File]::ReadAllText($Path)}else{''};return @{path=$Path;prefix=$text;length=$text.Length}}
function Read-ShippedLog($Cursor){
 $text=if(Test-Path $Cursor.path){[IO.File]::ReadAllText($Cursor.path)}else{''}
 if($text.Length -ge $Cursor.length -and $text.StartsWith($Cursor.prefix,[StringComparison]::Ordinal)){return $text.Substring($Cursor.length)}
 $old=if(Test-Path ($Cursor.path+'.old')){[IO.File]::ReadAllText($Cursor.path+'.old')}else{''}
 if($Cursor.length -and -not$old.StartsWith($Cursor.prefix,[StringComparison]::Ordinal)){throw 'App-log history rotated more than once; keep evidence and rerun in a fresh window.'};return $old.Substring($Cursor.length)+$text
}
function Test-ShippedRequestTimeout([string]$Text,[double]$Seconds){return $Text -ceq "Couldn't check for updates. The request timed out." -and $Seconds -ge 18 -and $Seconds -le 30}
function Test-ShippedGovernorReplacement($Before,$After){return $Before -and $After -and $After.pid -ne $Before.pid -and $After.creationTimeUtc -ne $Before.creationTimeUtc}
function Get-ShippedFinalStatus([string]$Status,$CleanupErrors){if(@($CleanupErrors).Count){return 'fail'};return $Status}
function Remove-ShippedHostsLine([string]$Path,[string]$Line,[string]$Marker){Remove-HarnessHostsLine $Path $Line $Marker}

function Ensure-HarnessOutputDirectory([string]$Path){
 $full=[IO.Path]::GetFullPath($Path)
 if(-not$full.StartsWith($script:Harness.Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Harness output is outside its verified frame.'}
 if(-not(Test-Path -LiteralPath $full)){New-HarnessDirectory $full 'harness-output'|Out-Null;return}
 $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.state -eq 'active' -and $_.identity.path -ieq $full})
 if($entries.Count -ne 1){throw 'Existing output folder is not in this frame creation ledger.'}
 $actual=Get-HarnessFolderIdentity $full
 if($actual.creationTimeFileTimeUtc -cne $entries[0].identity.creationTimeFileTimeUtc){throw 'Output folder identity changed; retained.'}
}
function Get-HarnessOutputPath([string]$Directory,[string]$Name){
 $path=Join-Path $Directory ([IO.Path]::GetFileNameWithoutExtension($Name)+'-'+$script:Harness.Nonce+'-'+[Guid]::NewGuid().ToString('N')+[IO.Path]::GetExtension($Name))
 if(Test-Path -LiteralPath $path){throw 'Invocation output already exists; retained.'};return $path
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
 . (Join-Path $PSScriptRoot '..\..\..\backend\scripts\BrandCompatibility.Common.ps1')
 $local=Get-RooIndustriesLocalAppData
 $install=Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite'
 $key='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'
 $roots=@(foreach($name in 'RooOptimizationSuite','RooIndustriesOptimizationSuite'){
  $path=Join-Path $local $name
  $files=@(if(Test-Path $path){Get-ChildItem $path -File -Force -Recurse|ForEach-Object {@{path=$_.FullName;bytes=$_.Length;sha256=(Get-FileHash $_.FullName).Hash}}})
  @{path=$path;exists=(Test-Path $path);files=$files}
 })
 $tasks=@(Get-ScheduledTask|ForEach-Object {@{name=$_.TaskName;path=$_.TaskPath;state=[string]$_.State;enabled=$_.Settings.Enabled;xml=(Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath)}})
 @{takenAtUtc=[DateTime]::UtcNow.ToString('o');installedVersion=if(Test-Path $key){(Get-ItemProperty $key).DisplayVersion}else{$null};installDirectory=@{path=$install;exists=(Test-Path $install)};dataRoots=$roots;tasks=$tasks}
}
function Add-HarnessHostsLine([string]$Path,[string]$Line,[string]$Marker){
 $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
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
 foreach($project in @(Get-ChildItem -LiteralPath $Base -File -Recurse -Filter '*.csproj'|Where-Object {$_.FullName.Substring($Base.Length) -notmatch '(^|\\)(bin|obj)(\\|$)'})){
  foreach($name in 'bin','obj'){
   $path=Join-Path $project.DirectoryName $name
   if(-not(Test-Path -LiteralPath $path)){New-HarnessDirectory $path 'generated-build'|Out-Null;continue}
   $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -ieq $path -and $_.state -eq 'active'})
   if($entries.Count -ne 1 -or (Get-HarnessFolderIdentity $path).creationTimeFileTimeUtc -cne $entries[0].identity.creationTimeFileTimeUtc){throw 'An existing build folder is not owned by this run; retained.'}
  }
 }
}

function Remove-HarnessDirectory([string]$Path){
 $queue=[Collections.Generic.Stack[string]]::new();$queue.Push('\\?\'+$Path)
 $folders=[Collections.Generic.List[string]]::new();$files=[Collections.Generic.List[string]]::new()
 while($queue.Count){$folder=$queue.Pop();$folders.Add($folder);foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($folder)){$attributes=[IO.File]::GetAttributes($entry);if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned folder contains a reparse point; retained.'};if($attributes -band [IO.FileAttributes]::Directory){$queue.Push($entry)}else{$files.Add($entry)}}}
 foreach($file in $files){$attributes=[IO.File]::GetAttributes($file);if($attributes -band [IO.FileAttributes]::ReadOnly){[IO.File]::SetAttributes($file,($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))};[IO.File]::Delete($file)}
 foreach($folder in @($folders|Sort-Object Length -Descending)){[IO.Directory]::Delete($folder,$false)}
}
