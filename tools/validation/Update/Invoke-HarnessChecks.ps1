param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[switch]$Hold,[switch]$TimeoutOnly,[switch]$CacheOnly,[switch]$TrackingOnly)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'harness-checks' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot 'checks'
if(@($Hold,$TimeoutOnly,$CacheOnly,$TrackingOnly|Where-Object {$_}).Count -gt 1){throw 'Choose only one harness check mode.'}
if($Hold){Write-HarnessResult $directory 'holding.json' @{pid=$PID;nonce=$nonce}|Out-Null;Start-Sleep -Seconds 30;Complete-HarnessInvocation 'pass' -Cleanup|Out-Null;return}
$rows=[Collections.Generic.List[object]]::new();$status='fail';$main=$script:Harness
function Passed([string]$Name,$Value){$rows.Add(@{check=$Name;status='pass';observed=$Value})}
function Rejected([string]$CaseName,[scriptblock]$Action,[scriptblock]$Unchanged){
 $message=$null;try{& $Action}catch{$message=$_.Exception.Message}
 $retained=[bool](& $Unchanged)
 if(-not$message -or -not$retained){throw ($CaseName+' did not safely refuse: '+$message+'; unchanged='+$retained)}
 Passed $CaseName $message
}
function Fixture([string]$Name,[string]$Text='untouched'){
 $folder=Join-Path $directory $Name;New-HarnessDirectory $folder 'targeted-fixture'|Out-Null
 $file=Join-Path $folder 'keep.txt';New-HarnessText $file $Text 'targeted-fixture'|Out-Null;return $folder
}
function CacheLifecycle([string]$Clean,[string]$Version){
 $path=Join-Path $Clean $Version
 [RooHarnessWindow]::CreateDirectory((Get-HarnessLongPath $path));$before=Register-HarnessCache $Version;Remove-HarnessDirectory $path
 if((Register-HarnessCache $Version) -or (Get-HarnessEntryById $before.id).state -cne 'removed'){throw 'App-deleted cache identity was not retired.'}
 [RooHarnessWindow]::CreateDirectory((Get-HarnessLongPath $path));$after=Register-HarnessCache $Version
 if($after.id -ceq $before.id -or $after.identity.creationTimeFileTimeUtc -ceq $before.identity.creationTimeFileTimeUtc){throw 'Recreated cache reused the earlier identity.'}
 Remove-HarnessEntry $after;Passed 'app-deleted cache retires before a later download creates it' @{before=$before.id;after=$after.id;version=$Version}
}
if($TrackingOnly){& (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Invoke-TraceOwnershipChecks.ps1')) -Source (Get-HarnessToolPath $Source) -OutRoot (Get-HarnessToolPath $OutRoot);return}
if($CacheOnly){
 try{$clean=Fixture 'cache-lifecycle';Initialize-HarnessCache $clean @('4.2.7-beta','4.2.8-beta');CacheLifecycle $clean '4.2.8-beta';$status='pass'}
 finally{$status=Complete-HarnessInvocation $status -Cleanup;Write-HarnessResult $directory 'receipt.json' @{status=$status;checks=@($rows)}|Out-Null}
 return
}
if($TimeoutOnly){
 try{
  $message="Couldn't check for updates. The request timed out."
  $values=@(foreach($seconds in 17.9,18,30,30.1){@{text=$message;seconds=$seconds;accepted=(Test-ShippedRequestTimeout $message $seconds)}})
  if($values[0].accepted -or -not$values[1].accepted -or -not$values[2].accepted -or $values[3].accepted -or (Test-ShippedRequestTimeout "Couldn't check for updates. Other failure." 20)){throw 'Hanging-network predicate accepts an incorrect status or deadline.'}
  Passed 'F12 hanging check requires the exact request timeout at 18 through 30 seconds' $values;$status='pass'
 }finally{$status=Complete-HarnessInvocation $status -Cleanup;Write-HarnessResult $directory 'receipt.json' @{status=$status;checks=@($rows)}|Out-Null}
 return
}
function ForeignScope{
 $root='C:\RooBuild\roo-industries-harness-'+[Guid]::NewGuid().ToString('N')
 $entry=New-HarnessDirectory $root 'foreign-ledger-fixture'
 $id=$root.Substring($root.Length-32);$manifest='0'*64
 $ledger=@{protocol='roo-harness-ledger/v1';machine=$env:COMPUTERNAME;frameId=$id;manifestSha256=$manifest;entries=@();invocations=@()}
 $stream=[IO.FileStream]::new((Get-HarnessLongPath (Join-Path $root 'ledger.json')),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($ledger|ConvertTo-Json -Depth 20));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
 Open-HarnessRun $root $id $manifest ([Guid]::NewGuid().ToString('N'))
 return @{scope=$script:Harness;rootEntry=$entry}
}
function LongFrame([bool]$Unrecorded){
 $root='C:\RooBuild\roo-industries-long-path-'+[Guid]::NewGuid().ToString('N')
 New-HarnessDirectory $root 'long-path-fixture' 'invocation'|Out-Null
 $source=Join-Path $root 'source';New-HarnessDirectory $source 'long-path-source' 'invocation'|Out-Null
 $id=$root.Substring($root.Length-32)
 $manifestPath=Join-Path $source 'source-verification.json'
 New-HarnessText $manifestPath (@{frameId=$id;files=@{}}|ConvertTo-Json) 'long-path-manifest' 'invocation'|Out-Null
 $path=$root
 foreach($segment in @(('a'*80),('b'*80),('c'*80))){$path=Join-Path $path $segment;New-HarnessDirectory $path 'long-path-fixture' 'invocation'|Out-Null}
 $file=Join-Path $path 'long-evidence.json'
 New-HarnessText $file (@{nonce=$nonce;value='long path bytes'}|ConvertTo-Json) 'long-path-file' 'invocation'|Out-Null
 if($file.Length -lt 300 -or $path.Length -lt 300){throw 'Fixture did not reach the long path.'}
 $owned=@(Get-HarnessEntries|Where-Object {$_.state -eq 'active' -and $_.identity.path -and ($_.identity.path -ieq $root -or $_.identity.path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase))})
 $entries=@($owned|ForEach-Object {$copy=$_|ConvertTo-Json -Depth 30|ConvertFrom-Json;if($copy.kind -eq 'folder'){$copy.purpose='source-frame'};if(-not$Unrecorded -or $copy.identity.path -notin @($path,$file)){$copy}})
 $ledgerPath=Join-Path $root 'ledger.json'
 $ledger=@{protocol='roo-harness-ledger/v1';machine=$env:COMPUTERNAME;frameId=$id;manifestSha256=(Get-HarnessFileSha256 $manifestPath).ToLowerInvariant();entries=$entries;invocations=@()}
 New-HarnessText $ledgerPath ($ledger|ConvertTo-Json -Depth 60) 'long-path-ledger' 'invocation'|Out-Null
 return @{root=$root;path=$file;unrecordedDirectory=$path;ledger=$ledgerPath;owned=@(Get-HarnessEntries|Where-Object {$_.state -eq 'active' -and $_.identity.path -and ($_.identity.path -ieq $root -or $_.identity.path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase))})}
}
function CloseLongFrame($Fixture){
 $closed=& (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Clear-UpdateFrame.ps1')) -Frame $Fixture.root -ExpectedMachine $env:COMPUTERNAME|ConvertFrom-Json
 $script:Harness=$main
 if([IO.Directory]::Exists((Get-HarnessLongPath $Fixture.root)) -or @($closed.entries|Where-Object state -EQ 'active').Count){throw 'Long frame or active ledger entry remained.'}
 foreach($entry in $Fixture.owned){Set-HarnessEntryState $entry.id 'removed'}
 return $closed
}
function ToolBoundaryChecks{
 $tools=Fixture 'tool-boundary'
 $long=Join-Path (Join-Path (Join-Path $tools ('a'*90)) ('b'*90)) ('c'*90)
 $longFile=Join-Path $long 'never-created.json'
 $refusals=@('Invoke-WebRequest -OutFile','Add-Type -OutputAssembly','Start-Process working directory and argument','Get-AuthenticodeSignature','Set-Location','Get-Acl','Expand-Archive','New-Item junction','script invocation','external executable','Get-Content','Copy-Item','Get-FileHash','Get-ChildItem','Remove-Item','Resolve-Path')
 foreach($category in $refusals){
  $called=$false;$message=$null
  try{$path=Get-HarnessToolPath $longFile;$called=$true;throw 'Tool guard unexpectedly allowed a long path'}catch{$message=$_.Exception.Message}
  if($called -or $message -notlike 'Path reaches the 260-character tool limit;*' -or (Test-HarnessPath $longFile)){throw ('Tool boundary did not refuse before '+$category)}
  Passed ('tool boundary refuses long path before '+$category) @{length=$longFile.Length;called=$called;message=$message}
 }
 $source=Join-Path $tools 'tool-fixture.cs';$assembly=Join-Path $tools 'tool-fixture.exe'
 $code=@'
using System;
using System.IO;
using System.Net;
using System.Text;
public static class ToolFixture {
 public static void Main(string[] args) {
  if(args[0]=="listener") { using(var listener=new HttpListener()){listener.Prefixes.Add(args[1]);listener.Start();var request=listener.GetContext();var bytes=Encoding.UTF8.GetBytes(args[2]);request.Response.ContentLength64=bytes.Length;request.Response.OutputStream.Write(bytes,0,bytes.Length);request.Response.Close();}return; }
  File.WriteAllText(args[1],Environment.CurrentDirectory,new UTF8Encoding(false));
 }
}
'@
 New-HarnessText $source $code 'tool-fixture'|Out-Null
 Add-Type -OutputAssembly (Get-HarnessToolPath $assembly) -OutputType ConsoleApplication -TypeDefinition $code
 Register-HarnessFile $assembly 'tool-fixture'|Out-Null
 Passed 'tool boundary Add-Type normal output' (Get-HarnessFileSha256 $assembly)
 $portProbe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$portProbe.Start();$port=$portProbe.LocalEndpoint.Port;$portProbe.Stop()
 $uri='http://127.0.0.1:'+ $port+'/'
 $listener=Start-OwnedProcess -FilePath $assembly -ArgumentList ('listener "'+$uri+'" '+$nonce) -Purpose local-listener
 try{
  $ready=$false;$deadline=[DateTime]::UtcNow.AddSeconds(10)
  do{$client=[Net.Sockets.TcpClient]::new();try{$client.Connect('127.0.0.1',$port);$ready=$true}catch{Start-Sleep -Milliseconds 50}finally{$client.Dispose()}}while(-not$ready -and [DateTime]::UtcNow -lt $deadline)
  if(-not$ready){throw 'Owned loopback listener did not start'}
  $download=Join-Path $tools 'download.txt'
  Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile (Get-HarnessToolPath $download)
  Register-HarnessFile $download 'tool-download'|Out-Null
  if([IO.File]::ReadAllText((Get-HarnessLongPath $download)) -cne $nonce){throw 'Owned loopback download bytes differ'}
  Passed 'tool boundary Invoke-WebRequest normal output' @{uri=$uri;sha256=(Get-HarnessFileSha256 $download)}
 }finally{Stop-HarnessProcess $listener}
 $output=Join-Path $tools 'working-directory.txt'
 $owned=Start-OwnedProcess -FilePath $assembly -WorkingDirectory (Get-HarnessLongPath $tools) -ArgumentList ('record "'+(Get-HarnessLongPath $output)+'"') -Purpose tool-fixture
 try{if(-not$owned.process.WaitForExit(10000) -or $owned.process.ExitCode -ne 0){throw 'Tool fixture process failed'};Register-HarnessFile $output 'tool-result'|Out-Null;if([IO.File]::ReadAllText((Get-HarnessLongPath $output)) -ine $tools){throw 'Child working directory or argument path differs'};Passed 'tool boundary Start-Process normal working directory and argument' $tools}finally{Stop-HarnessProcess $owned}
 $signature=Get-AuthenticodeSignature -LiteralPath (Get-HarnessToolPath $assembly)
 Passed 'tool boundary Get-AuthenticodeSignature normal path' ([string]$signature.Status)
 $beforeLocation=Get-Location
 try{Set-Location -LiteralPath (Get-HarnessToolPath $tools);if($pwd.ProviderPath -ine $tools){throw 'Tool fixture location differs'};Passed 'tool boundary Set-Location normal path' $pwd.ProviderPath}finally{Set-Location -LiteralPath (Get-HarnessToolPath $beforeLocation.ProviderPath)}
 $acl=Get-Acl -LiteralPath (Get-HarnessToolPath $tools);Passed 'tool boundary Get-Acl normal path' $acl.Owner
 $archive=Join-Path $tools 'normal.zip';New-HarnessArchive $tools $archive {$true}|Out-Null
 $expanded=Join-Path $tools 'expanded';New-HarnessDirectory $expanded 'tool-archive'|Out-Null
 Expand-Archive -LiteralPath (Get-HarnessToolPath $archive) -DestinationPath (Get-HarnessToolPath $expanded)
 if((Get-HarnessFileSha256 (Join-Path $expanded 'download.txt')) -cne (Get-HarnessFileSha256 $download)){throw 'Tool archive extraction bytes differ'}
 Passed 'tool boundary Expand-Archive normal paths' $expanded
 $junction=Join-Path $tools 'junction'
 New-Item -ItemType Junction -Path (Get-HarnessToolPath $junction) -Target (Get-HarnessToolPath $expanded)|Out-Null
 $entry=Add-HarnessEntry 'reparse' @{path=$junction;target=$expanded} 'tool-junction'
 Remove-HarnessEntry $entry;Passed 'tool boundary New-Item junction normal paths' $junction
 $scriptPath=Join-Path $tools 'tool-script.ps1';New-HarnessText $scriptPath "param([string]`$Value);`$Value" 'tool-script'|Out-Null
 $value=& (Get-HarnessToolPath $scriptPath) -Value $nonce
 if($value -cne $nonce){throw 'Tool script invocation differs'};Passed 'tool boundary script invocation normal path' $value
 $external=Invoke-HarnessProcess $assembly ('record "'+(Join-Path $tools 'external.txt')+'"') 'boundary-external'
 Register-HarnessFile (Join-Path $tools 'external.txt') 'tool-result'|Out-Null
 Passed 'tool boundary external executable normal paths' $assembly
 $text=Get-Content -LiteralPath (Get-HarnessToolPath $download) -Raw
 if($text -cne $nonce){throw 'Tool Get-Content bytes differ'};Passed 'tool boundary Get-Content normal path' $text
 $copy=Join-Path $tools 'cmdlet-copy.txt';Copy-Item -LiteralPath (Get-HarnessToolPath $download) -Destination (Get-HarnessToolPath $copy)
 $copyEntry=Register-HarnessFile $copy 'tool-copy'
 $hash=(Get-FileHash -LiteralPath (Get-HarnessToolPath $copy) -Algorithm SHA256).Hash
 if($hash -cne (Get-HarnessFileSha256 $download)){throw 'Tool copy/hash bytes differ'}
 Passed 'tool boundary Copy-Item normal paths' $hash;Passed 'tool boundary Get-FileHash normal path' $hash
 $children=@(Get-ChildItem -LiteralPath (Get-HarnessToolPath $tools) -File)
 if($children.Name -notcontains 'cmdlet-copy.txt'){throw 'Tool children missed a file'};Passed 'tool boundary Get-ChildItem normal path' $children.Count
 $resolved=(Resolve-Path -LiteralPath (Get-HarnessToolPath $copy)).ProviderPath
 if($resolved -ine $copy){throw 'Tool Resolve-Path differs'};Passed 'tool boundary Resolve-Path normal path' $resolved
 Remove-Item -LiteralPath (Get-HarnessToolPath $copy)
 Set-HarnessEntryState $copyEntry.id 'removed'
 if(Test-HarnessPath $copy){throw 'Tool Remove-Item left its owned file'};Passed 'tool boundary Remove-Item normal path' $copy
}
try{
 ToolBoundaryChecks
 $fixture=Fixture 'present-data';$sentinel=Join-Path $fixture 'keep.txt'
 Rejected 'active current data root present in preflight' {Move-ShippedFreshData $fixture @{dataRoots=@(@{path=$fixture;exists=$true})} (Join-Path $directory 'moved-data')} {[IO.File]::ReadAllText((Get-HarnessLongPath $sentinel)) -ceq 'untouched'}
 $staleP0=@{dataRoots=@(@{path=$fixture;exists=$false})}
 $p5=@{dataRoots=@(@{path=$fixture;exists=(Test-HarnessPath $fixture)})}
 Rejected 'F1 P5 resnapshot refuses root created since P0' {Assert-HarnessFreshData $fixture $p5} {[IO.File]::ReadAllText((Get-HarnessLongPath $sentinel)) -ceq 'untouched' -and -not$staleP0.dataRoots[0].exists}
 $foreign=ForeignScope
 $name='RooTest-ShippedOffline-'+[Guid]::NewGuid().ToString('N');$foreignNonce='OtherOwner-'+[Guid]::NewGuid().ToString('N')
 New-ShippedFirewall $name $foreignNonce "$env:SystemRoot\System32\PING.EXE"
 $script:Harness=$main
 Rejected 'existing offline firewall rule retained' {try{New-ShippedFirewall $name 'different-owner' "$env:SystemRoot\System32\PING.EXE"}finally{Remove-ShippedFirewall $name 'different-owner' $false}} {(Get-NetFirewallRule -Name $name).Description -ceq $foreignNonce}
 $script:Harness=$foreign.scope;Remove-HarnessEntry (@(Get-HarnessEntries|Where-Object kind -EQ 'firewall')[0]);$script:Harness=$main
 $script:Harness=$foreign.scope
 $image=Join-Path $foreign.scope.Root 'RooHarnessGame.exe';Copy-HarnessFile "$env:SystemRoot\System32\PING.EXE" $image|Out-Null
 $older=Start-HarnessExplorerProcess $image '-t 127.0.0.1';$script:Harness=$main
 try{
  Rejected 'pre-running app instance retained' {Assert-NoForeignInstance $image} {-not$older.process.HasExited}
  $after=[DateTime]::UtcNow;$second=Start-OwnedProcess -FilePath $image -ArgumentList '-t 127.0.0.1' -Purpose fixture
  try{Rejected 'second fixture with an earlier instance retained' {Get-ShippedFixture $image $after} {-not$older.process.HasExited -and -not$second.process.HasExited}}finally{Stop-HarnessProcess $second}
  Rejected 'earlier fixture instance retained' {Get-ShippedFixture $image $after} {-not$older.process.HasExited}
  Rejected 'Current refuses an app before its check launch window' {Assert-ShippedFreshApp $older.process $after} {-not$older.process.HasExited}
  Rejected 'F2 foreign process cannot be adopted as a descendant' {if(-not(Test-OwnedDescendant $older.Identity.pid)){throw 'Foreign process chain refused'}} {-not$older.process.HasExited}
  Rejected 'F2 process trace refuses a foreign anchor receipt' {Start-ProcessTrace -Anchor $older} {-not$older.process.HasExited}
 }finally{$script:Harness=$foreign.scope;Stop-HarnessProcess $older;$script:Harness=$main}

 $wizardSource=Join-Path $directory 'window-fixture.iss'
 $wizardText=@'
[Setup]
AppName=Roo Industries recovery fixture
AppVersion=1.0
DefaultDirName={tmp}\roo-owned-wizard-fixture
OutputBaseFilename=window-fixture
Uninstallable=no
CreateAppDir=no
PrivilegesRequired=admin
[Code]
procedure InitializeWizard;
var InfoButton: TNewButton;
begin
  WizardForm.Caption := ExpandConstant('{param:FixtureTitle|Setup Roo Industries recovery fixture}');
  InfoButton := TNewButton.Create(WizardForm);
  InfoButton.Parent := WizardForm;
  InfoButton.Caption := 'More info';
  InfoButton.Left := 8;
  InfoButton.Top := 8;
end;
'@
 New-HarnessText $wizardSource $wizardText 'wizard-fixture'|Out-Null
 $iscc=Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe';if(-not(Test-HarnessPath $iscc)){$iscc=Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'}
 Invoke-HarnessProcess $iscc ('/Q /O"'+$directory+'" "'+$wizardSource+'"') 'wizard-compile'|Out-Null
 $windowExe=Join-Path $directory 'window-fixture.exe';Register-HarnessFile $windowExe 'window-fixture'|Out-Null
 Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
 foreach($title in 'Setup Roo Industries recovery fixture','Windows protected your PC'){
  $script:Harness=$foreign.scope
  $foreignWindowExe=Join-Path $foreign.scope.Root ([IO.Path]::GetFileName($windowExe))
  if(-not(Test-HarnessPath $foreignWindowExe)){Copy-HarnessFile $windowExe $foreignWindowExe|Out-Null}
  $windowProcess=Start-HarnessExplorerProcess $foreignWindowExe ('/FixtureTitle="'+$title+'"') 'explorer-window'
  try{
   $until=[DateTime]::UtcNow.AddSeconds(30);$window=$null
   do{
    foreach($candidate in @([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition))){
     if($candidate.Current.ClassName -eq 'TWizardForm' -and $candidate.Current.Name -ceq $title -and (Test-OwnedDescendant ([int]$candidate.Current.ProcessId))){$window=$candidate;break}
    }
    if($window){break};Start-Sleep -Milliseconds 100
   }while([DateTime]::UtcNow -lt $until)
   if(-not$window){throw 'Owned foreign wizard fixture did not render'}
   $windowOwner=Test-OwnedDescendant ([int]$window.Current.ProcessId) -PassThru
   $script:Harness=$main
   if($title -like 'Setup*'){Rejected 'F2 foreign copy-failure TWizardForm is refused' {Register-HarnessWindow $window} {-not$windowOwner.process.HasExited}}
   else{Rejected 'F4 SmartScreen evidence stops without clicking' {Assert-HarnessSmartScreen $window $directory} {-not$windowOwner.process.HasExited -and $window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition).Count -ge 2}}
  }finally{
   $script:Harness=$foreign.scope
   $ownedChildren=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.state -eq 'active'});[array]::Reverse($ownedChildren)
   foreach($entry in $ownedChildren){Remove-HarnessEntry $entry};$script:Harness=$main
  }
 }
 $sequence=@(Get-HarnessEntries|Where-Object {$_.nonce -ceq $nonce -and $_.purpose -eq 'result'}).Count+1
 $stale=Join-Path $directory ('collision-'+$nonce+'-'+('{0:D4}'-f$sequence)+'.json');New-HarnessText $stale '{"nonce":"earlier","data":"stale"}' 'targeted-fixture'|Out-Null
 Rejected 'F3 existing invocation result is never overwritten or read' {Write-HarnessResult $directory 'collision.json' @{fresh=$true}} {[IO.File]::ReadAllText((Get-HarnessLongPath $stale)).Contains('stale')}
 $bound=Write-HarnessResult $directory 'bound.json' @{fresh=$true}
 Rejected 'F3 result reader refuses another nonce' {Read-HarnessResult $bound ('0'*32)} {Test-HarnessPath $bound}
 $frame='C:\RooBuild\roo-industries-roo29-shipped-'+[Guid]::NewGuid().ToString('N');New-HarnessDirectory $frame 'frame-guard-fixture'|Out-Null
 $stay=Join-Path $frame 'stay.ps1';New-HarnessText $stay 'Start-Sleep -Seconds 180' 'targeted-fixture'|Out-Null
 $owned=Start-OwnedProcess -FilePath powershell.exe -ArgumentList ('-NoProfile -File "'+$stay+'"') -Purpose fixture
 try{Rejected 'frame script in PowerShell command line retained' {Assert-HarnessFrameIdle $frame} {Test-HarnessPath $stay}}finally{Stop-HarnessProcess $owned}
 $target=Fixture 'junction-target';$junction='C:\RooBuild\roo-industries-roo29-shipped-'+[Guid]::NewGuid().ToString('N')
 New-Item -ItemType Junction -Path (Get-HarnessToolPath $junction) -Target (Get-HarnessToolPath $target)|Out-Null
 $junctionItem=Get-HarnessItem $junction -Force;$junctionEntry=Add-HarnessEntry 'folder' @{path=$junction;creationTimeFileTimeUtc=$junctionItem.CreationTimeUtc.ToFileTimeUtc().ToString()} 'junction-fixture' 'invocation' @{reparseTarget=$target}
 try{Rejected 'junction frame retained without touching target' {
  & (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Clear-UpdateFrame.ps1')) -Frame $junction -ExpectedMachine $env:COMPUTERNAME
 } {
  [IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $target 'keep.txt'))) -ceq 'untouched'
 }}finally{Remove-HarnessEntry $junctionEntry}
 $danglingTarget=Fixture 'dangling-junction-target';$dangling='C:\RooBuild\roo-industries-junction-'+[Guid]::NewGuid().ToString('N')
 New-Item -ItemType Junction -Path (Get-HarnessToolPath $dangling) -Target (Get-HarnessToolPath $danglingTarget)|Out-Null
 $item=Get-HarnessItem $dangling;$entry=Add-HarnessEntry 'folder' @{path=$dangling;creationTimeFileTimeUtc=$item.CreationTimeUtc.ToFileTimeUtc().ToString()} 'dangling-junction-fixture' 'invocation' @{reparseTarget=$danglingTarget}
 $targetEntries=@(Get-HarnessEntries|Where-Object {$_.state -eq 'active' -and $_.identity.path -and ($_.identity.path -ieq $danglingTarget -or $_.identity.path.StartsWith($danglingTarget+'\',[StringComparison]::OrdinalIgnoreCase))});[array]::Reverse($targetEntries);foreach($targetEntry in $targetEntries){Remove-HarnessEntry $targetEntry}
 if(-not(Test-HarnessPath $dangling) -or (Get-HarnessItem $dangling).Target[0] -ine $danglingTarget){throw 'A dangling recorded junction was missed.'}
 Remove-HarnessEntry $entry
 if(Test-HarnessPath $dangling){throw 'Recorded dangling junction remained.'}
 Passed 'CR8 recorded dangling junction retains its link identity through cleanup' @{path=$dangling;target=$danglingTarget;removed=$true}
 $unownedDownload=Fixture 'unowned-download'
 $entry=@(Get-HarnessEntries|Where-Object {$_.identity.path -ieq $unownedDownload})[0];Set-HarnessEntryState $entry.id 'retained'
 Complete-HarnessInvocation 'running' -Cleanup|Out-Null
 if(-not(Test-HarnessPath (Join-Path $unownedDownload 'keep.txt'))){throw 'Unowned download was removed'}
 Set-HarnessEntryState $entry.id 'active';Passed 'F5 cleanup ignores a download folder absent from the active ledger' $unownedDownload
 $cache=Fixture 'foreign-cache';$version='4.2.8-beta';$folder=Join-Path $cache $version;New-HarnessDirectory $folder 'targeted-fixture'|Out-Null
 Rejected 'F9 foreign B cache is refused and retained' {Initialize-HarnessCache $cache @('4.2.7-beta',$version)} {Test-HarnessPath $folder}
 $clean=Fixture 'cache-preflight';Initialize-HarnessCache $clean @('4.2.7-beta',$version)
 $b=Join-Path $clean $version;New-HarnessDirectory $b 'targeted-cache'|Out-Null
 $entry=Register-HarnessCache $version
 if($entry.metadata.version -cne $version){throw 'Reset used a hardcoded version'};Remove-HarnessEntry $entry
 if(Test-HarnessPath $b){throw 'Owned actual-version cache remained'};Passed 'F9 reset selects actual B version from preflight' @{version=$version;absent=$true}
 CacheLifecycle $clean $version
 $hosts=Join-Path $directory 'hosts-fixture';$original=[byte[]]@(239,187,191,35,32,195,169,10)
 $stream=[IO.FileStream]::new((Get-HarnessLongPath $hosts),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($original,0,$original.Length)}finally{$stream.Dispose()}
 $marker='# RooShipped-fixture';$line='192.0.2.1 example.test '+$marker
 Add-HarnessHostsLine $hosts $line $marker;Remove-HarnessEntry (@(Get-HarnessEntries|Where-Object {$_.kind -eq 'hosts' -and $_.identity.marker -eq $marker})[0])
 if([Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-HarnessLongPath $hosts))) -cne [Convert]::ToBase64String($original)){throw 'Hosts cleanup changed unrelated bytes.'}
 Passed 'hosts cleanup preserves BOM, UTF-8 and original line endings' 'byte-identical after marked line removal'
 Add-HarnessHostsLine $hosts $line $marker
 $writerCode='$ErrorActionPreference="Stop";for($i=0;$i -lt 100;$i++){try{$f=[IO.FileStream]::new((Get-HarnessLongPath "'+$hosts+'"),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$f.Position=$f.Length;$b=[Text.Encoding]::ASCII.GetBytes("SECOND-WRITER");$f.Write($b,0,$b.Length);$f.Dispose();exit 0}catch [IO.IOException]{Start-Sleep -Milliseconds 50}};exit 1'
 $writerCode='function Get-HarnessLongPath {'+${function:Get-HarnessLongPath}.ToString()+'};'+$writerCode
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($writerCode));$script:competingWriter=$null
 Remove-HarnessHostsLine $hosts $line $marker {
  $script:competingWriter=Start-OwnedProcess -FilePath powershell.exe -ArgumentList ('-NoProfile -EncodedCommand '+$encoded) -Purpose competing-hosts-writer
  Start-Sleep -Milliseconds 1000
  if($script:competingWriter.process.HasExited ){throw 'Second writer was not blocked by the exclusive cleanup stream'}
 }
 if(-not$script:competingWriter.process.WaitForExit(10000) -or $script:competingWriter.process.ExitCode -ne 0 -or -not[IO.File]::ReadAllText((Get-HarnessLongPath $hosts)).EndsWith('SECOND-WRITER') -or [IO.File]::ReadAllText((Get-HarnessLongPath $hosts)).Contains($marker)){throw 'Competing hosts edit did not survive after cleanup'}
 $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'hosts' -and $_.identity.marker -eq $marker -and $_.state -eq 'active'})[0];Set-HarnessEntryState $entry.id 'removed'
 Passed 'F13 concurrent hosts writer is blocked then its edit survives' 'SECOND-WRITER present after cleanup released its exclusive handle'
 $log=Join-Path $directory 'app.log';[IO.File]::WriteAllText((Get-HarnessLongPath $log),'before');$cursor=Get-ShippedLogCursor $log
 [IO.File]::AppendAllText((Get-HarnessLongPath $log),' old-tail');[IO.File]::Move((Get-HarnessLongPath $log),(Get-HarnessLongPath ($log+'.old')));[IO.File]::WriteAllText((Get-HarnessLongPath $log),'new-head')
 $read=Read-ShippedLog $cursor;if($read -cne ' old-tailnew-head'){throw 'Rotated log tail was lost.'};Passed 'app-log rotation retains old tail' $read
 $before=@{pid=100;creationTimeUtc='2026-10-01T00:00:00Z'}
 if((Test-ShippedGovernorReplacement $before $before) -or (Test-ShippedGovernorReplacement $before @{pid=101;creationTimeUtc=$before.creationTimeUtc}) -or (Test-ShippedGovernorReplacement $before @{pid=100;creationTimeUtc='2026-10-02T00:00:00Z'}) -or -not(Test-ShippedGovernorReplacement $before @{pid=101;creationTimeUtc='2026-10-02T00:00:00Z'})){throw 'Governor identity checks do not discriminate.'}
 Passed 'governor needs new PID and creation time' 'unchanged, PID-only and time-only refused; both changed accepted'
 if((Get-ShippedFinalStatus 'pass' @('Governor pause timeout')) -cne 'fail'){throw 'Cleanup failure was reported as pass.'};Passed 'cleanup error changes a pass to fail' 'Governor pause timeout => fail'
 $script:Harness=$foreign.scope
 Invoke-HarnessLedger {param($ledger) $ledger.invocations=@([pscustomobject]@{nonce=$script:Harness.Nonce;scenario='failed-cleanup-fixture';scope=$script:Harness.Root;status='fail';cleanupErrors=@('Governor pause timeout')})}|Out-Null
 if((Complete-HarnessInvocation 'pass') -cne 'fail'){throw 'The wrapper overwrote a completed cleanup failure.'}
 $script:Harness=$main;Passed 'shared ledger never turns an earlier cleanup failure into pass' 'fail remains fail when the wrapper finishes successfully'
 $nested=Join-Path $directory 'nested-output\builds';New-HarnessDirectory $nested 'nested-output' 'invocation'|Out-Null
 $parent=Split-Path $nested -Parent;Ensure-HarnessOutputDirectory $parent
 $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -in @($nested,$parent) -and $_.state -eq 'active'})
 if($entries.Count -ne 2 -or -not($entries|Where-Object {$_.identity.path -ieq $parent}).metadata.emptyOnly){throw 'Recursive output creation left an unrecorded ancestor or broad parent cleanup.'}
 try{[RooHarnessWindow]::CreateDirectory((Get-HarnessLongPath $parent));throw 'Atomic directory creation adopted an existing path.'}catch{if($_.Exception.Message -like '*adopted an existing*'){throw}}
 Passed 'nested output records every created ancestor' @{folders=$entries.identity.path;parentCleanup='empty-only';existingNativeCreate='refused'}
 $projectRoot=Fixture 'foreign-build-folder';New-HarnessText (Join-Path $projectRoot 'Example.csproj') '<Project/>' 'project-fixture'|Out-Null
 $script:Harness=$foreign.scope;$foreignBin=Join-Path $projectRoot 'bin';New-HarnessDirectory $foreignBin 'foreign-build'|Out-Null;New-HarnessText (Join-Path $foreignBin 'keep.txt') 'foreign build output'|Out-Null;$script:Harness=$main
 $refusal=$null;try{Initialize-HarnessBuildFolders $projectRoot}catch{$refusal=$_.Exception.Message}
 if($refusal -cne 'An existing build folder is not owned by this run; retained.' -or [IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $foreignBin 'keep.txt'))) -cne 'foreign build output' -or @(Get-HarnessEntries|Where-Object {$_.identity.path -ieq $foreignBin}).Count){throw 'Foreign build folder was not refused for its ownership.'}
 Passed 'foreign generated folder is never adopted by timestamp' $refusal
 $script:Harness=$foreign.scope;$entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.identity.path -ieq (Join-Path $foreignBin 'keep.txt')})[0];Remove-HarnessEntry $entry;$entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -ieq $foreignBin})[0];Remove-HarnessEntry $entry;$script:Harness=$main
 Initialize-HarnessBuildFolders $projectRoot
 if(@(Get-HarnessEntries|Where-Object {$_.purpose -eq 'generated-build' -and $_.identity.path -in @((Join-Path $projectRoot 'bin'),(Join-Path $projectRoot 'obj'))}).Count -ne 2){throw 'Prepared build folders were not recorded.'}
 $long=LongFrame $false
 $short=Fixture 'normalization';$shortDouble=$short.Replace('\normalization','\\normalization')
 if(-not(Test-HarnessPath $shortDouble -PathType Container)){throw 'Existing short directory with a doubled separator was missed.'}
 Passed 'normalization short doubled separator finds the owned directory' @{path=$shortDouble;found=$true}
 $longDouble=$long.unrecordedDirectory.Replace('\'+('c'*80),'\\'+('c'*80))
 if($longDouble.Length -lt 300 -or -not(Test-HarnessPath $longDouble -PathType Container)){throw 'Existing long directory with a doubled separator was missed.'}
 Passed 'normalization 300+ doubled separator finds the owned directory' @{path=$longDouble;length=$longDouble.Length;found=$true}
 $longParent=$long.unrecordedDirectory+'\..\'+('d'*80)
 Rejected 'normalization 300+ parent segment is refused' {Test-HarnessPath $longParent} {Test-HarnessPath $long.path}
 $longHash=Get-HarnessFileSha256 $long.path
 $closed=CloseLongFrame $long
 Write-HarnessResult $directory 'long-recorded-closed.json' $closed|Out-Null
 Passed 'CR8 recorded 300+ character frame clears with a closed ledger' @{path=$long.path;length=$long.path.Length;sha256=$longHash;frameGone=$true;activeEntries=0}
 $long=LongFrame $true
 $longHash=Get-HarnessFileSha256 $long.path;$message=$null
 try{& (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Clear-UpdateFrame.ps1')) -Frame $long.root -ExpectedMachine $env:COMPUTERNAME|Out-Null}catch{$message=$_.Exception.Message}finally{$script:Harness=$main}
 if($message -notmatch 'Unrecorded frame (file|directory) retained' -or -not($message.Contains($long.path) -or $message.Contains($long.unrecordedDirectory)) -or -not[IO.File]::Exists((Get-HarnessLongPath $long.ledger)) -or (Get-HarnessFileSha256 $long.path) -cne $longHash){throw ('Long unrecorded entry was not safely refused: '+$message)}
 $retained=[IO.File]::ReadAllText((Get-HarnessLongPath $long.ledger))|ConvertFrom-Json
 Write-HarnessResult $directory 'long-unrecorded-retained.json' @{message=$message;path=$long.path;pathLength=$long.path.Length;directory=$long.unrecordedDirectory;hash=$longHash;ledger=$retained}|Out-Null
 Passed 'CR8 unrecorded 300+ character directory and file are retained' @{message=$message;path=$long.path;length=$long.path.Length;sha256=$longHash;ledgerKept=$true}
 foreach($path in @($long.path,$long.unrecordedDirectory)){$entry=@($long.owned|Where-Object {$_.identity.path -ieq $path})[0];Remove-HarnessEntry $entry}
 CloseLongFrame $long|Out-Null
 $long=LongFrame $false
 $archive=Get-HarnessOutputPath $directory 'long-evidence.zip'
 New-HarnessArchive $long.root $archive {param($item,$relative) [IO.Path]::GetExtension($item.FullName) -ieq '.json'}|Out-Null
 $zip=[IO.Compression.ZipFile]::OpenRead((Get-HarnessLongPath $archive))
 $relative=$long.path.Substring($long.root.Length+1).Replace('\','/')
 try{$entry=$zip.GetEntry($relative);if(-not$entry){throw 'Long JSON archive member was omitted.'};$stream=$entry.Open();$reader=[IO.StreamReader]::new($stream);try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()};if($text -cne [IO.File]::ReadAllText((Get-HarnessLongPath $long.path))){throw 'Long JSON archive bytes differ.'}}finally{$zip.Dispose()}
 Passed 'CR8 archive includes 300+ character JSON with its relative name and bytes' @{path=$long.path;length=$long.path.Length;entry=$relative;archive=$archive;bytesMatch=$true}
 CloseLongFrame $long|Out-Null
 $lease=@(Get-HarnessEntries|Where-Object {$_.purpose -eq 'host-lease' -and $_.state -eq 'active'})[0]
 $sentinel=Fixture 'lease-owner';$app=Start-OwnedProcess -FilePath "$env:SystemRoot\System32\PING.EXE" -ArgumentList '-t 127.0.0.1' -Purpose lease-fixture
 try{
  $script:Harness=$foreign.scope
  Rejected 'R2 second frame install refused without touching first frame bytes/app' {Assert-HarnessInstallStart "$env:SystemRoot\System32\PING.EXE"} {[IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $sentinel 'keep.txt'))) -ceq 'untouched' -and -not$app.process.HasExited}
 }finally{$script:Harness=$main;Stop-HarnessProcess $app}
 Remove-HarnessEntry $lease
 $missing='C:\RooBuild\roo-industries-missing-'+[Guid]::NewGuid().ToString('N')
 $stale=New-HarnessText 'C:\RooBuild\host-lease.json' (@{frameId=$missing.Substring($missing.Length-32);nonce=$nonce;runRoot=$missing;createdUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress) 'stale-lease-fixture'
 try{Rejected 'R2 missing owner frame stale lease is kept' {Enter-HarnessHostLease} {(Get-HarnessFileSha256 $stale.identity.path) -ceq $stale.identity.hash}}finally{Remove-HarnessEntry $stale}
 $hostOwner=LongFrame $false
 $ownerMain=$script:Harness
 $manifest=(Get-HarnessFileSha256 (Join-Path $hostOwner.root 'source\source-verification.json')).ToLowerInvariant()
 Open-HarnessRun $hostOwner.root $hostOwner.root.Substring($hostOwner.root.Length-32) $manifest $nonce
 Enter-HarnessHostLease
 $script:Harness=$main
 $ownerClosed=CloseLongFrame $hostOwner
 if(Test-HarnessPath 'C:\RooBuild\host-lease.json'){throw 'Owner Clear did not release its lease'}
 Passed 'R2 owner frame Clear releases lease' @{frame=$hostOwner.root;leaseAbsent=$true;activeEntries=@($ownerClosed.entries|Where-Object state -EQ 'active').Count}
 Enter-HarnessHostLease
 $script:Harness=$foreign.scope
 $foreignAppImage=Join-Path $foreign.scope.Root 'NonLedgerApp.exe';Copy-HarnessFile "$env:SystemRoot\System32\PING.EXE" $foreignAppImage|Out-Null
 $foreignApp=Start-OwnedProcess -FilePath $foreignAppImage -ArgumentList '-t 127.0.0.1' -Purpose fixture
 $script:Harness=$main
 try{
  Rejected 'R2 manual-install foreign app refuses before setup starts' {Assert-HarnessInstallStart $foreignAppImage} {-not$foreignApp.process.HasExited}
 }finally{$script:Harness=$foreign.scope;Stop-HarnessProcess $foreignApp;$script:Harness=$main}
 $root=Fixture 'encoded-runners'
 Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RooSuspendedShell {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartInfo {public int cb; public string reserved,desktop,title; public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reserved2;public IntPtr data,input,output,error;}
 [StructLayout(LayoutKind.Sequential)] struct Info {public IntPtr process,thread;public int pid,tid;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string image,string command,IntPtr a,IntPtr b,bool inherit,int flags,IntPtr env,string directory,ref StartInfo start,out Info info);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public static int Start(string image,string arguments){var start=new StartInfo{cb=Marshal.SizeOf(typeof(StartInfo))};Info info;if(!CreateProcess(image,"\""+image+"\" "+arguments,IntPtr.Zero,IntPtr.Zero,false,4|0x08000000,IntPtr.Zero,null,ref start,out info))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());CloseHandle(info.thread);CloseHandle(info.process);return info.pid;}
}
'@
 foreach($switch in '-ec','/enc','-e'){
  $value=if($switch -eq '-e'){'%%%invalid%%%'}else{[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep 60 # '+$root))}
  $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $id=[RooSuspendedShell]::Start($shell,($switch+' '+$value));$ownedShell=Register-HarnessStartedProcess (Get-Process -Id $id) 'encoded-shell-fixture'
  try{Rejected ('R5 live suspended powershell '+$switch+' refuses frame clear') {Assert-HarnessFrameIdle $root} {Test-HarnessPath (Join-Path $root 'keep.txt')};if($rows[$rows.Count-1].observed -notlike 'Encoded PowerShell runner*'){throw 'The encoded fixture was refused by a different guard.'}}finally{Stop-HarnessProcess $ownedShell}
 }
 $payload=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($root))
 $pwsh=Get-Command pwsh.exe -ErrorAction SilentlyContinue
 if($pwsh){$id=[RooSuspendedShell]::Start($pwsh.Source,('--encodedcommand '+$payload));$ownedShell=Register-HarnessStartedProcess (Get-Process -Id $id) 'encoded-pwsh-fixture';try{Rejected 'R5 live suspended pwsh encoded command refuses frame clear' {Assert-HarnessFrameIdle $root} {Test-HarnessPath (Join-Path $root 'keep.txt')}}finally{Stop-HarnessProcess $ownedShell}}
 if(-not(Test-HarnessEncodedReference 'pwsh.exe' ('pwsh.exe --encodedcommand '+$payload) $root) -or -not(Test-HarnessEncodedReference 'PWSH.EXE' 'pwsh.exe /encodedarguments %%%' $root) -or -not(Test-HarnessEncodedReference 'pwsh.exe' 'pwsh.exe -e' $root)){throw 'pwsh or malformed encoded argument was missed'}
 Passed 'R5 pwsh decoder and malformed/missing values refuse' @{standIn=(-not[bool]$pwsh);image='pwsh.exe';switches=@('--encodedcommand','/encodedarguments','-e');refused=$true}
 $long=LongFrame $false
 $registered=Register-HarnessFile $long.path 'long-registration'
 if($registered.identity.hash -cne (Get-HarnessFileSha256 $long.path)){throw 'Long file registration hash differs'}
 $copy=Join-Path $long.unrecordedDirectory 'long-copy.json';Copy-HarnessFile $long.path $copy 'long-copy' 'invocation'|Out-Null
 if((Get-HarnessFileSha256 $copy) -cne (Get-HarnessFileSha256 $long.path)){throw 'Long copy bytes differ'}
 $result=Write-HarnessResult $long.unrecordedDirectory 'long-result.json' @{value='long result'}
 if((Read-HarnessResult $result $nonce).value -cne 'long result'){throw 'Long result read differs'}
 Passed 'CR10 long register/create/copy/result read use extended paths before normalization' @{path=$long.path;length=$long.path.Length;copy=$copy;result=$result}
 foreach($file in @($copy,$result)){$entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.identity.path -ieq $file -and $_.state -eq 'active'})[0];Remove-HarnessEntry $entry}
 Set-HarnessEntryState $registered.id 'removed'
 CloseLongFrame $long|Out-Null
 $status='pass'
}finally{
 $script:Harness=$main
 foreach($item in @($foreign.scope.Handles.Values)){if($item){$script:Harness=$foreign.scope;Stop-HarnessProcess $item;$script:Harness=$main}}
 $status=Complete-HarnessInvocation $status -Cleanup
 Write-HarnessResult $directory 'receipt.json' @{status=$status;checks=@($rows);nonce=$nonce}|Out-Null
}
'PASS '+$rows.Count+' owned fixture checks'
